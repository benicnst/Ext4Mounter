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
  - local packaged app output is ignored from git
- `docs/`
  - project notes and development journal
- `assets/`
  - icon sources and previews

## Status

- Current tracked version: `v1.2.5`
- Project is under active reorganization for public release

## Apple container roadmap

Apple's `apple/container` and `apple/containerization` are relevant future inputs for this project.
The near-term plan is to evaluate them for:

- ext4 feature preflight before VM boot
- ext4 image creation and test tooling
- possible read-only metadata access on the host side

The current VM-based mount path remains the primary implementation.

## Build notes

The Swift package lives under `src/`.
This repo currently keeps development notes and packaging files alongside the source tree.
