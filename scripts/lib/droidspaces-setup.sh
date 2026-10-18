#!/usr/bin/env bash
#
# Droidspaces container support integration helpers. Sourced, not executed.
# Depends on lib/git-helpers.sh for git_fetch_retry.
#
# Droidspaces needs CONFIG_SYSVIPC, CONFIG_POSIX_MQUEUE, the IPC and PID
# namespaces and devtmpfs. On Android GKI-derived kernels those options move
# fields inside core structures, so every kernel family below 6.12 needs the
# upstream kABI padding patch that parks the SYSVIPC fields in the Android
# kABI reservation area. Kernels 5.10 and older additionally move the
# POSIX_MQUEUE accounting field into ABI padding.
#
# The patch selection is driven by the real kernel Makefile version instead of
# the device profile, because the selected source branch is authoritative.
#

droidspaces_series_at_least() {
  local series="$1"
  local floor="$2"

  [[ "$(printf '%s\n' "$floor" "$series" | sort -V | head -n 1)" == "$floor" ]]
}

detect_kernel_series() {
  local makefile="${1:-Makefile}"
  local version patchlevel

  [[ -f "$makefile" ]] || {
    echo "::error::Cannot detect the kernel series: $makefile is missing."
    return 1
  }

  version="$(sed -nE 's/^VERSION[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$makefile" | head -n 1)"
  patchlevel="$(sed -nE 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$makefile" | head -n 1)"

  if [[ ! "$version" =~ ^[0-9]+$ || ! "$patchlevel" =~ ^[0-9]+$ ]]; then
    echo "::error::Cannot detect the kernel series from $makefile."
    return 1
  fi

  printf '%s.%s\n' "$version" "$patchlevel"
}

# Relative path of the kABI patch inside the pinned Droidspaces-OSS checkout.
droidspaces_gki_patch_relpath() {
  local series="$1"
  local slot_name="$2"

  if droidspaces_series_at_least "$series" "6.12"; then
    printf '%s\n' \
      "Documentation/resources/kernel-patches/GKI/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch"
    return 0
  fi

  case "$series" in
    5.10|5.15|6.1|6.6)
      printf '%s\n' \
        "Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_${slot_name}.patch"
      ;;
    *)
      echo "::error::Droidspaces has no kABI patch mapping for kernel ${series}." >&2
      return 1
      ;;
  esac
}

droidspaces_posix_patch_relpath() {
  printf '%s\n' \
    "Documentation/resources/kernel-patches/GKI/below-kernel-6.12/002.5.10_or_lower_use_android_abi_padding_for_posix_mqueue.patch"
}

# The 5.10 OnePlus/OxygenOS 14 kernel has a different POSIX_MQUEUE layout from
# the Android 12 5.10 tree, and the upstream NTSync compat patch reflects that.
droidspaces_ntsync_patch_name() {
  local series="$1"
  local android_versions="${2:-}"

  case "$series" in
    5.10)
      if [[ ",${android_versions}," == *",14,"* ]]; then
        printf '%s\n' "android12-5.10_OOS14"
      else
        printf '%s\n' "android12-5.10"
      fi
      ;;
    5.15) printf '%s\n' "android13-5.15" ;;
    6.1) printf '%s\n' "android14-6.1" ;;
    6.6) printf '%s\n' "android15-6.6" ;;
    6.12) printf '%s\n' "android16-6.12" ;;
    *)
      echo "::error::Droidspaces NTSync has no patch mapping for kernel ${series}." >&2
      return 1
      ;;
  esac
}

# True when an option is already enabled by the base defconfig or one of the
# vendor fragments that make will merge. In that case moving the fields into
# ABI padding would change the layout the stock modules were built against, so
# the kABI patch must be skipped instead of applied.
droidspaces_config_enabled_in_inputs() {
  local key="$1"
  local config_file
  local config_files=("arch/arm64/configs/gki_defconfig")

  # shellcheck disable=SC2206 # ACTIVE_BUILD_CONFIGS is a space-separated list.
  config_files+=(${ACTIVE_BUILD_CONFIGS:-})

  for config_file in "${config_files[@]}"; do
    [[ -f "$config_file" ]] || continue
    if grep -q "^${key}=y$" "$config_file"; then
      echo "[+] ${key} is already enabled in ${config_file}; keeping the stock layout."
      return 0
    fi
  done
  return 1
}

droidspaces_apply_patch() {
  local patch_file="$1"
  local label="$2"

  test -s "$patch_file" || {
    echo "::error::Droidspaces ${label} patch is missing at ${patch_file}."
    exit 1
  }

  if ! patch -p1 --dry-run --batch --forward --fuzz=3 < "$patch_file"; then
    echo "::error::Droidspaces ${label} patch (${patch_file}) is incompatible with this kernel tree."
    if [[ "$label" == "SYSVIPC kABI" ]]; then
      echo "::error::The selected kABI slot may already be reserved by this vendor kernel; try another slot (678 or 345 usually work, 123 is 5.15-only)."
    fi
    exit 1
  fi

  patch -p1 --batch --forward --fuzz=3 < "$patch_file"
}

install_droidspaces() {
  local repo="$1"
  local commit="$2"
  local slot="$3"
  local repo_dir="Droidspaces-OSS"
  local slot_name
  local series
  local patch_relpath
  local patch_file
  local patch_sha
  local posix_patch_file=""
  local posix_patch_sha=""
  local abi_patch_skipped=0
  local posix_patch_skipped=0

  test "$slot" != "off" || {
    echo "::error::install_droidspaces was called with the integration disabled."
    exit 1
  }

  slot_name="$(droidspaces_slot_name "$slot")" || exit 1
  series="$(detect_kernel_series Makefile)" || exit 1

  if droidspaces_series_at_least "$series" "6.12"; then
    echo "[+] Kernel ${series} uses the 6.12-or-above SYSVIPC kABI layout; the slot input does not apply."
  else
    echo "[+] Kernel ${series} uses SYSVIPC kABI padding slot ${slot} (${slot_name})."
  fi

  rm -rf "$repo_dir"
  git init -q "$repo_dir"
  git -C "$repo_dir" remote add origin "$repo"
  git_fetch_retry "$repo_dir" --depth=1 --no-tags origin "$commit"
  git -C "$repo_dir" checkout -q --detach FETCH_HEAD
  test "$(git -C "$repo_dir" rev-parse HEAD)" = "$commit" || {
    echo "::error::Droidspaces checkout does not match resolved commit $commit."
    exit 1
  }

  patch_relpath="$(droidspaces_gki_patch_relpath "$series" "$slot_name")" || exit 1
  patch_file="${repo_dir}/${patch_relpath}"

  if droidspaces_config_enabled_in_inputs CONFIG_SYSVIPC; then
    abi_patch_skipped=1
    echo "::warning::SYSVIPC is already enabled by the selected source; skipping the Droidspaces kABI patch to preserve the stock ABI."
  else
    droidspaces_apply_patch "$patch_file" "SYSVIPC kABI"
    if ! patch -p1 --dry-run --reverse --batch < "$patch_file" >/dev/null 2>&1; then
      echo "::error::Droidspaces SYSVIPC kABI patch did not apply cleanly."
      exit 1
    fi
    echo "[+] Applied the Droidspaces SYSVIPC kABI patch for kernel ${series}."
  fi

  if ! droidspaces_series_at_least "$series" "5.15"; then
    posix_patch_file="${repo_dir}/$(droidspaces_posix_patch_relpath)"
    if droidspaces_config_enabled_in_inputs CONFIG_POSIX_MQUEUE; then
      posix_patch_skipped=1
      echo "::warning::POSIX_MQUEUE is already enabled by the selected source; skipping the Droidspaces POSIX_MQUEUE kABI patch."
    else
      droidspaces_apply_patch "$posix_patch_file" "POSIX_MQUEUE kABI"
      echo "[+] Applied the Droidspaces POSIX_MQUEUE kABI patch for kernel ${series}."
    fi
  fi

  # Android 16 / 6.12 rust_binder.ko references init_ipc_ns and put_ipc_ns once
  # IPC_NS is enabled, but the AOSP common branch does not export them yet.
  if droidspaces_series_at_least "$series" "6.12"; then
    if [[ -f ipc/msgutil.c ]] && ! grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' ipc/msgutil.c; then
      sed -i '/^struct msg_msgseg {/i EXPORT_SYMBOL(init_ipc_ns);' ipc/msgutil.c
      if grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' ipc/msgutil.c; then
        echo "[+] Exported init_ipc_ns for the 6.12+ rust_binder module."
      else
        echo "::warning::Could not export init_ipc_ns; 6.12+ builds with rust_binder may fail modpost."
      fi
    fi
    if [[ -f ipc/namespace.c ]] && ! grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' ipc/namespace.c; then
      sed -i '/^static struct ns_common \*ipcns_get(/i EXPORT_SYMBOL(put_ipc_ns);' ipc/namespace.c
      if grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' ipc/namespace.c; then
        echo "[+] Exported put_ipc_ns for the 6.12+ rust_binder module."
      else
        echo "::warning::Could not export put_ipc_ns; 6.12+ builds with rust_binder may fail modpost."
      fi
    fi
  fi

  if [[ -e include/linux/sched.h.rej || -e include/linux/sched/user.h.rej ]]; then
    echo "::error::Droidspaces integration left patch reject files."
    find include/linux -maxdepth 2 -name '*.rej' -print
    exit 1
  fi

  patch_sha="$(sha256sum "$patch_file" | awk '{print $1}')"
  if [[ -n "$posix_patch_file" ]]; then
    posix_patch_sha="$(sha256sum "$posix_patch_file" | awk '{print $1}')"
  fi

  DROIDSPACES_SERIES="$series"
  DROIDSPACES_PATCH_FILE="$patch_relpath"
  DROIDSPACES_PATCH_SHA256="$patch_sha"
  DROIDSPACES_POSIX_PATCH_FILE=""
  DROIDSPACES_POSIX_PATCH_SHA256=""
  DROIDSPACES_ABI_PATCH_SKIPPED="$abi_patch_skipped"
  DROIDSPACES_POSIX_PATCH_SKIPPED="$posix_patch_skipped"
  if [[ -n "$posix_patch_file" ]]; then
    DROIDSPACES_POSIX_PATCH_FILE="$(droidspaces_posix_patch_relpath)"
    DROIDSPACES_POSIX_PATCH_SHA256="$posix_patch_sha"
  fi
  export DROIDSPACES_SERIES DROIDSPACES_PATCH_FILE DROIDSPACES_PATCH_SHA256
  export DROIDSPACES_POSIX_PATCH_FILE DROIDSPACES_POSIX_PATCH_SHA256
  export DROIDSPACES_ABI_PATCH_SKIPPED DROIDSPACES_POSIX_PATCH_SKIPPED

  {
    echo "DROIDSPACES_SERIES=$DROIDSPACES_SERIES"
    echo "DROIDSPACES_PATCH_FILE=$DROIDSPACES_PATCH_FILE"
    echo "DROIDSPACES_PATCH_SHA256=$DROIDSPACES_PATCH_SHA256"
    echo "DROIDSPACES_POSIX_PATCH_FILE=$DROIDSPACES_POSIX_PATCH_FILE"
    echo "DROIDSPACES_POSIX_PATCH_SHA256=$DROIDSPACES_POSIX_PATCH_SHA256"
    echo "DROIDSPACES_ABI_PATCH_SKIPPED=$DROIDSPACES_ABI_PATCH_SKIPPED"
    echo "DROIDSPACES_POSIX_PATCH_SKIPPED=$DROIDSPACES_POSIX_PATCH_SKIPPED"
  } >> "$GITHUB_ENV"

  {
    echo "==== DROIDSPACES SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "kernel_series=${DROIDSPACES_SERIES}"
    echo "slot=${slot}"
    echo "slot_name=${slot_name}"
    echo "droidspaces_commit=${commit}"
    echo "sysvipc_patch=${DROIDSPACES_PATCH_FILE}"
    echo "sysvipc_patch_sha256=${DROIDSPACES_PATCH_SHA256}"
    echo "sysvipc_patch_skipped=${DROIDSPACES_ABI_PATCH_SKIPPED}"
    echo "posix_mqueue_patch=${DROIDSPACES_POSIX_PATCH_FILE:-none}"
    echo "posix_mqueue_patch_sha256=${DROIDSPACES_POSIX_PATCH_SHA256:-none}"
    echo "posix_mqueue_patch_skipped=${DROIDSPACES_POSIX_PATCH_SKIPPED}"
    echo "---- include/linux/sched.h ----"
    grep -nE 'CONFIG_SYSVIPC|sysvsem|sysvshm|ANDROID_KABI_USE|_ANDROID_KABI_REPLACE' include/linux/sched.h || true
    if [[ -n "$DROIDSPACES_POSIX_PATCH_FILE" ]]; then
      echo "---- include/linux/sched/user.h ----"
      grep -nE 'CONFIG_POSIX_MQUEUE|mq_bytes|ANDROID_KABI_USE' include/linux/sched/user.h || true
    fi
  } | tee droidspaces-source-proof.txt

  echo "[+] Integrated Droidspaces container support for kernel ${series} from ${commit}."
}

install_droidspaces_ntsync() {
  local repo="$1"
  local commit="$2"
  local series="$3"
  local android_versions="$4"
  local repo_dir="Droidspaces-NTSync"
  local patch_name
  local base_patch
  local compat_patch
  local base_sha
  local compat_sha

  patch_name="$(droidspaces_ntsync_patch_name "$series" "$android_versions")" || exit 1
  echo "[+] Kernel ${series} (Android: ${android_versions:-unknown}) uses NTSync compatibility patch ${patch_name}."

  rm -rf "$repo_dir"
  git init -q "$repo_dir"
  git -C "$repo_dir" remote add origin "$repo"
  git_fetch_retry "$repo_dir" --depth=1 --no-tags origin "$commit"
  git -C "$repo_dir" checkout -q --detach FETCH_HEAD
  test "$(git -C "$repo_dir" rev-parse HEAD)" = "$commit" || {
    echo "::error::Droidspaces NTSync checkout does not match resolved commit $commit."
    exit 1
  }

  base_patch="${repo_dir}/NTsync/ntsync_base.patch"
  compat_patch="${repo_dir}/NTsync/ntsync_compat_${patch_name}.patch"
  droidspaces_apply_patch "$base_patch" "NTSync base"
  droidspaces_apply_patch "$compat_patch" "NTSync ${patch_name} compatibility"

  if find drivers/misc include/uapi/linux -maxdepth 1 -name '*.rej' -print -quit | grep -q .; then
    echo "::error::Droidspaces NTSync integration left patch reject files."
    find drivers/misc include/uapi/linux -maxdepth 1 -name '*.rej' -print
    exit 1
  fi

  base_sha="$(sha256sum "$base_patch" | awk '{print $1}')"
  compat_sha="$(sha256sum "$compat_patch" | awk '{print $1}')"

  DROIDSPACES_NTSYNC_PATCH="$patch_name"
  DROIDSPACES_NTSYNC_BASE_SHA256="$base_sha"
  DROIDSPACES_NTSYNC_COMPAT_SHA256="$compat_sha"
  export DROIDSPACES_NTSYNC_PATCH DROIDSPACES_NTSYNC_BASE_SHA256 DROIDSPACES_NTSYNC_COMPAT_SHA256
  {
    echo "DROIDSPACES_NTSYNC_PATCH=$DROIDSPACES_NTSYNC_PATCH"
    echo "DROIDSPACES_NTSYNC_BASE_SHA256=$DROIDSPACES_NTSYNC_BASE_SHA256"
    echo "DROIDSPACES_NTSYNC_COMPAT_SHA256=$DROIDSPACES_NTSYNC_COMPAT_SHA256"
  } >> "$GITHUB_ENV"

  {
    echo "==== DROIDSPACES NTSYNC SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "kernel_series=${series}"
    echo "android_versions=${android_versions}"
    echo "ntsync_commit=${commit}"
    echo "compat_patch=${patch_name}"
    echo "base_patch_sha256=${base_sha}"
    echo "compat_patch_sha256=${compat_sha}"
    echo "---- drivers/misc/Kconfig ----"
    grep -nE 'config NTSYNC' drivers/misc/Kconfig || true
    echo "---- drivers/misc/Makefile ----"
    grep -nF 'obj-$(CONFIG_NTSYNC)' drivers/misc/Makefile || true
  } | tee droidspaces-ntsync-source-proof.txt

  echo "[+] Integrated Droidspaces NTSync support (${patch_name}) from ${commit}."
}
