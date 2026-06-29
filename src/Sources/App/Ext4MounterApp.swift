import SwiftUI
import AppKit
import Engine
import Shared
import ServiceManagement

@available(macOS 14.0, *)
@main
struct Ext4MounterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(mountManager: appDelegate.mountManager, appDelegate: appDelegate)
        } label: {
            MenuBarIconView(mountManager: appDelegate.mountManager)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// MARK: - Visual Effect Background

/// NSVisualEffectView wrapper for SwiftUI — provides the system blurred/translucent background
/// used by all standard macOS menu bar panels (same as Spotlight, Control Center, etc.).
@available(macOS 14.0, *)
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material    = .popover
        v.state       = .active
        v.blendingMode = .behindWindow
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Menu Bar Icon

/// ZStack + opacity keeps the same view structure at all times.
/// Avoids the MenuBarExtra label disappearing bug when switching between icon types.
@available(macOS 14.0, *)
struct MenuBarIconView: View {
    @ObservedObject var mountManager: MountManager

    private var inProgress: Bool { mountManager.disks.contains { $0.status.isInProgress } }
    private var hasMounted: Bool { mountManager.disks.contains { $0.status == .mounted   } }

    var body: some View {
        ZStack {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .opacity(inProgress ? 1 : 0)

            Image(systemName: "externaldrive.fill.badge.checkmark")
                .foregroundColor(.green)
                .opacity(hasMounted && !inProgress ? 1 : 0)

            Image(systemName: "externaldrive")
                .foregroundColor(.secondary)
                .opacity(!hasMounted && !inProgress ? 1 : 0)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - App Delegate

@available(macOS 14.0, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let mountManager = MountManager()
    @Published var helperStatusText = "ヘルパー: 確認中..."
    @Published var helperNeedsAttention = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        EngineLog.shared.clear()
        elog("=== Ext4Mounter v1.2.5 started ===")
        elog("[App] log file: \(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Logs/Ext4Mounter/engine.log")

        refreshHelperStatus(attemptRegistration: true)

        mountManager.start()
        elog("[App] Disk monitoring started")
    }

    func refreshHelperStatus(attemptRegistration: Bool) {
        HelperServiceManager.refreshStatus(attemptRegistration: attemptRegistration,
                                           logger: { elog($0) }) { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.helperStatusText = snapshot.statusText
                self?.helperNeedsAttention = snapshot.needsAttention
                elog("[App] \(snapshot.statusText)")
            }
        }
    }

    /// Return .terminateLater when there are active NFS mounts so macOS waits for
    /// clean unmounting before the process actually exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {

        // ── Step 1: open-file guard ───────────────────────────────────────
        // root ヘルパー経由で lsof を実行（非 root では権限タイムアウトで遅い）。
        // 見つかった場合は警告ダイアログを表示し、キャンセルを促す。
        let mountedDisks = mountManager.disks.filter { $0.status == .mounted }
        for disk in mountedDisks {
            guard let mp = disk.mountPoint else { continue }

            // XPC は非同期だがここではセマフォで同期待ち（quit フローなので許容）
            // タイムアウト 2 秒: XPC が詰まってもメインスレッドが無限にフリーズしない
            let sem = DispatchSemaphore(value: 0)
            var openFiles: [String] = []
            XPCHelperClient.shared.getOpenFilesOnMount(mountPoint: mp) { files in
                openFiles = files; sem.signal()
            }
            let timedOut = sem.wait(timeout: .now() + 2) == .timedOut
            if timedOut {
                elog("[App] openFileGuard \(mp): XPC timeout — skipping open-file check")
                continue
            }

            elog("[App] openFileGuard \(mp): \(openFiles.count) open file(s)")
            guard !openFiles.isEmpty else { continue }

            let alert = NSAlert()
            alert.messageText = "ファイルが使用中です"
            let listed = openFiles.prefix(6).map { "・\($0)" }.joined(separator: "\n")
            let extra  = openFiles.count > 6 ? "\n… 他 \(openFiles.count - 6) 件" : ""
            alert.informativeText = """
                マウントしたボリュームを使用中のプロセスがあります。
                終了前にファイルを閉じてください。

                \(listed)\(extra)
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "キャンセル")     // .alertFirstButtonReturn
            alert.addButton(withTitle: "強制終了")        // .alertSecondButtonReturn

            if alert.runModal() == .alertFirstButtonReturn {
                elog("[App] Termination cancelled by user (open files)")
                return .terminateCancel
            }
            elog("[App] User chose force-quit despite open files")
            break
        }

        // ── Step 2: unmount then terminate ───────────────────────────────
        let hasActive = mountManager.disks.contains {
            $0.status == .mounted || $0.status == .mounting || $0.status == .starting
        }
        guard hasActive else {
            mountManager.stop()
            return .terminateNow
        }

        elog("[App] Active mounts found — unmounting before quit...")

        var replied = false
        func finish() {
            guard !replied else { return }
            replied = true
            mountManager.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        mountManager.unmountAll {
            elog("[App] All mounts released — terminating now")
            DispatchQueue.main.async { finish() }
        }

        // Safety net: force-terminate after 5 s
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            elog("[App] Unmount timeout — forcing termination")
            finish()
        }

        return .terminateLater
    }



    func applicationWillTerminate(_ notification: Notification) {
        elog("[App] Application terminated")
    }
}

// MARK: - Menu Bar Window View

@available(macOS 14.0, *)
struct MenuBarView: View {
    @ObservedObject var mountManager: MountManager
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ─────────────────────────────────────────────────────
            Text("Ext4Mounter v1.2.5")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            // ── Disk list ──────────────────────────────────────────────────
            if mountManager.disks.isEmpty {
                Text("ext4 デバイス未検出")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(mountManager.disks) { disk in
                    DiskRow(disk: disk, mountManager: mountManager)
                }
            }

            if appDelegate.helperNeedsAttention {
                Divider()
                HelperStatusRow(appDelegate: appDelegate)
            }

            // ── Quit ───────────────────────────────────────────────────────
            QuitRow()
        }
        .frame(width: 280)
        .background(VisualEffectBackground().ignoresSafeArea())
    }
}

// MARK: - Disk Row

@available(macOS 14.0, *)
struct DiskRow: View {
    let disk: Ext4Disk
    @ObservedObject var mountManager: MountManager
    @State private var isHovered = false

    private var isClickable: Bool {
        disk.status == .unmounted || disk.status == .error || disk.status == .mounted
    }

    private var actionLabel: String {
        switch disk.status {
        case .unmounted, .error:    return "マウント"
        case .mounted:              return "アンマウント"
        default:                    return ""
        }
    }

    private var preflightColor: Color {
        switch disk.preflight?.compatibility {
        case .readWriteReady:
            return .green
        case .caution:
            return .orange
        case .readOnlyRecommended:
            return .red
        case nil:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Left: status indicator
            Group {
                if disk.status.isInProgress {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else if disk.status == .mounted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if disk.status == .error {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 18)

            // Disk info
            VStack(alignment: .leading, spacing: 1) {
                Text(disk.displayName)
                    .font(.callout)
                    .lineLimit(1)
                Text(disk.formattedSize + " · " + disk.bsdName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let preflight = disk.preflightStatusLine {
                    Text(preflight)
                        .font(.caption2)
                        .foregroundColor(preflightColor)
                        .lineLimit(1)
                }
                if let note = disk.activityNote, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Right: action label
            if !disk.status.isInProgress && isClickable {
                Text(actionLabel)
                    .font(.callout)
                    .foregroundColor(isHovered ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHovered && isClickable
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in if isClickable { isHovered = hovering } }
        .onTapGesture {
            switch disk.status {
            case .unmounted, .error:
                mountManager.mount(bsdName: disk.bsdName)
            case .mounted:
                mountManager.unmount(bsdName: disk.bsdName)
            default:
                break
            }
        }
    }
}

// MARK: - Quit Row

@available(macOS 14.0, *)
struct QuitRow: View {
    @State private var isHovered = false

    var body: some View {
        HStack {
            Text("終了")
                .font(.callout)
            Spacer()
            Text("⌘Q")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { NSApplication.shared.terminate(nil) }
    }
}

@available(macOS 14.0, *)
struct HelperStatusRow: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("ヘルパー")
                .font(.callout)
            Text(appDelegate.helperStatusText)
                .font(.caption2)
                .foregroundColor(appDelegate.helperNeedsAttention ? .orange : .secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { appDelegate.refreshHelperStatus(attemptRegistration: true) }
    }
}
