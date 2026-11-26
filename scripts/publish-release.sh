#!/usr/bin/env bash
# publish-release.sh - create a GitHub release and upload assets via the REST API.
#
# Why not softprops/action-gh-release? Because its 403s are opaque. This script
# prints the token identity, the exact HTTP status and the response body for
# every attempt, and it can try several tokens in order.
#
# It also creates the git tag *first* through the Git Data API. That endpoint
# has no "workflow files" restriction, while POST /releases can refuse with
# 403 "Resource not accessible by integration" when the target commit touches
# .github/workflows/ and the token has no workflow permission.
#
# Environment:
#   REPO        owner/name                         (required)
#   TAG         tag name, e.g. zyte-kernel-v1.0-x  (required)
#   SHA         commit to tag                      (required)
#   NAME        release title                      (required)
#   BODY_FILE   markdown file for the release body (optional)
#   ASSETS      space-separated files to upload    (optional)
#   TOKENS      space-separated tokens, tried in order (required)
#   PROBE       1 = create a draft release, delete it, report, exit
#
set -Eeuo pipefail

REPO="${REPO:?REPO is required}"
TAG="${TAG:?TAG is required}"
SHA="${SHA:?SHA is required}"
NAME="${NAME:-$TAG}"
BODY_FILE="${BODY_FILE:-}"
ASSETS="${ASSETS:-}"
TOKENS="${TOKENS:?TOKENS is required}"
PROBE="${PROBE:-0}"

API="https://api.github.com"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# api TOKEN METHOD PATH [JSON] -> prints the HTTP status, body in $TMP/body.json
api() {
    local token="$1" method="$2" path="$3" data="${4:-}" code
    if [[ -n "$data" ]]; then
        code="$(curl -sS --max-time 60 -o "$TMP/body.json" -w '%{http_code}' \
            -X "$method" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$API$path" -d "$data" 2>/dev/null)" || code=000
    else
        code="$(curl -sS --max-time 60 -o "$TMP/body.json" -w '%{http_code}' \
            -X "$method" \
            -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$API$path" 2>/dev/null)" || code=000
    fi
    printf '%s' "$code"
}

json_field() {
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],"") if isinstance(d,dict) else "")' \
        "$TMP/body.json" "$1" 2>/dev/null || true
}

body_excerpt() {
    head -c 300 "$TMP/body.json" 2>/dev/null | tr '\n' ' ' || true
}

token_login() {
    local code repo_code
    code="$(api "$1" GET /user)"
    if [[ "$code" == "200" ]]; then
        json_field login
        return 0
    fi
    # GitHub App tokens (github-actions[bot]) cannot read /user at all - that
    # is not a broken token. Probe the repository instead so a perfectly
    # working token is not reported as "invalid".
    repo_code="$(api "$1" GET "/repos/$REPO")"
    if [[ "$repo_code" == "200" ]]; then
        printf 'token(/user HTTP %s, repo access OK)' "$code"
        return 0
    fi
    printf 'invalid-token(HTTP %s)' "$repo_code"
}

json_escape_file() {
    python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1],encoding="utf-8").read()))' "$1"
}

json_escape_str() {
    python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"
}

# ensure_tag TOKEN -> 0 if the tag now exists
ensure_tag() {
    local token="$1" code
    code="$(api "$token" POST "/repos/$REPO/git/refs" \
        "{\"ref\":\"refs/tags/$TAG\",\"sha\":\"$SHA\"}")"
    case "$code" in
        201) echo "    tag $TAG created"; return 0 ;;
        422) echo "    tag $TAG already exists"; return 0 ;;
        *)   echo "    tag $TAG failed -> HTTP $code $(body_excerpt)"; return 1 ;;
    esac
}

# create_release TOKEN DRAFT -> prints release id, empty on failure
create_release() {
    local token="$1" draft="$2" payload code
    payload="{\"tag_name\":$(json_escape_str "$TAG"),\"name\":$(json_escape_str "$NAME"),\"draft\":$draft,\"prerelease\":false"
    if [[ -n "$BODY_FILE" && -f "$BODY_FILE" ]]; then
        payload+=",\"body\":$(json_escape_file "$BODY_FILE")"
    fi
    payload+="}"

    code="$(api "$token" POST "/repos/$REPO/releases" "$payload")"
    if [[ "$code" == "201" ]]; then
        json_field id
        return 0
    fi
    if [[ "$code" == "422" && "$PROBE" != "1" ]]; then
        # Already released (re-run of the same build): reuse it. Never reuse in
        # probe mode - the probe must delete only what it created.
        code="$(api "$token" GET "/repos/$REPO/releases/tags/$TAG")"
        if [[ "$code" == "200" ]]; then
            echo "    release for $TAG already exists, reusing it" >&2
            json_field id
            return 0
        fi
    fi
    echo "    release failed -> HTTP $code $(body_excerpt)" >&2
    return 1
}

delete_release() {
    local token="$1" id="$2" code
    code="$(api "$token" DELETE "/repos/$REPO/releases/$id")"
    [[ "$code" == "204" || "$code" == "404" ]] || echo "    could not delete probe release $id (HTTP $code)"
}

delete_tag() {
    local token="$1" code
    code="$(api "$token" DELETE "/repos/$REPO/git/refs/tags/$TAG")"
    [[ "$code" == "204" || "$code" == "422" || "$code" == "404" ]] || echo "    could not delete probe tag (HTTP $code)"
}

upload_assets() {
    local token="$1" id="$2" url file code name
    code="$(api "$token" GET "/repos/$REPO/releases/$id")"
    [[ "$code" == "200" ]] || { echo "    cannot read release $id (HTTP $code)"; return 1; }
    url="$(json_field upload_url)"
    url="${url%%\{*}"
    [[ -n "$url" ]] || { echo "    release has no upload_url"; return 1; }

    local failed=0
    for file in $ASSETS; do
        [[ -f "$file" ]] || { echo "    missing asset: $file"; failed=1; continue; }
        name="$(basename "$file")"
        code="$(curl -sS --max-time 300 -o "$TMP/upload.json" -w '%{http_code}' \
            -X POST -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@$file" "$url?name=$name" 2>/dev/null)" || code=000
        if [[ "$code" == "201" ]]; then
            echo "    uploaded $name"
        elif [[ "$code" == "422" ]]; then
            echo "    $name already attached"
        else
            echo "    upload of $name failed -> HTTP $code $(head -c 200 "$TMP/upload.json" | tr '\n' ' ')"
            failed=1
        fi
    done
    return "$failed"
}

# ---------------------------------------------------------------- main

echo "Repository: $REPO"
echo "Tag:        $TAG"
echo "Commit:     $SHA"
[[ "$PROBE" == "1" ]] && echo "Mode:       probe (draft release, then deleted)"

chosen=""
chosen_name=""
for token in $TOKENS; do
    [[ -n "$token" ]] || continue
    login="$(token_login "$token")"
    echo "Token: $login"

    if [[ "$PROBE" == "1" ]]; then
        ensure_tag "$token" || continue
        id="$(create_release "$token" true)" || { delete_tag "$token"; continue; }
        [[ -n "$id" ]] || { delete_tag "$token"; continue; }
        delete_release "$token" "$id"
        delete_tag "$token"
        echo "  $login can create releases"
        chosen="$token"; chosen_name="$login"
        break
    fi

    ensure_tag "$token" || continue
    id="$(create_release "$token" false)" || continue
    [[ -n "$id" ]] || continue
    echo "Release created: $API/repos/$REPO/releases/$id"

    if [[ -n "$ASSETS" ]]; then
        upload_assets "$token" "$id" || { echo "::error::Release created but asset upload failed"; exit 1; }
    fi
    echo "Published with token: $login"
    chosen="$token"; chosen_name="$login"
    break
done

if [[ -z "$chosen" ]]; then
    echo "::error::No token could create a release on $REPO."
    echo "If a token can create tags but not releases, the commit touches .github/workflows/ and the token lacks workflow permission:"
    echo "  - classic PAT: add the 'workflow' scope"
    echo "  - fine-grained PAT: add 'Workflows: Read and write' for this repository"
    echo "  - GITHUB_TOKEN can never be authorised for this; the repo setting alone is not enough"
    exit 1
fi

if [[ "$PROBE" == "1" ]]; then
    echo "Probe OK with: $chosen_name"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        others=""
        for t in $TOKENS; do
            [[ "$t" == "$chosen" ]] || others="$others $t"
        done
        {
            echo "RELEASE_TOKEN_CHOSEN=$chosen"
            echo "RELEASE_TOKEN_OTHERS=${others# }"
            echo "RELEASE_TOKEN_SOURCE=$chosen_name"
        } >> "$GITHUB_ENV"
    fi
fi
