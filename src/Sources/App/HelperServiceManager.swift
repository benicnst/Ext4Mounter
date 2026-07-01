import Foundation
import Engine
import ServiceManagement

struct HelperServiceSnapshot {
    let statusText: String
    let needsAttention: Bool
}

enum HelperServiceManager {
    static let machServiceName = "com.ext4mounter.helper"
    static let daemonPlistName = "com.ext4mounter.helper.plist"

    static func refreshStatus(attemptRegistration: Bool,
                              logger: @escaping (String) -> Void,
                              completion: @escaping (HelperServiceSnapshot) -> Void) {
        pingWithRetry(remainingAttempts: 4, logger: logger) { ok in
            if ok {
                completion(HelperServiceSnapshot(statusText: "ヘルパー: 稼働中",
                                                 needsAttention: false))
                return
            }

            let snapshot = inspectRegistration(attemptRegistration: attemptRegistration, logger: logger)
            completion(snapshot)
        }
    }

    private static func pingWithRetry(remainingAttempts: Int,
                                      logger: @escaping (String) -> Void,
                                      completion: @escaping (Bool) -> Void) {
        XPCHelperClient.shared.ping { ok in
            if ok || remainingAttempts <= 1 {
                completion(ok)
                return
            }
            logger("[HelperService] helper ping failed; retrying before service registration changes")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                pingWithRetry(remainingAttempts: remainingAttempts - 1,
                              logger: logger,
                              completion: completion)
            }
        }
    }

    private static func inspectRegistration(attemptRegistration: Bool,
                                            logger: @escaping (String) -> Void) -> HelperServiceSnapshot {
        guard let service = daemonService() else {
            return HelperServiceSnapshot(
                statusText: "ヘルパー: 手動導入または署名済み配布版が必要",
                needsAttention: true
            )
        }

        let initialStatus = snapshot(for: service.status)
        logger("[HelperService] status=\(statusName(service.status)) bundle=\(Bundle.main.bundleURL.path)")
        if attemptRegistration,
           statusShouldResync(service.status) {
            if let resynced = resyncEnabledService(service, logger: logger) {
                return resynced
            }
        }

        if !attemptRegistration || !statusCanRegister(service.status) {
            return initialStatus
        }

        if let registered = registerService(service, logger: logger) {
            return registered
        }
        return HelperServiceSnapshot(statusText: "ヘルパー: 自動登録失敗", needsAttention: true)
    }

    private static func statusCanRegister(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .notRegistered, .notFound:
            return true
        default:
            return false
        }
    }

    private static func statusShouldResync(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    private static func registerService(_ service: SMAppService,
                                        logger: @escaping (String) -> Void) -> HelperServiceSnapshot? {
        do {
            try service.register()
            logger("[HelperService] register succeeded status=\(statusName(service.status))")
            return snapshot(for: service.status)
        } catch {
            let nsError = error as NSError
            logger("[HelperService] register failed domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            if nsError.domain == "SMAppServiceErrorDomain", nsError.code == 1 {
                return resyncEnabledService(service, logger: logger)
            }
            return nil
        }
    }

    private static func resyncEnabledService(_ service: SMAppService,
                                             logger: @escaping (String) -> Void) -> HelperServiceSnapshot? {
        do {
            try service.unregister()
            logger("[HelperService] removed stale helper registration")
            try service.register()
            logger("[HelperService] re-registered helper from \(Bundle.main.bundleURL.path) status=\(statusName(service.status))")
            return snapshot(for: service.status)
        } catch {
            let nsError = error as NSError
            logger("[HelperService] re-register failed domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            return HelperServiceSnapshot(statusText: "ヘルパー: 再登録失敗", needsAttention: true)
        }
    }

    private static func daemonService() -> SMAppService? {
        guard FileManager.default.fileExists(atPath: daemonPlistURL().path) else { return nil }
        return SMAppService.daemon(plistName: daemonPlistName)
    }

    private static func daemonPlistURL() -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(daemonPlistName)
    }

    private static func snapshot(for status: SMAppService.Status) -> HelperServiceSnapshot {
        switch status {
        case .enabled:
            return HelperServiceSnapshot(statusText: "ヘルパー: 登録済み", needsAttention: false)
        case .requiresApproval:
            return HelperServiceSnapshot(
                statusText: "ヘルパー: システム設定で承認待ち",
                needsAttention: true
            )
        case .notRegistered:
            return HelperServiceSnapshot(statusText: "ヘルパー: 未登録", needsAttention: true)
        case .notFound:
            return HelperServiceSnapshot(
                statusText: "ヘルパー: バンドル構成不足",
                needsAttention: true
            )
        @unknown default:
            return HelperServiceSnapshot(
                statusText: "ヘルパー: 状態不明",
                needsAttention: true
            )
        }
    }

    private static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
