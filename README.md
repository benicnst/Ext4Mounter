# Ext4Mounter

Ext4Mounter is a macOS menu bar app for mounting Linux ext4 volumes through an embedded lightweight VM.

## Current architecture

- Host app detects candidate Linux disks
- A Virtualization.framework guest mounts the ext4 volume
- The guest exports the mounted filesystem over NFS
- The macOS host mounts that export for Finder access

## Repository layout

- `src/`
  - Swift package source
- `app/`
  - signing entitlements
  - local app-bundle template used by packaging scripts
- `dist/`
  - generated release or local validation artifacts
  - ignored from git and safe to recreate
- `docs/`
  - public design and release notes
- `assets/`
  - icon sources and previews

## Status

- Current tracked version: `v1.2.6`
- Public developer preview
- External unmount reconciliation is implemented
- Helper status is surfaced in the menu bar UI

## Authentication model

Ext4Mounter currently has two different privilege domains:

- `PrivilegedHelper` for disk dialog suppression and host-side NFS mount/unmount
- `authopen` for the actual raw ext4 device FD used by the VM

What is expected today:

- One-time helper installation or approval for a signed release build
- One user authorization when a newly attached raw ext4 device is opened

What is already reduced:

- Re-mounting within the same attach session reuses the cached FD and skips Touch ID / password
- External unmounts initiated from macOS are detected and reconciled automatically

What cannot currently be removed in the VM architecture:

- The raw disk open authorization for `/dev/rdisk*`

Reason:

- macOS denies raw block-device open from the root helper context on current systems
- The app falls back to `authopen -extauth`, which is the working Apple-supplied path

## Helper packaging

The app bundle now carries:

- `Contents/MacOS/com.ext4mounter.helper`
- `Contents/Library/LaunchDaemons/com.ext4mounter.helper.plist`

This is intended for `SMAppService`-based release packaging.
For notarized releases placed in `/Applications`, the app can surface helper registration state and guide approval.

## Apple container roadmap

Apple's `apple/container` and `apple/containerization` are relevant future inputs for this project.
The near-term plan is to evaluate them for:

- ext4 feature preflight before VM boot
- ext4 image creation and test tooling
- possible read-only metadata access on the host side

The current VM-based mount path remains the primary implementation.

See also:

- `docs/containerization_integration_plan.md`
- `THIRD_PARTY_LICENSES.md`

## Build notes

The Swift package lives under `src/`.
This repo currently keeps development notes and packaging files alongside the source tree.

## Release notes

Release packaging is scripted in:

- `script/release_ext4mounter.sh`

Without `DEVELOPER_ID_APPLICATION`, the script creates a local ad-hoc signed `dist/` artifact for validation only.
With `DEVELOPER_ID_APPLICATION` and `NOTARY_PROFILE`, it creates the signed/notarized distribution artifact.

Distribution readiness notes live in:

- `docs/release_readiness.md`
