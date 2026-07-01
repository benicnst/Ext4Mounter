# App Template

`app/Ext4Mounter.app` is the local app-bundle template used by the build and release scripts.

It contains bundle metadata, resources, the LaunchDaemon plist, and locally staged binaries for validation.
Do not treat it as a release artifact.

Release outputs are generated under `dist/` by:

```bash
script/release_ext4mounter.sh
```

When `DEVELOPER_ID_APPLICATION` is not set, the script creates a local ad-hoc signed artifact for validation only.
When `DEVELOPER_ID_APPLICATION` and `NOTARY_PROFILE` are set, it creates the signed/notarized distribution artifact.
