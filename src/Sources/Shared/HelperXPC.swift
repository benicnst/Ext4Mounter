import Foundation

/// XPC protocol for the privileged helper (com.ext4mounter.helper).
/// The helper runs as root (LaunchDaemon) and performs privileged operations.
@objc public protocol HelperProtocol {
    /// Returns helper version string.
    func getVersion(reply: @escaping (String) -> Void)

    /// Opens a raw block device as root and exposes the FD via UNIX socket + SCM_RIGHTS.
    /// reply(true, socketPath) — app must connect to socketPath and receive FD.
    /// reply(false, errorMessage) on failure.
    func openDiskDevice(devicePath: String, reply: @escaping (Bool, String) -> Void)

    /// Runs /sbin/mount_nfs as root.
    func mountNFS(host: String, port: Int, exportPath: String,
                  mountPoint: String, options: String,
                  reply: @escaping (Bool, String) -> Void)

    /// Runs /sbin/umount as root.
    func unmountNFS(mountPoint: String, reply: @escaping (Bool, String) -> Void)

    /// `lsof -n -P -F pcn` を root で実行し mountPoint 配下のオープンファイルを返す。
    /// 非 root では権限タイムアウトで遅いため root ヘルパー経由で実行する。
    /// reply: ["ProcessName  /Volumes/xxx/path", ...] 形式の文字列配列。
    func getOpenFilesOnMount(mountPoint: String, reply: @escaping ([String]) -> Void)

    /// Helper が DADiskClaim でクレーム済みか（= ext4 確認済みか）を返す。
    /// claimedDisks に bsdName が存在する → ext4、存在しない → ext4 でない。
    func isClaimedDisk(bsdName: String, reply: @escaping (Bool) -> Void)
}
