#!/bin/bash
set -euo pipefail

EXPECTED_BRANCH="codepanda/claude-account-failover"
EXPECTED_APP_ID="com.codepanda.t3code-auto"
EXPECTED_PRODUCT_NAME="T3 Code Auto"
EXPECTED_SCHEME="t3code-auto"
INSTALL_PATH="/Applications/T3 Code Auto.app"
STATE_HOME="${HOME}/.t3-auto"
BACKUP_ROOT="${HOME}/.t3-auto-backups"

SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_PATH}" ]]; do
  LINK_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
  SCRIPT_PATH="$(readlink "${SCRIPT_PATH}")"
  [[ "${SCRIPT_PATH}" = /* ]] || SCRIPT_PATH="${LINK_DIR}/${SCRIPT_PATH}"
done
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
ACTIVE_BRANCH="$(git -C "${REPO_ROOT}" branch --show-current)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CANDIDATE_BRANCH="codepanda/t3-auto-candidate-${STAMP}"
CANDIDATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/t3-auto-update.XXXXXX")"
MOUNT_POINT=""
WORKTREE_ADDED=0

cleanup() {
  if [[ -n "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
  if [[ "${WORKTREE_ADDED}" -eq 1 ]]; then
    git -C "${REPO_ROOT}" worktree remove --force "${CANDIDATE_DIR}" >/dev/null 2>&1 || true
    git -C "${REPO_ROOT}" branch -D "${CANDIDATE_BRANCH}" >/dev/null 2>&1 || true
  else
    rmdir "${CANDIDATE_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "${1:-}" == "--help" ]]; then
  printf 'Usage: t3-auto-update\n'
  printf 'Fetch upstream/main, verify a candidate build, back up T3 Code Auto, and install it.\n'
  exit 0
fi

if [[ "$#" -ne 0 ]]; then
  printf 't3-auto-update: unknown argument: %s\n' "$1"
  exit 2
fi

if [[ "${ACTIVE_BRANCH}" != "${EXPECTED_BRANCH}" ]]; then
  printf 't3-auto-update: expected branch %s, found %s\n' "${EXPECTED_BRANCH}" "${ACTIVE_BRANCH:-detached}"
  exit 1
fi

if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
  printf 't3-auto-update: the fork worktree has uncommitted changes\n'
  exit 1
fi

if pgrep -f '/T3 Code Auto.app/Contents/MacOS/' >/dev/null 2>&1; then
  printf 't3-auto-update: quit T3 Code Auto before updating it\n'
  exit 1
fi
if launchctl print "gui/$(id -u)/com.codepanda.t3code-auto.service" >/dev/null 2>&1; then
  printf 't3-auto-update: turn off T3 Code Auto access-when-closed before updating it\n'
  exit 1
fi

git -C "${REPO_ROOT}" fetch upstream main
git -C "${REPO_ROOT}" worktree add -b "${CANDIDATE_BRANCH}" "${CANDIDATE_DIR}" HEAD
WORKTREE_ADDED=1

if ! git -C "${CANDIDATE_DIR}" merge --no-edit upstream/main; then
  git -C "${CANDIDATE_DIR}" merge --abort >/dev/null 2>&1 || true
  printf 't3-auto-update: upstream conflicts with the local fork; nothing was installed\n'
  exit 1
fi

export NVM_DIR="${HOME}/.nvm"
if [[ ! -s "${NVM_DIR}/nvm.sh" ]]; then
  printf 't3-auto-update: nvm is required at %s\n' "${NVM_DIR}/nvm.sh"
  exit 1
fi
# shellcheck source=/dev/null
. "${NVM_DIR}/nvm.sh"
nvm use 24.13.1 >/dev/null
corepack enable

cd "${CANDIDATE_DIR}"
pnpm install --frozen-lockfile
pnpm exec vp test run \
  packages/contracts/src/orchestration.test.ts \
  apps/server/src/orchestration/decider.settled.test.ts \
  apps/server/src/cloud/bootService.test.ts \
  apps/desktop/src/app/DesktopEnvironment.test.ts \
  apps/desktop/src/app/DesktopAppIdentity.test.ts \
  apps/desktop/src/app/DesktopEarlyElectronStartup.test.ts \
  apps/desktop/src/electron/ElectronProtocol.test.ts \
  apps/desktop/src/updates/DesktopUpdates.test.ts \
  scripts/build-desktop-artifact.test.ts
pnpm exec vp run \
  --filter @t3tools/contracts \
  --filter t3 \
  --filter @t3tools/desktop \
  --concurrency-limit 2 \
  typecheck

BASE_VERSION="$(node -p "require('./apps/server/package.json').version")"
BUILD_VERSION="${BASE_VERSION}-pr.codepanda.${STAMP}"
unset GITHUB_REPOSITORY
unset T3CODE_DESKTOP_UPDATE_REPOSITORY
unset T3CODE_DESKTOP_MOCK_UPDATES
pnpm exec node scripts/build-desktop-artifact.ts \
  --platform mac \
  --target dmg \
  --arch arm64 \
  --build-version "${BUILD_VERSION}" \
  --output-dir release-codepanda

DMG_PATH="$(find "${CANDIDATE_DIR}/release-codepanda" -maxdepth 1 -type f -name 'T3-Code-Auto-*.dmg' -print -quit)"
if [[ -z "${DMG_PATH}" ]]; then
  printf 't3-auto-update: the build produced no T3 Code Auto DMG\n'
  exit 1
fi

MOUNT_POINT="$(hdiutil attach -nobrowse -readonly "${DMG_PATH}" | awk '/\/Volumes\// { print substr($0, index($0, "/Volumes/")); exit }')"
CANDIDATE_APP="${MOUNT_POINT}/${EXPECTED_PRODUCT_NAME}.app"
INFO_PLIST="${CANDIDATE_APP}/Contents/Info.plist"
if [[ ! -f "${INFO_PLIST}" ]]; then
  printf 't3-auto-update: the DMG does not contain %s.app\n' "${EXPECTED_PRODUCT_NAME}"
  exit 1
fi

ACTUAL_APP_ID="$(plutil -extract CFBundleIdentifier raw "${INFO_PLIST}")"
ACTUAL_NAME="$(plutil -extract CFBundleName raw "${INFO_PLIST}")"
URL_TYPES="$(plutil -extract CFBundleURLTypes xml1 -o - "${INFO_PLIST}")"
if [[ "${ACTUAL_APP_ID}" != "${EXPECTED_APP_ID}" || "${ACTUAL_NAME}" != "${EXPECTED_PRODUCT_NAME}" ]]; then
  printf 't3-auto-update: packaged identity mismatch (%s, %s)\n' "${ACTUAL_APP_ID}" "${ACTUAL_NAME}"
  exit 1
fi
if [[ "${URL_TYPES}" != *"${EXPECTED_SCHEME}"* ]]; then
  printf 't3-auto-update: packaged URL scheme is missing\n'
  exit 1
fi
if [[ -e "${CANDIDATE_APP}/Contents/Resources/app-update.yml" ]]; then
  printf 't3-auto-update: packaged app unexpectedly contains an update feed\n'
  exit 1
fi

BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
mkdir -p "${BACKUP_DIR}"
if [[ -d "${STATE_HOME}/userdata" ]]; then
  mkdir -p "${BACKUP_DIR}/userdata"
  if [[ -f "${STATE_HOME}/userdata/state.sqlite" ]]; then
    sqlite3 -readonly "${STATE_HOME}/userdata/state.sqlite" \
      "VACUUM INTO '${BACKUP_DIR}/userdata/state.sqlite';"
  fi
  rsync -a \
    --exclude state.sqlite \
    --exclude state.sqlite-wal \
    --exclude state.sqlite-shm \
    --exclude server-runtime.json \
    --exclude logs \
    "${STATE_HOME}/userdata/" "${BACKUP_DIR}/userdata/"
fi
git -C "${REPO_ROOT}" merge --ff-only "${CANDIDATE_BRANCH}"

STAGED_APP="/Applications/.T3 Code Auto.installing.$$.app"
ditto "${CANDIDATE_APP}" "${STAGED_APP}"
if [[ -d "${INSTALL_PATH}" ]]; then
  mv "${INSTALL_PATH}" "${BACKUP_DIR}/${EXPECTED_PRODUCT_NAME}.previous.app"
fi
if ! mv "${STAGED_APP}" "${INSTALL_PATH}"; then
  if [[ -d "${BACKUP_DIR}/${EXPECTED_PRODUCT_NAME}.previous.app" ]]; then
    mv "${BACKUP_DIR}/${EXPECTED_PRODUCT_NAME}.previous.app" "${INSTALL_PATH}"
  fi
  printf 't3-auto-update: installation failed; the previous app was restored\n'
  exit 1
fi

SOURCE_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
git -C "${REPO_ROOT}" tag -a "t3-auto-installed-${STAMP}" -m "Installed T3 Code Auto ${BUILD_VERSION}" "${SOURCE_SHA}"
printf 'Installed T3 Code Auto %s from %s\n' "${BUILD_VERSION}" "${SOURCE_SHA}"
printf 'Backup: %s\n' "${BACKUP_DIR}"
