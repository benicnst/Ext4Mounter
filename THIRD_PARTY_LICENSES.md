# Third-Party Licenses

This file records third-party license obligations for the current Ext4Mounter worktree.

## Active dependency: apple/containerization

Repository:

- `https://github.com/apple/containerization`

Relevant module:

- `ContainerizationEXT4`

License:

- Apache License 2.0

Current use in Ext4Mounter:

- host-side ext4 preflight
- ext4 feature inspection

Planned future use:

- read-only recovery/export tooling
- ext4 test image generation

## Compliance notes

Because Ext4Mounter links against `apple/containerization`, keep the following in the repository and/or release materials:

- the Apache License 2.0 text
- copyright notices
- any required NOTICE content if provided upstream
- clear indication of local modifications where required by Apache 2.0 section 4

This is an open-source license compliance requirement, not a separate commercial Apple license.

## Source references checked on 2026-06-29

- `https://github.com/apple/containerization/blob/main/LICENSE`
- `https://github.com/apple/container/blob/main/LICENSE`

## Operational rule

Before each public release that includes `ContainerizationEXT4`, re-check upstream license files and add any missing third-party attribution files to the packaged app or release archive as needed.
