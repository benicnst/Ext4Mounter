import Foundation
import Shared

/// Client for the privileged helper XPC service (com.ext4mounter.helper).
@available(macOS 13.0, *)
public final class XPCHelperClient {
    public static let shared = XPCHelperClient()
    private init() {}

    private func makeConn() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: "com.ext4mounter.helper", options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.resume()
        return c
    }

    // MARK: - mountNFS

    public func mountNFS(host: String, port: UInt16, exportPath: String,
                         mountPoint: String, options: String,
                         completion: @escaping (Bool, String) -> Void) {
        let conn = makeConn()
        let lock = NSLock(); var done = false
        let once: (Bool, String) -> Void = { ok, msg in
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }; done = true; completion(ok, msg)
        }
        conn.interruptionHandler  = { once(false, "XPC interrupted") }
        conn.invalidationHandler  = { once(false, "XPC invalidated — helper not running?") }

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ e in
            once(false, "XPC proxy error: \(e.localizedDescription)")
        }) as? HelperProtocol else { once(false, "XPC proxy cast failed"); return }

        proxy.mountNFS(host: host, port: Int(port), exportPath: exportPath,
                       mountPoint: mountPoint, options: options) { ok, msg in
            conn.invalidate(); once(ok, msg)
        }
    }

    // MARK: - unmountNFS

    public func unmountNFS(mountPoint: String, completion: @escaping (Bool, String) -> Void) {
        let conn = makeConn()
        let lock = NSLock(); var done = false
        let once: (Bool, String) -> Void = { ok, msg in
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }; done = true; completion(ok, msg)
        }
        // ③修正: interruptionHandler を追加（XPC 切断時に completion が呼ばれない問題を修正）
        conn.interruptionHandler  = { once(false, "XPC interrupted") }
        conn.invalidationHandler  = { once(false, "XPC invalidated") }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ e in
            once(false, "XPC proxy error: \(e.localizedDescription)")
        }) as? HelperProtocol else { once(false, "XPC proxy cast failed"); return }
        proxy.unmountNFS(mountPoint: mountPoint) { ok, msg in
            conn.invalidate(); once(ok, msg)
        }
    }

    // MARK: - openDiskDevice (returns UNIX socket path for SCM_RIGHTS FD pickup)

    public func openDiskDevice(devicePath: String,
                               completion: @escaping (Bool, String) -> Void) {
        let conn = makeConn()
        let lock = NSLock(); var done = false
        let once: (Bool, String) -> Void = { ok, msg in
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }; done = true; completion(ok, msg)
        }
        conn.interruptionHandler = { once(false, "XPC interrupted") }
        conn.invalidationHandler = { once(false, "XPC invalidated") }

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ e in
            once(false, "XPC proxy: \(e.localizedDescription)")
        }) as? HelperProtocol else { once(false, "cast failed"); return }

        proxy.openDiskDevice(devicePath: devicePath) { ok, msg in
            conn.invalidate(); once(ok, msg)
        }
    }

    // MARK: - getOpenFilesOnMount

    /// root ヘルパー経由で lsof を実行し、mountPoint 配下のオープンファイル一覧を返す。
    public func getOpenFilesOnMount(mountPoint: String, completion: @escaping ([String]) -> Void) {
        let conn = makeConn()
        conn.invalidationHandler = { completion([]) }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in completion([]) })
                as? HelperProtocol else { completion([]); return }
        proxy.getOpenFilesOnMount(mountPoint: mountPoint) { files in
            conn.invalidate(); completion(files)
        }
    }

    // MARK: - isClaimedDisk

    /// Helper が ext4 確認済みとしてクレームしているか問い合わせる。
    public func isClaimedDisk(bsdName: String, completion: @escaping (Bool) -> Void) {
        let conn = makeConn()
        let lock = NSLock(); var done = false
        let once: (Bool) -> Void = { ok in
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }; done = true; completion(ok)
        }
        conn.interruptionHandler = { once(false) }
        conn.invalidationHandler = { once(false) }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in once(false) })
                as? HelperProtocol else { once(false); return }
        proxy.isClaimedDisk(bsdName: bsdName) { result in
            conn.invalidate(); once(result)
        }
    }

    // MARK: - ping

    public func ping(reply: @escaping (Bool) -> Void) {
        let conn = makeConn()
        let lock = NSLock(); var done = false
        let once: (Bool) -> Void = { ok in
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }; done = true; reply(ok)
        }
        conn.interruptionHandler = { once(false) }
        conn.invalidationHandler = { once(false) }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ _ in once(false) })
                as? HelperProtocol else { once(false); return }
        proxy.getVersion { ver in
            elog("[XPCHelperClient] ping OK ver=\(ver)")
            conn.invalidate(); once(true)
        }
    }
}
