#!/usr/bin/env bash
# Verify the few files that have to name the app version agree with
# `versionName` in app/build.gradle.kts, which is the single source.
#
# Run it after bumping the version (notes/release.md drives this). It only
# reports; it never edits.
#
# Errors (exit 1) mean a file names the wrong version. Warnings mean a file
# is present and correctly versioned but still holds placeholder text.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GRADLE="$ROOT_DIR/app/build.gradle.kts"
VERSION="$(sed -n 's/^ *versionName *= *"\([^"]*\)".*/\1/p' "$GRADLE" | head -1)"
[ -n "$VERSION" ] || { echo "ERROR: no versionName in $GRADLE" >&2; exit 1; }
echo "app version: $VERSION (from app/build.gradle.kts)"

errors=0
warnings=0
err() { echo "ERROR: $*" >&2; errors=$((errors + 1)); }
warn() { echo "warning: $*" >&2; warnings=$((warnings + 1)); }

# F-Droid reads one changelog per versionCode straight out of the repo.
# Each release adds a file; older ones stay for older releases.
CHANGELOG="$ROOT_DIR/fastlane/metadata/android/en-US/changelogs/$VERSION.txt"
if [ ! -f "$CHANGELOG" ]; then
    err "missing ${CHANGELOG#"$ROOT_DIR"/} — F-Droid shows no changelog for v$VERSION"
elif grep -q "TODO(" "$CHANGELOG"; then
    warn "${CHANGELOG#"$ROOT_DIR"/} still holds placeholder text"
elif [ "$(wc -c <"$CHANGELOG")" -gt 500 ]; then
    err "${CHANGELOG#"$ROOT_DIR"/} exceeds F-Droid's 500-character limit"
fi

# The fdroiddata recipe draft, until it is merged upstream. After that
# F-Droid's AutoUpdateMode maintains the version fields in *their* repo and
# this file should be deleted — see plans/f-droid.md step 4.
RECIPE="$ROOT_DIR/fdroid/me.phie.tawc.yml"
if [ -f "$RECIPE" ]; then
    check_field() {
        local field="$1" want="$2" got
        # Fields sit at the top level or as the first key of a Builds
        # list entry ("  - versionName: '1'"), hence the optional dash.
        got="$(sed -n "s/^ *-\{0,1\} *$field: *'\{0,1\}\([^']*\)'\{0,1\} *$/\1/p" "$RECIPE" | head -1)"
        [ -n "$got" ] || { err "no $field in ${RECIPE#"$ROOT_DIR"/}"; return; }
        [ "$got" = "$want" ] || err "${RECIPE#"$ROOT_DIR"/}: $field is '$got', expected '$want'"
    }
    check_field versionName "$VERSION"
    check_field versionCode "$VERSION"
    check_field commit "v$VERSION"
    check_field CurrentVersion "$VERSION"
    check_field CurrentVersionCode "$VERSION"
fi

if [ "$errors" -gt 0 ]; then
    echo "$errors error(s), $warnings warning(s)" >&2
    exit 1
fi
echo "version references consistent${warnings:+ ($warnings warning(s))}"
