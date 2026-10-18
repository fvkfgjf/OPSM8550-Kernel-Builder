# scripts/

Shell implementation used by the GitHub Actions workflows.

## Top-level scripts

| Script | Purpose |
| --- | --- |
| `check-upstreams.sh` | Resolves all supported profiles against live upstream refs for the scheduled health workflow. |
| `resolve-profile.sh` | Resolves a valid device/source profile, branch, toolchain, add-ons, and every upstream input to exact commits. |
| `clone-sources.sh` | Fetches exact kernel and modules commits in parallel and prepares the official OnePlus layout when required. |
| `download-clang.sh` | Downloads an AOSP Clang directory from an exact pinned Gitiles commit. |
| `compile-kernel.sh` | Applies integrations, generates config, performs validation-only runs or a full ccache-backed build, and reports timing/cache metrics. |
| `make-anykernel-zip.sh` | Creates a device-checked AnyKernel3 ZIP, provenance manifest, release notes, raw Image asset, and SHA-256 checksums. |
| `publish-diagnostics.sh` | Appends config, SUSFS, NoMount, and Droidspaces proof files to the job summary. |

## Shared libraries

- `lib/profile-data.sh` contains pure profile, BakaSU root, Clang, SUSFS,
  Droidspaces slot, and Android version mappings, including source-specific
  repository and modules-branch overrides. It performs no network access and is
  covered by offline tests.
- `lib/git-helpers.sh` provides bounded five-attempt retries for upstream ref
  lookup and fetches, with interactive credential prompts disabled in CI.
- `lib/anykernel-helpers.sh` applies and verifies device/version protection in
  AnyKernel3 properties.
- `lib/kernel-helpers.sh` edits and verifies Kconfig values and source insertions,
  and repairs the narrowly identified legacy `extract-cert` `key_pass` guard
  regression without changing provider-aware implementations. It also keeps
  module versioning while disabling unused-export trimming for external-driver
  compatibility.
- `lib/ksu-setup.sh` checks out BakaSU at the exact resolved commit and connects
  it to the kernel driver tree.
- `templates/anykernel.sh` provides the slot-aware OnePlus `boot` installer used
  in release ZIPs instead of AnyKernel3's example-device script.
- `lib/susfs-apply.sh` applies SUSFS at an exact commit, repairs explicitly
  recognized vendor include drift, enforces the supported version floor, and
  rejects unknown conflicts.
- `lib/nomount-setup.sh` integrates an exact NoMount commit into the kernel fs
  Kconfig/Makefile only for the explicit experimental preset.
- `lib/droidspaces-setup.sh` detects the cloned kernel series from its
  `Makefile`, applies the version-matched Droidspaces SYSVIPC (and, on 5.10 and
  older, POSIX_MQUEUE) kABI padding patch, skips the patch when the stock config
  already enables the option, and optionally backports NTSync from an exact
  pinned commit.
- `lib/verify.sh` performs source, config, hook-mode, and binary verification,
  including IPC init-symbol checks for Droidspaces, plus dedicated SUSFS,
  NoMount, and Droidspaces proofs. Full builds also verify that the final
  `Image` release suffix identifies the pinned kernel commit.

## Tests

`tests/profile-data-test.sh` verifies all supported profile mappings and keeps
the workflow dropdown synchronized with the mapping library. It also checks
representative BakaSU root, Clang, SUSFS, NoMount, Droidspaces
(series/slot/patch selection, stock-ABI guard, and config handling), and Android
version decisions.
crDroid 13 coverage checks Android 17 branch inference, the pinned
`clang-r584948` toolchain, automatic/manual resolver output for all three
crDroid profiles, retained Android 16 selection, and Android 17 ZIP properties.

The push/PR validation workflow runs Bash syntax checks, ShellCheck, these
offline tests, and actionlint. The scheduled upstream-health workflow resolves
every profile and runs a matrix covering BakaSU + SUSFS + NoMount on
representative SM7550, SM8450, SM8550 (including crDroid), and SM8650 sources,
including targeted integration object compilation, a LunarisOS OnePlus 11
baseline smoke test, and Droidspaces slot/NTSync coverage.

## Conventions

- Top-level scripts use `set -euo pipefail`.
- Library files are sourced and do not enable shell options themselves.
- Exact upstream commits are resolved before clone/fetch operations.
- AnyKernel3 uses a tested commit from the canonical `osm0sis/AnyKernel3`
  repository rather than the removed `Kernel-SU/AnyKernel3` fork.
- Full builds pass ccache compiler launchers on the `make` command line and use
  deterministic Kbuild metadata for repeatability.
- Unknown device/source pairs, invalid branch names, patch rejects, missing
  configs, and missing BakaSU/SUSFS/NoMount/Droidspaces signatures fail closed.
