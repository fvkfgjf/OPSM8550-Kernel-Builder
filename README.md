# OnePlus Snapdragon Kernel Builder

GitHub Actions pipeline for building selected OnePlus Snapdragon 7 Gen 3(SM7550),
8 Gen 1(SM8450), 8 Gen 2(SM8550), and 8 Gen 3(SM8650) kernels. The repository contains the build
pipeline, validation, packaging, and release automation; kernel sources are
resolved from upstream repositories at build time.

## Supported build profiles

The workflow exposes only device/source combinations that are intentionally
configured. This avoids late failures caused by selecting an incompatible SoC
and source independently.

| SoC | Target device | AnyKernel accepted device IDs | Source preset |
| --- | --- | --- | --- |
| `sm7550` | OnePlus Nord CE4 | `benz`, `OP5D3FL1`, `CPH2613` | Nord CE4 development |
| `sm7550` | OnePlus Nord CE4 | `benz`, `OP5D3FL1`, `CPH2613` | crDroid (recommended for crDroid) |
| `sm8450` | OnePlus 10 Pro | `negroni`, `OP516EL1`, `OP516FL1` | OnePlus official |
| `sm8450` | OnePlus 10T / Ace Pro | `ovaltine`, `OP5551L1`, `OP5552L1` | LineageOS community |
| `sm8550` | OnePlus 11 | `salami`, `OP591BL1`, `OP594DL1` | OnePlus official |
| `sm8550` | OnePlus 11 | `salami`, `OP591BL1`, `OP594DL1` | LunarisOS |
| `sm8550` | OnePlus 11 / 12R / Ace 3 | OnePlus 11 IDs plus `aston`, `OP5D35L1`, `astonc`, `OP5CF9L1` | LineageOS |
| `sm8550` | OnePlus 11 / 12R / Ace 3 | OnePlus 11 IDs plus `aston`, `OP5D35L1`, `astonc`, `OP5CF9L1` | crDroid |
| `sm8550` | OnePlus 12R / Ace 3 | `aston`, `OP5D35L1`, `astonc`, `OP5CF9L1` | OnePlus 12R development |
| `sm8650` | OnePlus 12 | `waffle`, `OP5929L1`, `OP595DL1` | OnePlus official |
| `sm8650` | OnePlus 12 | `waffle`, `OP5929L1`, `OP595DL1` | LineageOS |
| `sm8650` | OnePlus 12 | `waffle`, `OP5929L1`, `OP595DL1` | crDroid |

The OnePlus 10T community source is intentionally labeled `ovaltine`; it is
not presented as a OnePlus 10 Pro source.

The Nord CE4 source projects store their SM7550/crow device support in
`sm8550`-named kernel and modules repositories and build it with the Kalama
GKI fragments plus the benz-specific `CONFIG_OPLUS_DEVICE_DTBS=y` and
`CONFIG_BENZ_DTB=y` make flags. The profiles keep the real `sm7550` device
identity in release metadata while resolving that upstream naming explicitly.
Use the dedicated crDroid profile on crDroid: it resolves crDroid's own
kernel and modules instead of the unrelated development/Lineage branch, which
is not ABI-compatible with crDroid's first-stage vendor modules.

The OnePlus 12 LineageOS and crDroid profiles also reproduce both device-tree
make assignments, `CONFIG_OPLUS_DEVICE_DTBS=y` from the shared SM8650
BoardConfig and `CONFIG_WAFFLE_DTB=y` from the waffle BoardConfig, on every
make invocation and record them in build provenance. Command-line Kbuild
assignments are not expected to be written back to `.config`; keeping them on
the make command line matches how the ROM builds its kernel and external
modules.

The OnePlus 12 crDroid profile has an optional **ROM GKI module compatibility**
mode for a boot-only custom Image. A custom Image generates a new module signing
key, while the installed ROM keeps its `system_dlkm` GKI modules. On affected
builds, `rfkill.ko` is rejected with `exports protected symbol rfkill_alloc`,
which prevents the dependent `qca_cld3_kiwi_v2` Wi-Fi driver from loading.
Selecting `Use existing ROM system_dlkm modules (experimental)` disables
`CONFIG_MODULE_SIG_PROTECT` for that build while retaining module signature
parsing and module version checks. It allows modules whose signature cannot be
verified with this Image's newly generated key, so only use it with ROM modules
you trust. This can let the existing ROM modules load, but it reduces GKI
protected-symbol enforcement and does not guarantee
compatibility if module CRCs or firmware differ. The default remains strict.
The chosen mode is recorded in `build-info.json` and in the ZIP filename.
The OnePlus 12 crDroid flashable ZIP also replaces AnyKernel's 32-bit ARM
BusyBox and MagiskBoot with pinned arm64 versions from Magisk 30.7. The device
reports `arm64-v8a` and cannot execute the old 32-bit MagiskBoot; the package
verifies both binary checksums and ELF architecture before creating the ZIP.

The LunarisOS OnePlus 11 profile follows the kernel source published in the
LunarisOS OTA metadata. Its maintainer kernel uses `lineage-23.2`, while its
matching external modules use the `los` branch; the resolver pins both branches
independently and records both exact commits in the build provenance.

Every package accepts both its custom-ROM codename and the device-specific
stock board IDs published by the corresponding device tree. Generic SoC board
names such as `taro`, `kalama`, and `pineapple` are deliberately excluded so a
package cannot pass the check merely because another phone shares its chipset.
The check remains enabled, and a rejected flash prints all four device values
reported to AnyKernel so a genuinely missing regional alias can be diagnosed
safely.

## Build modes

`Build OnePlus Kernel` offers three modes:

- `Patch/config validation only` clones exact upstream revisions, applies the
  selected BakaSU/SUSFS/NoMount/Droidspaces integration, verifies the final
  config, and smoke-compiles the affected SUSFS, VFS, proc, reboot, NoMount,
  and IPC/namespace objects without spending time on a full kernel compile.
- `Full build (artifact only)` builds and uploads a 14-day workflow artifact.
  This is the default and does not create a permanent GitHub Release.
- `Full build and publish release` first reserves an immutable tag at the
  workflow commit, builds the same verified artifact, then a separate
  least-privilege job publishes the release from that tag.

Full builds preserve the upstream/vendor ABI-sensitive configuration instead of
forcing debugging, symbol-export, or spinlock options. The pipeline also pins
the kernel release suffix to the exact source commit (for example,
`-g0d516eb3375f`) and verifies that release in the final `Image` banner. This
keeps the kernel vermagic aligned with the ROM's vendor modules while the
selected root preset changes only its required feature options.

## crDroid 13 (Android 17)

The existing crDroid profiles cover Nord CE4, OnePlus 11 / 12R / Ace 3, and
OnePlus 12 on crDroid 13. Automatic branch selection follows the upstream
default, currently `17.0`, for both the kernel and matching modules. Manual
selection also offers `17.0`; retain `16.0` for crDroid 12 / Android 16.
[crDroid 13 is based on Android 17](https://crdroid.net/blog/2026-09-28-crDroid-13-BETA-source-is-now-pushed/),
so the ROM major version `13` must not be confused with the Android branch
`13.0`.

Android 17 branches select the pinned AOSP `clang-r584948` toolchain to match
[crDroid's compiler default](https://github.com/crdroidandroid/android_build_soong/blob/17.0/cc/config/global.go).
Flashable ZIPs enforce `supported.versions=17`. SUSFS and Droidspaces still use
the devices' GKI kernel families: Android 14 / 5.15 for Nord CE4 and OnePlus
11 / 12R / Ace 3, and Android 14 / 6.1 for OnePlus 12. The ROM Android version
does not change those kernel-base mappings; Droidspaces derives the patch
family from the cloned kernel's own `Makefile` version instead of the ROM.

The OnePlus 11 / 12R crDroid profile passes the common OPlus DTB flag and both
the Salami and Aston device flags on every make invocation, matching the
upstream device configurations for the shared kernel image.

## Root integration

BakaSU is the only supported root solution. The workflow exposes these presets:

| Preset | Integration | Status |
| --- | --- | --- |
| `No root changes` | No root integration (clean build) | Baseline |
| `BakaSU` | BakaSU | Supported |
| `BakaSU + SUSFS` | BakaSU with SUSFS | Supported |
| `BakaSU + SUSFS + NoMount (experimental)` | BakaSU with SUSFS and NoMount | Experimental |

Official KernelSU, KernelSU-Next, KowSU and SukiSU Ultra were removed together
with the KPM loader that only SukiSU provided. BakaSU is the renamed successor
of the former ReSukiSU project (`Baka-SU/BakaSU`). Every preset is pinned to an
exact revision:

- `BakaSU` uses `b2c595ddfa64b685e5a144ad37b7c95f912fb92a` on `main`.
- The SUSFS presets use `f308ed0936bdd31163cb53da3f42bc7a698f5512` from the
  upstream `sync-susfs` branch. BakaSU `main` deliberately suspends SUSFS
  builds (commit `48fa4bb7` makes `kernel/tools/susfs_compat.mk` fail with
  `Please wait susfs update.`) until simonpunk syncs the kernel-side hooks, and
  `sync-susfs` contains that sync plus the matching compat removal.

The pipeline verifies that the runtime exposes the expected SUSFS static keys
and that the build reports the inline hook mode, so a stale pin fails closed
instead of silently falling back to a tracepoint or manual hook. Advance a pin
only after a validation run against the new revision passes; switch SUSFS
presets back to `main` once upstream lifts the suspension.

The BakaSU + SUSFS presets resolve `simonpunk/susfs4ksu` at an exact commit,
apply the kernel-side SUSFS patch, and require upstream v2.2.0 or newer while
explicitly verifying `SUS_MAP` and `OPEN_REDIRECT` in the final config. The
NoMount preset integrates the exact resolved `master` commit, enables
`CONFIG_NOMOUNT=y`, and checks both source wiring and final kernel signatures.
NoMount hooks VFS operations and is marked experimental by its upstream
project, so it remains an explicit opt-in.

Validation mode compiles the SUSFS, VFS, and NoMount integration objects and
checks their exported signatures; a full build repeats the signature checks
against the final kernel artifacts. Both paths fail closed when expected
wiring, config, objects, or symbols are missing.

Patch/config validation uses the runner's distribution Clang, LLD, and LLVM
binutils; full builds use the selected pinned AOSP toolchain.

## Droidspaces container support

`droidspaces` is an independent option, not a root preset, so it can be combined
with any root solution or with `No root changes`. It ports the
[Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) kernel
integration used by the GKI BakaSU pipeline:

- Kernels below 6.12 receive the version-matched SYSVIPC kABI padding patch.
  The `678`, `123`, or `345` choice selects which Android kABI reservation slots
  hold `struct sysv_sem` and `struct sysv_shm`; start with `678` and only try the
  alternatives if the device bootloops with the stock vendor modules. On the
  OnePlus 5.10 and 6.1 sources, reservation slot 1 is already taken by
  `pf_io_worker` and `saved_state` respectively, so `123` only applies to the
  5.15 trees; `678` and `345` work on every supported source family.
- Kernels 5.10 and older also receive the POSIX_MQUEUE `user_struct` padding
  patch, because that field is not yet accounted in `ucounts` there.
- Kernels 6.12 and newer use the upstream union-based patch; the slot input is
  accepted for interface stability but ignored.
- The pipeline enables `CONFIG_SYSVIPC`, `CONFIG_POSIX_MQUEUE`, `CONFIG_IPC_NS`,
  `CONFIG_PID_NS`, and `CONFIG_DEVTMPFS`, plus the optional netfilter/ipset
  helpers only when the selected source defines them. It also disables
  `CONFIG_ANDROID_PARANOID_NETWORK` when that option exists, because it breaks
  container networking.
- If the selected source already enables `SYSVIPC` or `POSIX_MQUEUE`, the
  corresponding ABI patch is skipped deliberately: the stock layout is already
  in use, and moving the fields would break the vendor modules.

The patch repository is pinned at an exact commit and the applied patch files
are checksummed into `build-info.json` and the diagnostics artifact. The
flashable ZIP name gains a `_droidspaces-<slot>` suffix so Droidspaces and
plain builds of the same root preset cannot be confused.

`droidspaces_ntsync` additionally backports the NTSync driver used by Windows
applications inside containers. It is optional, experimental, pinned to an exact
commit, and mapped to the Android/kernel family (including the 5.10 OxygenOS 14
variant). Leave it disabled unless a specific container workload needs it.

Droidspaces changes kernel ABI-sensitive configuration. Keep a known-good stock
boot image available, validate with `Patch/config validation only` first, and be
prepared to try another kABI slot if the device does not boot with the stock
vendor modules.

SUSFS branches are selected from the SoC and Android/kernel branch. Known
vendor include drift is repaired only for explicitly recognized conflicts;
unknown patch rejects fail closed and are included in diagnostics.

## Quick start

1. Open `Actions` -> `Build OnePlus Kernel` -> `Run workflow`.
2. Select one device/source profile.
3. Keep automatic branch and Clang selection unless testing a known branch.
4. Select the root integration and, if needed, a Droidspaces slot.
5. Start with `Patch/config validation only` after an upstream update, then run
   a full build when validation passes.
6. Use release mode only for an artifact you intend to keep or distribute.

Manually selected branch names are validated with Git before they are written
to GitHub Actions environment files. Every kernel, modules, root implementation,
SUSFS, NoMount, Droidspaces, and AnyKernel inputs are resolved to exact
commits before cloning.

## Build performance

The full build passes `CC="ccache clang"` and host compiler wrappers directly
on every `make` invocation so Kbuild cannot replace the ccache launcher.
Build timestamps, user, and host metadata are deterministic for a given kernel
commit, which improves repeat-build cache hits.

The workflow also:

- clones kernel and modules repositories in parallel at exact commits
- caches the exact pinned AOSP Clang archive
- restores a profile/branch/compiler-specific 3 GB compressed ccache
- reports config, compile, total time, and ccache statistics in the job summary
- reclaims unused hosted runner SDKs and creates up to 32 GB of swap for Full LTO
- records memory, disk, and linker resource usage during full builds

GitHub cache entries are an optimization only. A build remains able to download
or regenerate every cached input.
Each run saves a fresh ccache snapshot while restoring earlier matching runs,
so an empty cache from an early failure cannot prevent later builds from saving
their compiled objects.

## Safe packaging and provenance

Generated AnyKernel3 ZIPs enable `do.devicecheck=1` and contain only the
device-specific codenames and stock board IDs assigned to the selected profile.
Android version checking is also enabled when the selected branch identifies a
known Android generation. The installer targets the current active `boot`
partition by name, refuses to continue unless the resolved `boot_a`/`boot_b`
path matches that slot, splits and rebuilds the boot image without unpacking
its ramdisk, and replaces only the kernel Image. This supports newer devices such as OnePlus 11,
where the first-stage ramdisk lives in `init_boot` and `boot` legitimately has
no ramdisk, while preserving a boot ramdisk when one is present. Upstream
AnyKernel example-device paths and demo ramdisk edits are not included. The
OnePlus 12 crDroid package replaces AnyKernel's legacy 32-bit ARM BusyBox and
MagiskBoot with verified AArch64 builds from a pinned official Magisk APK,
because that device is arm64-only. The installer also discards the manager
app's incompatible ARM32 `mkbootfs` injection and uses BusyBox `cpio` instead;
other unused ARM32 AnyKernel partition utilities are removed, and packaging
fails if any remaining native runtime tool is not ELF64/AArch64.

Each full build produces `release-assets/` containing:

- a device-checked AnyKernel3 ZIP
- a uniquely named raw `Image`
- `build-info.json` with all exact source commits and the workflow run URL
- `SHA256SUMS`
- generated `release-notes.md`

GitHub Actions uploads these release-ready files as one flat package artifact.
Build logs and configuration are kept in a separate diagnostics artifact,
along with the SUSFS, NoMount and Droidspaces source/binary proofs for the
selected presets. The release job downloads
only the package artifact and verifies its checksums before publishing.

The same `build-info.json` is embedded in the flashable ZIP. Keep a known-good
stock boot image available and never flash a package whose device check does
not match the phone.

## CI security and reliability

The tag-reservation job has `contents: write` but checks out and executes no
repository or external source. The build job keeps read-only repository
permissions and does not persist checkout credentials, so external kernel
Makefiles never run with release write credentials. After a successful build,
the separate publication job receives `contents: write`, verifies the reserved
tag and artifact checksums, and creates the Release. A failed build removes its
unused reserved tag automatically.

Network Git operations use bounded retries. Release creation and asset uploads
are idempotent, time-limited, and retried, preventing a stalled upload from
holding the build runner indefinitely.

All third-party GitHub Actions are pinned to full commit hashes. AOSP Clang
archive URLs are pinned to exact Gitiles commits, and changing the downloader
invalidates the toolchain cache.

## Validation and upstream health

Pushes and pull requests run:

- Bash syntax checks
- ShellCheck at warning severity
- offline tests for all twelve profile mappings, the BakaSU-only root
  mappings, Clang selection, SUSFS selection/version floor, NoMount selection
  and wiring, Droidspaces slot/patch/NTSync mapping and config handling,
  Android version inference, and workflow option synchronization
- actionlint for all workflow files

`Check upstream health` runs every Monday and can also be started manually. It
resolves exact commits for all twelve profiles, then runs a twelve-job
smoke-test matrix: BakaSU + SUSFS + NoMount (including the crDroid OnePlus 12 /
Android 6.1 vendor include drift) is validated on representative SM7550
(including both CE4 source families), SM8450, SM8550 (including crDroid), and
SM8650 sources, with additional baseline validation for the LunarisOS OnePlus
11 and crDroid OnePlus 12 sources. Droidspaces slots `678`, `123`, and `345`
are smoke-tested across the 5.10, 5.15, and 6.1 source families, and a BakaSU +
Droidspaces + NTSync combination runs on the LunarisOS SM8550 source.

## Important limitations

- A successful build does not prove that a kernel is safe for every firmware,
  region, or boot stack of the listed device.
- Community sources are not official OnePlus sources.
- Manual or unusual branches may disable Android version checking when their
  version cannot be inferred safely.
- This pipeline builds the raw GKI `Image`; it does not rebuild every vendor
  module or replace device-specific firmware.
- NoMount modifies VFS behavior and its upstream labels it experimental. Test
  the opt-in preset on a recoverable device before distributing it.
- Droidspaces needs ABI-sensitive IPC options. The kABI padding patch keeps the
  stock field offsets, but a slot that collides with a vendor module's own
  reservations can still prevent boot; try another slot or keep the stock
  configuration. NTSync is an additional experimental backport.
- Runtime performance tuning is intentionally left at upstream/vendor config
  defaults. Options such as KASAN, LTO mode, scheduler changes, and compiler
  optimization flags require device-specific boot, stability, power, and
  benchmark testing before becoming defaults.
