# containerization integration plan

## goal

Adopt Apple's `ContainerizationEXT4` in a way that improves Ext4Mounter on macOS 26 without destabilizing the current writable VM mount path.

## implementation status

### phase 1: read-only preflight

Implemented with `ContainerizationEXT4`. The host-side module opens the candidate ext4 device and reads:

- superblock
- volume label
- uuid
- block size
- journal presence
- compat / incompat / ro-compat feature flags

Expected output:

- richer disk metadata in UI/logs
- early unsupported-volume rejection
- better mount failure diagnostics before VM boot

### phase 2: mount naming improvement

Partially implemented. Ext4 label data from preflight is used as the preferred naming source.

Priority order should become:

1. ext4 filesystem label
2. GPT/media name hint
3. bsd name fallback

### phase 3: recovery/export mode

Add a read-only host-side fallback mode using `EXT4Reader`:

- list directory contents
- inspect file metadata
- export selected files
- optional full archive export

This is not a Finder mount replacement.

### phase 4: test tooling

Use `ContainerizationEXT4` formatter support for synthetic test images:

- labeled volumes
- journaled and non-journaled volumes
- xattr cases
- symlinks / hard links
- feature-flag coverage

## packaging rule

The first implementation step should avoid rewriting the existing Linux guest path.
The safest architecture is hybrid:

- host-side preflight and recovery via `ContainerizationEXT4`
- writable Finder mount still handled by the Linux VM path

## dependency rule

`ContainerizationEXT4` is now an active dependency because the preflight code has landed.

## release rule

For every public release that includes `ContainerizationEXT4`:

- update `THIRD_PARTY_LICENSES.md`
- re-check upstream license files
- verify macOS 26 build requirements
- document minimum supported OS and Apple silicon assumptions clearly
