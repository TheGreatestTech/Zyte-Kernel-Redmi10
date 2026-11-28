# Zyte Kernel - build & integration guide

This repository holds the **build tooling** for the Redmi 10 / 2022 / Prime (selene / MT6768)
kernel. The kernel sources live in a separate repository
([`TheGreatestTech/MT6768-Kernel-4.19`](https://github.com/TheGreatestTech/MT6768-Kernel-4.19),
`lineage-24.0`, Linux 4.19) and are cloned into `source/`:

| Path        | What it is                                                      |
|-------------|-----------------------------------------------------------------|
| `build.sh`  | Build + integration driver (BakaSU / SUSFS / NoMount)            |
| `patches/`  | The integration as reviewable patches (applied at build time)    |
| `.github/`  | CI workflow that builds & publishes the flashable zip           |
| `source/`   | Kernel clone - **not committed** (CI clones the branch tip)   |

`build.sh` works in both layouts: if `source/Makefile` exists it builds the kernel in
`source/`, otherwise it builds the tree it lives in.

## Design: the kernel tree is never committed with integrations

The root + SUSFS + NoMount integration touches 26 kernel files and adds 3 new ones.
Committing that means every kernel update becomes a 26-file merge conflict.

Instead, the integration lives in `patches/` and is **applied to the working tree at build
time**. CI checks out a clean kernel and patches it in the runner, so the kernel
repository always holds pristine sources.

```
clean kernel checkout (source/)
   │
   ├── build.sh --ci-integrate-only   ← clones BakaSU/NoMount, applies patches/
   │                                     (idempotent: safe to re-run)
   └── build.sh --variant kazesu       ← configures, compiles, packages the zip
```

## Build variants

| Variant | What it contains |
|---------|------------------|
| `base` | pristine kernel, no root integration |
| `kazesu` | **root only** - manual hook mode, no SUSFS kernel module, no NoMount |
| `all-in-one` | root (SUSFS inline hook) + SUSFS v2.4.0 + NoMount (default) |

```bash
./build.sh --ci-integrate --variant kazesu        # root only
./build.sh --ci-integrate --variant all-in-one    # everything
```

### Root implementation

`--root` selects the root solution; **BakaSU is the default**:

```bash
./build.sh --ci-integrate --variant kazesu                  # BakaSU (default)
./build.sh --ci-integrate --variant kazesu --root kazesu    # KazeSU/OriginSU
```

BakaSU is cloned from `https://github.com/Baka-SU/BakaSU.git` (branch `main`) into `BakaSU/`,
KazeSU from `https://github.com/KazeSU/KazeSU.git` (branch `legacy`) into `KazeSU/`.
Neither directory is committed - `build.sh --reset` removes them.

The `kazesu` variant uses `patches/bakasu_manual_hooks_4.19.selene.patch`, which adds the
call sites BakaSU's `manual_hook_check.mk` requires (`ksu_handle_execveat`,
`ksu_handle_post_execveat`, `ksu_handle_faccessat`, `ksu_handle_stat`,
`ksu_handle_newfstat_ret`, `ksu_handle_fstat64_ret`, `ksu_handle_sys_reboot`,
`ksu_handle_setresuid`, `ksu_handle_sys_read`, `ksu_handle_input_handle_event`) with the
non-SUSFS prototypes, following <https://bakasu.org/guide/manual-integrate>. BakaSU's own
`manual_hook_check.mk` verifies every one of them at build time. The three
`CONFIG_KSU_MANUAL_HOOK_AUTO_*` options stay off so nothing is hooked twice.

This is the variant to test first when triaging a bootloop: it adds the least to the kernel.

## Building locally

The kernel has to be in `source/` (CI does this automatically):

```bash
git clone --depth 1 https://github.com/TheGreatestTech/MT6768-Kernel-4.19.git source
```

```bash
# One-shot: integrate + build + package
./build.sh --ci-integrate --variant kazesu

# Or step by step
./build.sh --ci-integrate-only     # patch the tree only
./build.sh --clean --reconfig --variant all-in-one
```

Outputs land in `out/`:

* `out/arch/arm64/boot/Image.gz-dtb` - kernel + DTB + DTBO
* `out/Zyte-Kernel-all-in-one-*.zip` - AnyKernel3 flashable package
* `out/build.log` - full build log

The kernel release string is branded via `CONFIG_LOCALVERSION="-ZyteKernel"` in
`arch/arm64/configs/vendor/selene.config` (the fragment overrides the `-Skyron` value that
`vendor/mt6768_defconfig` ships with), giving:

```
4.19.325-cip136-st20-ZyteKernel
```

Requirements: `bc bison flex libssl-dev libelf-dev cpio`. The Neutron Clang toolchain and
the AnyKernel3 template are downloaded/cloned by `build.sh` automatically if they are
missing (`toolchains/neutron-clang/`, `Zyte-Kernel/`).

## Before you commit kernel changes

`--ci-integrate` leaves the tree dirty on purpose. To get back to pristine sources:

```bash
./build.sh --reset
```

This restores every tracked kernel file to `HEAD` and deletes the integration artifacts
(`KazeSU/`, `NoMount/`, `drivers/kernelsu`, `fs/nomount`, `fs/susfs.c`, …) while keeping
`build.sh`, `patches/`, `.github/` and `.gitignore` intact.

Then commit only your kernel changes:

```bash
git status                 # only kernel files should be modified
git add <files>
git commit -m "..."
```

`.gitignore` already hides every generated artifact, so `git status` stays readable.

## When the kernel tree changes

The patches in `patches/` are generated against a specific kernel commit. If the tree moves
and `build.sh --ci-integrate-only` fails with *"tree does not match patches/"*, regenerate them:

```bash
./build.sh --reset
git worktree add /tmp/patchbase HEAD
cd /tmp/patchbase && git apply <new-kernel-side-susfs-patch>
git diff > ../patches/susfs_patch_to_4.19.selene.patch
```

Then verify both patches still apply cleanly:

```bash
git worktree add --detach /tmp/verify HEAD
cd /tmp/verify
git apply --check ../../patches/susfs_patch_to_4.19.selene.patch
git apply --check ../../patches/kazesu_hooks_4.19.selene.patch
```

## CI

`.github/workflows/build-kernel.yml` runs on schedule and on manual dispatch:

1. checks out this repository (the kernel tree) at the selected ref
2. installs dependencies, downloads Neutron Clang
3. `build.sh --ci-integrate-only` - patches the checkout
4. `build.sh --clean --reconfig --variant all-in-one`
5. publishes `Zyte-Kernel-all-in-one-*.zip` as a GitHub Release

`workflow_dispatch` inputs: `neutron_tag` (compiler), `kernel_ref` (branch/tag/commit).

`notify-telegram.yml` runs after every successful build: it picks the release that contains
that run's artifact (not blindly `latest`), posts the banner + build details to Telegram,
and attaches the flashable zip and its `SHA256SUMS` directly to the message. It needs the
`TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHANNEL_ID` repository secrets.

## Patches in this directory

| File | Purpose |
|------|---------|
| `susfs_patch_to_4.19.selene.patch` | SUSFS v2.4.0 kernel side, adapted to this 4.19 tree (`fs_context` mounts, `mmap_read_lock_killable`) |
| `kazesu_hooks_4.19.selene.patch` | the seven KazeSU inline hooks required by `KazeSU/kernel/tools/inline_hook_check.mk` (SUSFS mode) |
| `kazesu_manual_hooks_4.19.selene.patch` | the KazeSU manual-hook call sites (`manual_hook_check.mk`), used by the `kazesu` variant |
| `susfs_4.19_fixes.selene.patch` | fixups for the 9 hunks the **generic** SUSFS patch rejects on this tree, plus the `SUSFS_LOGI_RL` compile fix (apply *after* it) |
| `susfs_patch_to_4.19.patch` | original upstream kernel-side patch, kept for reference - **not applied** |

Apply order matters: SUSFS first, then the KazeSU hooks.

### Generic patch vs. adapted patch

`susfs_patch_to_4.19.selene.patch` is exactly equivalent to applying the generic upstream
patch plus the fixup patch:

```bash
git apply --reject patches/susfs_patch_to_4.19.patch   # 9 hunks reject
git apply patches/susfs_4.19_fixes.selene.patch         # fixes those 9 + log macros
```

`patches/susfs_4.19_fixes.selene.patch` is 6 files / 10 hunks / 64 insertions, **0 deletions**:

* 9 hunks = the 9 rejected hunks, one-for-one (see table below)
* 1 hunk = `fs/susfs.c`: `SUSFS_LOGI_RL`/`SUSFS_LOGE_RL` are only defined when
  `CONFIG_KSU_SUSFS_ENABLE_LOG=y`; with logging off the build fails with
  *implicit declaration of function 'SUSFS_LOGI_RL'*

The 9 rejected hunks are all 4.19-vs-generic mismatches:

| File | Reject | Why it rejects | Fix |
|------|--------|----------------|-----|
| `fs/Makefile` | #1 | tree's `obj-y` ends with `fs_types.o fs_context.o fs_parser.o` | insert `susfs.o` after the `obj-y` block |
| `fs/namespace.c` | #1 | vendor include list differs | add `susfs_def.h` + externs at the real include block |
| `fs/namespace.c` | #6 | **no `vfs_kern_mount()`** - tree uses fs_context mounts | move the hook into `vfs_create_mount()` (`fc->source` instead of `name`) |
| `fs/proc/task_mmu.c` | #1 | vendor include list differs | add `susfs_def.h` include |
| `fs/proc/task_mmu.c` | #5 | tree's loop is `for (vma = ...; vma;)` (increment in body) | insert the SUS_MAP check at the top of the body |
| `fs/proc/task_mmu.c` | #7 | tree uses `mmap_read_lock_killable()`, not `mm->mmap_sem` | use the tree's locking API |
| `fs/super.c` | #1 | vendor include list differs | add `susfs_def.h` + externs |
| `mm/memory.c` | #1 | tree has `<linux/pgtable.h>`, not `<asm/pgtable.h>` | add `susfs_def.h` include |
| `mm/memory.c` | #2 | tree uses `mmap_read_lock_killable()` | use the tree's locking API |
