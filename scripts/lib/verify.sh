#!/usr/bin/env bash
#
# Post-patch/post-build verification helpers. Sourced, not executed.
#

verify_susfs_source_integration() {
  local ksu_kernel_dir="$1"
  local runtime_file="${ksu_kernel_dir}/runtime/ksud_integration.c"

  test -f fs/susfs.c || {
    echo "::error::fs/susfs.c is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs.h || {
    echo "::error::include/linux/susfs.h is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs_def.h || {
    echo "::error::include/linux/susfs_def.h is missing after applying susfs patches."
    exit 1
  }

  grep -Fq "#define SUSFS_VERSION \"v${SUSFS_VERSION}\"" include/linux/susfs.h || {
    echo "::error::Integrated SUSFS headers do not report expected version v${SUSFS_VERSION}."
    exit 1
  }

  grep -Fq 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || {
    echo "::error::fs/Makefile does not reference susfs.o after applying susfs patches."
    exit 1
  }

  grep -q 'ksu_handle_sys_reboot' kernel/reboot.c || {
    echo "::error::kernel/reboot.c is missing the susfs reboot hook after applying susfs patches."
    exit 1
  }

  grep -R -q 'CMD_SUSFS_SHOW_VERSION' "$ksu_kernel_dir" || {
    echo "::error::KernelSU tree does not expose CMD_SUSFS_SHOW_VERSION, so the manager will not detect susfs."
    exit 1
  }

  if grep -R -q 'ksu_selinux_hide_running' security/selinux; then
    local fake_state_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*struct[[:space:]]+selinux_state[[:space:]]+fake_state([[:space:];=]|$)'
    local running_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*bool[[:space:]]+ksu_selinux_hide_running([[:space:];=]|$)'

    grep -R --include='*.c' --include='*.h' -Eq "$fake_state_def_re" "$ksu_kernel_dir" || {
      echo "::error::KernelSU tree does not define fake_state required by the susfs SELinux hooks."
      exit 1
    }
    grep -R --include='*.c' --include='*.h' -Eq "$running_def_re" "$ksu_kernel_dir" || {
      echo "::error::KernelSU tree does not define ksu_selinux_hide_running required by the susfs SELinux hooks."
      exit 1
    }
  fi

  if [[ "$KSU_TYPE" == BakaSU* ]]; then
    test -f "$runtime_file" || {
      echo "::error::BakaSU runtime file is missing at ${runtime_file}"
      exit 1
    }

    grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" || {
      echo "::error::BakaSU runtime compat is missing ksu_is_init_rc_hook_enabled, so SUSFS builds will fail or silently fall back."
      exit 1
    }

    grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" || {
      echo "::error::BakaSU runtime compat is missing ksu_is_input_hook_enabled, so susfs builds will fail or silently fall back."
      exit 1
    }

    if ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled$' "$runtime_file" && \
       ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file"; then
      echo "::error::BakaSU runtime compat is not pointing init_rc hook to the susfs static key."
      exit 1
    fi

    if ! grep -Eq '^[[:space:]]*#define ksu_input_hook ksu_is_input_hook_enabled$' "$runtime_file" && \
       ! grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
      echo "::error::BakaSU runtime compat is not pointing input hook to the susfs static key."
      exit 1
    fi
  fi

  {
    echo "==== SUSFS SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "modules_branch=${MODULES_BRANCH}"
    echo "modules_commit=${MODULES_COMMIT}"
    echo "ksu_commit=${KSU_COMMIT}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_commit=${SUSFS_COMMIT}"
    echo "susfs_version=${SUSFS_VERSION}"
    echo "susfs_min_version=${SUSFS_MIN_VERSION}"
    echo "susfs_patch=${SUSFS_PATCH_FILE}"
    grep -Fn 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || true
    grep -n 'ksu_handle_sys_reboot' kernel/reboot.c | head -n 5 || true
    grep -R -n 'CMD_SUSFS_SHOW_VERSION' "$ksu_kernel_dir" | head -n 10 || true
    grep -R -nE 'fake_state|ksu_selinux_hide_running' "$ksu_kernel_dir" | head -n 10 || true
    if [[ -f "$runtime_file" ]]; then
      grep -nE 'ksu_is_init_rc_hook_enabled|ksu_is_input_hook_enabled|ksu_init_rc_hook_key_false|ksu_input_hook_key_false' "$runtime_file" | head -n 20 || true
    fi
  } | tee susfs-source-proof.txt
}

verify_susfs_binary_presence() {
  local symbol_hits=0
  local string_hits=0

  if [[ -f out/fs/susfs.o ]]; then
    nm out/fs/susfs.o | grep -E 'susfs_(init|show_version|get_enabled_features)' && symbol_hits=1 || true
    strings out/fs/susfs.o | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION' && string_hits=1 || true
  fi

  if [[ -f out/System.map ]]; then
    grep -E 'susfs_(init|show_version|get_enabled_features)' out/System.map && symbol_hits=1 || true
  fi

  if [[ -f out/vmlinux ]]; then
    strings out/vmlinux | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION|CONFIG_KSU_SUSFS_SUS_MOUNT' && string_hits=1 || true
  fi

  if [[ "$symbol_hits" -eq 0 && "$string_hits" -eq 0 ]]; then
    echo "::error::susfs config flags were enabled, but no susfs signature was found in the final kernel artifacts."
    exit 1
  fi

  {
    echo "==== SUSFS BINARY PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "modules_branch=${MODULES_BRANCH}"
    echo "modules_commit=${MODULES_COMMIT}"
    echo "ksu_commit=${KSU_COMMIT}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_commit=${SUSFS_COMMIT}"
    echo "susfs_version=${SUSFS_VERSION}"
    echo "susfs_patch=${SUSFS_PATCH_FILE}"
    if [[ -f out/fs/susfs.o ]]; then
      nm out/fs/susfs.o | grep -E 'susfs_(init|show_version|get_enabled_features)' | head -n 20 || true
      strings out/fs/susfs.o | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION' | head -n 20 || true
    fi
    if [[ -f out/System.map ]]; then
      grep -E 'susfs_(init|show_version|get_enabled_features)' out/System.map | head -n 20 || true
    fi
    if [[ -f out/vmlinux ]]; then
      strings out/vmlinux | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION|CONFIG_KSU_SUSFS_' | head -n 20 || true
    fi
  } | tee susfs-proof.txt
}

verify_nomount_source_integration() {
  local fs_dir="${NOMOUNT_FS_DIR:?}"
  local detected_version

  test -f "$fs_dir/nomount/nomount.c" || {
    echo "::error::NoMount source is missing at $fs_dir/nomount/nomount.c."
    exit 1
  }
  test -f "$fs_dir/nomount/nomount.h" || {
    echo "::error::NoMount header is missing at $fs_dir/nomount/nomount.h."
    exit 1
  }
  grep -Fq 'obj-$(CONFIG_NOMOUNT) += nomount/' "$fs_dir/Makefile" || {
    echo "::error::$fs_dir/Makefile does not reference the NoMount directory."
    exit 1
  }
  grep -Fq "source \"${fs_dir}/nomount/Kconfig\"" "$fs_dir/Kconfig" || {
    echo "::error::$fs_dir/Kconfig does not include the NoMount Kconfig."
    exit 1
  }
  detected_version="$(detect_nomount_version "$fs_dir/nomount")" && \
    [[ "$detected_version" == "$NOMOUNT_VERSION" ]] || {
    echo "::error::Integrated NoMount headers do not report expected version ${NOMOUNT_VERSION}."
    exit 1
  }
}

verify_nomount_binary_presence() {
  local symbol_hits=0
  local string_hits=0
  local object_file="out/${NOMOUNT_FS_DIR}/nomount/nomount.o"

  if [[ -f "$object_file" ]]; then
    nm "$object_file" | grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' && symbol_hits=1 || true
    strings "$object_file" | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' && string_hits=1 || true
  fi

  if [[ -f out/System.map ]]; then
    grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' out/System.map && symbol_hits=1 || true
  fi
  if [[ -f out/vmlinux ]]; then
    strings out/vmlinux | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' && string_hits=1 || true
  fi
  if [[ "$symbol_hits" -eq 0 && "$string_hits" -eq 0 ]]; then
    echo "::error::CONFIG_NOMOUNT=y, but no NoMount signature was found in the final kernel artifacts."
    exit 1
  fi

  {
    echo "==== NOMOUNT BINARY PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "nomount_ref=${NOMOUNT_REF}"
    echo "nomount_commit=${NOMOUNT_COMMIT}"
    echo "nomount_version=${NOMOUNT_VERSION}"
    if [[ -f "$object_file" ]]; then
      nm "$object_file" | grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' | head -n 20 || true
      strings "$object_file" | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' | head -n 20 || true
    fi
    if [[ -f out/System.map ]]; then
      grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' out/System.map | head -n 20 || true
    fi
    if [[ -f out/vmlinux ]]; then
      strings out/vmlinux | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' | head -n 20 || true
    fi
  } | tee nomount-proof.txt
}

verify_bakasu_susfs_hook_mode() {
  test -f build.log || {
    echo "::error::build.log is missing, cannot verify BakaSU hook mode."
    exit 1
  }

  if grep -Eq 'using KSU_TRACEPOINT_HOOK|using Tracepoint Syscall Redirect Hook' build.log; then
    echo "::error::BakaSU fell back to KSU_TRACEPOINT_HOOK, so the manager will not detect susfs inline mode."
    exit 1
  fi

  if grep -Eq 'using KSU_MANUAL_HOOK|using Manual Hook' build.log; then
    echo "::error::BakaSU fell back to KSU_MANUAL_HOOK, so this build is not the expected susfs inline mode."
    exit 1
  fi

  grep -Eq 'using SUSFS_INLINE_HOOK|using SuSFS Inline hook' build.log || {
    echo "::error::BakaSU did not report SUSFS_INLINE_HOOK in build.log."
    exit 1
  }

  {
    echo "==== BAKASU SUSFS HOOK PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "modules_branch=${MODULES_BRANCH}"
    echo "modules_commit=${MODULES_COMMIT}"
    echo "ksu_commit=${KSU_COMMIT}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_commit=${SUSFS_COMMIT}"
    grep -nE 'using SUSFS_INLINE_HOOK|using SuSFS Inline hook|using KSU_TRACEPOINT_HOOK|using Tracepoint Syscall Redirect Hook|using KSU_MANUAL_HOOK|using Manual Hook' build.log || true
  } | tee susfs-hook-proof.txt
}

verify_droidspaces_source_integration() {
  : "${DROIDSPACES_SERIES:?}"
  : "${DROIDSPACES_PATCH_FILE:?}"

  test -f include/linux/sched.h || {
    echo "::error::include/linux/sched.h is missing after Droidspaces integration."
    exit 1
  }

  if [[ "${DROIDSPACES_ABI_PATCH_SKIPPED:-0}" == "0" ]]; then
    # Below 6.12 the fields are parked in ANDROID_KABI_USE slots; the 6.12+
    # variant instead uses a packed union inside the existing ABI padding.
    if ! grep -qE 'ANDROID_KABI_USE\([0-9]+, struct sysv_sem sysvsem\)|__kabi_ignored_0' include/linux/sched.h; then
      echo "::error::Droidspaces kABI patch is not present in include/linux/sched.h."
      exit 1
    fi
  fi

  if [[ -n "${DROIDSPACES_POSIX_PATCH_FILE:-}" && "${DROIDSPACES_POSIX_PATCH_SKIPPED:-0}" == "0" ]]; then
    grep -q 'ANDROID_KABI_USE(1, unsigned long mq_bytes)' include/linux/sched/user.h || {
      echo "::error::Droidspaces POSIX_MQUEUE kABI patch is not present in include/linux/sched/user.h."
      exit 1
    }
  fi

  test -f ipc/msg.c || test -f ipc/syscall.c || {
    echo "::error::The kernel tree does not contain an ipc/ implementation after Droidspaces integration."
    exit 1
  }

  {
    echo "==== DROIDSPACES SOURCE VERIFICATION ===="
    echo "kernel_series=${DROIDSPACES_SERIES}"
    echo "sysvipc_patch=${DROIDSPACES_PATCH_FILE}"
    echo "sysvipc_patch_skipped=${DROIDSPACES_ABI_PATCH_SKIPPED:-0}"
    echo "posix_mqueue_patch=${DROIDSPACES_POSIX_PATCH_FILE:-none}"
    echo "posix_mqueue_patch_skipped=${DROIDSPACES_POSIX_PATCH_SKIPPED:-0}"
    grep -nE 'CONFIG_SYSVIPC|sysvsem|sysvshm|ANDROID_KABI_USE|__kabi_ignored' include/linux/sched.h || true
    if [[ -n "${DROIDSPACES_POSIX_PATCH_FILE:-}" ]]; then
      grep -nE 'CONFIG_POSIX_MQUEUE|mq_bytes|ANDROID_KABI_USE' include/linux/sched/user.h || true
    fi
  } | tee -a droidspaces-source-proof.txt
}

verify_droidspaces_ntsync_source_integration() {
  [[ "${DROIDSPACES_NTSYNC:-false}" == "true" ]] || return 0

  test -f drivers/misc/ntsync.c || {
    echo "::error::Droidspaces NTSync source is missing at drivers/misc/ntsync.c."
    exit 1
  }
  test -f include/uapi/linux/ntsync.h || {
    echo "::error::Droidspaces NTSync UAPI header is missing at include/uapi/linux/ntsync.h."
    exit 1
  }
  grep -Eq '^[[:space:]]*config NTSYNC$' drivers/misc/Kconfig || {
    echo "::error::drivers/misc/Kconfig does not expose CONFIG_NTSYNC."
    exit 1
  }
  grep -Fq 'obj-$(CONFIG_NTSYNC)' drivers/misc/Makefile || {
    echo "::error::drivers/misc/Makefile does not wire the NTSync object."
    exit 1
  }

  {
    echo "==== DROIDSPACES NTSYNC SOURCE VERIFICATION ===="
    echo "compat_patch=${DROIDSPACES_NTSYNC_PATCH:-unknown}"
    grep -nE 'config NTSYNC' drivers/misc/Kconfig || true
    grep -nF 'obj-$(CONFIG_NTSYNC)' drivers/misc/Makefile || true
  } | tee -a droidspaces-ntsync-source-proof.txt
}

verify_droidspaces_binary_presence() {
  local nm_tool="${CLANG_ROOT:?}/llvm-nm"
  local object_file
  local symbol_hits=0
  local ntsync_hits=0

  if [[ ! -x "$nm_tool" ]]; then
    nm_tool="$(command -v llvm-nm || command -v nm || true)"
  fi
  test -n "$nm_tool" || {
    echo "::error::No symbol tool is available to verify the compiled Droidspaces IPC objects."
    exit 1
  }

  for object_file in out/ipc/shm.o out/ipc/sem.o out/ipc/mqueue.o; do
    [[ -f "$object_file" ]] || continue
    if "$nm_tool" "$object_file" 2>/dev/null | \
       grep -qE '[[:space:]][Tt][[:space:]]+(shm_init|sem_init|mq_init)([.[][^[:space:]]*)?$'; then
      symbol_hits=1
    fi
  done
  if [[ -f out/System.map ]] && \
     grep -qE '[[:space:]](shm_init|sem_init|mq_init)$' out/System.map; then
    symbol_hits=1
  fi
  if [[ "$symbol_hits" -eq 0 ]]; then
    echo "::error::Droidspaces IPC configs are enabled, but no SYSVIPC/POSIX_MQUEUE init symbol was found in the compiled artifacts."
    exit 1
  fi

  if [[ "${DROIDSPACES_NTSYNC:-false}" == "true" ]]; then
    if [[ -f out/drivers/misc/ntsync.o ]]; then
      ntsync_hits=1
    fi
    if [[ -f out/System.map ]] && grep -qE '[[:space:]]ntsync_(init|ioctl)' out/System.map; then
      ntsync_hits=1
    fi
    if [[ "$ntsync_hits" -eq 0 ]]; then
      echo "::error::CONFIG_NTSYNC=y, but the compiled NTSync driver was not found in the kernel artifacts."
      exit 1
    fi
  fi

  {
    echo "==== DROIDSPACES BINARY PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "kernel_series=${DROIDSPACES_SERIES:-unknown}"
    echo "sysvipc_patch=${DROIDSPACES_PATCH_FILE:-unknown}"
    echo "posix_mqueue_patch=${DROIDSPACES_POSIX_PATCH_FILE:-none}"
    echo "ntsync=${DROIDSPACES_NTSYNC:-false}"
    for object_file in out/ipc/shm.o out/ipc/sem.o out/ipc/mqueue.o; do
      if [[ -f "$object_file" ]]; then
        "$nm_tool" "$object_file" 2>/dev/null | \
          grep -E '[[:space:]][Tt][[:space:]]+(shm_init|sem_init|mq_init)' | head -n 5 || true
      fi
    done
    if [[ -f out/System.map ]]; then
      grep -E '[[:space:]](shm_init|sem_init|mq_init)$' out/System.map | head -n 5 || true
      if [[ "${DROIDSPACES_NTSYNC:-false}" == "true" ]]; then
        grep -E '[[:space:]]ntsync_(init|ioctl)' out/System.map | head -n 5 || true
      fi
    fi
  } | tee droidspaces-proof.txt
}
