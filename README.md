# Zyte Kernel Build

Automated build repository for the **Redmi 10 / 2022 / Prime (selene / MT6768)** kernel.

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

### Component versions

The build resolves the upstream version of every component and shows it in the
release notes, the run summary and the Telegram post - no commit hashes needed:

| Component | Version | Source |
|-----------|---------|--------|
| BakaSU | `v4.2.0-rc3` | nearest tag in `Baka-SU/BakaSU@main` |
| SUSFS | `v2.4.0` | the SUSFS release the integration is based on |
| NoMount | `v2.3.1` | nearest tag in `maxsteeel/nomount@dev` |

`build.sh` finds them with `git describe --tags --abbrev=0` (the root clone is
deepened by 300 commits so the tag is reachable) and writes them to
`out/build-stats.json`, which the release body and the Telegram workflow read.

### Build progress

The compile step counts kbuild's own progress lines (`CC`, `AS`, `HOSTCC`) and shows
how far along the build really is:

```
# interactive terminal - live, in place
  35% ██████████░░░░░░░░░░░░░░░░  1187/3400  92 u/min  ETA 24m00s  drivers/gpu/drm/panel/panel-simple.o

# CI / piped output - one line per 5%, so the Actions log stays readable
  [ 35%] ███████░░░░░░░  1187/3400  92 u/min  ETA 24m00s  drivers/gpu/drm/panel/panel-simple.o
```

Only the new bytes of `out/build.log` are scanned, so the counter costs nothing even on a
20 MB log. The expected unit count is remembered from the last clean build
(`.build-logs/units-<variant>.txt`) - a clean selene all-in-one build is ~3.3k units.
Override it with `--units N` or `BUILD_UNITS=N`.

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
(`none` / `patch` / `minor` / `major`), `jobs_count` (parallel make jobs, default `5`).

### Publishing releases

Releases are created by [`scripts/publish-release.sh`](scripts/publish-release.sh), not by
an action, because the 403s were opaque. It prints the token identity and the exact HTTP
response for every attempt, creates the tag through the Git Data API first, and falls back
to the second token if the first one cannot publish.

> **Gotcha:** `POST /releases` refuses with `403 Resource not accessible by integration`
> when the target commit touches `.github/workflows/` and the token has no *workflow*
> permission - and the built-in `GITHUB_TOKEN` **can never** be authorised for that.
> A classic PAT needs the `workflow` scope; a fine-grained PAT needs
> *Workflows: Read and write*. A tag-only probe does **not** catch this, which is why the
> preflight now creates a draft release too.

### BakaSU manager APK

The build also grabs the latest BakaSU **manager APK** (`arm64-v8a`) from the
`@BakaSU_Grp` topic `4` and publishes it next to the kernel: it is attached to
the GitHub release, added to the artifact and sent to Telegram.

That group has no public web preview, so the file can only be read over
MTProto with a user session. Three repository secrets are needed:

| Secret | Where it comes from |
|--------|---------------------|
| `TELEGRAM_API_ID` | [my.telegram.org](https://my.telegram.org) → API Development Tools |
| `TELEGRAM_API_HASH` | same page |
| `TELEGRAM_SESSION` | `python3 scripts/telegram-login.py` (run locally once) |

The session string is printed by the login helper - put it into
*Settings → Secrets and variables → Actions*. The account must be a member of
`@BakaSU_Grp` (a public group is enough).

Without the secrets the step is skipped with a warning: the kernel release
still publishes, just without the manager APK.

### CI performance

* **ccache is real now** - `ccache-action` saves under `<key>-<timestamp>`, so the exact
  key never matches; `restore-keys` is what restores. It was missing, so every run
  recompiled everything. Keys are also variant/commit-agnostic so all builds share objects.
* **ccache is actually invoked** - kbuild with `LLVM=1` does `CC = clang` inside the kernel
  Makefile, and a makefile assignment beats the environment, so `CC="ccache clang"` was
  silently ignored and the compiler ran uncached (the log even said *"Not saving cache
  because no objects are cached"*). `build.sh` now puts a directory with `clang -> ccache`
  symlinks in front of the toolchain in `PATH`, which intercepts every compiler call.
* **Concurrency** cancels superseded runs (`cancel-in-progress`), and the job is capped at
  **120 min** instead of the 6 h default.
* **Shallow, adaptive kernel fetch** - depth 1 (the pin is the branch tip), deepening to
  50/200 only if the pin needs it.
* **5 make jobs on 4 vCPU** (`jobs_count`) - oversubscribed because kernel builds block on I/O.
* Artifacts are kept **30 days**; a build summary is written to the run page.

`notify-telegram.yml` posts the banner, build details and the zip to Telegram after every
successful build.

See [BUILD.md](BUILD.md) for the full details.
