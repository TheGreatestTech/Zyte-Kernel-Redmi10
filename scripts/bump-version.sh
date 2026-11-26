#!/usr/bin/env bash
# =============================================================================
#  Zyte Kernel - version bumper
#  Usage: scripts/bump-version.sh [auto|major|patch|none]
#
#  auto   - bump the minor part by one, but only when a dependency changed
#           1.0 -> 1.1 -> 1.2 -> ... -> 1.9 -> 1.10 -> 2.0 -> 2.1 -> ...
#           (the minor part counts up to 10, then the major part takes over)
#  major  - always bump the major part (1.9 -> 2.0) - use it when you changed
#           something yourself
#  patch  - always do the "auto" step, even when nothing changed
#  none   - never touch the version (same release, new build)
#
#  The dependencies (BakaSU, NoMount, SUSFS, kernel) are remembered in
#  dependencies.json - "auto" compares them with the current ones.
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
DEPS_FILE="$ROOT/dependencies.json"
TYPE="${1:-auto}"

[[ -f "$VERSION_FILE" ]] || { echo "No VERSION file at $VERSION_FILE" >&2; exit 1; }
CUR="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$CUR" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
    echo "Invalid VERSION '$CUR' (expected e.g. 1.0 or 1.10)" >&2
    exit 1
}

# split into up to 3 numeric components
IFS='.' read -r MAJOR MINOR PATCH <<<"$CUR"
MAJOR="${MAJOR:-0}"
MINOR="${MINOR:-0}"

# The dependencies of this build. They are exported by build.sh after the
# integration step.
CURRENT_DEPS="$(python3 - <<'PY'
import json
import os

deps = {
    "root": os.environ.get("KAZESU_VERSION", ""),
    "nomount": os.environ.get("NOMOUNT_VERSION", ""),
    "susfs": os.environ.get("SUSFS_VERSION", ""),
    "kernel": os.environ.get("KERNEL_COMMIT", ""),
}
print(json.dumps({k: v for k, v in deps.items() if v}))
PY
)"

# Compare with the dependencies of the last release.
CHANGED="$(python3 - "$DEPS_FILE" "$CURRENT_DEPS" <<'PY'
import json
import os
import sys

path, current = sys.argv[1], json.loads(sys.argv[2])

if not os.path.exists(path):
    # First run: there is nothing to compare against yet.
    print("new")
    raise SystemExit(0)

try:
    with open(path) as fh:
        old = json.load(fh)
except Exception:
    old = {}

changed = [k for k, v in current.items() if old.get(k, "") != v]
print(",".join(changed))
PY
)"

bump_minor() {
    local next=$((MINOR + 1))
    if (( next > 10 )); then
        printf '%s.0' "$((MAJOR + 1))"
    else
        printf '%s.%s' "$MAJOR" "$next"
    fi
}

case "$TYPE" in
    none)
        NEW="$CUR"
        ;;
    auto)
        if [[ "$CHANGED" == "new" ]]; then
            NEW="$CUR"
            echo "No dependency state yet - keeping v$CUR"
        elif [[ -n "$CHANGED" ]]; then
            NEW="$(bump_minor)"
            echo "Dependencies changed ($CHANGED) - bumping the version"
        else
            NEW="$CUR"
            echo "No dependency change - keeping v$CUR"
        fi
        ;;
    patch)
        NEW="$(bump_minor)"
        ;;
    major)
        NEW="$((MAJOR + 1)).0"
        ;;
    *)
        echo "Unknown bump type '$TYPE' (use auto, major, patch or none)" >&2
        exit 1
        ;;
esac

printf '%s\n' "$NEW" > "$VERSION_FILE"

# Remember the dependencies of this version, so the next run can tell whether
# something changed.
if [[ -n "$CURRENT_DEPS" ]]; then
    python3 - "$DEPS_FILE" "$CURRENT_DEPS" <<'PY'
import json
import sys

path, current = sys.argv[1], sys.argv[2]
with open(path, "w") as fh:
    json.dump(json.loads(current), fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
fi

echo "Version: v$CUR -> v$NEW"
echo "Dependencies: $CURRENT_DEPS"

if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        echo "ZYTE_VERSION=$NEW"
        echo "ZYTE_VERSION_TAG=v$NEW"
        echo "ZYTE_VERSION_PREVIOUS=$CUR"
    } >> "$GITHUB_ENV"
fi

# the build script reads VERSION itself; keep its env in sync for anything
# that already sourced it
export ZYTE_VERSION="$NEW"
export ZYTE_VERSION_TAG="v$NEW"
