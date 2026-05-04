#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/aaif-goose/goose.git"
IMAGE_NAME="goose-fedora-desktop-builder:42"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_ROOT="${PROJECT_ROOT}/source"
GOOSE_DIR="${SOURCE_ROOT}/goose"
CONTAINERFILE="${PROJECT_ROOT}/container/Containerfile"
DIST_DIR="${PROJECT_ROOT}/dist"

NO_PULL=false
KEEP_ARTIFACTS=false
BUILD_JOBS=1

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --no-pull          Skip fetching/pulling latest source from upstream
  --keep-artifacts   Keep existing RPM files in ${DIST_DIR} (do not clean first)
  --jobs N           Rust/Cargo build jobs inside container (default: 1)
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-pull)
      NO_PULL=true
      shift
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS=true
      shift
      ;;
    --jobs)
      if [[ $# -lt 2 ]]; then
        echo "--jobs requires a numeric argument"
        exit 1
      fi
      BUILD_JOBS="$2"
      if ! [[ "${BUILD_JOBS}" =~ ^[0-9]+$ ]] || [[ "${BUILD_JOBS}" -lt 1 ]]; then
        echo "--jobs must be an integer >= 1"
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

log() {
  printf "\n[%s] %s\n" "$(date +"%H:%M:%S")" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1"
    exit 1
  fi
}

log "Validating host prerequisites"
require_cmd git
require_cmd podman

mkdir -p "${SOURCE_ROOT}" "${DIST_DIR}"

if [[ ! -d "${GOOSE_DIR}/.git" ]]; then
  log "Cloning Goose source into ${GOOSE_DIR}"
  git clone "${REPO_URL}" "${GOOSE_DIR}"
fi

log "Checking Goose source checkout"
cd "${GOOSE_DIR}"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Goose checkout has local changes at ${GOOSE_DIR}. Commit/stash/reset before running."
  exit 1
fi

if [[ "$NO_PULL" == false ]]; then
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    echo "Goose branch has no upstream tracking branch. Configure upstream or use --no-pull."
    exit 1
  fi

  log "Updating Goose source on ${CURRENT_BRANCH}"
  git fetch --prune --tags
  git pull --ff-only
else
  log "Skipping source update (--no-pull)"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  log "Ensuring Podman machine is initialized and running"

  MACHINE_LIST_RAW="$(podman machine list --format '{{.Name}}' 2>/dev/null || true)"
  MACHINE_LIST="$(printf '%s\n' "${MACHINE_LIST_RAW}" | sed -e 's/[[:space:]]//g' -e 's/\*$//' | sed '/^$/d')"

  if [[ -z "${MACHINE_LIST}" ]]; then
    podman machine init
    MACHINE_NAME="podman-machine-default"
  else
    # Prefer default machine if present, else pick first available machine.
    if printf '%s\n' "${MACHINE_LIST}" | grep -qx 'podman-machine-default'; then
      MACHINE_NAME="podman-machine-default"
    else
      MACHINE_NAME="$(printf '%s\n' "${MACHINE_LIST}" | head -n1)"
    fi
  fi

  MACHINE_STATE="$(podman machine inspect "${MACHINE_NAME}" --format '{{.State}}' 2>/dev/null || true)"
  if [[ "${MACHINE_STATE}" != "running" ]]; then
    podman machine start "${MACHINE_NAME}"
  fi
fi

log "Building Fedora builder image"
podman build \
  --build-arg USER_ID="$(id -u)" \
  --build-arg GROUP_ID="$(id -g)" \
  -t "${IMAGE_NAME}" \
  -f "${CONTAINERFILE}" \
  "${PROJECT_ROOT}"

if [[ "$KEEP_ARTIFACTS" == false ]]; then
  rm -f "${DIST_DIR}"/*.rpm
else
  log "Keeping existing artifacts in ${DIST_DIR} (--keep-artifacts)"
fi

WORKTREE_DIR="${SOURCE_ROOT}/goose-build-worktree"
if [[ -d "${WORKTREE_DIR}" ]]; then
  rm -rf "${WORKTREE_DIR}"
fi

log "Creating temporary clean worktree for build"
cd "${GOOSE_DIR}"
git worktree add --force "${WORKTREE_DIR}" HEAD >/dev/null

log "Running aarch64 RPM build in container"
podman run --rm -i \
  -e CARGO_BUILD_JOBS="${BUILD_JOBS}" \
  -e CARGO_INCREMENTAL=0 \
  -e RUSTFLAGS="-C codegen-units=1" \
  -e LIBCLANG_PATH="/usr/lib64" \
  -e npm_config_jobs="${BUILD_JOBS}" \
  -e npm_config_loglevel=warn \
  -v "${WORKTREE_DIR}":/work/goose:Z \
  -w /work/goose \
  "${IMAGE_NAME}" \
  bash -lc '
    set -euo pipefail

    ARCH="$(uname -m)"
    if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
      echo "This workflow is pinned to aarch64 for Fedora Asahi. Detected: $ARCH"
      exit 1
    fi

    echo "Container architecture: $ARCH"
    rustc --version
    cargo --version
    node --version
    pnpm --version

    cargo build --release -j "${CARGO_BUILD_JOBS}" -p goose-server

    mkdir -p ui/desktop/src/bin
    cp target/release/goosed ui/desktop/src/bin/

    cd ui
    pnpm install --frozen-lockfile --network-concurrency "${CARGO_BUILD_JOBS}"

    cd desktop

    # Build packaged Linux app directory first (more reliable), then create RPM via fpm.
    pnpm run package

    APP_DIR=$(find out -maxdepth 1 -type d -name "Goose-linux-*" | head -n1)
    if [[ -z "${APP_DIR}" ]]; then
      echo "Could not find packaged app directory under ui/desktop/out"
      find out -maxdepth 3 -type d | sed "s#^#  #"
      exit 1
    fi

    APP_VERSION=$(node -p "require(\"./package.json\").version")

    mkdir -p out/make/rpm/aarch64

    # rpmlint hygiene adjustments that do not alter runtime behavior
    rm -f "${APP_DIR}/resources/bin/.gitkeep" || true
    find "${APP_DIR}" -type f -perm -002 -exec chmod o-w {} +
    find "${APP_DIR}" -type f -perm -020 -exec chmod g-w {} +

    # rpmlint compatibility fixes for bundled Electron assets
    if [[ -f "${APP_DIR}/chrome-sandbox" ]]; then
      chmod u-s,g-s "${APP_DIR}/chrome-sandbox"
      chmod 0755 "${APP_DIR}/chrome-sandbox"
    fi
    if [[ -f "${APP_DIR}/resources/images/prepare.sh" ]]; then
      sed -i "1s|^#! */usr/bin/env sh$|#!/bin/sh|" "${APP_DIR}/resources/images/prepare.sh"
      chmod 0755 "${APP_DIR}/resources/images/prepare.sh"
    fi

    fpm -s dir -t rpm \
      -n goose-desktop \
      -v "${APP_VERSION}" \
      --iteration 1 \
      --architecture aarch64 \
      --description "Desktop AI agent application" \
      --license "Apache-2.0" \
      --url "https://goose-docs.ai/" \
      --maintainer "AAIF (Agentic AI Foundation)" \
      --rpm-os linux \
      --prefix /usr/lib/goose \
      -C "${APP_DIR}" \
      --rpm-rpmbuild-define "_build_id_links none" \
      .

    mv -f ./*.rpm out/make/rpm/aarch64/
  '

log "Collecting RPM artifacts"
RPM_LIST_FILE="$(mktemp)"
find "${WORKTREE_DIR}/ui/desktop/out/make" -type f -name '*.rpm' | sort > "${RPM_LIST_FILE}"

if [[ ! -s "${RPM_LIST_FILE}" ]]; then
  echo "No RPM artifacts found under ${WORKTREE_DIR}/ui/desktop/out/make"
  rm -f "${RPM_LIST_FILE}"
  git -C "${GOOSE_DIR}" worktree remove --force "${WORKTREE_DIR}" || true
  exit 1
fi

while IFS= read -r rpm; do
  cp -f "$rpm" "${DIST_DIR}/"
  echo "Exported: ${DIST_DIR}/$(basename "$rpm")"
done < "${RPM_LIST_FILE}"

rm -f "${RPM_LIST_FILE}"

log "Cleaning temporary build worktree"
git -C "${GOOSE_DIR}" worktree remove --force "${WORKTREE_DIR}" >/dev/null || true

log "Done"
echo "Asahi-ready aarch64 RPM(s):"
ls -1 "${DIST_DIR}"/*.rpm
