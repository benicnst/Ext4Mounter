# Ext4Mounter v6.0 — 計画書

---

## ⚠️ プロジェクト絶対ルール（必ず守ること）

### 必須条件
- 完全にanylinuxfsの構成を真似たもの
- swiftアプリとして作成していってください
- 外部依存しない、スタンドアローンアプリです
- 自動マウントを備えたいが、まずはマウントできることを優先にめざします
- 読み書き1000Mbps以上を目指します
- VM使用率上昇によるフリーズ対策を
- 作業計画についてはPlan.mdに記録
- 毎回の作業終了時に作業記録としてJournal.mdへ記録すること
- リミット制限防止のために極力会話を残さず、他AIへの質問がある場合のみメッセージを残してください

### 禁止事項
| 禁止内容 | 理由 |
|----------|------|
| プロジェクトディレクトリ外へのファイル作成 | `~/tmp_*` 等 HOME 直下一時フォルダ厳禁 |
| シェルスクリプト・AppleScript の新規作成・実行 | 安全確保のため |
| ループ・パイプ複合コマンドの実行 | 安全確保のため（initramfs 再パックは例外として MEMORY.md に記録済み）|
| 安全確認前のアプリ起動 | フリーズ防止のため |

---

## 目的

anylinuxfs に依存しない **完全スタンドアロン** の macOS メニューバーアプリとして再設計する。
VZ.framework (Apple Virtualization.framework) で Alpine Linux microVM を起動し、
ext4 ドライブを NFS (over vsock proxy) 経由でホスト macOS にマウントする。

## 要件

| 項目 | 仕様 |
|------|------|
| アーキテクチャ | Swift / SwiftUI, VZ.framework, XPC helper |
| 外部依存 | なし (Homebrew / anylinuxfs 不要) |
| 性能目標 | 読み書き 1000 Mbps 以上 |
| 自動マウント | ドライブ挿入時に自動検出・自動マウント |
| VM フリーズ防止 | VZVirtualMachine を background vmQueue で動作 |
| NFS バージョン | NFSv4 のみ (VZ.framework は port 111 をブロックするため) |
| デバイス open | `/usr/libexec/authopen` (macOS 14+ では root XPC でも raw disk を open 不可) |

## アーキテクチャ概要

```
[DiskMonitor]   ext4 ディスク検出 (DiskArbitration)
     │
     ▼
[MountManager]  ディスクごとのライフサイクル管理 (ObservableObject)
     │
     ▼
[VZEngine]      Alpine Linux microVM の起動・マウント・停止
     │  ┌─── authopen → SCM_RIGHTS → device FD
     │  ├─── VZVirtualMachine (vmQueue: background serial)
     │  └─── VsockProxy (TCP 127.0.0.1:RANDOM ↔ guest vsock port 5000)
     │
     ▼
[XPCHelperClient] → [インストール済み PrivilegedHelper (root)]
                      └─── mount_nfs / umount
```

### vsock NFS トンネル

```
mount_nfs (host) → VsockProxy TCP → vmQueue: socketDevice.connect(5000)
                                              │
                                    (guest) vsock_fwd 5000→2049
                                              │
                                          rpc.nfsd TCP 2049
```

### virtiofs ステータス通知

- タグ: `"ext4share"`
- ホスト側: `~/Library/Caches/Ext4Mounter/<bsdName>/shared/`
- ゲスト側が `status.txt` に `"nfs_ready"` を書き込む → ホストがポーリングで検出

## ファイル構成

```
Ext4Mounter_v6.0/
├── PLAN.md                         ← 本ファイル
├── JOURNAL.md                      ← 作業履歴
├── Ext4Mounter.entitlements        ← VZ.framework + authopen 用
├── Ext4Mounter.app/                ← デプロイ先アプリバンドル
│   └── Contents/
│       ├── MacOS/Ext4Mounter       ← デプロイ済みバイナリ
│       ├── Info.plist
│       └── Resources/
│           ├── vmlinux-alpine-raw  ← Linux 6.14 ARM64 (v3.5 から流用)
│           └── initramfs-alpine.gz ← Alpine 3.23 initramfs (v3.5 から流用)
└── Ext4Mounter/                    ← Swift パッケージ
    ├── Package.swift
    └── Sources/
        ├── App/
        │   └── Ext4MounterApp.swift    ← MenuBarExtra UI / AppDelegate
        ├── Engine/
        │   ├── VZEngine.swift          ← VZ.framework コア
        │   ├── MountManager.swift      ← ObservableObject ディスク管理
        │   └── VsockProxy.swift        ← TCP ↔ vsock ブリッジ
        └── Shared/
            ├── Types.swift             ← 共有型定義
            ├── HelperXPC.swift         ← XPC プロトコル定義
            ├── ProcessRunner.swift     ← Process ラッパー
            ├── DiskMonitor.swift       ← DiskArbitration ラッパー
            └── XPCHelperClient.swift   ← XPC クライアント
```

## 実装フェーズ

### Phase 1: 基盤層 ✅ 完了
- [x] Package.swift / entitlements / Info.plist
- [x] Types.swift (MountStatus, Ext4Disk, Ext4MounterError, VMEngineConfig)
- [x] HelperXPC.swift, ProcessRunner.swift, DiskMonitor.swift
- [x] VsockProxy.swift, XPCHelperClient.swift

### Phase 2: エンジン層 ✅ 完了
- [x] VZEngine.swift (authopen FD取得, VM起動, vsock, NFS マウント)
- [x] MountManager.swift (ObservableObject, ライフサイクル管理)

### Phase 3: UI 層 ✅ 完了
- [x] Ext4MounterApp.swift (MenuBarExtra, DiskRow, AppDelegate)

### Phase 4: デプロイ・デバッグ ✅ 完了
- [x] ビルド成功
- [x] アプリバンドル構築 (kernel + initramfs コピー)
- [x] codesign

### Phase 5: バグ修正・動作確認 🔄 進行中
- [x] authopen でのデバイス FD 取得 (XPC helper の EPERM を回避)
- [x] VsockProxy に vmQueue パラメータ追加・dispatch_assert_queue_fail 修正
- [x] VZEngine.unmount の @MainActor ブロック修正（Thread.detachNewThread）
- [x] XPCHelperClient.ping 二重コールバック修正（once ガード）
- [x] 自動マウントデバッグコードの除去
- [x] CPUWatchdog 実装（閾値 80%/s, grace 10s）
- [x] EngineLog 永続ログ（~/Library/Logs/Ext4Mounter/engine.log）
- [x] フリーズ修正: CPUWatchdog 閾値 15%→80%
- [x] フリーズ修正: VsockProxy.start の DispatchQueue.main 依存除去
- [x] フリーズ修正: stopVMNow() の vmDied race condition 修正
- [x] フリーズ修正: メモリ 1024MB→512MB
- [x] initramfs init 修正: NFSv3 パスで NFSv4 も有効化（--nfs-version 3 除去）
- [ ] 動作確認: NFS マウント成功（ユーザーテスト待ち）

### Phase 6: 品質・性能検証 📋 未着手
- [ ] 1000 Mbps 読み書き性能確認
- [ ] アンマウント → 再マウントのサイクルテスト
- [ ] VM 異常停止時のリカバリ確認
- [ ] メニューバー UI の最終確認
