#!/usr/bin/env bash
# =============================================================================
#  Zyte Kernel build script
#  Device : Redmi 10 / 2022 / Prime (selene) - MediaTek MT6768
#  Kernel : 4.19 (LineageOS 24.0 tree)
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [[ -f "$ROOT/source/Makefile" ]]; then
    SRC="$ROOT/source"
else
    SRC="$ROOT"
fi
OUT="${OUT_DIR:-$ROOT/out}"
AK3="${ANYKERNEL_DIR:-$ROOT/Zyte-Kernel}"
TC="${TOOLCHAIN_DIR:-$ROOT/toolchains/neutron-clang}"
LOG="$OUT/build.log"

# Marketing name, kept in one place so the banner, the summary, the AnyKernel3
# kernel.string and the release notes all agree with the artwork.
DEVICE_NAME="Redmi 10 / 2022 / Prime"

# SUSFS release this integration is based on.
SUSFS_VERSION="v2.4.0"

# Zyte release version (see the VERSION file). Bump it there; it ends up in
# the kernel release string, the zip name, the GitHub release and Telegram.
ZYTE_VERSION="${ZYTE_VERSION:-}"
if [[ -z "$ZYTE_VERSION" && -f "$ROOT/VERSION" ]]; then
    ZYTE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
fi
[[ "$ZYTE_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || die "Invalid VERSION '$ZYTE_VERSION' (expected e.g. 1.0 or 1.0.1)"
ZYTE_VERSION_TAG="v$ZYTE_VERSION"

ARCH="arm64"
DEFCONFIG="vendor/mt6768_defconfig"
FRAGMENT_REL="vendor/selene.config"
FRAGMENT="$SRC/arch/arm64/configs/$FRAGMENT_REL"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
# Load limit for make (prevents overloading the system). 0 = no limit.
# Can be overridden with MAKE_LOAD_LIMIT env var or --load-limit arg.
MAKE_LOAD_LIMIT="${MAKE_LOAD_LIMIT:-0}"
# Expected number of compiled translation units, used by the build progress bar.
# Auto-calibrated after the first clean build (see expected_units).
BUILD_UNITS="${BUILD_UNITS:-}"

DO_CLEAN=0
DO_RECONFIG=0
DO_MENUCONFIG=0
DO_ZIP=1
VERBOSE=0
BUILD_VARIANT="${BUILD_VARIANT:-all-in-one}"
# Root implementation: bakasu (BakaSU) or kazesu (KazeSU/OriginSU)
ROOT_IMPL="${ROOT_IMPL:-bakasu}"
DO_CI_INTEGRATE=0
CI_INTEGRATE_ONLY=0
DO_RESET=0

BUILD_PID=""
STAGE_DIR=""
EXTRACT_CERT_CFLAGS=""
TOTAL_START="$(date +%s)"

# -----------------------------------------------------------------------------
# Colours & Theme (Catppuccin Mocha inspired)
# -----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    # Reset & styles
    R=$'\e[0m'      B=$'\e[1m'     D=$'\e[2m'     U=$'\e[4m'
    # Catppuccin Mocha palette
    ROSE=$'\e[38;5;203m'   FLAM=$'\e[38;5;209m'  PEACH=$'\e[38;5;215m'
    YELL=$'\e[38;5;221m'   GREE=$'\e[38;5;114m'  TEAL=$'\e[38;5;73m'
    SKY=$'\e[38;5;75m'     SAPP=$'\e[38;5;74m'   BLUE=$'\e[38;5;75m'
    LAVE=$'\e[38;5;140m'   MAUV=$'\e[38;5;177m'  PINK=$'\e[38;5;218m'
    TEXT=$'\e[38;5;186m'   SUB0=$'\e[38;5;243m'  SUB1=$'\e[38;5;245m'
    SURF0=$'\e[38;5;235m'  SURF1=$'\e[38;5;237m' BASE=$'\e[38;5;234m'
    # Semantic aliases
    RED=$ROSE     GRN=$GREE     YEL=$YELL     BLU=$SKY
    MAG=$MAUV     CYN=$TEAL     GRY=$SUB0     WHI=$TEXT
    ACC=$PEACH    INF=$SKY      SUC=$GREE     WRN=$PEACH
    ERR=$ROSE     DIM=$SUB1
else
    R="" B="" D="" U="" RED="" GRN="" YEL="" BLU="" MAG="" CYN="" GRY="" WHI=""
    ROSE="" FLAM="" PEACH="" YELL="" GREE="" TEAL="" SKY="" SAPP="" BLUE=""
    LAVE="" MAUV="" PINK="" TEXT="" SUB0="" SUB1="" SURF0="" SURF1="" BASE=""
    ACC="" INF="" SUC="" WRN="" ERR="" DIM=""
fi

# Gradient helper (simple 3-stop)
gradient() {
    # If colors disabled or no args, just return plain text
    [[ -z "${R:-}" || $# -eq 0 ]] && { printf '%s' "${1:-}"; return; }
    local text c1 c2 c3 len i out
    text="${1-}"
    c1="${2-}"
    c2="${3-}"
    c3="${4-}"
    len=${#text}
    i=0
    out=""
    for ((i=0; i<len; i++)); do
        local ratio=$((i * 100 / (len > 1 ? len - 1 : 1)))
        if (( ratio < 50 )); then
            out+="$c1${text:i:1}"
        elif (( ratio < 75 )); then
            out+="$c2${text:i:1}"
        else
            out+="$c3${text:i:1}"
        fi
    done
    printf '%s%s' "$out" "$R"
}

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
banner() {
    local art=(
        "  ______      _       _  __                    _"
        " |___  /     | |     | |/ /                   | |"
        "    / / _   _| |_ ___| ' / ___ _ __ _ __   ___| |"
        "   / / | | | | __/ _ \\  < / _ \\ '__| '_ \\ / _ \\ |"
        "  / /__| |_| | ||  __/ . \\  __/ |  | | | |  __/ |"
        " /_____|__, |\\__\\___|_|\\_ \\___|_|  |_| |_|\\___|_|"
        "         __/ |"
        "        |___/"
    )
    printf '\n'
    for line in "${art[@]}"; do
        gradient "  $line" "$CYN" "$BLU" "$MAUV"
        printf '\n'
    done
    gradient "  Zyte Kernel  ·  $DEVICE_NAME (selene)  ·  MediaTek MT6768  ·  Linux 4.19" "$GRY" "$SUB1" "$DIM"
    printf '\n'
    printf '  %s%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$DIM" "$R"
}

section() {
    local title="$*"
    local line=$(printf '─%.0s' {1..70})
    printf '\n  %s%s %s%s\n' "$B$INF" "$title" "$DIM$line${#title}" "$R"
}

subsection() {
    printf '\n  %s%s▸%s %s%s\n' "$DIM" "$B" "$R" "$INF" "$*" "$R"
}

row() {
    printf '  %s%-14s%s %s\n' "$DIM" "$1" "$R" "$2"
}

info() { printf '  %s▸%s %s\n' "$INF" "$R" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$SUC" "$R" "$*"; }
warn() { printf '  %s⚠%s %s\n' "$WRN" "$R" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$ERR" "$R" "$*"; }
note() { printf '  %sℹ%s %s\n' "$CYN" "$R" "$*"; }
debug() { (( VERBOSE )) && printf '  %s◆%s %s\n' "$MAUV" "$R" "$*"; }

die() {
    bad "$*"
    printf '\n'
    exit 1
}

cleanup() {
    if [[ -n "$BUILD_PID" ]] && kill -0 "$BUILD_PID" 2>/dev/null; then
        kill "$BUILD_PID" 2>/dev/null || true
    fi
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        rm -rf "$STAGE_DIR"
    fi
}

on_interrupt() {
    printf '\r\033[2K'
    printf '\n'
    bad "Build interrupted"
    cleanup
    exit 130
}

trap on_interrupt INT TERM
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Small utilities
# -----------------------------------------------------------------------------
relpath() {
    local p="$1"
    printf '%s' "${p#"$ROOT"/}"
}

human_size() {
    local bytes="$1"
    if (( bytes < 1024 )); then
        printf '%d B' "$bytes"
    else
        numfmt --to=iec-i --suffix=B --format='%.1f' "$bytes"
    fi
}

fmt_duration() {
    local s="$1"
    if (( s >= 3600 )); then
        printf '%dh %02dm %02ds' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
    elif (( s >= 60 )); then
        printf '%dm %02ds' $((s / 60)) $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

center() {
    local text="$1" width="$2"
    local len=${#text}
    local left=$(((width - len) / 2))
    local right=$((width - len - left))
    printf '%*s%s%*s' "$left" "" "$text" "$right" ""
}

artifact() {
    local label="$1" path="$2" colour="${3:-$CYN}"
    [[ -e "$path" ]] || return 0
    local size
    size="$(human_size "$(stat -c %s "$path")")"
    printf '  %s%-11s%s %-56s %9s\n' "$colour" "$label" "$R" "$(relpath "$path")" "$size"
}

usage() {
    cat <<EOF

  Zyte Kernel build script - Redmi 10 / 2022 / Prime (selene)

  Usage: ./build.sh [options]

  Version: v$ZYTE_VERSION  (edit the VERSION file to bump it)

  Options:
    -j, --jobs N           Parallel jobs (default: $(nproc 2>/dev/null || echo 4))
        --units N          Expected compile units for the progress bar
                           (default: auto - remembered from the last clean build)
    -c, --clean            Delete out/ and do a clean rebuild
    -r, --reconfig         Regenerate .config from vendor/mt6768_defconfig + vendor/selene.config
    -m, --menuconfig       Open menuconfig before building
        --no-zip           Do not create the AnyKernel3 flashable zip
        --variant V        base (no integration), root (root only, manual hook),
                         root-nomount (root + NoMount) or all-in-one
                         (root + SUSFS + NoMount, default)
        --root R           bakasu (default) or kazesu - which root implementation
    -v, --verbose          Stream raw make output instead of the live status line
        --load-limit N     Limit make load average (0 = no limit, default: 0)
        --ci-integrate     Integrate KazeSU/SUSFS/NoMount, then build
        --ci-integrate-only  Run CI integration only, then exit
        --reset             Revert the integration (restore a pristine kernel tree)
    -h, --help             Show this help

  Examples:
    ./build.sh                       Incremental all-in-one build + AnyKernel3 zip
    ./build.sh -c -j8                Clean rebuild with 8 jobs
    ./build.sh -r -m                 Regenerate config, tweak it, then build
    ./build.sh --variant base        Clean kernel without root integration
    ./build.sh --ci-integrate-only   Prepare source for CI (no build)
    ./build.sh --reset               Undo KazeSU/SUSFS/NoMount before committing

EOF
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
while (($#)); do
    case "$1" in
        -j|--jobs)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            JOBS="$2"
            shift 2
            ;;
        -j*)
            JOBS="${1#-j}"
            shift
            ;;
        -c|--clean)
            DO_CLEAN=1
            shift
            ;;
        -r|--reconfig)
            DO_RECONFIG=1
            shift
            ;;
        -m|--menuconfig)
            DO_MENUCONFIG=1
            shift
            ;;
        --no-zip)
            DO_ZIP=0
            shift
            ;;
        --variant)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            BUILD_VARIANT="$2"
            shift 2
            ;;
        --variant=*)
            BUILD_VARIANT="${1#*=}"
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        --units)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            BUILD_UNITS="$2"
            shift 2
            ;;
        --units=*)
            BUILD_UNITS="${1#*=}"
            shift
            ;;
        --load-limit)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            MAKE_LOAD_LIMIT="$2"
            shift 2
            ;;
        --load-limit=*)
            MAKE_LOAD_LIMIT="${1#*=}"
            shift
            ;;
        --version)
            echo "Zyte Kernel v$ZYTE_VERSION"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --ci-integrate)
            DO_CI_INTEGRATE=1
            shift
            ;;
        --ci-integrate-only)
            DO_CI_INTEGRATE=1
            CI_INTEGRATE_ONLY=1
            shift
            ;;
        --root)
            [[ $# -ge 2 ]] || die "$1 needs a value"
            ROOT_IMPL="$2"
            shift 2
            ;;
        --root=*)
            ROOT_IMPL="${1#*=}"
            shift
            ;;
        --reset|--reset-integration)
            DO_RESET=1
            shift
            ;;
        *)
            die "Unknown option: $1 (try --help)"
            ;;
    esac
done

[[ "$JOBS" =~ ^[0-9]+$ ]] && (( JOBS > 0 )) || die "Invalid job count: $JOBS"
[[ -z "$BUILD_UNITS" ]] || [[ "$BUILD_UNITS" =~ ^[0-9]+$ && "$BUILD_UNITS" -gt 0 ]] || die "Invalid unit count: $BUILD_UNITS"

case "$BUILD_VARIANT" in
    base|all-in-one|kazesu|root|root-nomount) ;;
    *) die "Unknown variant: $BUILD_VARIANT (use base, kazesu, root-nomount or all-in-one)" ;;
esac

# "kazesu" is the old name for the root-only variant
[[ "$BUILD_VARIANT" == "kazesu" ]] && BUILD_VARIANT="root"

case "$ROOT_IMPL" in
    kazesu|bakasu) ;;
    *) die "Unknown root implementation: $ROOT_IMPL (use kazesu or bakasu)" ;;
esac

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
ensure_toolchain() {
    if [[ -x "$TC/bin/clang" ]]; then
        return 0
    fi

    info "Neutron Clang not found at $TC - downloading it"
    mkdir -p "$TC"

    local tag
    tag="$(curl -fsSL --retry 5 --retry-all-errors \
        https://raw.githubusercontent.com/Neutron-Toolchains/clang-build-catalogue/main/latest.txt \
        | awk '/^\[tag\]$/{getline; print; exit}')"
    [[ -n "$tag" ]] || die 'Could not resolve the latest Neutron Clang tag'

    curl -fsSLo "$TC/antman" \
        https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman \
        || die 'Failed to download antman'
    chmod +x "$TC/antman"
    (cd "$TC" && ./antman "-S=$tag") || die 'Neutron Clang download failed'

    [[ -x "$TC/bin/clang" ]] || die 'Neutron Clang download was incomplete'
    ok "Neutron Clang $tag ready at $TC"
}

ensure_anykernel() {
    if [[ -f "$AK3/anykernel.sh" ]]; then
        return 0
    fi

    # No explicit ANYKERNEL_DIR: reuse a template that already exists next to
    # the repo before fetching one (e.g. <repo>/../Zyte-Kernel).
    if [[ -z "${ANYKERNEL_DIR:-}" ]]; then
        local candidate
        for candidate in "$ROOT/../Zyte-Kernel" "$ROOT/Zyte-Kernel"; do
            if [[ -f "$candidate/anykernel.sh" ]]; then
                AK3="$(cd "$candidate" && pwd)"
                ok "Using existing AnyKernel3 template at $AK3"
                return 0
            fi
        done
    fi

    info "AnyKernel3 template not found at $AK3 - fetching it"
    mkdir -p "$(dirname "$AK3")"
    rm -rf "$AK3"
    git clone --depth 1 --branch master \
        https://github.com/TheGreatestTech/AnyKernel3-selene.git "$AK3" \
        || die "Failed to clone the AnyKernel3 template into $AK3"
    [[ -f "$AK3/anykernel.sh" ]] || die 'AnyKernel3 clone is incomplete'
    ok "AnyKernel3 template ready at $AK3"

    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "ANYKERNEL_COMMIT=$(git -C "$AK3" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" >> "$GITHUB_ENV"
    fi
}

preflight() {
    [[ -f "$SRC/Makefile" ]] || die "Kernel source not found at $SRC"
    [[ -f "$FRAGMENT" ]] || die "Config fragment not found: $FRAGMENT_REL"
    ensure_toolchain

    if [[ "$BUILD_VARIANT" == "all-in-one" ]]; then
        [[ -e "$SRC/drivers/kernelsu/Kconfig" ]] \
            || die "KazeSU not integrated (run --ci-integrate first)"
        [[ -f "$SRC/fs/susfs.c" ]] \
            || die "SUSFS not integrated (run --ci-integrate first)"
    elif [[ "$BUILD_VARIANT" == "root" || "$BUILD_VARIANT" == "root-nomount" ]]; then
        [[ -e "$SRC/drivers/kernelsu/Kconfig" ]] \
            || die "$ROOT_IMPL not integrated (run --ci-integrate first)"
        grep -q 'ksu_handle_execveat' "$SRC/fs/exec.c" \
            || die "KazeSU manual hooks not integrated (run --ci-integrate first)"
        grep -q 'ksu_handle_newfstat_ret' "$SRC/fs/stat.c" \
            || die "$ROOT_IMPL manual hooks not integrated (run --ci-integrate first)"
    fi

    export PATH="$TC/bin:$PATH"
    export ARCH="$ARCH"
    # Appends the Zyte version to the kernel release string (uname -r).
    export LOCALVERSION="-$ZYTE_VERSION_TAG"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "ZYTE_VERSION=$ZYTE_VERSION" >> "$GITHUB_ENV"
        echo "ZYTE_VERSION_TAG=$ZYTE_VERSION_TAG" >> "$GITHUB_ENV"
    fi
    export LLVM=1
    export LLVM_IAS=1
    export CROSS_COMPILE="aarch64-linux-gnu-"

    # link-vmlinux.sh bumps .version on every link. Without a fixed value,
    # compile.h changes -> init/version.o rebuilds -> vmlinux.o relinks on
    # every single build, even when nothing else changed.
    export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}"

    # ccache setup (speeds up rebuilds significantly)
    if command -v ccache >/dev/null 2>&1; then
        export CCACHE_DIR="${CCACHE_DIR:-$ROOT/.ccache}"
        export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
        export CCACHE_COMPRESS=1
        export CCACHE_COMPRESSLEVEL=6
        export CCACHE_SLOPPINESS="time_macros,include_file_ctime,include_file_mtime,file_macro,file_stat_matches"
        # Keep the cache valid even when the workspace path changes.
        export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$ROOT}"
        ccache --max-size="$CCACHE_MAXSIZE" >/dev/null 2>&1 || true
        ccache -z >/dev/null 2>&1 || true  # zero stats for this build

        # Kbuild with LLVM=1 does `CC = clang` inside the kernel Makefile,
        # and a makefile assignment beats the environment - so "CC=ccache
        # clang" is silently ignored and the compiler is called directly.
        # The only reliable way to intercept every invocation is to put a
        # directory with ccache symlinks (clang -> ccache) in front of the
        # toolchain: ccache then finds the real clang further down the PATH.
        local CCACHE_BIN="$OUT/.ccache-bin"
        mkdir -p "$CCACHE_BIN"
        local ccache_bin
        ccache_bin="$(command -v ccache)"
        for cc in clang clang++; do
            ln -sf "$ccache_bin" "$CCACHE_BIN/$cc"
        done
        export PATH="$CCACHE_BIN:$PATH"

        # Fail loudly instead of silently building without a cache.
        if ! "$CCACHE_BIN/clang" --version >/dev/null 2>&1; then
            warn "ccache wrapper does not work - continuing without ccache"
        else
            info "ccache enabled (dir: $CCACHE_DIR, max: $CCACHE_MAXSIZE, wrapper: $CCACHE_BIN)"
        fi
    fi

    local tool
    for tool in make bc bison flex perl python3 cpio gzip stat numfmt awk df; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
    done
    for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf; do
        command -v "$tool" >/dev/null 2>&1 || die "Missing toolchain tool: $tool"
    done

    if (( DO_ZIP == 1 )); then
        ensure_anykernel
    fi

    local avail_kb
    avail_kb="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
    if (( avail_kb < 10 * 1024 * 1024 )); then
        warn "Less than 10 GiB free on the build volume"
    fi

    # Modern OpenSSL builds (3.x/4.x) may omit the ENGINE API entirely.
    # Kernel 4.19's extract-cert.c only guards that code for BoringSSL, so
    # compile the PKCS#11 branch out when the host library lacks ENGINE.
    local crypto_lib=""
    crypto_lib="$(ldconfig -p 2>/dev/null | awk '/libcrypto\.so/{lib=$NF} END{print lib}')"
    if [[ -z "$crypto_lib" ]]; then
        crypto_lib="$(pkg-config --variable=libdir libcrypto 2>/dev/null || true)/libcrypto.so"
    fi
    if [[ -e "$crypto_lib" ]] && ! llvm-nm -D "$crypto_lib" 2>/dev/null \
        | grep -w 'ENGINE_load_builtin_engines' >/dev/null; then
        EXTRACT_CERT_CFLAGS="$(pkg-config --cflags libcrypto 2>/dev/null || true) -DOPENSSL_IS_BORINGSSL"
        EXTRACT_CERT_CFLAGS="${EXTRACT_CERT_CFLAGS# }"
        info "OpenSSL without ENGINE detected - applying extract-cert compatibility"
    fi
}

# -----------------------------------------------------------------------------
# Reset: undo the KazeSU/SUSFS/NoMount integration
# -----------------------------------------------------------------------------
reset_integration() {
    section "Resetting integration"

    [[ -f "$SRC/Makefile" ]] || die "Kernel source not found at $SRC"
    cd "$SRC"

    warn "This discards the changes made by the KazeSU/SUSFS/NoMount integration"
    warn "Your own uncommitted kernel work is left untouched"

    # Untracked integration artifacts (cloned trees, symlinks, new sources).
    rm -rf "$SRC/KazeSU" "$SRC/BakaSU" "$SRC/NoMount"
    rm -f  "$SRC/drivers/kernelsu" "$SRC/fs/nomount"
    rm -rf "$SRC/fs/susfs" "$SRC/fs/susfs.c"
    rm -f  "$SRC/include/linux/susfs.h" "$SRC/include/linux/susfs_def.h"

    if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
        # Restore exactly the files the integration touches:
        #   - everything the two patches modify
        #   - the four Makefile/Kconfig files edited by the setup scripts
        local -a restore=()
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            git -C "$SRC" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 \
                && restore+=("$f")
        done < <(
            {
                grep -h '^+++ b/' "$ROOT"/patches/*.selene.patch 2>/dev/null || true
                printf '%s\n' drivers/Makefile drivers/Kconfig fs/Makefile fs/Kconfig
            } | sed 's|^+++ b/||' | sort -u
        )

        if ((${#restore[@]})); then
            git -C "$SRC" checkout -- "${restore[@]}" || die 'git checkout failed'
            ok "Restored ${#restore[@]} integration-touched file(s) to HEAD"
        fi
    fi

    cd "$ROOT"
    ok 'Integration reset - kernel tree is pristine again'
}

# -----------------------------------------------------------------------------
# CI Integration: clone KazeSU, integrate SUSFS, set up NoMount
# -----------------------------------------------------------------------------
# Resolve the upstream version of a component checkout: the tag on HEAD, or
# the nearest tag in its history (e.g. "v4.2.0-rc3" for a commit that is 114
# commits ahead of that tag). Empty when the checkout has no tags.
resolve_component_version() {
    local dir="$1" tag=""
    [[ -d "$dir/.git" ]] || return 0
    tag="$(git -C "$dir" tag --points-at HEAD 2>/dev/null | grep -E '^v[0-9]' | sort -V | tail -n1 || true)"
    if [[ -z "$tag" ]]; then
        tag="$(git -C "$dir" describe --tags --abbrev=0 2>/dev/null || true)"
    fi
    printf '%s' "$tag"
}

# Versions + commits of everything that goes into the kernel. Filled in both
# the integration step and the build step, so the release notes and the
# Telegram post can show "BakaSU v4.2.0-rc3" instead of a bare commit hash.
component_versions() {
    local root_dir="$SRC/BakaSU" nomount_dir="$SRC/NoMount"
    [[ "$ROOT_IMPL" == "kazesu" ]] && root_dir="$SRC/KazeSU"

    ROOT_NAME="$ROOT_IMPL"
    [[ "$ROOT_IMPL" == "bakasu" ]] && ROOT_NAME="BakaSU"
    [[ "$ROOT_IMPL" == "kazesu" ]] && ROOT_NAME="KazeSU"

    ROOT_VERSION="$(resolve_component_version "$root_dir")"
    ROOT_COMMIT="$(git -C "$root_dir" rev-parse --short=12 HEAD 2>/dev/null || echo none)"
    NOMOUNT_VERSION="$(resolve_component_version "$nomount_dir")"
    NOMOUNT_COMMIT="$(git -C "$nomount_dir" rev-parse --short=12 HEAD 2>/dev/null || echo none)"

    export ROOT_NAME ROOT_VERSION ROOT_COMMIT NOMOUNT_VERSION NOMOUNT_COMMIT SUSFS_VERSION
}

integrate_root() {
    # Root implementation: KazeSU/OriginSU (legacy branch) or BakaSU (main).
    local repo branch
    case "$ROOT_IMPL" in
        kazesu)
            repo="https://github.com/KazeSU/KazeSU.git"
            branch="legacy"
            ;;
        bakasu)
            repo="https://github.com/Baka-SU/BakaSU.git"
            branch="main"
            ;;
    esac

    info "[1/4] Cloning $ROOT_IMPL ($branch)"
    if [[ -d "$ROOT_DIR/kernel" ]]; then
        info "$ROOT_IMPL already cloned at $(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
    else
        rm -rf "$ROOT_DIR"
        git clone --depth 1 --branch "$branch" "$repo" "$ROOT_DIR"
        [[ -d "$ROOT_DIR/kernel" ]] || die "$ROOT_IMPL clone did not create $ROOT_IMPL/kernel"
        # A depth-1 clone has no history, so `git describe` cannot tell which
        # release the checkout is based on. Deepen it (the tags are ~100
        # commits back) and fetch the tag refs.
        git -C "$ROOT_DIR" fetch --quiet --deepen 300 origin "$branch" 2>/dev/null || true
        git -C "$ROOT_DIR" fetch --quiet --tags origin 2>/dev/null || true
        ok "$ROOT_IMPL cloned at $(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
    fi

    info "[2/4] Setting up $ROOT_IMPL integration (symlink + drivers/ patching)"
    cd "$SRC"
    local DRIVER_DIR="$SRC/drivers"
    local DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
    local DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"

    if [[ -L "$DRIVER_DIR/kernelsu" && -e "$DRIVER_DIR/kernelsu/Kconfig" ]]; then
        info "$ROOT_IMPL integration already set up"
    else
        [[ -L "$DRIVER_DIR/kernelsu" ]] && rm "$DRIVER_DIR/kernelsu"

        local rel_target
        rel_target=$(realpath --relative-to="$DRIVER_DIR" "$ROOT_DIR/kernel" 2>/dev/null) || \
            rel_target="$ROOT_DIR/kernel"
        ln -sf "$rel_target" "$DRIVER_DIR/kernelsu"
        ok "Created symlink drivers/kernelsu -> $rel_target"
    fi

    if ! grep -q "kernelsu" "$DRIVER_MAKEFILE"; then
        printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE"
        ok "Patched drivers/Makefile"
    else
        info "drivers/Makefile already patched"
    fi

    if ! grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG"; then
        if grep -q "^endmenu" "$DRIVER_KCONFIG"; then
            sed -i '/^endmenu/i\source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG"
        else
            printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$DRIVER_KCONFIG"
        fi
        ok "Patched drivers/Kconfig"
    else
        info "drivers/Kconfig already patched"
    fi
}

integrate_susfs() {
    info "[2/4] Integrating SUSFS v2.4.0 (kernel-side patch)"
    cd "$SRC"

    local susfs_patch="$ROOT/patches/susfs_patch_to_4.19.selene.patch"
    [[ -f "$susfs_patch" ]] || die "Missing SUSFS patch: $susfs_patch"

    # A patch is "already applied" only if it can be reversed cleanly -
    # that catches partially applied trees that a symbol grep would miss.
    if git apply --reverse --check --recount --whitespace=nowarn "$susfs_patch" 2>/dev/null; then
        info "SUSFS v2.4.0 already integrated"
    else
        # Drop artifacts from older/broken integrations so the patch applies.
        rm -rf fs/susfs fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h
        git apply --check --recount --whitespace=nowarn "$susfs_patch" 2>/dev/null \
            || die "Failed to apply SUSFS patch to $SRC (tree does not match patches/; regenerate the patch against this kernel commit, or run: $0 --reset)"
        git apply --recount --whitespace=nowarn "$susfs_patch" \
            || die "Failed to apply SUSFS patch to $SRC"
        ok "SUSFS v2.4.0 kernel patch applied"
    fi
}

integrate_inline_hooks() {
    info "[3/4] Adding SUSFS inline hooks"
    cd "$SRC"

    local hooks_patch="$ROOT/patches/susfs_inline_hooks_4.19.selene.patch"
    [[ -f "$hooks_patch" ]] || die "Missing SUSFS inline hooks patch: $hooks_patch"

    if git apply --reverse --check --recount --whitespace=nowarn "$hooks_patch" 2>/dev/null; then
        info "SUSFS inline hooks already present"
    else
        git apply --check --recount --whitespace=nowarn "$hooks_patch" 2>/dev/null \
            || die "Failed to apply SUSFS inline hooks patch (tree mismatch; run: $0 --reset)"
        git apply --recount --whitespace=nowarn "$hooks_patch" \
            || die "Failed to apply SUSFS inline hooks patch"
        ok "SUSFS inline hooks applied"
    fi
}

integrate_manual_hooks() {
    info "[3/4] Adding $ROOT_IMPL manual hooks (no SUSFS)"
    cd "$SRC"

    local hooks_patch="$ROOT/patches/bakasu_manual_hooks_4.19.selene.patch"
    [[ -f "$hooks_patch" ]] || die "Missing $ROOT_IMPL manual hooks patch: $hooks_patch"

    if git apply --reverse --check --recount --whitespace=nowarn "$hooks_patch" 2>/dev/null; then
        info "$ROOT_IMPL manual hooks already present"
    else
        git apply --check --recount --whitespace=nowarn "$hooks_patch" 2>/dev/null \
            || die "Failed to apply $ROOT_IMPL manual hooks patch (tree mismatch; run: $0 --reset)"
        git apply --recount --whitespace=nowarn "$hooks_patch" \
            || die "Failed to apply $ROOT_IMPL manual hooks patch"
        ok "$ROOT_IMPL manual hooks applied"
    fi
}

integrate_nomount() {
    info "[4/4] Setting up NoMount"
    cd "$SRC"
    if [[ -d "$SRC/NoMount" && -e "$SRC/fs/nomount/Kconfig" ]]; then
        info "NoMount already integrated"
    else
        curl -fsSL --retry 5 --retry-all-errors \
            https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh \
            | bash -s dev
        [[ -d "$SRC/NoMount" ]] || die 'NoMount setup did not create NoMount/'
        [[ -e "$SRC/fs/nomount/Kconfig" ]] || die 'NoMount setup did not link fs/nomount'
        ok "NoMount integrated"
    fi
}

verify_integration() {
    info "[4/4] Verifying $ROOT_IMPL wiring"
    [[ -L "$SRC/drivers/kernelsu" ]] || die 'drivers/kernelsu symlink was not created'
    [[ -e "$SRC/drivers/kernelsu/Kconfig" ]] || die 'drivers/kernelsu does not resolve to the root kernel dir'

    local -a call_sites=(
        "kernel/sys.c:ksu_handle_setresuid"
        "fs/exec.c:ksu_handle_execveat"
        "fs/open.c:ksu_handle_faccessat"
        "fs/read_write.c:ksu_handle_sys_read"
        "fs/stat.c:ksu_handle_stat"
        "kernel/reboot.c:ksu_handle_sys_reboot"
        "drivers/input/input.c:ksu_handle_input_handle_event"
    )
    local call_site file symbol
    for call_site in "${call_sites[@]}"; do
        file="${call_site%%:*}"
        symbol="${call_site##*:}"
        grep -q "$symbol" "$SRC/$file" || die "$ROOT_IMPL call site $symbol missing from $file"
    done

    if [[ "$BUILD_VARIANT" == "all-in-one" ]]; then
        [[ -f "$SRC/fs/susfs.c" ]] || die 'SUSFS core was not created'
        grep -q 'SUSFS_VERSION "v2.4.0"' "$SRC/include/linux/susfs.h" \
            || die 'SUSFS v2.4.0 version marker missing'
        grep -q 'susfs_init' "$SRC/fs/susfs.c" \
            || die 'SUSFS init function missing'
        grep -q 'susfs_get_non_sus_mnt_id_from_mnt' "$SRC/fs/namespace.c" \
            || die 'SUSFS mount-id helper missing from fs/namespace.c'

        grep -q 'ksu_handle_faccessat(int \*dfd, struct filename \*\*' "$ROOT_DIR/kernel/feature/sucompat.h" \
            || die "$ROOT_IMPL faccessat handler is not the SUSFS filename variant"
        grep -q 'ksu_handle_stat(int \*dfd, struct filename \*\*' "$ROOT_DIR/kernel/feature/sucompat.h" \
            || die "$ROOT_IMPL stat handler is not the SUSFS filename variant"
        grep -q 'ksu_handle_post_execveat_sucompat' "$SRC/fs/exec.c" \
            || die 'post-execve hook is missing from fs/exec.c'
        grep -q 'ksu_handle_vfs_fstat' "$SRC/fs/stat.c" \
            || die 'ksu_handle_vfs_fstat hook is missing from fs/stat.c'
        grep -q '^config KSU_SUSFS$' "$ROOT_DIR/kernel/Kconfig" \
            || die "$ROOT_IMPL SUSFS Kconfig entry missing"
        ok "All $ROOT_IMPL inline hooks (incl. ksu_handle_vfs_fstat) and SUSFS v2.4.0 wiring present"
    else
        grep -q 'ksu_handle_newfstat_ret' "$SRC/fs/stat.c" \
            || die 'newfstat hook is missing from fs/stat.c'
        grep -q 'ksu_handle_fstat64_ret' "$SRC/fs/stat.c" \
            || die 'fstat64 hook is missing from fs/stat.c'
        grep -q 'ksu_handle_post_execve' "$SRC/fs/exec.c" \
            || die 'post-execve hook is missing from fs/exec.c'
        grep -q 'ksu_handle_faccessat(int \*dfd, const char __user \*\*' "$ROOT_DIR/kernel/feature/sucompat.h" \
            || die "$ROOT_IMPL faccessat handler is not the manual-hook variant"
        grep -q 'ksu_handle_stat(int \*dfd, const char __user \*\*' "$ROOT_DIR/kernel/feature/sucompat.h" \
            || die "$ROOT_IMPL stat handler is not the manual-hook variant"
        grep -q '^config KSU_MANUAL_HOOK$' "$ROOT_DIR/kernel/Kconfig" \
            || die "$ROOT_IMPL manual hook Kconfig entry missing"
        if [[ "$BUILD_VARIANT" == "root-nomount" ]]; then
            [[ -e "$SRC/fs/nomount/Kconfig" ]] \
                || die 'NoMount was not integrated'
            ok "All $ROOT_IMPL manual hook call sites + NoMount present (no SUSFS)"
        else
            ok "All $ROOT_IMPL manual hook call sites present (no SUSFS, no NoMount)"
        fi
    fi

    component_versions
    KAZESU_COMMIT="$ROOT_COMMIT"
    NOMOUNT_COMMIT="$NOMOUNT_COMMIT"
    echo "KAZESU_COMMIT=$KAZESU_COMMIT"
    echo "KAZESU_VERSION=${ROOT_VERSION:-unknown}"
    echo "NOMOUNT_COMMIT=$NOMOUNT_COMMIT"
    echo "NOMOUNT_VERSION=${NOMOUNT_VERSION:-unknown}"
    echo "SUSFS_VERSION=$SUSFS_VERSION"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "KAZESU_COMMIT=$KAZESU_COMMIT" >> "$GITHUB_ENV"
        echo "KAZESU_VERSION=${ROOT_VERSION:-unknown}" >> "$GITHUB_ENV"
        echo "NOMOUNT_COMMIT=$NOMOUNT_COMMIT" >> "$GITHUB_ENV"
        echo "NOMOUNT_VERSION=${NOMOUNT_VERSION:-unknown}" >> "$GITHUB_ENV"
        echo "SUSFS_VERSION=$SUSFS_VERSION" >> "$GITHUB_ENV"
    fi
}

ci_integrate() {
    section "CI Integration ($BUILD_VARIANT)"

    local ROOT_DIR
    case "$ROOT_IMPL" in
        kazesu) ROOT_DIR="$SRC/KazeSU" ;;
        bakasu) ROOT_DIR="$SRC/BakaSU" ;;
    esac

    [[ -f "$SRC/Makefile" ]] \
        || die "Kernel source not found at $SRC"

    case "$BUILD_VARIANT" in
        base)
            info "Variant 'base' needs no integration"
            cd "$ROOT"
            return 0
            ;;
        all-in-one)
            integrate_root
            integrate_susfs
            integrate_inline_hooks
            integrate_nomount
            verify_integration
            ;;
        root|root-nomount)
            integrate_root
            integrate_manual_hooks
            [[ "$BUILD_VARIANT" == "root-nomount" ]] && integrate_nomount
            verify_integration
            ;;
    esac

    cd "$ROOT"
    ok "Integrated $ROOT_IMPL ($BUILD_VARIANT) successfully"
}

git_meta() {
    GIT_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    GIT_COMMIT="$(git -C "$SRC" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    GIT_DIRTY=""
    if [[ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]]; then
        GIT_DIRTY=" (dirty)"
    fi
}

compiler_meta() {
    local line version vendor=""
    line="$("$TC/bin/clang" --version | head -n1)"
    version="$(sed -n 's/.*clang version \([^ ]*\).*/\1/p' <<<"$line")"
    [[ "$line" == Neutron* ]] && vendor="Neutron "
    COMPILER="${vendor}clang ${version:-unknown} + LLD"
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
kconfig() {
    make -s -C "$SRC" O="$OUT" ARCH="$ARCH" "$@"
}

config_toggle() {
    bash "$SRC/scripts/config" --file "$OUT/.config" "--$1" "CONFIG_$2"
}

apply_variant_config() {
    section "Variant configuration: $BUILD_VARIANT"

    local symbol
    local has_nomount=0
    [[ -e "$SRC/fs/nomount/Kconfig" ]] && has_nomount=1

    # KazeSU builds either "Manual Hook" or "SUSFS Inline Hook"; KSU_SUSFS is
    # one of the choice alternatives.  The all-in-one variant therefore uses
    # the SUSFS inline mode (manual hook + auto hooks are forced off).
    local -a manual_symbols=(
        KSU_MANUAL_HOOK
        KSU_MANUAL_HOOK_AUTO_SETUID_HOOK
        KSU_MANUAL_HOOK_AUTO_INITRC_HOOK
        KSU_MANUAL_HOOK_AUTO_INPUT_HOOK
    )
    local -a ksu_symbols=(
        KSU KSU_SUSFS KSU_SUSFS_SUS_PATH KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT
        KSU_SUSFS_SPOOF_UNAME KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
        KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG KSU_SUSFS_OPEN_REDIRECT
        KSU_SUSFS_SUS_MAP
    )

    if [[ "$BUILD_VARIANT" == "all-in-one" ]]; then
        for symbol in "${manual_symbols[@]}"; do
            config_toggle disable "$symbol"
        done
        for symbol in "${ksu_symbols[@]}"; do
            config_toggle enable "$symbol"
        done
        # Logging stays off by choice; it can still be enabled at runtime.
        config_toggle disable KSU_SUSFS_ENABLE_LOG
        (( has_nomount )) && config_toggle enable NOMOUNT
    elif [[ "$BUILD_VARIANT" == "root" || "$BUILD_VARIANT" == "root-nomount" ]]; then
        # Root only: manual hook mode, no SUSFS kernel module.
        # root-nomount additionally enables NoMount.
        for symbol in "${ksu_symbols[@]}"; do
            config_toggle disable "$symbol"
        done
        config_toggle disable KSU_SUSFS_ENABLE_LOG
        config_toggle enable KSU
        config_toggle enable KSU_MANUAL_HOOK
        # The call sites are patched in the kernel by patches/kazesu_manual_hooks_*,
        # so KazeSU's own LSM/input auto-hooks must stay off.
        config_toggle disable KSU_MANUAL_HOOK_AUTO_SETUID_HOOK
        config_toggle disable KSU_MANUAL_HOOK_AUTO_INITRC_HOOK
        config_toggle disable KSU_MANUAL_HOOK_AUTO_INPUT_HOOK
        config_toggle disable KSU_TRACEPOINT_HOOK
        config_toggle disable KSU_TAMPER_SYSCALL_TABLE
        if [[ "$BUILD_VARIANT" == "root-nomount" ]] && (( has_nomount )); then
            config_toggle enable NOMOUNT
        else
            config_toggle disable NOMOUNT
        fi
    else
        for symbol in "${manual_symbols[@]}"; do
            config_toggle disable "$symbol"
        done
        for symbol in "${ksu_symbols[@]}"; do
            config_toggle disable "$symbol"
        done
        config_toggle disable KSU_SUSFS_ENABLE_LOG
        config_toggle disable NOMOUNT
    fi

    kconfig olddefconfig >>"$LOG" 2>&1 || build_failed "Variant olddefconfig failed"

    if [[ "$BUILD_VARIANT" == "all-in-one" ]]; then
        for symbol in KSU KSU_SUSFS KSU_SUSFS_SUS_PATH \
            KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT KSU_SUSFS_SPOOF_UNAME \
            KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
            KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_MAP; do
            grep -qx "CONFIG_${symbol}=y" "$OUT/.config" \
                || build_failed "Required all-in-one option CONFIG_${symbol} did not enable"
        done
        grep -qx "# CONFIG_KSU_MANUAL_HOOK is not set" "$OUT/.config" \
            || build_failed "KazeSU SUSFS mode must not also select CONFIG_KSU_MANUAL_HOOK"
        (( has_nomount )) && {
            grep -qx "CONFIG_NOMOUNT=y" "$OUT/.config" \
                || build_failed "Required all-in-one option CONFIG_NOMOUNT did not enable"
        }
        grep -qx "# CONFIG_KSU_SUSFS_ENABLE_LOG is not set" "$OUT/.config" \
            || build_failed "SUSFS logging must stay off in the all-in-one config"
        ok "$ROOT_IMPL SUSFS inline hooks + SUSFS v2.4.0$( (( has_nomount )) && echo ' + NoMount') enabled"
    elif [[ "$BUILD_VARIANT" == "root" || "$BUILD_VARIANT" == "root-nomount" ]]; then
        for symbol in KSU KSU_MANUAL_HOOK; do
            grep -qx "CONFIG_${symbol}=y" "$OUT/.config" \
                || build_failed "Required kazesu option CONFIG_${symbol} did not enable"
        done
        # Symbols that are absent from .config (no Kconfig entry at all) are
        # fine too - only "=y" is a failure.
        for symbol in KSU_SUSFS \
                      KSU_MANUAL_HOOK_AUTO_SETUID_HOOK KSU_MANUAL_HOOK_AUTO_INITRC_HOOK \
                      KSU_MANUAL_HOOK_AUTO_INPUT_HOOK; do
            grep -qx "CONFIG_${symbol}=y" "$OUT/.config" \
                && build_failed "$BUILD_VARIANT variant must not select CONFIG_${symbol}"
        done
        if [[ "$BUILD_VARIANT" == "root-nomount" ]]; then
            if (( has_nomount )); then
                grep -qx "CONFIG_NOMOUNT=y" "$OUT/.config" \
                    || build_failed "Required root-nomount option CONFIG_NOMOUNT did not enable"
            fi
            ok "$ROOT_IMPL manual hook + NoMount enabled (no SUSFS)"
        else
            grep -qx "CONFIG_NOMOUNT=y" "$OUT/.config" \
                && build_failed "root variant must not select CONFIG_NOMOUNT"
            ok "$ROOT_IMPL manual hook enabled (no SUSFS, no NoMount)"
        fi
    else
        grep -q '^CONFIG_KSU=y' "$OUT/.config" \
            && build_failed "Base variant must not enable CONFIG_KSU"
        ok "Root/SUSFS/NoMount disabled for clean base build"
    fi
}

configure_kernel() {
    section "Configuration"

    if (( DO_RECONFIG == 1 )) || [[ ! -s "$OUT/.config" ]]; then
        info "Generating .config from $DEFCONFIG"
        kconfig "$DEFCONFIG" >>"$LOG" 2>&1 || build_failed "Failed to generate base config"

        info "Merging fragment $FRAGMENT_REL"
        (
            cd "$OUT"
            sh "$SRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$FRAGMENT"
        ) >>"$LOG" 2>&1 || build_failed "Failed to merge configuration fragment"

        kconfig olddefconfig >>"$LOG" 2>&1 || build_failed "olddefconfig failed"

        grep -q '^CONFIG_TARGET_PRODUCT_SELENE=y' "$OUT/.config" \
            || die "selene fragment did not apply correctly"
        ok "Config generated from $DEFCONFIG + $FRAGMENT_REL"
    else
        info "Reusing existing out/.config"
        ok "Config unchanged (use -r to regenerate)"
    fi

    apply_variant_config

    if (( DO_MENUCONFIG == 1 )); then
        info "Opening menuconfig"
        make -C "$SRC" O="$OUT" ARCH="$ARCH" menuconfig
        ok "menuconfig finished"
    fi
}

# -----------------------------------------------------------------------------
# Compilation
# -----------------------------------------------------------------------------
# How many compile units to expect? Explicit > remembered > a sane default
# (a clean selene all-in-one build compiles ~3.3k units).
expected_units() {
    local f="$ROOT/.build-logs/units-${BUILD_VARIANT}.txt"
    if [[ -n "${BUILD_UNITS:-}" ]]; then
        printf '%s' "$BUILD_UNITS"
    elif [[ -s "$f" ]] && [[ "$(tr -dc '0-9' < "$f")" =~ ^[0-9]+$ ]]; then
        tr -dc '0-9' < "$f"
    else
        printf '3400'
    fi
}

compile_kernel() {
    section "Compilation"
    info "Building Image.gz-dtb with -j$JOBS"
    printf '  %sFull log: %s%s\n' "$GRY" "$(relpath "$LOG")" "$R"

    # Use LLVM toolchain utilities for better LTO/ThinLTO performance
    local make_cmd=(make -C "$SRC" O="$OUT" ARCH="$ARCH" -j"$JOBS"
        LLVM=1
        LLVM_IAS=1
        NM=llvm-nm
        OBJCOPY=llvm-objcopy
        OBJDUMP=llvm-objdump
        READELF=llvm-readelf
        AR=llvm-ar
        STRIP=llvm-strip
        LD=ld.lld
        HOSTLD=ld.lld)
    # Add load limit if set (prevents overloading CI runners)
    if [[ "$MAKE_LOAD_LIMIT" != "0" ]]; then
        make_cmd+=(-l"$MAKE_LOAD_LIMIT")
    fi
    if [[ -n "$EXTRACT_CERT_CFLAGS" ]]; then
        make_cmd+=("HOSTCFLAGS_extract-cert.o=$EXTRACT_CERT_CFLAGS")
    fi
    make_cmd+=(Image.gz-dtb)

    local start now elapsed
    local units_total units_seen=0 offset=0 last_pct=-1 bar_len=26
    local BAR_FULL='█' BAR_EMPTY='░'
    case "${LC_ALL:-${LANG:-}}" in
        *UTF-8*|*utf8*|*UTF8*) ;;
        *) BAR_FULL='#'; BAR_EMPTY='-' ;;
    esac
    local PCT=0 RATE=0 ETA=0 LAST=""
    units_total="$(expected_units)"
    start="$(date +%s)"

    # Count the compile units kbuild has finished so far. Only the new bytes of
    # the log are scanned, so this stays cheap even on a 20 MB log.
    count_units() {
        local size added
        size="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
        (( size > offset )) || return 0
        added="$(tail -c +$((offset + 1)) "$LOG" 2>/dev/null \
            | grep -cE '^  (CC|AS|HOSTCC) ' || true)"
        offset="$size"
        units_seen=$(( units_seen + added ))
    }

    render_bar() {
        local pct="$1" width="$2" fill empty out=""
        fill=$(( pct * width / 100 ))
        if (( fill > width )); then
            fill="$width"
        fi
        empty=$(( width - fill ))
        # printf with an empty arg list still prints the format once, hence
        # the explicit guards (0% would otherwise emit one full block).
        if (( fill > 0 )); then
            out+="$(printf "$BAR_FULL%.0s" $(seq 1 "$fill"))"
        fi
        if (( empty > 0 )); then
            out+="$(printf "$BAR_EMPTY%.0s" $(seq 1 "$empty"))"
        fi
        printf '%s' "$out"
    }

    progress_stats() {
        local secs
        count_units
        secs=$(( $(date +%s) - start )); (( secs > 0 )) || secs=1
        # An estimate can undershoot (incremental builds, config changes):
        # grow it rather than showing "67/12" and a nonsense percentage.
        if (( units_seen > units_total )); then
            units_total="$units_seen"
        fi
        PCT=$(( units_seen * 100 / units_total ))
        if (( PCT > 99 )); then
            PCT=99
        fi
        RATE=$(( units_seen * 60 / secs ))
        if (( RATE > 0 && units_seen < units_total )); then
            ETA=$(( (units_total - units_seen) * 60 / RATE ))
        else
            ETA=0
        fi
        LAST="$(grep -E '^  (CC|AS|HOSTCC) ' "$LOG" 2>/dev/null | tail -n1 \
            | sed 's/^  [A-Z]*  *//' || true)"
    }

    if (( VERBOSE == 1 )); then
        if ! "${make_cmd[@]}" 2>&1 | tee -a "$LOG"; then
            build_failed "Compilation failed"
        fi
    else
        "${make_cmd[@]}" >>"$LOG" 2>&1 &
        BUILD_PID=$!

        if [[ -t 1 ]]; then
            # Interactive: a live, in-place bar.
            while kill -0 "$BUILD_PID" 2>/dev/null; do
                progress_stats
                printf '\r\033[2K  %s%3d%%%s %s%s%s %s%5d/%-5d%s %s%s u/min%s %sETA %s%s %s%s%s' \
                    "$INF" "$PCT" "$R" \
                    "$ACC" "$(render_bar "$PCT" "$bar_len")" "$R" \
                    "$DIM" "$units_seen" "$units_total" "$R" \
                    "$DIM" "$RATE" "$R" \
                    "$DIM" "$(fmt_duration "$ETA")" "$R" \
                    "$DIM" "${LAST:0:46}" "$R"
                sleep 0.25
            done
            printf '\r\033[2K'
        else
            # CI / piped output: one line per 5%, so the log stays readable.
            printf '  %s[  0%%]%s 0/%d compile units (bar updates every 5%%)\n' \
                "$INF" "$R" "$units_total"
            while kill -0 "$BUILD_PID" 2>/dev/null; do
                progress_stats
                if (( PCT >= last_pct + 5 )); then
                    printf '  %s[%3d%%]%s %s %5d/%-5d %s u/min  ETA %-6s %s\n' \
                        "$INF" "$PCT" "$R" "$(render_bar "$PCT" 20)" \
                        "$units_seen" "$units_total" "$RATE" \
                        "$(fmt_duration "$ETA")" "${LAST:0:46}"
                    last_pct="$PCT"
                fi
                sleep 2
            done
        fi

        set +e
        wait "$BUILD_PID"
        local rc=$?
        set -e
        BUILD_PID=""

        if (( rc != 0 )); then
            build_failed "Compilation failed"
        fi

        count_units
        printf '  %s[100%%]%s %s %d compile units in %s\n' \
            "$INF" "$R" "$(render_bar 100 20)" "$units_seen" \
            "$(fmt_duration $(( $(date +%s) - start )))"

        # Remember the real unit count so the next clean build's bar is exact.
        if (( DO_CLEAN == 1 && units_seen > 500 )); then
            mkdir -p "$ROOT/.build-logs"
            printf '%s\n' "$units_seen" > "$ROOT/.build-logs/units-${BUILD_VARIANT}.txt"
        fi
    fi

    COMPILE_SECONDS=$(($(date +%s) - start))
    ok "Kernel compiled in $(fmt_duration "$COMPILE_SECONDS")"

    # Show ccache statistics if available
    local ccache_rate=""
    if command -v ccache >/dev/null 2>&1 && [[ -n "${CCACHE_DIR:-}" ]]; then
        subsection "ccache statistics"
        ccache -s 2>/dev/null | sed 's/^/  /' || true
        ccache_rate="$(ccache -s 2>/dev/null \
            | sed -n 's/^ *Hits:.*(\([0-9.]*\)%).*/\1/p' | head -n1 || true)"
    fi

    # Machine-readable stats for the release body and the Telegram post.
    component_versions
    {
        printf '{"variant":"%s","jobs":%s,"compile_seconds":%s,"units":%s' \
            "$BUILD_VARIANT" "$JOBS" "$COMPILE_SECONDS" "$units_seen"
        if [[ -n "$ccache_rate" ]]; then
            printf ',"ccache_hit_rate":%s' "$ccache_rate"
        fi
        printf ',"components":{'
        printf '"root":"%s","root_version":"%s","root_commit":"%s"' \
            "$ROOT_NAME" "$ROOT_VERSION" "$ROOT_COMMIT"
        printf ',"susfs_version":"%s"' "$SUSFS_VERSION"
        printf ',"nomount_version":"%s","nomount_commit":"%s"' \
            "$NOMOUNT_VERSION" "$NOMOUNT_COMMIT"
        printf '}}\n'
    } > "$OUT/build-stats.json"
}

# -----------------------------------------------------------------------------
# Artifact verification
# -----------------------------------------------------------------------------
KERNEL_IMAGE="$OUT/arch/arm64/boot/Image.gz-dtb"
DTB="$OUT/arch/arm64/boot/dts/mediatek/mt6768.dtb"
DTBO="$OUT/arch/arm64/boot/dts/mediatek/selene.dtbo"

verify_artifacts() {
    local f
    for f in "$KERNEL_IMAGE" "$DTB" "$DTBO"; do
        [[ -s "$f" ]] || build_failed "Expected artifact missing or empty: $(relpath "$f")"
    done
}

resolve_release() {
    KERNEL_RELEASE="$(cat "$OUT/include/config/kernel.release" 2>/dev/null || true)"
    if [[ -z "$KERNEL_RELEASE" ]]; then
        KERNEL_RELEASE="$(make -s -C "$SRC" O="$OUT" ARCH="$ARCH" kernelrelease 2>>"$LOG" | tail -n1)"
    fi
    [[ -n "$KERNEL_RELEASE" ]] || die "Could not determine kernel release"
}

# MediaTek's eccci Makefile does `obj-y += $(CONFIG_MTK_PLATFORM)/` while the
# Kconfig value contains quotes ("mt6768"). The shell strips them when running
# ar, but Kbuild's prerequisite list keeps the literal quotes and therefore
# always sees a missing input, rebuilding this archive -> drivers -> vmlinux.o
# -> LTO on every single build. Satisfy that phantom dependency with a symlink
# so incremental builds are actually incremental.
fix_mtk_quoted_platform() {
    local platform quoted
    platform="$(sed -n 's/^CONFIG_MTK_PLATFORM="\([^"]*\)"/\1/p' "$OUT/.config" | head -n1)"
    [[ -n "$platform" ]] || return 0

    quoted="$OUT/drivers/misc/mediatek/eccci/\"$platform\""
    mkdir -p "$quoted"
    ln -sfn "../$platform/built-in.a" "$quoted/built-in.a"
}

# -----------------------------------------------------------------------------
# AnyKernel3 packaging
# -----------------------------------------------------------------------------
ZIP=""

package_anykernel() {
    (( DO_ZIP == 1 )) || return 0

    section "AnyKernel3 package"
    info "Staging kernel + AnyKernel3"

    STAGE_DIR="$(mktemp -d "$OUT/.ak3-stage.XXXXXX")"
    cp -a "$AK3/." "$STAGE_DIR/"
    # The AnyKernel3 template is a git checkout - never ship its .git metadata.
    rm -rf "$STAGE_DIR/.git"
    cp -f "$KERNEL_IMAGE" "$STAGE_DIR/Image.gz-dtb"
    cp -f "$DTB" "$STAGE_DIR/dtb"

    local stamp base
    stamp="$(date +%Y%m%d-%H%M)"
    base="${KERNEL_RELEASE}"
    [[ "$base" == *"-$ZYTE_VERSION_TAG" ]] || base="$base-$ZYTE_VERSION_TAG"
    ZIP="$OUT/Zyte-Kernel-${BUILD_VARIANT}-${base}-${stamp}.zip"
    rm -f "$ZIP"

    if command -v zip >/dev/null 2>&1; then
        (cd "$STAGE_DIR" && zip -qr9 "$ZIP" .) >>"$LOG" 2>&1 \
            || build_failed "Failed to create AnyKernel3 zip"
    else
        python3 - "$STAGE_DIR" "$ZIP" <<'PY' >>"$LOG" 2>&1 || build_failed "Failed to create AnyKernel3 zip"
import os
import sys
import zipfile

stage, output = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
    for root, dirs, files in os.walk(stage):
        dirs.sort()
        files.sort()
        for name in files:
            full = os.path.join(root, name)
            zf.write(full, os.path.relpath(full, stage))
PY
    fi

    python3 - "$ZIP" <<'PY' >>"$LOG" 2>&1 || build_failed "AnyKernel3 zip validation failed"
import sys
import zipfile

zf = zipfile.ZipFile(sys.argv[1])
names = set(zf.namelist())
required = {
    "anykernel.sh",
    "Image.gz-dtb",
    "dtb",
    "META-INF/com/google/android/update-binary",
    "tools/ak3-core.sh",
}
missing = required - names
if missing:
    raise SystemExit("missing from zip: " + ", ".join(sorted(missing)))
for item in ("anykernel.sh", "META-INF/com/google/android/update-binary"):
    mode = (zf.getinfo(item).external_attr >> 16) & 0o777
    if not mode & 0o111:
        raise SystemExit(f"{item} is not executable in zip (mode {mode:o})")
PY

    rm -rf "$STAGE_DIR"
    STAGE_DIR=""
    ok "Packaged $(basename "$ZIP")"
}

# -----------------------------------------------------------------------------
# Failure / success screens
# -----------------------------------------------------------------------------
build_failed() {
    local title="$1"
    cleanup
    printf '\r\033[2K'
    printf '\n'
    bad "$title"
    printf '\n'

    local errors
    errors="$(grep -nE 'error:|Error [0-9]+|undefined reference|No rule to make target|fatal error' \
        "$LOG" 2>/dev/null | tail -n 12 || true)"
    if [[ -n "$errors" ]]; then
        subsection "Errors"
        printf '%s\n' "$errors" | sed "s/^/  ${DIM}│${R} /"
        printf '\n'
    fi

    subsection "Last 25 log lines"
    tail -n 25 "$LOG" 2>/dev/null | sed "s/^/  ${DIM}│${R} /"
    printf '\n  %sFull log:%s %s\n\n' "$DIM" "$R" "$(relpath "$LOG")"
    exit 1
}

success_screen() {
    local total
    total=$(($(date +%s) - TOTAL_START))

    # Calculate dynamic width based on longest line
    local kernel_str="$KERNEL_RELEASE"
    [[ "$kernel_str" == *"-$ZYTE_VERSION_TAG" ]] || kernel_str="$kernel_str-$ZYTE_VERSION_TAG"
    local min_width=50
    local max_width=80
    local str_width=${#kernel_str}
    local width=$(( str_width > min_width ? (str_width < max_width ? str_width : max_width) : min_width ))
    width=$((width + 4))  # padding
    local hr=$(printf '━%.0s' $(seq 1 $width))

    # Clear line and show completion
    printf '\r\033[2K'
    section "Build Complete"

    # Fancy box with gradient - centered properly
    printf '  %s┌%s┐%s\n' "$SUC" "$hr" "$R"
    local success_text="BUILD SUCCESSFUL"
    local success_pad=$(( (width - ${#success_text}) / 2 ))
    printf '  %s│%s%*s%s%*s%s│%s\n' "$SUC" "$R" $success_pad "" "$(gradient "$success_text" "$ROSE" "$PEACH" "$GREE")" $((width - ${#success_text} - success_pad)) "" "$SUC" "$R"
    local kernel_pad=$(( (width - ${#kernel_str}) / 2 ))
    printf '  %s│%s%*s%s%*s%s│%s\n' "$SUC" "$R" $kernel_pad "" "$(gradient "$kernel_str" "$CYN" "$BLU" "$MAUV")" $((width - ${#kernel_str} - kernel_pad)) "" "$SUC" "$R"
    printf '  %s└%s┘%s\n' "$SUC" "$hr" "$R"
    printf '\n'

    # Info rows with icons
    printf '  %s%s  %s%-14s%s %s\n' "$INF" "📱" "$DIM" "Device" "$R" "$DEVICE_NAME (selene) · MT6768"
    printf '  %s%s  %s%-14s%s %s\n' "$INF" "🌿" "$DIM" "Source" "$R" "$GIT_BRANCH @ $GIT_COMMIT$GIT_DIRTY"
    printf '  %s%s  %s%-14s%s %s\n' "$INF" "🔧" "$DIM" "Compiler" "$R" "$COMPILER"
    printf '  %s%s  %s%-14s%s %s\n' "$INF" "⏱️"  "$DIM" "Build time" "$R" "$(fmt_duration "$total")"
    printf '  %s%s  %s%-14s%s %s\n' "$INF" "⚙️"  "$DIM" "Jobs" "$R" "$JOBS"
    printf '\n'

    section "Artifacts"
    # Enhanced artifact display with icons
    artifact "📦 Kernel"   "$KERNEL_IMAGE"   "$SUC$B"
    artifact "📄 DTB"      "$DTB"            "$INF"
    artifact "📄 DTBO"     "$DTBO"           "$INF"
    artifact "🖼️  Image"    "$OUT/arch/arm64/boot/Image" "$CYN"
    artifact "🔍 vmlinux"  "$OUT/vmlinux"    "$MAUV"
    artifact "🗺️  System.map" "$OUT/System.map" "$PEACH"
    artifact "⚙️  Config"   "$OUT/.config"    "$TEAL"
    if [[ -n "$ZIP" ]]; then
        artifact "📦 AnyKernel" "$ZIP" "$MAG$B"
    fi
    printf '  %s%s  %s%-11s%s %s\n' "$INF" "📝" "$DIM" "Log" "$R" "$(relpath "$LOG")"
    printf '\n'

    # Flash instructions
    printf '  %s%s  %sKernel + DTB + DTBO are appended in Image.gz-dtb.%s\n' "$INF" "💡" "$DIM" "$R"
    if [[ -n "$ZIP" ]]; then
        printf '  %s%s  %sZip contains Image.gz-dtb + standalone dtb (mt6768).%s\n' "$INF" "💡" "$DIM" "$R"
        printf '  %s%s  %sFlash the AnyKernel3 zip in recovery, or use Image.gz-dtb directly.%s\n' "$INF" "💡" "$DIM" "$R"
    fi
    printf '\n'
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
banner
if (( DO_RESET == 1 )); then
    reset_integration
    exit 0
fi
if (( DO_CI_INTEGRATE == 1 )); then
    ci_integrate
    if (( CI_INTEGRATE_ONLY == 1 )); then
        ok "CI integration complete (exiting as requested)"
        exit 0
    fi
fi

preflight
git_meta
compiler_meta

section "Build configuration"
row "Target" "$DEVICE_NAME (selene) · MT6768"
row "Source" "$GIT_BRANCH @ $GIT_COMMIT$GIT_DIRTY"
row "Config" "$DEFCONFIG + $FRAGMENT_REL"
row "Variant" "$BUILD_VARIANT"
row "Version" "$ZYTE_VERSION_TAG"
row "Toolchain" "$COMPILER"
row "Output" "out/"
row "Jobs" "$JOBS"

if (( DO_CLEAN == 1 )); then
    section "Clean"
    info "Removing out/"
    rm -rf "$OUT"
    ok "Clean"
fi

mkdir -p "$OUT"
{
    printf 'Zyte Kernel build log\n'
    printf 'Started : %s\n' "$(date -Is)"
    printf 'Target  : Image.gz-dtb (selene)\n'
    printf 'Config  : %s + %s\n' "$DEFCONFIG" "$FRAGMENT_REL"
    printf 'Variant : %s\n' "$BUILD_VARIANT"
    printf 'Compiler: %s\n\n' "$COMPILER"
} >"$LOG"

configure_kernel
fix_mtk_quoted_platform
compile_kernel
verify_artifacts
resolve_release
package_anykernel
success_screen
