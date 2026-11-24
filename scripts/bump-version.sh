#!/usr/bin/env bash
# =============================================================================
#  Zyte Kernel - version bumper
#  Usage: scripts/bump-version.sh [patch|minor|major|none]
#
#  Bumps the VERSION file and (when GITHUB_ENV is set) exports the new
#  version so the workflow can tag the release with it.
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
TYPE="${1:-patch}"

[[ -f "$VERSION_FILE" ]] || { echo "No VERSION file at $VERSION_FILE" >&2; exit 1; }
CUR="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$CUR" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
    echo "Invalid VERSION '$CUR' (expected e.g. 1.0 or 1.0.1)" >&2
    exit 1
}

# split into up to 3 numeric components
IFS='.' read -r MAJOR MINOR PATCH <<<"$CUR"
MINOR="${MINOR:-0}"
PATCH="${PATCH:-0}"

case "$TYPE" in
    none)
        NEW="$CUR"
        ;;
    patch)
        # 1.0   -> 1.0.1
        # 1.0.1 -> 1.0.2
        NEW="$MAJOR.$MINOR.$((PATCH + 1))"
        ;;
    minor)
        # 1.0   -> 1.1
        # 1.0.1 -> 1.1.0
        NEW="$MAJOR.$((MINOR + 1)).0"
        ;;
    major)
        NEW="$((MAJOR + 1)).0.0"
        ;;
    *)
        echo "Unknown bump type '$TYPE' (use patch, minor, major or none)" >&2
        exit 1
        ;;
esac

printf '%s\n' "$NEW" > "$VERSION_FILE"

echo "Version: v$CUR -> v$NEW"

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
