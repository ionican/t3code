#!/bin/bash
set -euo pipefail

EXPECTED_BRANCH="codepanda/claude-account-failover"
EXPECTED_APP_ID="com.codepanda.t3code-auto"
EXPECTED_PRODUCT_NAME="T3 Code Auto"
EXPECTED_SCHEMES_JSON='["t3code-auto","t3code-auto-dev"]'
APPLICATIONS_ROOT="/Applications"
INSTALL_PATH="${APPLICATIONS_ROOT}/T3 Code Auto.app"
STATE_HOME="${HOME}/.t3-auto"
BACKUP_ROOT="${HOME}/.t3-auto-backups"
ELECTRON_DATA_ROOT="${HOME}/Library/Application Support"
LOCK_PATH="${HOME}/.cache/t3-auto-update.lock"
BACKUP_KEEP=3

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
STAGED_APP=""
PREVIOUS_APP=""
BACKUP_DIR=""
FINAL_BACKUP_DIR=""
INSTALL_PROMOTED=0
LOCK_HELD=0

cleanup() {
  local exit_status=$?
  local promotion_observed="${INSTALL_PROMOTED}"
  set +e
  # The staged-to-installed rename is atomic, but a signal can arrive before
  # the following shell assignment. A vanished staged path plus an installed
  # bundle is conservative evidence that promotion may have completed.
  if [[ "${promotion_observed}" -eq 0 && -n "${STAGED_APP}" && ! -e "${STAGED_APP}" && -d "${INSTALL_PATH}" ]]; then
    promotion_observed=1
  fi
  if [[ -n "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${PREVIOUS_APP}" && -d "${PREVIOUS_APP}" ]]; then
    if [[ ! -e "${INSTALL_PATH}" ]]; then
      mv "${PREVIOUS_APP}" "${INSTALL_PATH}" >/dev/null 2>&1 || true
    elif [[ -n "${BACKUP_DIR}" && ! -e "${BACKUP_DIR}/${EXPECTED_PRODUCT_NAME}.previous.app" ]]; then
      mv "${PREVIOUS_APP}" "${BACKUP_DIR}/${EXPECTED_PRODUCT_NAME}.previous.app" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${STAGED_APP}" && -d "${STAGED_APP}" ]]; then
    case "${STAGED_APP}" in
      "${APPLICATIONS_ROOT}"/.T3\ Code\ Auto.installing.*.app) rm -rf -- "${STAGED_APP}" ;;
    esac
  fi
  if [[ "${exit_status}" -ne 0 && "${promotion_observed}" -eq 0 && -n "${BACKUP_DIR}" &&
    ! -e "${BACKUP_DIR}/${EXPECTED_PRODUCT_NAME}.previous.app" ]]; then
    case "${BACKUP_DIR}" in
      "${BACKUP_ROOT}"/*.incomplete) rm -rf -- "${BACKUP_DIR}" ;;
    esac
  fi
  if [[ "${WORKTREE_ADDED}" -eq 1 ]]; then
    git -C "${REPO_ROOT}" worktree remove --force "${CANDIDATE_DIR}" >/dev/null 2>&1 || true
    git -C "${REPO_ROOT}" branch -D "${CANDIDATE_BRANCH}" >/dev/null 2>&1 || true
  else
    rmdir "${CANDIDATE_DIR}" >/dev/null 2>&1 || true
  fi
  if [[ "${LOCK_HELD}" -eq 1 ]]; then
    exec 9>&-
  fi
  return "${exit_status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

assert_app_stopped() {
  if pgrep -f '/T3 Code Auto.app/Contents/MacOS/' >/dev/null 2>&1; then
    printf 't3-auto-update: quit T3 Code Auto before updating it\n'
    return 1
  fi
  if launchctl print "gui/$(id -u)/com.codepanda.t3code-auto.service" >/dev/null 2>&1; then
    printf 't3-auto-update: turn off T3 Code Auto access-when-closed before updating it\n'
    return 1
  fi
}

acquire_update_lock() {
  mkdir -p "${LOCK_PATH%/*}"
  exec 9>"${LOCK_PATH}"
  if ! /usr/bin/lockf -s -t 0 9; then
    exec 9>&-
    printf 't3-auto-update: another update is already running\n'
    return 1
  fi
  LOCK_HELD=1
}

app_has_expected_identity() {
  local app_path="$1"
  local info_plist="${app_path}/Contents/Info.plist"
  local actual_app_id
  local actual_name
  local url_type_count
  local url_name
  local url_schemes
  [[ -f "${info_plist}" ]] || return 1
  actual_app_id="$(plutil -extract CFBundleIdentifier raw "${info_plist}" 2>/dev/null)" || return 1
  actual_name="$(plutil -extract CFBundleName raw "${info_plist}" 2>/dev/null)" || return 1
  url_type_count="$(plutil -extract CFBundleURLTypes raw "${info_plist}" 2>/dev/null)" || return 1
  url_name="$(plutil -extract CFBundleURLTypes.0.CFBundleURLName raw "${info_plist}" 2>/dev/null)" || return 1
  url_schemes="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes json -o - "${info_plist}" 2>/dev/null)" || return 1
  [[ "${actual_app_id}" == "${EXPECTED_APP_ID}" ]] || return 1
  [[ "${actual_name}" == "${EXPECTED_PRODUCT_NAME}" ]] || return 1
  [[ "${url_type_count}" == "1" ]] || return 1
  [[ "${url_name}" == "${EXPECTED_PRODUCT_NAME}" ]] || return 1
  [[ "${url_schemes}" == "${EXPECTED_SCHEMES_JSON}" ]]
}

reconcile_interrupted_install() {
  local recovery=""
  local candidate
  local name
  local stamp
  local interrupted_backup
  local completed_backup
  local staged_recovery=""

  for candidate in "${APPLICATIONS_ROOT}"/.T3\ Code\ Auto.previous.*.app; do
    [[ -d "${candidate}" ]] || continue
    [[ "${candidate##*/}" =~ ^\.T3\ Code\ Auto\.previous\.[0-9]{8}T[0-9]{6}Z\.app$ ]] || continue
    if codesign --verify --deep --strict "${candidate}" >/dev/null 2>&1 &&
      app_has_expected_identity "${candidate}" &&
      [[ -z "${recovery}" || "${candidate}" > "${recovery}" ]]; then
      recovery="${candidate}"
    fi
  done
  if [[ ! -e "${INSTALL_PATH}" && -n "${recovery}" ]]; then
    mv "${recovery}" "${INSTALL_PATH}"
    printf 't3-auto-update: restored the app left by an interrupted installation\n'
  fi

  if [[ ! -e "${INSTALL_PATH}" ]]; then
    for candidate in "${APPLICATIONS_ROOT}"/.T3\ Code\ Auto.installing.*.app; do
      [[ -d "${candidate}" ]] || continue
      [[ "${candidate##*/}" =~ ^\.T3\ Code\ Auto\.installing\.[0-9]{8}T[0-9]{6}Z\.[0-9]+\.app$ ]] || continue
      if codesign --verify --deep --strict "${candidate}" >/dev/null 2>&1 &&
        app_has_expected_identity "${candidate}"; then
        if [[ -z "${staged_recovery}" || "${candidate}" > "${staged_recovery}" ]]; then
          staged_recovery="${candidate}"
        fi
      fi
    done
    if [[ -n "${staged_recovery}" ]]; then
      mv "${staged_recovery}" "${INSTALL_PATH}"
      printf 't3-auto-update: promoted the signed app left by an interrupted first installation\n'
    fi
  fi

  for candidate in "${APPLICATIONS_ROOT}"/.T3\ Code\ Auto.previous.*.app; do
    [[ -d "${candidate}" ]] || continue
    name="${candidate##*/}"
    [[ "${name}" =~ ^\.T3\ Code\ Auto\.previous\.([0-9]{8}T[0-9]{6}Z)\.app$ ]] || continue
    if ! codesign --verify --deep --strict "${candidate}" >/dev/null 2>&1 ||
      ! app_has_expected_identity "${candidate}"; then
      printf 't3-auto-update: retained an invalid previous app for manual recovery: %s\n' "${candidate}"
      continue
    fi
    stamp="${BASH_REMATCH[1]}"
    interrupted_backup="${BACKUP_ROOT}/${stamp}.incomplete"
    completed_backup="${BACKUP_ROOT}/${stamp}"
    if [[ -d "${completed_backup}" ]]; then
      interrupted_backup="${completed_backup}"
    else
      mkdir -p "${interrupted_backup}"
    fi
    if [[ ! -e "${interrupted_backup}/${EXPECTED_PRODUCT_NAME}.previous.app" ]]; then
      mv "${candidate}" "${interrupted_backup}/${EXPECTED_PRODUCT_NAME}.previous.app"
      touch "${interrupted_backup}/.snapshot-complete"
    else
      printf 't3-auto-update: retained duplicate previous app for manual recovery: %s\n' "${candidate}"
    fi
  done

  for candidate in "${APPLICATIONS_ROOT}"/.T3\ Code\ Auto.installing.*.app; do
    [[ -d "${candidate}" ]] || continue
    [[ "${candidate##*/}" =~ ^\.T3\ Code\ Auto\.installing\.[0-9]{8}T[0-9]{6}Z\.[0-9]+\.app$ ]] || continue
    rm -rf -- "${candidate}"
  done

  if [[ -d "${BACKUP_ROOT}" ]]; then
    for candidate in "${BACKUP_ROOT}"/*.incomplete; do
      [[ -d "${candidate}" ]] || continue
      name="${candidate##*/}"
      [[ "${name}" =~ ^([0-9]{8}T[0-9]{6}Z)\.incomplete$ ]] || continue
      stamp="${BASH_REMATCH[1]}"
      completed_backup="${BACKUP_ROOT}/${stamp}"
      interrupted_backup="${candidate}/${EXPECTED_PRODUCT_NAME}.previous.app"
      if [[ -d "${interrupted_backup}" ]] &&
        { ! codesign --verify --deep --strict "${interrupted_backup}" >/dev/null 2>&1 ||
          ! app_has_expected_identity "${interrupted_backup}"; }; then
        printf 't3-auto-update: retained an incomplete backup with an invalid previous app: %s\n' "${candidate}"
        continue
      fi
      if [[ ! -e "${INSTALL_PATH}" && -d "${interrupted_backup}" ]]; then
        ditto "${interrupted_backup}" "${INSTALL_PATH}"
        codesign --verify --deep --strict "${INSTALL_PATH}"
        printf 't3-auto-update: restored the previous app from %s\n' "${candidate}"
      fi
      if [[ -f "${candidate}/.snapshot-complete" || -d "${interrupted_backup}" ]]; then
        if [[ ! -e "${completed_backup}" ]]; then
          mv "${candidate}" "${completed_backup}"
          printf 't3-auto-update: finalised the complete backup left by an interrupted installation\n'
        else
          printf 't3-auto-update: retained colliding incomplete backup for manual recovery: %s\n' "${candidate}"
        fi
      else
        rm -rf -- "${candidate}"
      fi
    done
  fi
}

prune_backups() {
  local kept=0
  local candidate
  local name
  [[ -d "${BACKUP_ROOT}" ]] || return
  while IFS= read -r candidate; do
    name="${candidate##*/}"
    [[ "${name}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
    kept=$((kept + 1))
    if [[ "${kept}" -gt "${BACKUP_KEEP}" ]]; then
      rm -rf -- "${candidate}"
    fi
  done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -print | sort -r)
}

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

acquire_update_lock
reconcile_interrupted_install
assert_app_stopped

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
# Electron 43 installs its binary lazily when lifecycle scripts are skipped by
# pnpm policy. Pre-install it once so parallel test workers cannot race while
# extracting the same Electron.app directory.
pnpm --filter @t3tools/desktop exec install-electron
pnpm exec vp test run \
  packages/contracts/src/orchestration.test.ts \
  apps/server/src/orchestration/decider.settled.test.ts \
  apps/server/src/cloud/bootService.test.ts \
  apps/server/src/project/RepositoryIdentityResolver.test.ts \
  apps/server/src/vcs/GitVcsDriver.test.ts \
  apps/server/src/vcs/VcsDriverRegistry.test.ts \
  apps/desktop/src/app/DesktopEnvironment.test.ts \
  apps/desktop/src/app/DesktopAppIdentity.test.ts \
  apps/desktop/src/app/DesktopClerk.test.ts \
  apps/desktop/src/app/DesktopEarlyElectronStartup.test.ts \
  apps/desktop/src/electron/ElectronProtocol.test.ts \
  apps/desktop/src/updates/DesktopUpdates.test.ts \
  apps/desktop/scripts/electron-launcher.test.mjs \
  apps/server/src/http.test.ts \
  apps/server/src/server.test.ts \
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

if ! app_has_expected_identity "${CANDIDATE_APP}"; then
  printf 't3-auto-update: packaged identity or URL schemes do not match the isolated fork\n'
  exit 1
fi
if [[ -e "${CANDIDATE_APP}/Contents/Resources/app-update.yml" ]]; then
  printf 't3-auto-update: packaged app unexpectedly contains an update feed\n'
  exit 1
fi

assert_app_stopped

BACKUP_DIR="${BACKUP_ROOT}/${STAMP}.incomplete"
FINAL_BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
test ! -e "${BACKUP_DIR}"
test ! -e "${FINAL_BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
if [[ -d "${STATE_HOME}/userdata" ]]; then
  mkdir -p "${BACKUP_DIR}/userdata"
  if [[ -f "${STATE_HOME}/userdata/state.sqlite" ]]; then
    # A clean WAL shutdown may remove -wal/-shm. SQLite cannot recreate those
    # sidecars through -readonly even though VACUUM INTO only reads the source.
    # The app/service stop guards above make a normal connection safe here.
    sqlite3 "${STATE_HOME}/userdata/state.sqlite" \
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
for electron_dir in "t3code-auto" "T3 Code Auto (Alpha)"; do
  if [[ -d "${ELECTRON_DATA_ROOT}/${electron_dir}" ]]; then
    mkdir -p "${BACKUP_DIR}/electron-userdata/${electron_dir}"
    rsync -a \
      "${ELECTRON_DATA_ROOT}/${electron_dir}/" \
      "${BACKUP_DIR}/electron-userdata/${electron_dir}/"
  fi
done
git -C "${REPO_ROOT}" merge --ff-only "${CANDIDATE_BRANCH}"

STAGED_APP="${APPLICATIONS_ROOT}/.T3 Code Auto.installing.${STAMP}.$$.app"
PREVIOUS_APP="${APPLICATIONS_ROOT}/.T3 Code Auto.previous.${STAMP}.app"
ditto "${CANDIDATE_APP}" "${STAGED_APP}"
codesign --force --deep --sign - "${STAGED_APP}"
codesign --verify --deep --strict "${STAGED_APP}"
assert_app_stopped
if [[ -d "${INSTALL_PATH}" ]]; then
  mv "${INSTALL_PATH}" "${PREVIOUS_APP}"
fi
if [[ -e "${INSTALL_PATH}" ]]; then
  printf 't3-auto-update: install destination reappeared during the guarded swap\n'
  exit 1
fi
if ! node -e 'require("node:fs").renameSync(process.argv[1], process.argv[2])' "${STAGED_APP}" "${INSTALL_PATH}"; then
  if [[ -d "${PREVIOUS_APP}" && ! -e "${INSTALL_PATH}" ]]; then
    mv "${PREVIOUS_APP}" "${INSTALL_PATH}"
  fi
  printf 't3-auto-update: installation failed; the previous app was restored\n'
  exit 1
fi
INSTALL_PROMOTED=1
STAGED_APP=""
if [[ -d "${PREVIOUS_APP}" ]]; then
  mv "${PREVIOUS_APP}" "${BACKUP_DIR}/${EXPECTED_PRODUCT_NAME}.previous.app"
fi
PREVIOUS_APP=""
touch "${BACKUP_DIR}/.snapshot-complete"

mv "${BACKUP_DIR}" "${FINAL_BACKUP_DIR}"
BACKUP_DIR="${FINAL_BACKUP_DIR}"

SOURCE_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
git -C "${REPO_ROOT}" tag -a "t3-auto-installed-${STAMP}" -m "Installed T3 Code Auto ${BUILD_VERSION}" "${SOURCE_SHA}"
prune_backups
printf 'Installed T3 Code Auto %s from %s\n' "${BUILD_VERSION}" "${SOURCE_SHA}"
printf 'Backup: %s\n' "${BACKUP_DIR}"
