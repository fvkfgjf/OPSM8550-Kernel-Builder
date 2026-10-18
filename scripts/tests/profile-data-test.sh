#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/profile-data.sh
. "${SCRIPT_DIR}/../lib/profile-data.sh"
# shellcheck source=../lib/git-helpers.sh
. "${SCRIPT_DIR}/../lib/git-helpers.sh"
# shellcheck source=../lib/anykernel-helpers.sh
. "${SCRIPT_DIR}/../lib/anykernel-helpers.sh"
# shellcheck source=../lib/nomount-setup.sh
. "${SCRIPT_DIR}/../lib/nomount-setup.sh"
# shellcheck source=../lib/droidspaces-setup.sh
. "${SCRIPT_DIR}/../lib/droidspaces-setup.sh"
# shellcheck source=../lib/susfs-apply.sh
. "${SCRIPT_DIR}/../lib/susfs-apply.sh"
# shellcheck source=../lib/kernel-helpers.sh
. "${SCRIPT_DIR}/../lib/kernel-helpers.sh"
# shellcheck source=../lib/verify.sh
. "${SCRIPT_DIR}/../lib/verify.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

profiles=()
mapfile -t profiles < <(list_build_profiles)
assert_eq "12" "${#profiles[@]}" "profile count"

WORKFLOW_FILE="${SCRIPT_DIR}/../../.github/workflows/build.yml"
UPSTREAM_HEALTH_WORKFLOW="${SCRIPT_DIR}/../../.github/workflows/upstream-health.yml"
COMPILE_SCRIPT="${SCRIPT_DIR}/../compile-kernel.sh"
ANYKERNEL_PACKAGE_SCRIPT="${SCRIPT_DIR}/../make-anykernel-zip.sh"
ANYKERNEL_TEMPLATE="${SCRIPT_DIR}/../templates/anykernel.sh"
RESOLVER_SCRIPT="${SCRIPT_DIR}/../resolve-profile.sh"
KSU_SETUP_SCRIPT="${SCRIPT_DIR}/../lib/ksu-setup.sh"
GIT_HELPERS_SCRIPT="${SCRIPT_DIR}/../lib/git-helpers.sh"
SUSFS_APPLY_SCRIPT="${SCRIPT_DIR}/../lib/susfs-apply.sh"
DROIDSPACES_SETUP_SCRIPT="${SCRIPT_DIR}/../lib/droidspaces-setup.sh"
sh -n "$ANYKERNEL_TEMPLATE" || fail "AnyKernel device template has invalid shell syntax"
for profile in "${profiles[@]}"; do
  grep -Fq -- "- ${profile}" "$WORKFLOW_FILE" \
    || fail "workflow is missing profile option: $profile"
done
kernel_branch_input="$(sed -n '/^      kernel_branch:/,/^      clang_choice:/p' "$WORKFLOW_FILE")"
grep -Fq 'type: choice' <<< "$kernel_branch_input" \
  || fail "manual kernel branch input must be a choice"
grep -Fq -- '- "16.0"' <<< "$kernel_branch_input" \
  || fail "manual kernel branch choices must include crDroid 16.0"
grep -Fq -- '- "17.0"' <<< "$kernel_branch_input" \
  || fail "manual kernel branch choices must include crDroid 13 / Android 17"
grep -Fq -- '- clang-r584948 (Android 17 / crDroid 13 era)' "$WORKFLOW_FILE" \
  || fail "workflow must offer the crDroid 13 compiler"
grep -Fq '/b896c53892be0ae507473a9f3dce67907edf4965/clang-r584948.tar.gz' \
  "${SCRIPT_DIR}/../download-clang.sh" \
  || fail "crDroid 13 compiler download must use the pinned AOSP revision"
grep -Fq '"CC=ccache clang"' "$COMPILE_SCRIPT" \
  || fail "compile script is not passing ccache on the make command line"
grep -Fq 'KBUILD_BUILD_TIMESTAMP=' "$COMPILE_SCRIPT" \
  || fail "compile script is missing deterministic Kbuild metadata"
if grep -Fq 'CCACHE_PREFIX' "$WORKFLOW_FILE"; then
  fail "workflow must not export ccache's reserved CCACHE_PREFIX variable"
fi
grep -Fq 'CCACHE_KEY_PREFIX' "$WORKFLOW_FILE" \
  || fail "workflow is missing the cache-key-only ccache prefix"
grep -Fq 'RELEASE_TAG="kernel-build-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"' "$WORKFLOW_FILE" \
  || fail "release workflow is missing its immutable tag reservation"
grep -Fq 'if ! EXISTING_SHA="$(gh api' "$WORKFLOW_FILE" \
  || fail "release tag lookup must distinguish a missing tag from an existing SHA"
grep -Fq 'gh release create "$RELEASE_TAG"' "$WORKFLOW_FILE" \
  || fail "release workflow must publish the pre-reserved tag"
grep -Fq 'gh api "repos/${GH_REPO}/git/refs/tags/${RELEASE_TAG}" --method DELETE' "$WORKFLOW_FILE" \
  || fail "release workflow must clean up a reserved tag after a failed build"
for validation_workflow in "$WORKFLOW_FILE" "$UPSTREAM_HEALTH_WORKFLOW"; do
  grep -Eq '^[[:space:]]+lld \\' "$validation_workflow" \
    || fail "$validation_workflow is missing the LLVM linker"
  grep -Eq '^[[:space:]]+llvm \\' "$validation_workflow" \
    || fail "$validation_workflow is missing the LLVM binutils"
done
grep -Fq 'MODULES_CLONE_DIR="${UPSTREAM_SOC}-modules"' "$RESOLVER_SCRIPT" \
  || fail "community module checkout must preserve the upstream repository stem"
grep -Fq 'clone_repo "$MODULES_REPO" "$MODULES_BRANCH"' "${SCRIPT_DIR}/../clone-sources.sh" \
  || fail "modules checkout must use its independently resolved branch"
grep -Fq 'MAKE_ARGS+=("${KERNEL_MAKE_FLAG_ARRAY[@]}")' "$COMPILE_SCRIPT" \
  || fail "compile script must pass profile-specific flags to every make invocation"
grep -Fq 'make "${MAKE_ARGS[@]}" "$EXTRACT_CERT_TARGET"' "$COMPILE_SCRIPT" \
  || fail "validation mode must smoke-compile the kernel certificate host tool"
grep -Fq 'local max_attempts=5' "$GIT_HELPERS_SCRIPT" \
  || fail "git network helpers must tolerate a longer transient outage"
grep -Fq 'GIT_TERMINAL_PROMPT=0 git ls-remote' "$GIT_HELPERS_SCRIPT" \
  || fail "git ref lookup must not wait for credentials in CI"
grep -Fq 'GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" fetch' "$GIT_HELPERS_SCRIPT" \
  || fail "git fetch must not wait for credentials in CI"
grep -Fq 'ANYKERNEL_REPO="https://github.com/osm0sis/AnyKernel3.git"' "$RESOLVER_SCRIPT" \
  || fail "resolver must use the canonical live AnyKernel3 repository"
grep -Fq 'ANYKERNEL_COMMIT="020dfeccf9d7e962a48400fc94d3e451df92eead"' "$RESOLVER_SCRIPT" \
  || fail "resolver must pin the tested AnyKernel3 revision"
grep -Fq 'sanitize_cached_anykernel_checkout AnyKernel3' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must sanitize a restored checkout"
grep -Fq 'install_anykernel_template "$ANYKERNEL_TEMPLATE" "$ANYKERNEL_SCRIPT"' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must install the device-specific flash template"
grep -Fq 'patch_anykernel_app_flash_staging "$ANYKERNEL_UPDATE_BINARY"' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must move app-triggered flashes out of app-private data"
grep -Fq 'install_anykernel_arm64_magiskboot \' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "arm64-only packaging must replace AnyKernel's legacy ARM MagiskBoot"
grep -Fq 'prepare_anykernel_arm64_toolset "AnyKernel3/tools"' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "arm64-only packaging must reject remaining non-AArch64 runtime tools"
grep -Fq 'add_anykernel_preflight_diagnostics \' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must report the device and BusyBox ABIs"
grep -Fq 'git checkout -q --force --detach FETCH_HEAD' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must force the pinned detached checkout"
if grep -Fq 'Kernel-SU/AnyKernel3.git' "$RESOLVER_SCRIPT"; then
  fail "resolver still references the removed Kernel-SU AnyKernel3 fork"
fi
grep -Fq 'profile: SM8650 | OnePlus 12 | crDroid' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health must exercise the crDroid SM8650 certificate compatibility path"
grep -Fq -- '- BakaSU + SUSFS + NoMount (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health must exercise the BakaSU SUSFS/NoMount integration"
if grep -Eq 'KernelSU-Next|SukiSU|KowSU|Official KernelSU|KPM' "$UPSTREAM_HEALTH_WORKFLOW"; then
  fail "upstream health still exercises a removed root solution"
fi

expected_socs=(sm7550 sm7550 sm8450 sm8450 sm8550 sm8550 sm8550 sm8550 sm8550 sm8650 sm8650 sm8650)
expected_upstream_socs=(sm8550 sm8550 sm8450 sm8450 sm8550 sm8550 sm8550 sm8550 sm8550 sm8650 sm8650 sm8650)
expected_codenames=(benz benz negroni ovaltine salami salami "salami aston astonc" "salami aston astonc" "aston astonc" waffle waffle waffle)
expected_devices=("benz OP5D3FL1 CPH2613" "benz OP5D3FL1 CPH2613" "negroni OP516EL1 OP516FL1" "ovaltine OP5551L1 OP5552L1" "salami OP591BL1 OP594DL1" "salami OP591BL1 OP594DL1" "salami OP591BL1 OP594DL1 aston OP5D35L1 astonc OP5CF9L1" "salami OP591BL1 OP594DL1 aston OP5D35L1 astonc OP5CF9L1" "aston OP5D35L1 astonc OP5CF9L1" "waffle OP5929L1 OP595DL1" "waffle OP5929L1 OP595DL1" "waffle OP5929L1 OP595DL1")

for i in "${!profiles[@]}"; do
  resolve_build_profile "${profiles[$i]}"
  assert_eq "${expected_socs[$i]}" "$SOC" "${profiles[$i]} SoC"
  assert_eq "${expected_upstream_socs[$i]}" "$UPSTREAM_SOC" "${profiles[$i]} upstream SoC"
  assert_eq "${expected_codenames[$i]}" "$DEVICE_CODENAMES" "${profiles[$i]} codenames"
  assert_eq "${expected_devices[$i]}" "$DEVICE_NAMES" "${profiles[$i]} devices"
  [[ -n "$PROFILE_ID" && -n "$BUILD_CONFIGS" && -n "$SOURCE_SLUG" ]] \
    || fail "${profiles[$i]} did not resolve all required metadata"
done

resolve_build_profile "SM7550 | OnePlus Nord CE4 | development"
assert_eq "CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_BENZ_DTB=y" "$KERNEL_MAKE_FLAGS" "Nord CE4 development make flags"
resolve_build_profile "SM7550 | OnePlus Nord CE4 | crDroid (recommended for crDroid)"
assert_eq "crdroidandroid" "$KERNEL_SOURCE" "Nord CE4 crDroid kernel source"
assert_eq "sm8550" "$UPSTREAM_SOC" "Nord CE4 crDroid upstream repository SoC"
assert_eq "CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_BENZ_DTB=y" "$KERNEL_MAKE_FLAGS" "Nord CE4 crDroid make flags"

resolve_build_profile "SM8650 | OnePlus 12 | LineageOS (recommended)"
assert_eq "CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_WAFFLE_DTB=y" "$KERNEL_MAKE_FLAGS" "OnePlus 12 LineageOS make flags"
resolve_build_profile "SM8650 | OnePlus 12 | crDroid"
assert_eq "CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_WAFFLE_DTB=y" "$KERNEL_MAKE_FLAGS" "OnePlus 12 crDroid make flags"
resolve_build_profile "SM8550 | OnePlus 11 / 12R | crDroid"
assert_eq "CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_SALAMI_DTB=y CONFIG_ASTON_DTB=y" \
  "$KERNEL_MAKE_FLAGS" "OnePlus 11 / 12R crDroid make flags"
grep -Fq -- '- SM8550 | OnePlus 11 / 12R | crDroid' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health must exercise the crDroid SM8550 source"
grep -Fq 'device_kernel_make_flags: ($kernel_make_flags | split(" ") | map(select(length > 0)))' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "build provenance does not record device kernel make flags"
grep -Fq "out/Module.symvers" "$WORKFLOW_FILE" \
  || fail "diagnostics do not retain the kernel module CRC table"
grep -Fq "it does not replace the ROM's system_dlkm or vendor_dlkm modules" "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "release notes do not warn about the retained ROM modules"
grep -Fq 'INPUT_ROM_GKI_MODULE_COMPAT: ${{ inputs.rom_gki_module_compat }}' "$WORKFLOW_FILE" \
  || fail "workflow does not pass the selected ROM GKI module compatibility mode"
grep -Fq 'rom_gki_module_compat: $rom_gki_module_compat' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "package provenance does not record ROM GKI module compatibility"

resolve_build_profile "SM8550 | OnePlus 11 | LunarisOS"
assert_eq "https://github.com/osm1019/kernel_oneplus_sm8550.git" "$KERNEL_REPO_OVERRIDE" "LunarisOS kernel repository"
assert_eq "https://github.com/osm1019/android_kernel_oneplus_sm8550-modules.git" "$MODULES_REPO_OVERRIDE" "LunarisOS modules repository"
assert_eq "los" "$MODULES_BRANCH_OVERRIDE" "LunarisOS modules branch"
assert_eq "lunarisos" "$SOURCE_SLUG" "LunarisOS source slug"

resolve_root_solution "BakaSU"
assert_eq "BakaSU" "$KSU_TYPE" "BakaSU root mapping"
resolve_root_solution "BakaSU + SUSFS"
assert_eq "BakaSU-with-susfs" "$KSU_TYPE" "BakaSU SUSFS root mapping"
resolve_root_solution "BakaSU + SUSFS + NoMount (experimental)"
assert_eq "BakaSU-with-susfs-nomount" "$KSU_TYPE" "BakaSU NoMount root mapping"
for retired_root_option in \
  'Official KernelSU' \
  'KernelSU-Next' \
  'KernelSU-Next + SUSFS' \
  'KernelSU-Next + SUSFS + NoMount (experimental)' \
  'KowSU' \
  'SukiSU Ultra + KPM (experimental)' \
  'SukiSU Ultra + SUSFS + KPM (experimental)' \
  'SukiSU Ultra + SUSFS + NoMount + KPM (experimental)' \
  'ReSukiSU' \
  'ReSukiSU + susfs' \
  'ReSukiSU + SUSFS + NoMount (experimental)'; do
  if resolve_root_solution "$retired_root_option" >/dev/null 2>&1; then
    fail "removed root preset must be rejected: $retired_root_option"
  fi
done
grep -Fq -- '- BakaSU' "$WORKFLOW_FILE" \
  || fail "workflow is missing the BakaSU root option"
grep -Fq -- '- BakaSU + SUSFS' "$WORKFLOW_FILE" \
  || fail "workflow is missing the BakaSU SUSFS root option"
grep -Fq -- '- BakaSU + SUSFS + NoMount (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the BakaSU NoMount root option"
grep -Fq -- '- "678"' "$WORKFLOW_FILE" \
  || fail "workflow is missing the Droidspaces kABI slot input"
grep -Fq 'droidspaces_ntsync:' "$WORKFLOW_FILE" \
  || fail "workflow is missing the Droidspaces NTSync input"
for retired_option in ZeroMount KPM SukiSU KowSU 'KernelSU-Next' 'Official KernelSU'; do
  if grep -Fq "$retired_option" "$WORKFLOW_FILE"; then
    fail "workflow still offers a removed integration: $retired_option"
  fi
done
grep -Fq 'name: Build ${{ matrix.root_solution }}' "$WORKFLOW_FILE" \
  || fail "workflow build job does not use the root-solution matrix"
grep -Fq 'ARTIFACT_NAME="kernel-package-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${KSU_TYPE}${DROIDSPACES_SUFFIX}"' "$WORKFLOW_FILE" \
  || fail "workflow package artifact names must include the root and Droidspaces mode"

# Every root preset advertised by the workflow must resolve through the
# mapping library, and only BakaSU presets may remain.
root_solution_block="$(sed -n '/^      root_solution:/,/^      droidspaces:/p' "$WORKFLOW_FILE")"
mapfile -t workflow_root_options < <(sed -n 's/^          - //p' <<< "$root_solution_block")
assert_eq "4" "${#workflow_root_options[@]}" "workflow root option count"
assert_eq "No root changes BakaSU BakaSU + SUSFS BakaSU + SUSFS + NoMount (experimental)" \
  "${workflow_root_options[*]}" "workflow root options"
for workflow_root_option in "${workflow_root_options[@]}"; do
  resolve_root_solution "$workflow_root_option" \
    || fail "workflow root option does not resolve: $workflow_root_option"
done

# The Droidspaces slot choices advertised by the workflow must match the
# mapping library exactly.
droidspaces_block="$(sed -n '/^      droidspaces:/,/^      droidspaces_ntsync:/p' "$WORKFLOW_FILE")"
mapfile -t workflow_droidspaces_slots < <(sed -n 's/^          - "\(.*\)"$/\1/p' <<< "$droidspaces_block")
mapfile -t mapped_droidspaces_slots < <(droidspaces_slot_choices)
assert_eq "${mapped_droidspaces_slots[*]}" "${workflow_droidspaces_slots[*]}" \
  "workflow Droidspaces slot choices"
grep -Fq 'DROIDSPACES_SUFFIX="-droidspaces-${DROIDSPACES_SLOT}"' "$WORKFLOW_FILE" \
  || fail "workflow package artifact names must include the Droidspaces mode"

grep -Fq 'KSU_REPO="https://github.com/Baka-SU/BakaSU.git"' "$RESOLVER_SCRIPT" \
  || fail "resolver must use the BakaSU repository"
grep -Fq 'KSU_REF="b2c595ddfa64b685e5a144ad37b7c95f912fb92a"' "$RESOLVER_SCRIPT" \
  || fail "resolver must pin the tested BakaSU revision"
grep -Fq '"BakaSU"|"BakaSU-with-susfs"|"BakaSU-with-susfs-nomount")' "$KSU_SETUP_SCRIPT" \
  || fail "KernelSU setup must install BakaSU for every preset"
if grep -Fq 'tiann/KernelSU' "$RESOLVER_SCRIPT" "$KSU_SETUP_SCRIPT"; then
  fail "resolver still references Official KernelSU"
fi
if grep -Fq 'KernelSU-Next' "$RESOLVER_SCRIPT" "$KSU_SETUP_SCRIPT"; then
  fail "resolver still references KernelSU-Next"
fi
if grep -Fq 'SukiSU' "$RESOLVER_SCRIPT" "$KSU_SETUP_SCRIPT" "$SUSFS_APPLY_SCRIPT"; then
  fail "resolver still references SukiSU"
fi
if grep -Eq 'KPM' "$COMPILE_SCRIPT" "${SCRIPT_DIR}/../lib/verify.sh" "${SCRIPT_DIR}/../lib/kernel-helpers.sh"; then
  fail "KPM integration is still wired into the build"
fi

grep -Fq 'DROIDSPACES_COMMIT="9cf13113f0bbcc6c86d76dcf20647ffca8a30647"' "$RESOLVER_SCRIPT" \
  || fail "Droidspaces patch source is not pinned to the tested commit"
grep -Fq 'DROIDSPACES_NTSYNC_COMMIT="9ce4f6d896e0fbc266f1a058e048fb95fa3ceef0"' "$RESOLVER_SCRIPT" \
  || fail "Droidspaces NTSync patch source is not pinned to the tested commit"
grep -Fq 'patch -p1 --dry-run --batch --forward --fuzz=3' "$DROIDSPACES_SETUP_SCRIPT" \
  || fail "Droidspaces integration must validate the whole patch before applying it"
grep -Fq 'droidspaces_config_enabled_in_inputs CONFIG_SYSVIPC' "$DROIDSPACES_SETUP_SCRIPT" \
  || fail "Droidspaces integration must preserve an already enabled stock SYSVIPC ABI"
grep -Fq 'droidspaces_config_enabled_in_inputs CONFIG_POSIX_MQUEUE' "$DROIDSPACES_SETUP_SCRIPT" \
  || fail "Droidspaces integration must preserve an already enabled stock POSIX_MQUEUE ABI"
grep -Fq -- '- BakaSU + SUSFS + NoMount (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing BakaSU NoMount"
grep -Fq 'droidspaces: "678"' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing the Droidspaces 5.10 slot coverage"
grep -Fq 'droidspaces: "123"' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing the Droidspaces 5.15 slot coverage"
grep -Fq 'droidspaces: "345"' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing the Droidspaces 6.1 slot coverage"
grep -Fq 'droidspaces_ntsync: true' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing the Droidspaces NTSync coverage"
if grep -Fq 'ZeroMount' "$UPSTREAM_HEALTH_WORKFLOW"; then
  fail "upstream health still exercises ZeroMount"
fi

resolve_clang_version "Recommended (auto-select based on branch)" "lineage-23.2"
assert_eq "clang-r563880c" "$CLANG_VERSION" "LineageOS 23.2 clang"
resolve_clang_version "Recommended (auto-select based on branch)" "main"
assert_eq "clang-r596125" "$CLANG_VERSION" "mainline clang"
for android17_branch in 17.0 17.1 lineage-24.0 seventeen seventeen-qpr1 android17; do
  resolve_clang_version "Recommended (auto-select based on branch)" "$android17_branch"
  assert_eq "clang-r584948" "$CLANG_VERSION" "$android17_branch clang"
  infer_android_versions "$android17_branch"
  assert_eq "17" "$SUPPORTED_ANDROID_VERSIONS" "$android17_branch Android version"
done
resolve_clang_version "clang-r584948 (Android 17 / crDroid 13 era)" 16.0
assert_eq "clang-r584948" "$CLANG_VERSION" "manual crDroid 13 compiler override"
for older_branch in 13.0 14.0 15.0 16.0; do
  infer_android_versions "$older_branch"
  assert_eq "${older_branch%%.*}" "$SUPPORTED_ANDROID_VERSIONS" "$older_branch Android version"
done
resolve_clang_version "Recommended (auto-select based on branch)" 16.0
assert_eq "clang-r563880c" "$CLANG_VERSION" "retained crDroid 12 compiler"

resolve_susfs_settings sm8550 lineage-20.0
assert_eq "gki-android13-5.15" "$SUSFS_REF" "Android 13 susfs"
resolve_susfs_settings sm8550 lineage-23.2
assert_eq "gki-android14-5.15" "$SUSFS_REF" "Android 16 susfs"
resolve_susfs_settings sm7550 lineage-23.0
assert_eq "gki-android14-5.15" "$SUSFS_REF" "Nord CE4 susfs"
for crdroid_soc in sm7550 sm8550 sm8650; do
  resolve_susfs_settings "$crdroid_soc" 17.0
  if [[ "$crdroid_soc" == sm8650 ]]; then
    assert_eq "gki-android14-6.1" "$SUSFS_REF" "crDroid 13 OnePlus 12 GKI base"
  else
    assert_eq "gki-android14-5.15" "$SUSFS_REF" "crDroid 13 $crdroid_soc GKI base"
  fi
done
version_is_at_least 2.2.0 2.2.0 || fail "SUSFS minimum version equality"
version_is_at_least 2.3.0 2.2.0 || fail "SUSFS newer version acceptance"
if version_is_at_least 2.1.9 2.2.0; then
  fail "SUSFS old version rejection"
fi

infer_android_versions oneplus/sm8550_v_15.0.0_oneplus11
assert_eq "15" "$SUPPORTED_ANDROID_VERSIONS" "OnePlus Android 15 detection"
infer_android_versions sixteen-qpr2
assert_eq "16" "$SUPPORTED_ANDROID_VERSIONS" "Android 16 development detection"

ANYKERNEL_FIXTURE="$(mktemp)"
UPDATE_BINARY_FIXTURE="$(mktemp)"
APP_STAGING_FIXTURE="$(mktemp)"
BAKASU_NOMOUNT_CONFIG_FIXTURE="$(mktemp)"
DROIDSPACES_CONFIG_FIXTURE="$(mktemp)"
DROIDSPACES_FIXTURE_DIR="$(mktemp -d)"
MODULE_CONFIG_FIXTURE="$(mktemp)"
SCMVERSION_FIXTURE="$(mktemp)"
NOMOUNT_FIXTURE_DIR="$(mktemp -d)"
EXTRACT_CERT_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_CACHE_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_PACKAGE_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_SLOT_FIXTURE_DIR="$(mktemp -d)"
SUSFS_VENDOR_FIXTURE_DIR="$(mktemp -d)"
RESOLVER_FIXTURE_DIR="$(mktemp -d)"
trap 'rm -f "$ANYKERNEL_FIXTURE" "$UPDATE_BINARY_FIXTURE" "$APP_STAGING_FIXTURE" "$BAKASU_NOMOUNT_CONFIG_FIXTURE" "$DROIDSPACES_CONFIG_FIXTURE" "$MODULE_CONFIG_FIXTURE" "$SCMVERSION_FIXTURE"; rm -rf "$NOMOUNT_FIXTURE_DIR" "$DROIDSPACES_FIXTURE_DIR" "$EXTRACT_CERT_FIXTURE_DIR" "$ANYKERNEL_CACHE_FIXTURE_DIR" "$ANYKERNEL_PACKAGE_FIXTURE_DIR" "$ANYKERNEL_SLOT_FIXTURE_DIR" "$SUSFS_VENDOR_FIXTURE_DIR" "$RESOLVER_FIXTURE_DIR"' EXIT

# Exercise the real resolver with offline upstream refs, including a default
# branch migration to 17.0 and an explicit selection of the older 16.0 branch.
mkdir -p "$RESOLVER_FIXTURE_DIR/bin"
cat > "$RESOLVER_FIXTURE_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" != ls-remote ]]; then
  exec "${RESOLVER_REAL_GIT:?}" "$@"
fi
if [[ "$2" == --symref ]]; then
  printf 'ref: refs/heads/17.0\tHEAD\n'
  exit 0
fi
commit=1111111111111111111111111111111111111111
for argument in "$@"; do
  if [[ "$argument" == *-modules.git ]]; then
    commit=2222222222222222222222222222222222222222
  fi
done
printf '%s\trefs/heads/%s\n' "$commit" "${@: -1}"
EOF
chmod +x "$RESOLVER_FIXTURE_DIR/bin/git"
RESOLVER_REAL_GIT="$(command -v git)"
for crdroid_profile in \
  "SM7550 | OnePlus Nord CE4 | crDroid (recommended for crDroid)" \
  "SM8550 | OnePlus 11 / 12R | crDroid" \
  "SM8650 | OnePlus 12 | crDroid"; do
  resolve_build_profile "$crdroid_profile"
  for resolver_case in automatic-17 manual-17 manual-16; do
    resolver_mode="I want to select the branch myself"
    resolver_branch=17.0
    expected_android=17
    expected_clang=clang-r584948
    if [[ "$resolver_case" == automatic-17 ]]; then
      resolver_mode="Use the recommended branch automatically"
      resolver_branch=""
    elif [[ "$resolver_case" == manual-16 ]]; then
      resolver_branch=16.0
      expected_android=16
      expected_clang=clang-r563880c
    fi
    expected_branch="${resolver_branch:-17.0}"
    : > "$RESOLVER_FIXTURE_DIR/env"
    : > "$RESOLVER_FIXTURE_DIR/output"
    : > "$RESOLVER_FIXTURE_DIR/summary"
    PATH="$RESOLVER_FIXTURE_DIR/bin:$PATH" \
    RESOLVER_REAL_GIT="$RESOLVER_REAL_GIT" \
    INPUT_BUILD_PROFILE="$crdroid_profile" \
    INPUT_BRANCH_MODE="$resolver_mode" \
    INPUT_KERNEL_BRANCH="$resolver_branch" \
    INPUT_CLANG_CHOICE="Recommended (auto-select based on branch)" \
    INPUT_ROOT_SOLUTION="No root changes" \
    INPUT_BUILD_MODE="Patch/config validation only" \
    INPUT_ROM_GKI_MODULE_COMPAT="Strict GKI module checks (default)" \
    GITHUB_ENV="$RESOLVER_FIXTURE_DIR/env" \
    GITHUB_OUTPUT="$RESOLVER_FIXTURE_DIR/output" \
    GITHUB_STEP_SUMMARY="$RESOLVER_FIXTURE_DIR/summary" \
      bash "$RESOLVER_SCRIPT" > "$RESOLVER_FIXTURE_DIR/log" \
      || fail "$crdroid_profile $resolver_case resolver failed"
    for expected_field in \
      "PROFILE_ID=$PROFILE_ID" \
      "KERNEL_REPO=https://github.com/crdroidandroid/android_kernel_oneplus_${UPSTREAM_SOC}.git" \
      "MODULES_REPO=https://github.com/crdroidandroid/android_kernel_oneplus_${UPSTREAM_SOC}-modules.git" \
      "KERNEL_BRANCH=$expected_branch" "MODULES_BRANCH=$expected_branch" \
      "KERNEL_COMMIT=1111111111111111111111111111111111111111" \
      "MODULES_COMMIT=2222222222222222222222222222222222222222" \
      "CLANG_VERSION=$expected_clang" "SUPPORTED_ANDROID_VERSIONS=$expected_android" \
      "KERNEL_MAKE_FLAGS=$KERNEL_MAKE_FLAGS"; do
      grep -Fxq "$expected_field" "$RESOLVER_FIXTURE_DIR/env" \
        || fail "$crdroid_profile $resolver_case missing $expected_field"
    done
    grep -Fxq "supported_android_versions=$expected_android" "$RESOLVER_FIXTURE_DIR/output" \
      || fail "$crdroid_profile $resolver_case output Android version"
    grep -Fq "Android package check: $expected_android" "$RESOLVER_FIXTURE_DIR/summary" \
      || fail "$crdroid_profile $resolver_case summary Android version"
    if grep -Eq '::warning::|disabled' "$RESOLVER_FIXTURE_DIR/log"; then
      fail "$crdroid_profile $resolver_case emitted an unexpected warning"
    fi
  done
done

# BakaSU is the only supported root solution and is always pinned to the
# tested revision so that a moving main cannot change an otherwise identical
# build.
for root_preset in \
  'BakaSU' \
  'BakaSU + SUSFS' \
  'BakaSU + SUSFS + NoMount (experimental)'; do
  : > "$RESOLVER_FIXTURE_DIR/env"
  PATH="$RESOLVER_FIXTURE_DIR/bin:$PATH" \
  RESOLVER_REAL_GIT="$RESOLVER_REAL_GIT" \
  INPUT_BUILD_PROFILE='SM8550 | OnePlus 11 / 12R | crDroid' \
  INPUT_BRANCH_MODE='Use the recommended branch automatically' \
  INPUT_CLANG_CHOICE='Recommended (auto-select based on branch)' \
  INPUT_ROOT_SOLUTION="$root_preset" \
  INPUT_BUILD_MODE='Patch/config validation only' \
  GITHUB_ENV="$RESOLVER_FIXTURE_DIR/env" \
  GITHUB_OUTPUT="$RESOLVER_FIXTURE_DIR/output" \
  GITHUB_STEP_SUMMARY="$RESOLVER_FIXTURE_DIR/summary" \
    bash "$RESOLVER_SCRIPT" > "$RESOLVER_FIXTURE_DIR/log" \
    || fail "$root_preset resolver failed"
  grep -Fxq 'KSU_REPO=https://github.com/Baka-SU/BakaSU.git' "$RESOLVER_FIXTURE_DIR/env" \
    || fail "$root_preset must resolve the BakaSU repository"
  grep -Fxq 'KSU_COMMIT=b2c595ddfa64b685e5a144ad37b7c95f912fb92a' "$RESOLVER_FIXTURE_DIR/env" \
    || fail "$root_preset lost its BakaSU pin"
done

# Droidspaces integration: kernel series detection, kABI slot/patch mapping,
# NTSync patch mapping and the stock-ABI guard are pure or fixture-driven so
# they can be verified without cloning a kernel.
mkdir -p "$DROIDSPACES_FIXTURE_DIR/kernel"
printf '%s\n' 'VERSION = 5' 'PATCHLEVEL = 15' 'SUBLEVEL = 123' \
  > "$DROIDSPACES_FIXTURE_DIR/kernel/Makefile"
assert_eq "5.15" "$(detect_kernel_series "$DROIDSPACES_FIXTURE_DIR/kernel/Makefile")" \
  "Droidspaces 5.15 series detection"
printf '%s\n' 'VERSION = 6' 'PATCHLEVEL = 12' \
  > "$DROIDSPACES_FIXTURE_DIR/kernel/Makefile"
assert_eq "6.12" "$(detect_kernel_series "$DROIDSPACES_FIXTURE_DIR/kernel/Makefile")" \
  "Droidspaces 6.12 series detection"
if detect_kernel_series "$DROIDSPACES_FIXTURE_DIR/missing-Makefile" >/dev/null 2>&1; then
  fail "Droidspaces series detection accepted a missing kernel Makefile"
fi

assert_eq "6_7_8" "$(droidspaces_slot_name 678)" "Droidspaces slot 678 mapping"
assert_eq "1_2_3" "$(droidspaces_slot_name 123)" "Droidspaces slot 123 mapping"
assert_eq "3_4_5" "$(droidspaces_slot_name 345)" "Droidspaces slot 345 mapping"
assert_eq "" "$(droidspaces_slot_name off)" "Droidspaces disabled slot mapping"
if droidspaces_slot_name 999 >/dev/null 2>&1; then
  fail "Droidspaces accepted an unknown kABI slot"
fi
for droidspaces_series in 5.10 5.15 6.1 6.6; do
  assert_eq \
    "Documentation/resources/kernel-patches/GKI/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_3_4_5.patch" \
    "$(droidspaces_gki_patch_relpath "$droidspaces_series" 3_4_5)" \
    "Droidspaces $droidspaces_series kABI patch mapping"
done
for droidspaces_series in 6.12 6.18; do
  assert_eq \
    "Documentation/resources/kernel-patches/GKI/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch" \
    "$(droidspaces_gki_patch_relpath "$droidspaces_series" 6_7_8)" \
    "Droidspaces $droidspaces_series kABI patch mapping"
done
if droidspaces_gki_patch_relpath 4.19 6_7_8 >/dev/null 2>&1; then
  fail "Droidspaces accepted an unsupported kernel series"
fi
assert_eq "android12-5.10" "$(droidspaces_ntsync_patch_name 5.10 12)" \
  "Droidspaces NTSync 5.10 patch mapping"
assert_eq "android12-5.10_OOS14" "$(droidspaces_ntsync_patch_name 5.10 14)" \
  "Droidspaces NTSync 5.10 OOS14 patch mapping"
assert_eq "android13-5.15" "$(droidspaces_ntsync_patch_name 5.15 15)" \
  "Droidspaces NTSync 5.15 patch mapping"
assert_eq "android14-6.1" "$(droidspaces_ntsync_patch_name 6.1 14)" \
  "Droidspaces NTSync 6.1 patch mapping"
assert_eq "android15-6.6" "$(droidspaces_ntsync_patch_name 6.6 15)" \
  "Droidspaces NTSync 6.6 patch mapping"
assert_eq "android16-6.12" "$(droidspaces_ntsync_patch_name 6.12 16)" \
  "Droidspaces NTSync 6.12 patch mapping"
if droidspaces_ntsync_patch_name 4.19 12 >/dev/null 2>&1; then
  fail "Droidspaces NTSync accepted an unsupported kernel series"
fi

# The stock ABI guard must detect an already enabled option in the base
# defconfig or in any active vendor fragment.
mkdir -p "$DROIDSPACES_FIXTURE_DIR/config/arch/arm64/configs"
printf '%s\n' '# CONFIG_SYSVIPC is not set' \
  > "$DROIDSPACES_FIXTURE_DIR/config/arch/arm64/configs/gki_defconfig"
printf '%s\n' 'CONFIG_SYSVIPC=y' \
  > "$DROIDSPACES_FIXTURE_DIR/config/arch/arm64/configs/vendor.config"
(
  cd "$DROIDSPACES_FIXTURE_DIR/config"
  ACTIVE_BUILD_CONFIGS="arch/arm64/configs/vendor.config"
  droidspaces_config_enabled_in_inputs CONFIG_SYSVIPC >/dev/null \
    || fail "Droidspaces did not detect SYSVIPC in a vendor fragment"
  if droidspaces_config_enabled_in_inputs CONFIG_POSIX_MQUEUE >/dev/null; then
    fail "Droidspaces reported a disabled option as enabled"
  fi
)

# Enabling Droidspaces must turn on the guarded container options, skip
# symbols the source does not define and disable Android's paranoid network
# option when the kernel implements it.
cat > "$DROIDSPACES_FIXTURE_DIR/config/Kconfig" <<'EOF'
config SYSVIPC
	bool "System V IPC"
config POSIX_MQUEUE
	bool "POSIX Message Queues"
config IPC_NS
	bool "IPC Namespaces"
config PID_NS
	bool "PID Namespaces"
config DEVTMPFS
	bool "Maintain a devtmpfs"
config ANDROID_PARANOID_NETWORK
	bool "Android paranoid network"
config NETFILTER_XT_MATCH_ADDRTYPE
	bool "addrtype match"
config IP_SET
	bool "IP set support"
EOF
cp "$DROIDSPACES_FIXTURE_DIR/config/arch/arm64/configs/gki_defconfig" \
  "$DROIDSPACES_CONFIG_FIXTURE"
printf '%s\n' 'CONFIG_ANDROID_PARANOID_NETWORK=y' >> "$DROIDSPACES_CONFIG_FIXTURE"
(
  cd "$DROIDSPACES_FIXTURE_DIR/config"
  KSU_TYPE=None DROIDSPACES_SLOT=678 DROIDSPACES_NTSYNC=true \
    apply_variant_configs "$DROIDSPACES_CONFIG_FIXTURE"
)
for droidspaces_key in \
  CONFIG_SYSVIPC CONFIG_POSIX_MQUEUE CONFIG_IPC_NS CONFIG_PID_NS \
  CONFIG_DEVTMPFS CONFIG_NTSYNC CONFIG_NETFILTER_XT_MATCH_ADDRTYPE CONFIG_IP_SET; do
  grep -q "^${droidspaces_key}=y$" "$DROIDSPACES_CONFIG_FIXTURE" \
    || fail "Droidspaces did not enable $droidspaces_key"
done
grep -q '^# CONFIG_ANDROID_PARANOID_NETWORK is not set$' "$DROIDSPACES_CONFIG_FIXTURE" \
  || fail "Droidspaces did not disable Android paranoid networking"
if grep -q 'CONFIG_IP_SET_HASH_IP' "$DROIDSPACES_CONFIG_FIXTURE"; then
  fail "Droidspaces enabled an optional symbol the source does not define"
fi

DROIDSPACES_DISABLED_FIXTURE="$(mktemp)"
printf '%s\n' 'CONFIG_SYSVIPC=y' > "$DROIDSPACES_DISABLED_FIXTURE"
(
  cd "$DROIDSPACES_FIXTURE_DIR/config"
  KSU_TYPE=None DROIDSPACES_SLOT=off DROIDSPACES_NTSYNC=false \
    apply_variant_configs "$DROIDSPACES_DISABLED_FIXTURE"
)
assert_eq "CONFIG_SYSVIPC=y" "$(cat "$DROIDSPACES_DISABLED_FIXTURE")" \
  "disabled Droidspaces must not change the config"
rm -f "$DROIDSPACES_DISABLED_FIXTURE"

# Droidspaces workflow inputs resolve to exact pinned patch commits and reject
# NTSync without the container support.
: > "$RESOLVER_FIXTURE_DIR/env"
PATH="$RESOLVER_FIXTURE_DIR/bin:$PATH" \
RESOLVER_REAL_GIT="$RESOLVER_REAL_GIT" \
INPUT_BUILD_PROFILE='SM8550 | OnePlus 11 / 12R | LineageOS (recommended)' \
INPUT_BRANCH_MODE='Use the recommended branch automatically' \
INPUT_CLANG_CHOICE='Recommended (auto-select based on branch)' \
INPUT_ROOT_SOLUTION='BakaSU + SUSFS + NoMount (experimental)' \
INPUT_DROIDSPACES=678 \
INPUT_DROIDSPACES_NTSYNC=true \
INPUT_BUILD_MODE='Patch/config validation only' \
GITHUB_ENV="$RESOLVER_FIXTURE_DIR/env" \
GITHUB_OUTPUT="$RESOLVER_FIXTURE_DIR/output" \
GITHUB_STEP_SUMMARY="$RESOLVER_FIXTURE_DIR/summary" \
  bash "$RESOLVER_SCRIPT" > "$RESOLVER_FIXTURE_DIR/log" \
  || fail "Droidspaces resolver case failed"
for expected_field in \
  'DROIDSPACES_SLOT=678' \
  'DROIDSPACES_SLOT_NAME=6_7_8' \
  'DROIDSPACES_ENABLED=1' \
  'DROIDSPACES_COMMIT=9cf13113f0bbcc6c86d76dcf20647ffca8a30647' \
  'DROIDSPACES_NTSYNC=true' \
  'DROIDSPACES_NTSYNC_COMMIT=9ce4f6d896e0fbc266f1a058e048fb95fa3ceef0'; do
  grep -Fxq "$expected_field" "$RESOLVER_FIXTURE_DIR/env" \
    || fail "Droidspaces resolver output missing $expected_field"
done
grep -Fq 'Droidspaces: kABI slot 678' "$RESOLVER_FIXTURE_DIR/summary" \
  || fail "Droidspaces resolver summary is missing the selected slot"
if PATH="$RESOLVER_FIXTURE_DIR/bin:$PATH" \
   RESOLVER_REAL_GIT="$RESOLVER_REAL_GIT" \
   INPUT_BUILD_PROFILE='SM8550 | OnePlus 11 / 12R | LineageOS (recommended)' \
   INPUT_BRANCH_MODE='Use the recommended branch automatically' \
   INPUT_CLANG_CHOICE='Recommended (auto-select based on branch)' \
   INPUT_ROOT_SOLUTION='No root changes' \
   INPUT_DROIDSPACES=off \
   INPUT_DROIDSPACES_NTSYNC=true \
   INPUT_BUILD_MODE='Patch/config validation only' \
   GITHUB_ENV="$RESOLVER_FIXTURE_DIR/env" \
   GITHUB_OUTPUT="$RESOLVER_FIXTURE_DIR/output" \
   GITHUB_STEP_SUMMARY="$RESOLVER_FIXTURE_DIR/summary" \
     bash "$RESOLVER_SCRIPT" >/dev/null 2>&1; then
  fail "resolver accepted NTSync without Droidspaces"
fi
if PATH="$RESOLVER_FIXTURE_DIR/bin:$PATH" \
   RESOLVER_REAL_GIT="$RESOLVER_REAL_GIT" \
   INPUT_BUILD_PROFILE='SM8550 | OnePlus 11 / 12R | LineageOS (recommended)' \
   INPUT_BRANCH_MODE='Use the recommended branch automatically' \
   INPUT_CLANG_CHOICE='Recommended (auto-select based on branch)' \
   INPUT_ROOT_SOLUTION='No root changes' \
   INPUT_DROIDSPACES=999 \
   INPUT_BUILD_MODE='Patch/config validation only' \
   GITHUB_ENV="$RESOLVER_FIXTURE_DIR/env" \
   GITHUB_OUTPUT="$RESOLVER_FIXTURE_DIR/output" \
   GITHUB_STEP_SUMMARY="$RESOLVER_FIXTURE_DIR/summary" \
     bash "$RESOLVER_SCRIPT" >/dev/null 2>&1; then
  fail "resolver accepted an invalid Droidspaces slot"
fi

mkdir -p "$SUSFS_VENDOR_FIXTURE_DIR/fs"
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/namespace.c" <<'EOF'
#include <linux/mnt_idmapping.h>

#include "pnode.h"
#include "internal.h"

/* Maximum number of mounts in a mount namespace */
EOF
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c" <<'EOF'
#include <linux/fs_context.h>
#include <uapi/linux/mount.h>
#include "internal.h"

static int thaw_super_locked(struct super_block *sb);
EOF
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/namespace.c.rej" <<'EOF'
+#include <linux/susfs_def.h>
+extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
EOF
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c.rej" <<'EOF'
+#include <linux/susfs_def.h>
+extern bool susfs_is_current_ksu_domain(void);
EOF
(
  cd "$SUSFS_VENDOR_FIXTURE_DIR"
  resolve_known_susfs_rejects >/dev/null
)
test ! -e "$SUSFS_VENDOR_FIXTURE_DIR/fs/namespace.c.rej" \
  || fail "SM8650 SUSFS recovery left the namespace reject in place"
test ! -e "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c.rej" \
  || fail "SM8650 SUSFS recovery left the superblock reject in place"
grep -Fq '#include <linux/susfs_def.h>' "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c" \
  || fail "SM8650 SUSFS recovery did not add the superblock header"
grep -Fq 'extern bool susfs_is_current_ksu_domain(void);' "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c" \
  || fail "SM8650 SUSFS recovery did not add the superblock domain declaration"

# Link the generated SELinux compatibility object with all combinations of
# native symbols. Source inspection alone misses duplicate definitions at LTO.
for native_symbols in neither fake running both; do
  selinux_fixture="$SUSFS_VENDOR_FIXTURE_DIR/selinux-$native_symbols"
  mkdir -p "$selinux_fixture/include/linux" "$selinux_fixture/compat"
  printf '%s\n' '#define __read_mostly' '#define __maybe_static' > "$selinux_fixture/include/linux/cache.h"
  echo '#include <stdbool.h>' > "$selinux_fixture/include/linux/types.h"
  echo 'struct selinux_state { int initialized; };' > "$selinux_fixture/include/security.h"
  cat > "$selinux_fixture/native.c" <<'EOF'
#include <linux/cache.h>
#include <linux/types.h>
#include "security.h"
EOF
  if [[ "$native_symbols" == fake || "$native_symbols" == both ]]; then
    echo '__maybe_static struct selinux_state fake_state;' >> "$selinux_fixture/native.c"
  fi
  if [[ "$native_symbols" == running || "$native_symbols" == both ]]; then
    echo 'bool ksu_selinux_hide_running __read_mostly = false;' >> "$selinux_fixture/native.c"
  fi
  # Patch backups and stale generated files must not count as native symbols.
  printf '%s\n' 'struct selinux_state fake_state;' 'bool ksu_selinux_hide_running;' \
    > "$selinux_fixture/native.c.orig"
  cp "$selinux_fixture/native.c.orig" "$selinux_fixture/compat/susfs_selinux_hide_compat.c"
  echo 'kernelsu-objs += compat/susfs_selinux_hide_compat.o' > "$selinux_fixture/Kbuild"
  patch_susfs_selinux_hide_compat "$selinux_fixture" >/dev/null
  patch_susfs_selinux_hide_compat "$selinux_fixture" >/dev/null
  cc -DCONFIG_KSU_SUSFS -fno-common -I "$selinux_fixture/include" \
    -c "$selinux_fixture/native.c" -o "$selinux_fixture/native.o"
  if [[ "$native_symbols" == both ]]; then
    test ! -f "$selinux_fixture/compat/susfs_selinux_hide_compat.c" \
      || fail "native SELinux symbols left a stale compatibility object"
    test ! -s "$selinux_fixture/Kbuild" \
      || fail "native SELinux symbols left stale Kbuild wiring"
  else
    assert_eq 1 "$(grep -c 'kernelsu-objs += compat/susfs_selinux_hide_compat.o' "$selinux_fixture/Kbuild")" \
      "SELinux compatibility Kbuild idempotence ($native_symbols)"
    cc -DCONFIG_KSU_SUSFS -fno-common -I "$selinux_fixture/include" \
      -c "$selinux_fixture/compat/susfs_selinux_hide_compat.c" -o "$selinux_fixture/compat.o"
    cc -r "$selinux_fixture/native.o" "$selinux_fixture/compat.o" -o "$selinux_fixture/linked.o" \
      || fail "SELinux compatibility duplicates native symbols ($native_symbols)"
  fi
done

ANYKERNEL_TEMPLATE_FIXTURE="$(mktemp)"
printf '%s\n' placeholder > "$ANYKERNEL_TEMPLATE_FIXTURE"
chmod 755 "$ANYKERNEL_TEMPLATE_FIXTURE"
install_anykernel_template "$ANYKERNEL_TEMPLATE" "$ANYKERNEL_TEMPLATE_FIXTURE"
grep -Fxq 'BLOCK=boot;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not target boot by partition name"
grep -Fxq 'IS_SLOT_DEVICE=1;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not enable A/B slot detection"
grep -Fxq 'SLOT_SELECT=active;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not pin flashing to the active slot"
grep -Fxq 'PATCH_VBMETA_FLAG=0;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not preserve the boot vbmeta flag"
grep -Fxq 'NO_MAGISK_CHECK=1;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not skip unnecessary Magisk ramdisk handling"
grep -Fxq 'NO_VBMETA_PARTITION_PATCH=1;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not protect the standalone vbmeta partition"
grep -Fq 'Active-slot boot target verification failed' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not verify the resolved active-slot boot target"
grep -Fxq 'split_boot;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not support ramdiskless boot images"
grep -Fxq 'flash_boot;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not preserve a ramdiskless boot layout"
if grep -Eq '^[[:space:]]*(dump_boot|write_boot);' "$ANYKERNEL_TEMPLATE_FIXTURE"; then
  fail "AnyKernel device template still requires a boot ramdisk"
fi
grep -Fq 'Stage 1/3: dumping and splitting boot image' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not report the dump stage"
grep -Fq 'Stage 3/3: rebuilding and flashing boot image' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not report the flash stage"
if grep -Eq 'omap_hsmmc|maguro|toro|tuna' "$ANYKERNEL_TEMPLATE_FIXTURE"; then
  fail "AnyKernel device template retained an upstream example-device setting"
fi

mkdir -p "$ANYKERNEL_SLOT_FIXTURE_DIR/tools"
cp "$ANYKERNEL_TEMPLATE_FIXTURE" "$ANYKERNEL_SLOT_FIXTURE_DIR/anykernel.sh"
cat > "$ANYKERNEL_SLOT_FIXTURE_DIR/tools/ak3-core.sh" <<'EOF'
ui_print() { :; }
abort() {
  printf '%s\n' "$*"
  exit 97
}
SLOT="${TEST_RESOLVED_SLOT:?}"
BLOCK="${TEST_RESOLVED_BLOCK:?}"
split_boot() { printf '%s\n' split >> "$TEST_TRACE"; }
flash_boot() { printf '%s\n' flash >> "$TEST_TRACE"; }
EOF
SLOT_TRACE="$ANYKERNEL_SLOT_FIXTURE_DIR/trace"
(
  cd "$ANYKERNEL_SLOT_FIXTURE_DIR"
  TEST_RESOLVED_SLOT=_a \
    TEST_RESOLVED_BLOCK=/dev/block/by-name/boot_a \
    TEST_TRACE="$SLOT_TRACE" \
    sh anykernel.sh
)
assert_eq $'split\nflash' "$(cat "$SLOT_TRACE")" \
  "AnyKernel verified active-slot flash path"
rm -f "$SLOT_TRACE"
if (
  cd "$ANYKERNEL_SLOT_FIXTURE_DIR"
  TEST_RESOLVED_SLOT=_a \
    TEST_RESOLVED_BLOCK=/dev/block/by-name/boot_b \
    TEST_TRACE="$SLOT_TRACE" \
    sh anykernel.sh >/dev/null 2>&1
); then
  fail "AnyKernel accepted an inactive-slot boot target"
fi
test ! -e "$SLOT_TRACE" \
  || fail "AnyKernel started modifying boot before rejecting an inactive-slot target"
rm -f "$ANYKERNEL_TEMPLATE_FIXTURE"

printf '%s\n' \
  '[ "$AKHOME" ] || export AKHOME=$POSTINSTALL/tmp/anykernel;' \
  'printf "%s\n" "$AKHOME"' \
  > "$APP_STAGING_FIXTURE"
chmod 755 "$APP_STAGING_FIXTURE"
patch_anykernel_app_flash_staging "$APP_STAGING_FIXTURE"
sh -n "$APP_STAGING_FIXTURE" \
  || fail "AnyKernel app-flasher staging produced invalid shell syntax"
APP_PRIVATE_AKHOME="$(
  AKHOME=/data/user/0/com.sukisu.ultra/files/tmp/anykernel \
    POSTINSTALL=/data/user/0/com.sukisu.ultra/files \
    sh "$APP_STAGING_FIXTURE"
)"
[[ "$APP_PRIVATE_AKHOME" == /data/local/tmp/anykernel-* ]] \
  || fail "AnyKernel did not replace an app-private AKHOME: $APP_PRIVATE_AKHOME"
APP_PRIVATE_POSTINSTALL="$(
  AKHOME='' \
    POSTINSTALL=/data/user/0/com.sukisu.ultra/files \
    sh "$APP_STAGING_FIXTURE"
)"
[[ "$APP_PRIVATE_POSTINSTALL" == /data/local/tmp/anykernel-* ]] \
  || fail "AnyKernel did not replace an app-private POSTINSTALL: $APP_PRIVATE_POSTINSTALL"
RECOVERY_AKHOME="$(AKHOME='' POSTINSTALL=/postinstall sh "$APP_STAGING_FIXTURE")"
assert_eq "/postinstall/tmp/anykernel" "$RECOVERY_AKHOME" \
  "AnyKernel recovery staging path"
APP_STAGING_HASH="$(sha256sum "$APP_STAGING_FIXTURE" | cut -d' ' -f1)"
patch_anykernel_app_flash_staging "$APP_STAGING_FIXTURE"
assert_eq "$APP_STAGING_HASH" \
  "$(sha256sum "$APP_STAGING_FIXTURE" | cut -d' ' -f1)" \
  "AnyKernel app-flasher staging idempotence"

(
  cd "$EXTRACT_CERT_FIXTURE_DIR"
  if detect_extract_cert_source >/dev/null; then
    fail "certificate source detection accepted a missing source"
  fi
  mkdir -p scripts certs
  touch scripts/extract-cert.c
  assert_eq scripts/extract-cert.c "$(detect_extract_cert_source)" "5.15 certificate source layout"
  touch certs/extract-cert.c
  assert_eq certs/extract-cert.c "$(detect_extract_cert_source)" "6.1 certificate source layout"
)

cat > "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" <<'EOF'
#include <openssl/engine.h>
#ifdef USE_PKCS11_ENGINE
static const char *key_pass;
#endif
int main(void)
{
#ifndef OPENSSL_IS_BORINGSSL
#ifdef USE_PKCS11_ENGINE
	key_pass = getenv("KBUILD_SIGN_PIN");
#endif
	if (key_pass)
		ENGINE_ctrl_cmd_string(e, "PIN", key_pass, 0);
}
EOF
repair_extract_cert_key_pass_guard "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" >/dev/null
if grep -Fq '#ifdef USE_PKCS11_ENGINE' "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c"; then
  fail "extract-cert compatibility repair left the broken key_pass guards in place"
fi
assert_eq "1" "$(grep -Fc 'static const char *key_pass;' "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c")" \
  "extract-cert key_pass declaration"
assert_eq "1" "$(grep -Fc 'key_pass = getenv("KBUILD_SIGN_PIN");' "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c")" \
  "extract-cert key_pass assignment"
EXTRACT_CERT_REPAIRED_HASH="$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" | cut -d' ' -f1)"
repair_extract_cert_key_pass_guard "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" >/dev/null
assert_eq "$EXTRACT_CERT_REPAIRED_HASH" \
  "$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" | cut -d' ' -f1)" \
  "extract-cert repair idempotence"

cat > "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" <<'EOF'
#define USE_PKCS11_PROVIDER
#ifndef OPENSSL_IS_BORINGSSL
#ifdef USE_PKCS11_ENGINE
static const char *key_pass;
#endif
#ifdef USE_PKCS11_ENGINE
	key_pass = getenv("KBUILD_SIGN_PIN");
#endif
ENGINE_ctrl_cmd_string(e, "PIN", key_pass, 0);
EOF
EXTRACT_CERT_PROVIDER_HASH="$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" | cut -d' ' -f1)"
repair_extract_cert_key_pass_guard "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" >/dev/null
assert_eq "$EXTRACT_CERT_PROVIDER_HASH" \
  "$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" | cut -d' ' -f1)" \
  "provider-aware extract-cert source preservation"

KSU_TYPE="BakaSU-with-susfs-nomount"
apply_variant_configs "$BAKASU_NOMOUNT_CONFIG_FIXTURE"
grep -q '^CONFIG_KSU_SUSFS=y$' "$BAKASU_NOMOUNT_CONFIG_FIXTURE" || fail "BakaSU NoMount SUSFS config"
grep -q '^CONFIG_KSU_SUSFS_SUS_MAP=y$' "$BAKASU_NOMOUNT_CONFIG_FIXTURE" || fail "BakaSU NoMount SUSFS map config"
grep -q '^CONFIG_KSU_SUSFS_OPEN_REDIRECT=y$' "$BAKASU_NOMOUNT_CONFIG_FIXTURE" || fail "BakaSU NoMount SUSFS redirect config"
grep -q '^# CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS is not set$' "$BAKASU_NOMOUNT_CONFIG_FIXTURE" || fail "BakaSU symbol hiding must stay disabled"
grep -q '^CONFIG_KEYS=y$' "$BAKASU_NOMOUNT_CONFIG_FIXTURE" || fail "BakaSU NoMount key config"
grep -q '^CONFIG_NOMOUNT=y$' "$BAKASU_NOMOUNT_CONFIG_FIXTURE" || fail "BakaSU NoMount config"
cat > "$MODULE_CONFIG_FIXTURE" <<'EOF'
CONFIG_MODULES=y
# CONFIG_MODULE_UNLOAD is not set
# CONFIG_MODVERSIONS is not set
# CONFIG_MODULE_FORCE_LOAD is not set
CONFIG_ARCH_INLINE_SPIN_LOCK=y
CONFIG_ARCH_INLINE_SPIN_UNLOCK=y
CONFIG_INLINE_SPIN_LOCK=y
# CONFIG_UNINLINE_SPIN_UNLOCK is not set
CONFIG_TRIM_UNUSED_KSYMS=y
# CONFIG_KASAN is not set
CONFIG_KASAN_GENERIC=y
CONFIG_KASAN_SW_TAGS=y
# CONFIG_KASAN_HW_TAGS is not set
EOF
MODULE_CONFIG_HASH="$(sha256sum "$MODULE_CONFIG_FIXTURE" | cut -d' ' -f1)"
MODULE_ABI_PATTERN='^(CONFIG|# CONFIG)_(MODULES|MODULE_UNLOAD|MODVERSIONS|MODULE_FORCE_LOAD|ARCH_INLINE_SPIN_LOCK|ARCH_INLINE_SPIN_UNLOCK|INLINE_SPIN_LOCK|UNINLINE_SPIN_UNLOCK|TRIM_UNUSED_KSYMS|KASAN|KASAN_GENERIC|KASAN_SW_TAGS|KASAN_HW_TAGS)'
MODULE_ABI_SNAPSHOT="$(grep -E "$MODULE_ABI_PATTERN" "$MODULE_CONFIG_FIXTURE")"
KSU_TYPE="None"
apply_variant_configs "$MODULE_CONFIG_FIXTURE"
assert_eq "$MODULE_CONFIG_HASH" \
  "$(sha256sum "$MODULE_CONFIG_FIXTURE" | cut -d' ' -f1)" \
  "no-root preset must preserve vendor ABI-sensitive configs byte for byte"
KSU_TYPE="BakaSU-with-susfs-nomount"
apply_variant_configs "$MODULE_CONFIG_FIXTURE"
assert_eq "$MODULE_ABI_SNAPSHOT" \
  "$(grep -E "$MODULE_ABI_PATTERN" "$MODULE_CONFIG_FIXTURE")" \
  "root presets must preserve vendor ABI-sensitive configs"
printf '%s\n' 'CONFIG_MODULE_SIG=y' '# CONFIG_MODULE_SIG_FORCE is not set' \
  'CONFIG_MODULE_SIG_PROTECT=y' >> "$MODULE_CONFIG_FIXTURE"
ROM_GKI_MODULE_COMPAT=0
MODULE_CONFIG_HASH="$(sha256sum "$MODULE_CONFIG_FIXTURE" | cut -d' ' -f1)"
apply_rom_gki_module_compat_config "$MODULE_CONFIG_FIXTURE"
assert_eq "$MODULE_CONFIG_HASH" \
  "$(sha256sum "$MODULE_CONFIG_FIXTURE" | cut -d' ' -f1)" \
  "strict mode must preserve GKI protection"
ROM_GKI_MODULE_COMPAT=1
apply_rom_gki_module_compat_config "$MODULE_CONFIG_FIXTURE"
grep -Fqx '# CONFIG_MODULE_SIG_PROTECT is not set' "$MODULE_CONFIG_FIXTURE" \
  || fail "ROM compatibility mode did not disable GKI module protection"
grep -Fqx 'CONFIG_MODULE_SIG=y' "$MODULE_CONFIG_FIXTURE" \
  || fail "ROM compatibility mode disabled module signature verification"
grep -Fqx '# CONFIG_MODULE_SIG_FORCE is not set' "$MODULE_CONFIG_FIXTURE" \
  || fail "ROM compatibility mode changed required module signatures"
ROM_GKI_MODULE_COMPAT=0
grep -Fq 'write_kernel_scmversion "$KERNEL_COMMIT"' "$COMPILE_SCRIPT" \
  || fail "full builds do not pin the ROM-compatible kernel release suffix"
if grep -Fq 'touch .scmversion' "$COMPILE_SCRIPT"; then
  fail "full builds still erase the kernel source identity from vermagic"
fi
write_kernel_scmversion \
  0123456789abcdef0123456789abcdef01234567 \
  "$SCMVERSION_FIXTURE"
assert_eq '-g0123456789ab' "$(cat "$SCMVERSION_FIXTURE")" \
  "kernel source identity suffix"
verify_kernel_release_identity \
  '5.15.211-g0123456789ab' \
  0123456789abcdef0123456789abcdef01234567
if verify_kernel_release_identity \
  '5.15.211' \
  0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  fail "kernel release verification accepted a missing source identity"
fi

printf '%s\n' \
  'kernel.string=placeholder' \
  'do.devicecheck=0' \
  'device.name1=' \
  'device.name2=' \
  'device.name3=' \
  'device.name4=' \
  'device.name5=' \
  'device.name6=' \
  'device.name7=' \
  'supported.versions=' > "$ANYKERNEL_FIXTURE"
chmod 755 "$ANYKERNEL_FIXTURE"
configure_anykernel_properties "$ANYKERNEL_FIXTURE" "Test Kernel" "salami OP591BL1 OP594DL1 aston OP5D35L1 astonc OP5CF9L1" "16"
assert_eq "755" "$(stat -c '%a' "$ANYKERNEL_FIXTURE")" "AnyKernel script permissions"
grep -q '^kernel.string=Test Kernel$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel string"
grep -q '^do.devicecheck=1$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel device check"
grep -q '^device.name1=salami$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel salami mapping"
grep -q '^device.name2=OP591BL1$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel stock ID mapping"
grep -q '^device.name4=aston$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel aston mapping"
grep -q '^device.name5=OP5D35L1$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel 12R stock ID mapping"
grep -q '^device.name6=astonc$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel Ace 3 codename mapping"
grep -q '^device.name7=OP5CF9L1$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel Ace 3 stock ID mapping"
grep -q '^supported.versions=16$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel Android mapping"

git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" init -q
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" config user.name fixture
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" config user.email fixture@example.invalid
printf '%s\n' 'kernel.string=upstream' > "$ANYKERNEL_CACHE_FIXTURE_DIR/anykernel.sh"
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" add anykernel.sh
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" commit -qm fixture
printf '%s\n' 'kernel.string=modified-by-prior-matrix-job' > "$ANYKERNEL_CACHE_FIXTURE_DIR/anykernel.sh"
printf '%s\n' stale > "$ANYKERNEL_CACHE_FIXTURE_DIR/Image"
sanitize_cached_anykernel_checkout "$ANYKERNEL_CACHE_FIXTURE_DIR"
grep -q '^kernel.string=upstream$' "$ANYKERNEL_CACHE_FIXTURE_DIR/anykernel.sh" \
  || fail "cached AnyKernel sanitation did not restore tracked files"
test ! -e "$ANYKERNEL_CACHE_FIXTURE_DIR/Image" \
  || fail "cached AnyKernel sanitation did not remove generated files"
test -z "$(git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" status --porcelain)" \
  || fail "cached AnyKernel sanitation left a dirty checkout"

mkdir -p \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/out/arch/arm64/boot" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8650/out/arch/arm64/boot" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin"
printf '%s\n' \
  'kernel.string=placeholder' \
  'do.devicecheck=0' \
  'device.name1=' \
  'device.name2=' \
  'device.name3=' \
  'device.name4=' \
  'device.name5=' \
  'device.name6=' \
  'device.name7=' \
  'supported.versions=' \
  > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/anykernel.sh"
printf '%s\n' \
  '[ "$AKHOME" ] || export AKHOME=$POSTINSTALL/tmp/anykernel;' \
  'ui_print " " "AnyKernel3 by osm0sis @ xda-developers" " ";' \
  '  if [ ! "$match" ]; then' \
  '    abort " " "Unsupported device. Aborting...";' \
  '  fi;' \
  'setup_bb;' \
  'if [ $? != 0 ]; then exit 1; fi;' \
  'OLD_PATH="$PATH";' \
  > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android/update-binary"
printf '%s\n' upstream-arm-busybox > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/busybox"
printf '%s\n' upstream-arm-magiskboot > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/magiskboot"
for optional_tool in fec httools_static lptools_static magiskpolicy snapshotupdater_static; do
  printf '%s\n' upstream-arm-optional > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/$optional_tool"
done
chmod 755 \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/anykernel.sh" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android/update-binary" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/busybox" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/magiskboot"
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" init -q
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" config user.name fixture
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" config user.email fixture@example.invalid
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" add .
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" commit -qm fixture
ANYKERNEL_PACKAGE_COMMIT="$(git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" rev-parse HEAD)"
git clone -q "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3"
printf '%s\n' 'kernel.string=dirty-cache' > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh"
printf '%s\n' stale > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/Image"
printf '%s\n' image > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/out/arch/arm64/boot/Image"
printf '%s\n' image > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8650/out/arch/arm64/boot/Image"
printf '%s\n' magisk-arm64-magiskboot > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a/libmagiskboot.so"
printf '%s\n' magisk-arm64-busybox > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a/libbusybox.so"
(
  cd "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk"
  zip -q "$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" lib/arm64-v8a/libmagiskboot.so lib/arm64-v8a/libbusybox.so
)
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{}'
EOF
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/zip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' zip-fixture > "$2"
EOF
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/readelf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '  Class:                             ELF64'
printf '%s\n' '  Machine:                           AArch64'
EOF
chmod +x \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/jq" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/zip" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/readelf"

for package_timestamp in 20260101_000000 20260101_000001; do
  (
    cd "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work"
    PATH="$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin:$PATH" \
    SOC=sm8550 \
    PROFILE_ID=test-profile \
    TARGET_NAME='Test target' \
    DEVICE_CODENAMES='salami aston' \
    DEVICE_NAMES='salami aston' \
    SUPPORTED_ANDROID_VERSIONS=16 \
    SOURCE_NAME=test \
    KERNEL_BRANCH=test \
    MODULES_BRANCH=test \
    KERNEL_COMMIT=1111111111111111111111111111111111111111 \
    MODULES_COMMIT=2222222222222222222222222222222222222222 \
    CLANG_VERSION=test-clang \
    KSU_TYPE=BakaSU-with-susfs-nomount \
    KSU_REPO=https://github.com/Baka-SU/BakaSU.git \
    KSU_COMMIT=3333333333333333333333333333333333333333 \
    SUSFS_REF=test \
    SUSFS_COMMIT=4444444444444444444444444444444444444444 \
    SUSFS_VERSION=2.3.0 \
    BUILD_TIMESTAMP="$package_timestamp" \
    GITHUB_WORKSPACE="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work" \
    GITHUB_ENV="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-env" \
    GITHUB_OUTPUT="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-output" \
    MAGISK_APK_PATH="$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" \
    MAGISK_APK_SHA256="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" | cut -d' ' -f1)" \
    MAGISKBOOT_ARM64_SHA256="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a/libmagiskboot.so" | cut -d' ' -f1)" \
    ANYKERNEL_REPO="$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" \
    ANYKERNEL_COMMIT="$ANYKERNEL_PACKAGE_COMMIT" \
    bash "$ANYKERNEL_PACKAGE_SCRIPT" >/dev/null
  )
  test -s "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/release-assets/test-profile_BakaSU-with-susfs-nomount_111111111111_${package_timestamp}.zip" \
    || fail "AnyKernel packaging did not produce the flashable archive"
  test -s "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/release-assets/SHA256SUMS" \
    || fail "AnyKernel packaging did not produce checksums"
  grep -Fxq 'ui_print " " "Kernel developer: AzusaMyo @ xda-developers" " ";' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel package does not show the requested kernel developer"
  grep -Fxq 'split_boot;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not split ramdiskless boot images"
  grep -Fxq 'flash_boot;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not flash ramdiskless boot images"
  grep -Fxq 'SLOT_SELECT=active;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not force active-slot flashing"
  grep -Fq 'Active-slot boot target verification failed' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not verify the resolved active-slot boot target"
  if grep -Eq '^[[:space:]]*(dump_boot|write_boot);' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh"; then
    fail "AnyKernel package still attempts to unpack a boot ramdisk"
  fi
  grep -Fq 'export AKHOME=/data/local/tmp/anykernel-$$;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel package does not stage app-triggered flashes in executable temporary storage"
  grep -Fq 'AnyKernel work directory: $AKHOME' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel package does not report its effective staging directory"
  grep -Fq 'Bundled BusyBox ABI: arm' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel package does not report the legacy ARM BusyBox"
  grep -Fq 'Bundled MagiskBoot ABI: arm' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel package does not report the legacy ARM MagiskBoot"
  sh -n "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel preflight diagnostics produced invalid shell syntax"
  PREFLIGHT_UPDATER_HASH="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" | cut -d' ' -f1)"
  patch_anykernel_app_flash_staging \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary"
  add_anykernel_preflight_diagnostics \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" arm false
  assert_eq "$PREFLIGHT_UPDATER_HASH" \
    "$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" | cut -d' ' -f1)" \
    "AnyKernel preflight diagnostics idempotence"
done

(
  cd "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work"
  PATH="$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin:$PATH" \
  SOC=sm8650 \
  PROFILE_ID=sm8650-oneplus12-crdroid \
  TARGET_NAME='OnePlus 12' \
  DEVICE_CODENAMES=waffle \
  DEVICE_NAMES='waffle OP5929L1 OP595DL1' \
  SUPPORTED_ANDROID_VERSIONS=17 \
  SOURCE_NAME=crDroid \
  KERNEL_BRANCH=17.0 \
  MODULES_BRANCH=17.0 \
  KERNEL_COMMIT=1111111111111111111111111111111111111111 \
  MODULES_COMMIT=2222222222222222222222222222222222222222 \
  CLANG_VERSION=test-clang \
  KSU_TYPE=BakaSU-with-susfs \
  ROM_GKI_MODULE_COMPAT=1 \
  BUILD_TIMESTAMP=20260101_000002 \
  GITHUB_WORKSPACE="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work" \
  GITHUB_ENV="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-env" \
  GITHUB_OUTPUT="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-output" \
  MAGISK_APK_PATH="$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" \
  MAGISK_APK_SHA256="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" | cut -d' ' -f1)" \
  MAGISKBOOT_ARM64_SHA256="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a/libmagiskboot.so" | cut -d' ' -f1)" \
  MAGISK_BUSYBOX_ARM64_SHA256="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a/libbusybox.so" | cut -d' ' -f1)" \
  ANYKERNEL_REPO="$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" \
  ANYKERNEL_COMMIT="$ANYKERNEL_PACKAGE_COMMIT" \
  bash "$ANYKERNEL_PACKAGE_SCRIPT" >/dev/null
)
test -s "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/release-assets/sm8650-oneplus12-crdroid_BakaSU-with-susfs_111111111111_20260101_000002_rom-gki-compat.zip" \
  || fail "OnePlus 12 package with arm64 tools was not produced"
grep -Fxq 'supported.versions=17' "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
  || fail "crDroid 13 OnePlus 12 package does not enforce Android 17"
assert_eq "magisk-arm64-magiskboot" \
  "$(cat "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/tools/magiskboot")" \
  "OnePlus 12 MagiskBoot replacement"
assert_eq "magisk-arm64-busybox" \
  "$(cat "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/tools/busybox")" \
  "OnePlus 12 BusyBox replacement"
grep -Fq 'Bundled MagiskBoot ABI: arm64' \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
  || fail "OnePlus 12 package does not report arm64 MagiskBoot"
grep -Fq 'Removing incompatible app-injected mkbootfs' \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
  || fail "OnePlus 12 package does not remove an injected 32-bit mkbootfs"

for i in "${!profiles[@]}"; do
  resolve_build_profile "${profiles[$i]}"
  package_android=16
  if [[ "$KERNEL_SOURCE" == crdroidandroid ]]; then
    infer_android_versions 17.0
    package_android="$SUPPORTED_ANDROID_VERSIONS"
  fi
  configure_anykernel_properties \
    "$ANYKERNEL_FIXTURE" \
    "${PROFILE_ID} test kernel" \
    "$DEVICE_NAMES" \
    "$package_android"
  grep -Fxq "supported.versions=$package_android" "$ANYKERNEL_FIXTURE" \
    || fail "${profiles[$i]} did not enforce Android $package_android"
  for device_name in $DEVICE_NAMES; do
    grep -q "^device.name[1-7]=${device_name}$" "$ANYKERNEL_FIXTURE" \
      || fail "${profiles[$i]} did not inject device ID: $device_name"
  done
done

printf '%s\n' \
  '  if [ ! "$match" ]; then' \
  '    abort " " "Unsupported device. Aborting...";' \
  '  fi;' > "$UPDATE_BINARY_FIXTURE"
chmod 755 "$UPDATE_BINARY_FIXTURE"
add_anykernel_devicecheck_diagnostics "$UPDATE_BINARY_FIXTURE"
assert_eq "755" "$(stat -c '%a' "$UPDATE_BINARY_FIXTURE")" "update-binary permissions"
grep -Fq 'ro.product.device=$device' "$UPDATE_BINARY_FIXTURE" \
  || fail "AnyKernel device diagnostics"

printf '%s\n' 'menu "one"' endmenu 'menu "two"' endmenu > "$NOMOUNT_FIXTURE_DIR/Kconfig"
insert_line_before_last_match \
  "$NOMOUNT_FIXTURE_DIR/Kconfig" \
  endmenu \
  'source "fs/nomount/Kconfig"'
assert_eq "4" "$(grep -nF 'source "fs/nomount/Kconfig"' "$NOMOUNT_FIXTURE_DIR/Kconfig" | cut -d: -f1)" \
  "NoMount Kconfig insertion"

# Exercise NoMount's literal and composed versions through the real installer,
# including shallow history and both kernel source layouts.
NOMOUNT_SOURCE_FIXTURE="$NOMOUNT_FIXTURE_DIR/source"
mkdir -p "$NOMOUNT_SOURCE_FIXTURE/kernel/src"
printf '%s\n' '#define NOMOUNT_VERSION "20"' > "$NOMOUNT_SOURCE_FIXTURE/kernel/src/nomount.h"
assert_eq "20" "$(detect_nomount_version "$NOMOUNT_SOURCE_FIXTURE/kernel/src")" \
  "legacy NoMount literal version"
printf '%s\n' 'obj-$(CONFIG_NOMOUNT) += nomount.o' > "$NOMOUNT_SOURCE_FIXTURE/kernel/src/Makefile"
printf '%s\n' 'config NOMOUNT' > "$NOMOUNT_SOURCE_FIXTURE/kernel/src/Kconfig"
printf '%s\n' 'void nomount_init(void) {}' > "$NOMOUNT_SOURCE_FIXTURE/kernel/src/nomount.c"
git -C "$NOMOUNT_SOURCE_FIXTURE" init -q
git -C "$NOMOUNT_SOURCE_FIXTURE" config user.name fixture
git -C "$NOMOUNT_SOURCE_FIXTURE" config user.email fixture@example.invalid
git -C "$NOMOUNT_SOURCE_FIXTURE" add .
git -C "$NOMOUNT_SOURCE_FIXTURE" commit -qm legacy
NOMOUNT_LEGACY_COMMIT="$(git -C "$NOMOUNT_SOURCE_FIXTURE" rev-parse HEAD)"
cat > "$NOMOUNT_SOURCE_FIXTURE/kernel/src/nomount.h" <<'EOF'
#define NOMOUNT_BASE_VERSION "21"
#ifdef NOMOUNT_COMMIT_COUNT
    #define NOMOUNT_VERSION NOMOUNT_BASE_VERSION "-" NOMOUNT_COMMIT_COUNT
#else
    #define NOMOUNT_VERSION NOMOUNT_BASE_VERSION
#endif
EOF
cat > "$NOMOUNT_SOURCE_FIXTURE/kernel/src/Makefile" <<'EOF'
NM_REAL_PATH := $(shell readlink -f $(src))
NOMOUNT_COMMITS := $(shell git -C $(NM_REAL_PATH) rev-list --count HEAD 2>/dev/null)
ifneq ($(NOMOUNT_COMMITS),)
ccflags-y += -DNOMOUNT_COMMIT_COUNT=\"$(NOMOUNT_COMMITS)\"
endif
obj-$(CONFIG_NOMOUNT) += nomount.o
EOF
git -C "$NOMOUNT_SOURCE_FIXTURE" add .
git -C "$NOMOUNT_SOURCE_FIXTURE" commit -qm composed
NOMOUNT_COMPOSED_COMMIT="$(git -C "$NOMOUNT_SOURCE_FIXTURE" rev-parse HEAD)"
assert_eq "21-2" "$(detect_nomount_version "$NOMOUNT_SOURCE_FIXTURE/kernel/src")" \
  "NoMount version includes the source history count"
for nomount_layout in fs common/fs; do
  for nomount_revision in legacy composed; do
    nomount_work="$NOMOUNT_FIXTURE_DIR/$nomount_layout-$nomount_revision"
    mkdir -p "$nomount_work/$nomount_layout"
    : > "$nomount_work/$nomount_layout/Makefile"
    printf '%s\n' 'menu "Filesystems"' endmenu > "$nomount_work/$nomount_layout/Kconfig"
    nomount_commit="$NOMOUNT_COMPOSED_COMMIT"
    expected_nomount_version=21-1
    if [[ "$nomount_revision" == legacy ]]; then
      nomount_commit="$NOMOUNT_LEGACY_COMMIT"
      expected_nomount_version=20
    fi
    (
      cd "$nomount_work"
      export GITHUB_ENV="$nomount_work/github-env"
      install_nomount "$NOMOUNT_SOURCE_FIXTURE" master "$nomount_commit" >/dev/null
      assert_eq "$expected_nomount_version" "$NOMOUNT_VERSION" \
        "$nomount_layout $nomount_revision integrated version"
      verify_nomount_source_integration
      grep -Fxq "nomount_version=$expected_nomount_version" nomount-source-proof.txt \
        || fail "NoMount proof does not report the compiled version"
      if (NOMOUNT_VERSION=unexpected; verify_nomount_source_integration) >/dev/null 2>&1; then
        fail "NoMount verification accepted a mismatched version"
      fi
    )
  done
done
printf '%s\n' '#define NOMOUNT_VERSION UNKNOWN_VERSION_EXPRESSION' \
  > "$NOMOUNT_SOURCE_FIXTURE/kernel/src/nomount.h"
if detect_nomount_version "$NOMOUNT_SOURCE_FIXTURE/kernel/src" >/dev/null 2>&1; then
  fail "unknown NoMount version expressions must fail closed"
fi

echo "PASS: profiles, BakaSU-only root mapping, SUSFS floor, NoMount/Droidspaces integration, and AnyKernel protection"
