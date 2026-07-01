# Release Readiness

## Current state

The repository is prepared for a signed app bundle that contains:

- `Ext4Mounter.app`
- nested helper executable at `Contents/MacOS/com.ext4mounter.helper`
- LaunchDaemon plist at `Contents/Library/LaunchDaemons/com.ext4mounter.helper.plist`

The menu bar UI also reports helper status so release builds can distinguish:

- helper already running
- helper not registered
- helper approval required
- bundle missing service assets

## What is still required on this Mac

Distribution is blocked until both of these exist:

1. A valid `Developer ID Application` signing identity in Keychain
2. A saved `notarytool` keychain profile

As of 2026-06-29 this machine reports:

- `security find-identity -p codesigning -v` → `0 valid identities found`
- `xcrun notarytool history --keychain-profile <name>` → no saved profile

## Release command

Use:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="your-notary-profile"
export TEAM_ID="TEAMID"
script/release_ext4mounter.sh
```

If `NOTARY_PROFILE` is omitted, the script signs and packages but skips notarization.

## Expected Apple-side behavior

- The app bundle must be signed and notarized for distribution.
- LaunchDaemons registered through `SMAppService` require admin approval in System Settings.
- `/Applications` is the recommended installed location for distribution. The app now re-syncs stale helper registration if a copied bundle is launched from a different path.

## Authentication reality

Even with a finished signed release:

- helper installation/approval should become a one-time setup step
- raw ext4 device open still requires user authorization on first mount after attach

That raw-device prompt is the remaining unavoidable authorization in the current VM architecture.
