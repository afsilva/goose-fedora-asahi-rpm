#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/aaif-goose/goose.git"
IMAGE_NAME="goose-fedora-desktop-builder:44"

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

# Compute next RPM iteration from existing dist artifacts before optional cleanup.
DESKTOP_VERSION="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "${GOOSE_DIR}/ui/desktop/package.json" | head -n1)"
if [[ -z "${DESKTOP_VERSION}" ]]; then
  echo "Could not determine Goose desktop version from ${GOOSE_DIR}/ui/desktop/package.json"
  exit 1
fi

MAX_ITERATION=0
for rpm in "${DIST_DIR}/goose-desktop-${DESKTOP_VERSION}-"*.aarch64.rpm; do
  [[ -e "$rpm" ]] || continue
  iter="$(basename "$rpm" | sed -E "s/^goose-desktop-${DESKTOP_VERSION}-([0-9]+)\.aarch64\.rpm$/\1/")"
  if [[ "$iter" =~ ^[0-9]+$ ]] && (( iter > MAX_ITERATION )); then
    MAX_ITERATION="$iter"
  fi
done
RPM_ITERATION=$((MAX_ITERATION + 1))
log "Using RPM release iteration: ${RPM_ITERATION} (version ${DESKTOP_VERSION})"

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
  -e RPM_ITERATION="${RPM_ITERATION}" \
  -v "${WORKTREE_DIR}":/work/goose:Z \
  -v "${DIST_DIR}":/work/dist:Z \
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

    RPM_TOPDIR="$(pwd)/out/rpmbuild"
    mkdir -p "${RPM_TOPDIR}/"{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    # Ensure license file is present in payload for %license
    if [[ -f "/work/goose/LICENSE" && ! -f "${APP_DIR}/LICENSE" ]]; then
      cp -f "/work/goose/LICENSE" "${APP_DIR}/LICENSE"
    fi

    # Build source tarball with stable top-level directory for rpmbuild %setup
    SRCROOT="${RPM_TOPDIR}/SOURCES/goose-desktop-${APP_VERSION}"
    rm -rf "${SRCROOT}"
    mkdir -p "${SRCROOT}"
    cp -a "${APP_DIR}"/. "${SRCROOT}/"
    tar -C "${RPM_TOPDIR}/SOURCES" -czf "${RPM_TOPDIR}/SOURCES/goose-desktop-${APP_VERSION}.tar.gz" "goose-desktop-${APP_VERSION}"

    cat > "${RPM_TOPDIR}/SPECS/goose-desktop.spec" <<EOF
Name:           goose-desktop
Version:        ${APP_VERSION}
Release:        ${RPM_ITERATION}%{?dist}
Summary:        Desktop AI agent application
License:        Apache-2.0
URL:            https://goose-docs.ai/
BuildArch:      aarch64
Source0:        %{name}-%{version}.tar.gz

%description
Goose Desktop application bundle for Fedora Asahi.

%prep
%setup -q -n %{name}-%{version}

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/usr/lib/goose
cp -a * %{buildroot}/usr/lib/goose/

# CLI/launcher wrapper for Linux conventions
mkdir -p %{buildroot}/usr/bin
cat > %{buildroot}/usr/bin/goose <<'WRAP'
#!/bin/sh
exec /usr/lib/goose/Goose "$@"
WRAP
chmod 0755 %{buildroot}/usr/bin/goose

# Desktop integration for GNOME app launcher
mkdir -p %{buildroot}/usr/share/applications
cat > %{buildroot}/usr/share/applications/goose.desktop <<'DESKTOP'
[Desktop Entry]
Name=Goose
Comment=Goose Desktop AI agent
Exec=/usr/bin/goose
Icon=goose
Terminal=false
Type=Application
Categories=Utility;Development;
StartupNotify=true
DESKTOP

# App icon for menu/launcher
mkdir -p %{buildroot}/usr/share/icons/hicolor/512x512/apps
if [ -f %{buildroot}/usr/lib/goose/resources/images/icon-512.png ]; then
  cp -f %{buildroot}/usr/lib/goose/resources/images/icon-512.png \
    %{buildroot}/usr/share/icons/hicolor/512x512/apps/goose.png
elif [ -f %{buildroot}/usr/lib/goose/resources/images/icon.png ]; then
  cp -f %{buildroot}/usr/lib/goose/resources/images/icon.png \
    %{buildroot}/usr/share/icons/hicolor/512x512/apps/goose.png
fi

%files
/usr/lib/goose
/usr/bin/goose
/usr/share/applications/goose.desktop
/usr/share/icons/hicolor/512x512/apps/goose.png

%changelog
* $(date "+%a %b %d %Y") Goose Fedora Asahi Builder <noreply@example.com> - ${APP_VERSION}-${RPM_ITERATION}
- Automated build
EOF

    rpmbuild -bb \
      --define "_topdir ${RPM_TOPDIR}" \
      --define "_build_id_links none" \
      --define "debug_package %{nil}" \
      --define "_enable_debug_packages 0" \
      --define "__os_install_post %{nil}" \
      "${RPM_TOPDIR}/SPECS/goose-desktop.spec"

    mkdir -p out/make/rpm/aarch64
    find "${RPM_TOPDIR}/RPMS/aarch64" -type f -name '*.rpm' -exec cp -f {} out/make/rpm/aarch64/ \;
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
