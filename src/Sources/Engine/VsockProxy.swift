import Foundation
import Virtualization

/// Bridges a localhost TCP port ↔ guest vsock port.
/// Used to tunnel NFSv3 (guest vsock:5000 → nfsd port 2049) to the host.
@available(macOS 14.0, *)
public class VsockProxy {

    private let socketDevice: VZVirtioSocketDevice
    private let guestVsockPort: UInt32
    private let label: String
    private let queue: DispatchQueue
    /// The queue on which VZVirtualMachine was created.
    /// VZ.framework requires socketDevice.connect(toPort:) to be called from this queue.
    private let vmQueue: DispatchQueue

    private var listenSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var connections: [ProxyConnection] = []

    public private(set) var localPort: UInt16 = 0

    public init(socketDevice: VZVirtioSocketDevice,
                guestPort: UInt32 = 5000,
                label: String = "nfs",
                vmQueue: DispatchQueue) {
        self.socketDevice = socketDevice
        self.guestVsockPort = guestPort
        self.label = label
        self.queue = DispatchQueue(label: "com.ext4mounter.vsock.\(label)", attributes: .concurrent)
        self.vmQueue = vmQueue
    }

    deinit { stop() }

    // MARK: - Start / Stop

    public func start(completion: @escaping (UInt16?) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { completion(nil); return }

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { completion(nil); return }

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port   = UInt16(0).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindOK = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard bindOK, listen(sock, 16) == 0 else { close(sock); completion(nil); return }

            var bound = sockaddr_in(); var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &blen) }
            }
            let port = UInt16(bigEndian: bound.sin_port)
            self.listenSocket = sock; self.localPort = port

            elog("[VsockProxy:\(self.label)] listening on 127.0.0.1:\(port)")

            let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: self.queue)
            src.setEventHandler  { [weak self] in self?.acceptConnection() }
            src.setCancelHandler { close(sock) }
            src.resume()
            self.listenSource = src

            completion(port)
        }
    }

    public func stop() {
        listenSource?.cancel(); listenSource = nil
        connections.forEach { $0.close() }; connections.removeAll()
        elog("[VsockProxy:\(label)] stopped")
    }

    // MARK: - Accept

    private func acceptConnection() {
        var ca = sockaddr_in(); var cl = socklen_t(MemoryLayout<sockaddr_in>.size)
        let cfd = withUnsafeMutablePointer(to: &ca) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenSocket, $0, &cl) }
        }
        guard cfd >= 0 else { return }

        // TCP_NODELAY: minimize latency for small NFS RPC request packets
        var nd: Int32 = 1
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))

        // Large TCP socket buffers to handle burst NFS reads (16 MB each).
        // macOS doubles SO_SNDBUF/SO_RCVBUF internally, so 16 MB → 32 MB effective.
        // Matches the pipe buffer (4 MB) × 8 in-flight requests for QD8 saturation.
        var tcpBuf: Int32 = 16 * 1024 * 1024
        setsockopt(cfd, SOL_SOCKET, SO_SNDBUF, &tcpBuf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &tcpBuf, socklen_t(MemoryLayout<Int32>.size))

        elog("[VsockProxy:\(label)] TCP accepted fd=\(cfd)")

        // VZ.framework vsock connect MUST be called from the queue the VM was created on.
        vmQueue.async { [weak self] in
            guard let self = self else { close(cfd); return }
            self.socketDevice.connect(toPort: self.guestVsockPort) { [weak self] result in
                guard let self = self else { close(cfd); return }
                switch result {
                case .success(let conn):
                    let vfd = Int32(conn.fileDescriptor)
                    elog("[VsockProxy:\(self.label)] vsock connected fd=\(vfd)")

                    // Large vsock socket buffers (16 MB each) — matches TCP side.
                    var vsockBuf: Int32 = 16 * 1024 * 1024
                    setsockopt(vfd, SOL_SOCKET, SO_SNDBUF, &vsockBuf,
                               socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(vfd, SOL_SOCKET, SO_RCVBUF, &vsockBuf,
                               socklen_t(MemoryLayout<Int32>.size))

                    let pc = ProxyConnection(tcpFD: cfd, vsockFD: vfd, vsockConn: conn)
                    self.queue.async(flags: .barrier) { self.connections.append(pc) }
                    pc.start { [weak self] in
                        self?.queue.async(flags: .barrier) {
                            self?.connections.removeAll { $0 === pc }
                        }
                    }
                case .failure(let e):
                    elog("[VsockProxy:\(self.label)] vsock connect failed: \(e)")
                    close(cfd)
                }
            }
        }
    }
}

// MARK: - ProxyConnection

/// Full-duplex bidirectional relay: TCP ↔ vsock.
///
/// Uses TWO dedicated threads — one per direction — so that large NFS response
/// data flowing vsock→TCP never blocks NFS request data flowing TCP→vsock.
/// This eliminates the head-of-line blocking that a single poll()-based loop
/// would create and allows the proxy to saturate vsock bandwidth (~2 Gbps).
@available(macOS 14.0, *)
private class ProxyConnection {
    private let tcpFD:   Int32
    private let vsockFD: Int32
    private let vsockConn: VZVirtioSocketConnection
    private let lock  = NSLock()
    private var closed = false
    private var onClose: (() -> Void)?

    init(tcpFD: Int32, vsockFD: Int32, vsockConn: VZVirtioSocketConnection) {
        self.tcpFD = tcpFD; self.vsockFD = vsockFD; self.vsockConn = vsockConn
    }

    func start(onClose: @escaping () -> Void) {
        self.onClose = onClose
        // Blocking I/O: each thread sleeps in read() until data arrives.
        // When closeOnce() shuts down both FDs, any blocked read() returns
        // immediately with n == 0 or errno == EBADF, ending the loop.
        Thread.detachNewThread { [self] in self.pipe(from: tcpFD,   to: vsockFD, label: "t→v") }
        Thread.detachNewThread { [self] in self.pipe(from: vsockFD, to: tcpFD,   label: "v→t") }
    }

    /// Unidirectional pipe: reads up to 4 MB at a time from `src`, writes to `dst`.
    /// Larger buffer = fewer read/write syscalls = higher sustained throughput.
    /// 4 MB matches the TCP+vsock socket buffer size set in acceptConnection(),
    /// so a single read() can drain an entire full buffer without partial reads.
    /// Calls closeOnce() on exit (idempotent — the second caller is a no-op).
    private func pipe(from src: Int32, to dst: Int32, label: String) {
        let bufSize = 4 * 1024 * 1024  // 4 MB — matches socket buffer, minimises syscall count
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer {
            buf.deallocate()
            closeOnce()
        }

        while !closed {
            let n = read(src, buf, bufSize)
            if n > 0 {
                if !writeAll(dst, buf, n) { return }
            } else if n == 0 {
                return  // clean EOF
            } else {
                if errno == EINTR { continue }
                return  // EBADF, ECONNRESET, etc. — peer already closed
            }
        }
    }

    private func writeAll(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>, _ count: Int) -> Bool {
        var written = 0
        while written < count {
            let w = write(fd, buf + written, count - written)
            if w > 0 {
                written += w
            } else if errno == EINTR {
                continue
            } else {
                return false  // EPIPE, EBADF, etc.
            }
        }
        return true
    }

    func close() { closeOnce() }

    private func closeOnce() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        // shutdown() unblocks any thread currently sleeping in read() on tcpFD
        shutdown(tcpFD, SHUT_RDWR); Darwin.close(tcpFD)
        // vsockConn.close() closes the vsock FD, waking the vsock reader thread
        vsockConn.close()
        onClose?()
    }
}
