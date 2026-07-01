# Unsigned Distribution Policy

Ext4Mounter does not currently use a Developer ID certificate.

That means public builds cannot be notarized and will not pass Gatekeeper's default assessment.
This is an Apple platform limitation, not a packaging bug.

## Supported no-budget paths

### 1. Build from source

This is the recommended trust model for users who can build locally.

```bash
git clone https://github.com/benicnst/Ext4Mounter.git
cd Ext4Mounter
script/release_ext4mounter.sh
```

Without `DEVELOPER_ID_APPLICATION`, the script creates:

```text
dist/Ext4Mounter.app
dist/Ext4Mounter-v<version>-local-ad-hoc.zip
dist/SHA256SUMS.txt
```

The app is ad-hoc signed for local validation only.

### 2. Download a prerelease artifact

Prerelease artifacts are ad-hoc signed and not notarized.
Users should verify the checksum before opening the app:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

macOS may still block the app because it is not notarized.
Users who choose to run it must explicitly allow it in macOS security settings or remove the quarantine attribute themselves:

```bash
xattr -dr com.apple.quarantine Ext4Mounter.app
```

This is less polished than Developer ID distribution, but it is the honest no-budget route.

## Not supported

- Claiming that ad-hoc builds are notarized
- Bypassing Gatekeeper silently
- Asking users to install a custom trusted root certificate for general public distribution
- Reusing `dist/` as a long-term archive of old builds

## Release storage

`dist/` is always the latest generated local artifact.
Historical artifacts belong in GitHub Releases, not in the working tree.
