# Goose Desktop RPM Builder for Fedora Asahi (aarch64)

This repository is a **packaging/build orchestration project**.
It is intentionally separate from Goose source code.

## Directory layout

- `source/` — upstream Goose checkout (auto-cloned, ignored by git)
- `container/` — Fedora build container definition
- `scripts/` — build orchestration scripts
- `dist/` — final RPM artifacts

## Goal

Produce Fedora Asahi-compatible (`aarch64`) Goose Desktop RPMs using Podman on macOS.

## Prerequisites (macOS)

```bash
brew install podman git
podman machine init   # first time
podman machine start
```

## Build

Run from this project root:

```bash
chmod +x scripts/build-goose-desktop-rpm.sh
./scripts/build-goose-desktop-rpm.sh
```

### Options

- `--no-pull` — build current checked-out Goose source without fetching/pulling
- `--keep-artifacts` — keep existing `dist/*.rpm` before exporting new artifacts
- `--jobs N` — set build parallelism inside container (default: `1`)

Examples:

```bash
./scripts/build-goose-desktop-rpm.sh --no-pull --jobs 1
./scripts/build-goose-desktop-rpm.sh --keep-artifacts
```

## What the script does

1. Clones/updates Goose into `source/goose`
2. Ensures Podman machine is initialized/running (macOS)
3. Builds Fedora builder image from `container/Containerfile`
4. Creates a temporary clean Goose worktree for build isolation
5. Builds `goosed` (Rust)
6. Packages Goose Desktop (Electron)
7. Builds an `aarch64` RPM via `fpm`
8. Copies RPM artifacts into `dist/`
9. Cleans temporary worktree

## Output

- `dist/*.rpm`

These are the artifacts to deploy on Fedora Asahi.

## Notes

- The build is pinned to `aarch64` and fails fast on other architectures.
- Some non-fatal platform/engine warnings from pnpm may appear during install/package.

## If build gets killed (OOM)

If you see `Killed` during `cargo build`, increase Podman VM resources:

```bash
podman machine stop
podman machine set --cpus 6 --memory 12288 --disk-size 80
podman machine start
```

Then rerun with low parallelism:

```bash
./scripts/build-goose-desktop-rpm.sh --jobs 1
```
