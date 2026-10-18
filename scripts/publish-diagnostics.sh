#!/usr/bin/env bash
#
# Emit build diagnostics into the GitHub Actions job summary.
#
# Required env:
#   SOC
#   KSU_TYPE
#   KERNEL_BRANCH
#   MODULES_BRANCH
#   KERNEL_COMMIT
#   MODULES_COMMIT
#   GITHUB_STEP_SUMMARY
#
# Optional env:
#   SUSFS_REF
#   KERNEL_MAKE_FLAGS
#
set -euo pipefail

: "${SOC:?}"
: "${KSU_TYPE:?}"
: "${KERNEL_BRANCH:?}"
: "${MODULES_BRANCH:?}"
: "${GITHUB_STEP_SUMMARY:?}"

append_file_block() {
  local label="$1"
  local path="$2"

  [[ -f "$path" ]] || return 0

  echo "#### $label"
  echo '```text'
  cat "$path"
  echo '```'
  echo
}

{
  echo "### Build diagnostics"
  echo
  echo "- Root solution: ${KSU_TYPE}"
  echo "- Target: ${TARGET_NAME:-unknown}"
  echo "- Device codenames: ${DEVICE_CODENAMES:-unknown}"
  echo "- Accepted device IDs: ${DEVICE_NAMES:-unknown}"
  echo "- Branch: ${KERNEL_BRANCH}"
  echo "- Kernel commit: \`${KERNEL_COMMIT}\`"
  echo "- Modules branch: ${MODULES_BRANCH}"
  echo "- Modules commit: \`${MODULES_COMMIT}\`"
  echo "- Device kernel make flags: ${KERNEL_MAKE_FLAGS:-none}"
  echo "- ROM GKI module compatibility: ${ROM_GKI_MODULE_COMPAT:-0}"
  if [[ -n "${KSU_COMMIT:-}" ]]; then
    echo "- KernelSU repository: ${KSU_REPO:-unknown}"
    echo "- KernelSU ref: ${KSU_REF:-unknown}"
    echo "- KernelSU commit: \`${KSU_COMMIT}\`"
  fi
  if [[ -n "${SUSFS_REF:-}" ]]; then
    echo "- susfs ref: ${SUSFS_REF}"
    echo "- susfs commit: \`${SUSFS_COMMIT}\`"
    echo "- susfs version: v${SUSFS_VERSION:-unknown}"
  fi
  if [[ -n "${NOMOUNT_REF:-}" ]]; then
    echo "- NoMount ref: ${NOMOUNT_REF}"
    echo "- NoMount commit: \`${NOMOUNT_COMMIT}\`"
    echo "- NoMount version: v${NOMOUNT_VERSION:-unknown}"
  fi
  if [[ "${DROIDSPACES_SLOT:-off}" != "off" ]]; then
    echo "- Droidspaces kABI slot: ${DROIDSPACES_SLOT}"
    echo "- Droidspaces kernel series: ${DROIDSPACES_SERIES:-unknown}"
    echo "- Droidspaces patch commit: \`${DROIDSPACES_COMMIT:-unknown}\`"
    echo "- Droidspaces SYSVIPC patch: ${DROIDSPACES_PATCH_FILE:-unknown}"
    echo "- Droidspaces SYSVIPC patch SHA-256: ${DROIDSPACES_PATCH_SHA256:-unknown}"
    if [[ -n "${DROIDSPACES_POSIX_PATCH_FILE:-}" ]]; then
      echo "- Droidspaces POSIX_MQUEUE patch: ${DROIDSPACES_POSIX_PATCH_FILE}"
      echo "- Droidspaces POSIX_MQUEUE patch SHA-256: ${DROIDSPACES_POSIX_PATCH_SHA256:-unknown}"
    fi
    echo "- Droidspaces NTSync: ${DROIDSPACES_NTSYNC:-false}"
    if [[ "${DROIDSPACES_NTSYNC:-false}" == "true" ]]; then
      echo "- Droidspaces NTSync patch: ${DROIDSPACES_NTSYNC_PATCH:-unknown}"
      echo "- Droidspaces NTSync patch SHA-256: ${DROIDSPACES_NTSYNC_COMPAT_SHA256:-unknown}"
    fi
  fi
  echo

  if [[ -f "${SOC}/out/.config" ]]; then
    echo '#### .config snapshot'
    echo '```text'
    grep -E '^CONFIG_(MODULES|MODULE_UNLOAD|MODVERSIONS|MODULE_SIG|MODULE_SIG_FORCE|MODULE_SIG_PROTECT|MODULE_FORCE_LOAD|ARCH_INLINE_SPIN_LOCK|ARCH_INLINE_SPIN_UNLOCK|INLINE_SPIN_LOCK|UNINLINE_SPIN_UNLOCK|TRIM_UNUSED_KSYMS|KASAN|KASAN_GENERIC|KASAN_SW_TAGS|KASAN_HW_TAGS)=|^# CONFIG_(MODULE_SIG_FORCE|MODULE_SIG_PROTECT|MODULE_FORCE_LOAD|UNINLINE_SPIN_UNLOCK|TRIM_UNUSED_KSYMS|KASAN|KASAN_GENERIC|KASAN_SW_TAGS|KASAN_HW_TAGS) is not set$|^CONFIG_KSU=|^CONFIG_KSU_SUSFS|^CONFIG_KSU_MANUAL_HOOK|^CONFIG_NOMOUNT=|^CONFIG_SYSVIPC=|^CONFIG_POSIX_MQUEUE=|^CONFIG_IPC_NS=|^CONFIG_PID_NS=|^CONFIG_DEVTMPFS=|^CONFIG_NTSYNC=|^CONFIG_USER_NS=' "${SOC}/out/.config" || true
    echo '```'
    echo
  fi

  append_file_block "susfs-source-proof.txt" "${SOC}/susfs-source-proof.txt"
  append_file_block "susfs-hook-proof.txt"   "${SOC}/susfs-hook-proof.txt"
  append_file_block "susfs-proof.txt"        "${SOC}/susfs-proof.txt"
  append_file_block "nomount-source-proof.txt" "${SOC}/nomount-source-proof.txt"
  append_file_block "nomount-proof.txt"        "${SOC}/nomount-proof.txt"
  append_file_block "droidspaces-source-proof.txt" "${SOC}/droidspaces-source-proof.txt"
  append_file_block "droidspaces-ntsync-source-proof.txt" "${SOC}/droidspaces-ntsync-source-proof.txt"
  append_file_block "droidspaces-proof.txt"        "${SOC}/droidspaces-proof.txt"
} >> "$GITHUB_STEP_SUMMARY"
