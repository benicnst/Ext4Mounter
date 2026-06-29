import Foundation
import Engine
import ServiceManagement

@available(macOS 14.0, *)
struct HelperServiceSnapshot {
    let statusText: String
    let needsAttention: Bool
}

@available(macOS 14.0, *)
enum HelperServiceManager {
    static let machServiceName = "com.ext4mounter.helper"
    static let daemonPlistName = "com.ext4mounter.helper.plist"

    static func refreshStatus(attemptRegistration: Bool,
                              logger: @escaping (String) -> Void,
                              completion: @escaping (HelperServiceSnapshot) -> Void) {
        XPCHelperClient.shared.ping { ok in
            if ok {
                completion(HelperServiceSnapshot(statusText: "ヘルパー: 稼働中",
                                                 needsAttention: false))
                return
            }

            let snapshot = inspectRegistration(attemptRegistration: attemptRegistration, logger: logger)
            completion(snapshot)
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
        if !attemptRegistration || service.status != .notRegistered {
            return initialStatus
        }

        do {
            try service.register()
            let registered = snapshot(for: service.status)
            logger("[HelperService] register succeeded status=\(statusName(service.status))")
            return registered
        } catch {
            let nsError = error as NSError
            logger("[HelperService] register failed domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")

            let prefix: String
            if nsError.localizedDescription.localizedCaseInsensitiveContains("signature") {
                prefix = "ヘルパー: 署名/公証済み配布版で登録可能"
            } else if nsError.localizedDescription.localizedCaseInsensitiveContains("denied") {
                prefix = "ヘルパー: システム設定で承認が必要"
            } else {
                prefix = "ヘルパー: 自動登録失敗"
            }
            return HelperServiceSnapshot(statusText: prefix, needsAttention: true)
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
            if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
                return HelperServiceSnapshot(
                    statusText: "ヘルパー: /Applications 配置後に登録",
                    needsAttention: true
                )
            }
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
