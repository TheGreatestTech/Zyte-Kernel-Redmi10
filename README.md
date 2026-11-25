# Zyte Kernel Build

Automated build repository for the **Redmi 10 Prime (selene / MT6768)** kernel.

**Current release: `v1.0`** — see the [`VERSION`](VERSION) file (bump it there).

This repo contains **only the build tooling**. The kernel sources live in
[`TheGreatestTech/MT6768-Kernel-4.19`](https://github.com/TheGreatestTech/MT6768-Kernel-4.19)
and are cloned + patched at build time, so the kernel tree always stays pristine.

```
.
├── build.sh              # build + integration driver
├── patches/              # the integrations, as reviewable patches
├── .github/workflows/    # CI: clone kernel -> patch -> build -> release
└── source/               # kernel clone (not committed)
```

## What's in the kernel

| Component | Version |
|-----------|---------|
| Kernel | `MT6768-Kernel-4.19` @ `lineage-24.0` (4.19.325) |
| Root | [BakaSU](https://github.com/Baka-SU/BakaSU) (`main`), manual hook mode |
| SUSFS | v2.4.0 kernel side (`all-in-one` variant only) |
| NoMount | `maxsteeel/nomount` (`all-in-one` variant only) |
| Toolchain | Neutron Clang (downloaded automatically) |
| Version | `v1.0` (from the `VERSION` file; ends up in `uname -r`, the zip name, the GitHub release and Telegram) |
| Packaging | [AnyKernel3-selene](https://github.com/TheGreatestTech/AnyKernel3-selene) |

## Build it locally

```bash
# clone the kernel next to this repo (or let CI do it)
git clone --depth 1 --branch lineage-24.0 \
    https://github.com/TheGreatestTech/MT6768-Kernel-4.19.git source

# root only (BakaSU, manual hooks)
./build.sh --ci-integrate --variant kazesu --clean --reconfig

# everything (BakaSU + SUSFS + NoMount)
./build.sh --ci-integrate --variant all-in-one --clean --reconfig

# pristine kernel, no root
./build.sh --clean --reconfig --variant base
```

`build.sh` fetches what it needs on its own: the Neutron Clang toolchain and the
AnyKernel3 template are downloaded/cloned if they are missing.

Output lands in `out/`:

* `out/arch/arm64/boot/Image.gz-dtb` - kernel + DTB + DTBO
* `out/Zyte-Kernel-*.zip` - AnyKernel3 flashable package
* `out/build.log` - full build log

## The integration is applied at build time

The KazeSU/BakaSU + SUSFS + NoMount integration touches ~26 kernel files. Committing it
would mean a 26-file merge conflict on every kernel update, so it lives in `patches/`
and is applied to the working tree when building:

```bash
./build.sh --ci-integrate-only    # clone root, apply patches, set up NoMount
./build.sh --reset                 # undo it again -> pristine kernel tree
```

`--reset` restores exactly the files the integration touches and leaves your own work
alone.

### Patches

| File | Purpose |
|------|---------|
| `bakasu_manual_hooks_4.19.selene.patch` | the 10 call sites BakaSU's `manual_hook_check.mk` requires (<https://bakasu.org/guide/manual-integrate>) |
| `susfs_4.19_fixes.selene.patch` | fixes for the 9 hunks the generic SUSFS patch rejects on this tree (apply *after* it) |
| `susfs_patch_to_4.19.selene.patch` | SUSFS v2.4.0 kernel side, adapted to this tree |
| `susfs_patch_to_4.19.patch` | original upstream SUSFS patch, kept for reference - **not applied** |
| `susfs_inline_hooks_4.19.selene.patch` | the SUSFS-inline call sites BakaSU/KazeSU require (incl. `ksu_handle_vfs_fstat`) |

`patches/susfs_4.19_fixes.selene.patch` is byte-identical to the reference
`redmi_10_prime_los24_a17/susfs_fixed.patch` from
[`TheGreatestTech/NonGKI_Kernel_Patches`](https://github.com/TheGreatestTech/NonGKI_Kernel_Patches).

## Versioning

The version lives in one file, [`VERSION`](VERSION):

```bash
echo "1.1" > VERSION     # v1.0 -> v1.1
```

It is used everywhere: `uname -r` (`...-ZyteKernel-v1.1`), the zip name, the GitHub
release tag/title and the Telegram post.

### Policy: bumps are opt-in

A weekly rebuild is the **same release** built against newer upstream BakaSU/NoMount
commits - not a new version. The build date in the tag plus the dependency commit SHAs
in the release body already identify each build exactly.

| `version_bump` input | Effect |
|---|---|
| `none` *(default, and always for scheduled runs)* | keep the current version |
| `patch` | `1.0` → `1.0.1` |
| `minor` | `1.0` → `1.1.0` |
| `major` | `1.0` → `2.0.0` |

* **Weekly rebuild** → `zyte-kernel-v1.0-<date>` (same version, new date)
* **A real change** → dispatch with `patch`/`minor`/`major` → the version moves and is
  committed back to the branch

[`scripts/bump-version.sh`](scripts/bump-version.sh) does the bump and exports the new
version to `$GITHUB_ENV` for the release tag and Telegram. If the push fails (two runs
at once), the build still succeeds with a warning.

## CI

`.github/workflows/build-kernel.yml` runs on schedule and on manual dispatch:

1. clones the kernel at the pinned ref into `source/`
2. downloads Neutron Clang, clones the AnyKernel3 template
3. `build.sh --ci-integrate-only` - patches the checkout
4. `build.sh --clean --reconfig --variant <variant>`
5. publishes `Zyte-Kernel-*.zip` as a GitHub Release

`workflow_dispatch` inputs: `neutron_tag` (compiler), `kernel_ref` (kernel branch/tag/commit),
`variant` (`all-in-one` / `root-nomount` / `kazesu` / `base`), `version_bump`
(`none` / `patch` / `minor` / `major`).

`notify-telegram.yml` posts the banner, build details and the zip to Telegram after every
successful build.

See [BUILD.md](BUILD.md) for the full details.
