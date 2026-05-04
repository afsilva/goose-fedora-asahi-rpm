# Rebuild Prompts for Goose Fedora Asahi RPM Project

This file provides copy/paste prompts you can use with an AI coding agent to recreate or maintain this project.

---

## 1) Bootstrap the project structure

Use this when starting from an empty directory.

```text
Create a standalone project to build Goose Desktop RPMs for Fedora Asahi (aarch64) on macOS using Podman.

Requirements:
- Keep Goose source separate from packaging project files.
- Project layout:
  - source/         (auto-cloned Goose checkout; must be git-ignored)
  - container/      (Fedora Containerfile with all build deps)
  - scripts/        (one end-to-end build script)
  - dist/           (final RPM outputs)
- Add a top-level README explaining build flow and output.
- Add .gitignore so source/goose, source/goose-build-worktree, and dist/*.rpm are not committed.
```

---

## 2) Implement an end-to-end build script

Use this to regenerate/repair build automation.

```text
Create scripts/build-goose-desktop-rpm.sh with these behaviors:

1) Validate host tools (git, podman).
2) Clone Goose into source/goose if missing from:
   https://github.com/aaif-goose/goose.git
3) Refuse to proceed if source/goose has local changes.
4) Support flags:
   - --no-pull
   - --keep-artifacts
   - --jobs N (default 1)
5) On macOS, ensure Podman machine exists and is running.
6) Build Fedora builder image from container/Containerfile.
7) Build in a temporary git worktree (avoid dirtying source checkout).
8) Build goose-server in release mode with low-memory defaults.
9) Package desktop app (`pnpm run package`).
10) Build RPM using generated SPEC + rpmbuild (not electron-forge maker-rpm).
11) Force aarch64 only and fail on other architectures.
12) Export RPM artifacts into dist/.
13) Clean temporary worktree.
14) Ensure script is compatible with macOS bash 3.2 (avoid mapfile).
15) Auto-increment RPM `Release` via SPEC by inspecting existing dist artifacts for same Version.
```

---

## 3) Container requirements prompt

Use this to recreate the container reliably.

```text
Create container/Containerfile based on official Fedora image (fedora:44).
Install all dependencies needed to build Goose desktop RPM on aarch64, including:
- Core build tools: make, gcc, g++, pkgconfig, python3, cmake, ninja
- Rust toolchain: rust, cargo
- Node toolchain: nodejs, npm, pnpm 10.30.0
- RPM tools: rpm-build, rpmdevtools, rpmlint, fakeroot, dpkg, dpkg-dev
- Clang stack for bindgen/llama builds: clang, clang-devel, llvm, llvm-devel
- Linux desktop/electron deps: gtk/dbus/x11/libsecret/nss/alsa/etc dev packages

Set up non-root builder user using build args USER_ID/GROUP_ID.
```

---

## 4) RPM spec packaging prompt

Use this to enforce Linux/Fedora packaging conventions.

```text
In the generated SPEC/rpmbuild flow, ensure install layout includes:
- /usr/lib/goose                         (app bundle)
- /usr/bin/goose                         (launcher wrapper script)
- /usr/share/applications/goose.desktop  (GNOME app launcher)
- /usr/share/icons/hicolor/512x512/apps/goose.png (icon)

Also:
- Set License: Apache-2.0
- Keep BuildArch: aarch64
- Keep Release: <auto-increment>%{?dist}
- Disable build-id links if needed for bundled Electron binaries
- Preserve upstream runtime behavior for chrome-sandbox
```

---

## 5) Troubleshooting prompt

Use this when builds fail and you want agent-driven fixes.

```text
Diagnose and fix the build script/container for Fedora Asahi desktop RPM generation.
Context:
- Build runs in Podman on macOS.
- Must produce aarch64 RPM for Goose Desktop.
- Avoid modifying upstream Goose checkout permanently.

When analyzing failures:
1) Identify whether failure is host-side, container dependency, cargo compile, electron packaging, or rpmbuild/spec generation.
2) Apply the smallest durable fix in this project (container/ or scripts/).
3) Keep README in sync with new requirements.
4) Re-run until dist/*.rpm is produced.
```

---

## 6) Release prompt (GitHub)

Use this to publish the built RPM as a release asset.

```text
Using this repository, upload dist/*.rpm as binary assets to an existing GitHub release tag.
If gh CLI is unavailable in PATH, try common Homebrew path (/opt/homebrew/bin/gh).
If still unavailable, explain required setup and exact commands.
```

---

## 7) Reproducibility hardening prompt

Use this for security/reproducibility upgrades.

```text
Harden reproducibility for this build project:
- Pin Fedora base image by digest instead of mutable tag.
- Keep pnpm lockfile behavior strict (--frozen-lockfile).
- Document exact tool versions used at build time.
- Add checksum generation for output RPM in dist/.
- Keep all changes within this packaging repo (not upstream Goose).
```
