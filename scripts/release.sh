#!/bin/bash
# Releases a new version of AVDs:
#   scripts/release.sh <version name>             for example: scripts/release.sh 1.1.0
#   scripts/release.sh <version name> --dry-run   builds the DMG, changes nothing
#
# Sets the version name, bumps the version code (CFBundleVersion) by one, builds the app,
# commits the version change, tags it v<version name>, pushes branch and tag, and creates a
# GitHub release with a DMG of the app attached. The release text explains how to install it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${1:-}"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true
fail() { echo "error: $*" >&2; exit 1; }

[ -n "$NAME" ] || fail "missing version name. Usage: scripts/release.sh <version name> [--dry-run]"
# Semantic versioning, MAJOR.MINOR.PATCH. macOS only allows numbers in CFBundleShortVersionString,
# so pre-release suffixes like -beta.1 don't work.
[[ "$NAME" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "version name must be semver MAJOR.MINOR.PATCH like 1.2.0, got '$NAME'"
TAG="v$NAME"
PLIST=app/Resources/Info.plist
OLD_CODE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
CODE=$((OLD_CODE + 1))

if ! $DRY_RUN; then
  command -v gh >/dev/null || fail "the GitHub CLI (gh) is missing. Install it with: brew install gh"
  gh auth status >/dev/null 2>&1 || fail "gh isn't logged in. Run: gh auth login"
  [ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first"
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
  git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fail "tag $TAG already exists on origin"
fi

echo "releasing AVDs $NAME (version code $OLD_CODE -> $CODE)"
if ! $DRY_RUN; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CODE" "$PLIST"
fi

scripts/build.sh
# The DMG opens to AVDs.app next to a shortcut to Applications, to drag it there.
DMG="app/build/AVDs-$NAME.dmg"
STAGE=app/build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto app/build/AVDs.app "$STAGE/AVDs.app"
ln -s /Applications "$STAGE/Applications"
diskutil image create from --format UDZO --volumeName "AVDs $NAME" "$STAGE" "$DMG" >/dev/null 2>&1 \
  || fail "creating the DMG failed"
rm -rf "$STAGE"
echo "created $DMG"

if $DRY_RUN; then
  echo "dry run: no commit, tag, push or GitHub release"
  exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
git add "$PLIST"
git commit -m "Release $NAME ($CODE)"
git tag -a "$TAG" -m "AVDs $NAME"
git push origin "$BRANCH" "$TAG"
# Install steps first, then GitHub's generated list of changes.
REPO_URL=$(gh repo view --json url -q .url)
DMG_NAME=$(basename "$DMG")
NOTES=app/build/release-notes.md
cat > "$NOTES" <<EOF
## Install

1. Download [$DMG_NAME]($REPO_URL/releases/download/$TAG/$DMG_NAME) and open it.
2. Drag AVDs onto Applications.
3. The app isn't signed or notarized, so macOS blocks it on the first launch with "Apple could not verify AVDs". Open System Settings, Privacy & Security, scroll down and click Open Anyway. Or run this once in Terminal: \`xattr -dr com.apple.quarantine /Applications/AVDs.app\`

AVDs needs macOS 26 on Apple silicon, the [\`android\` CLI](https://developer.android.com/tools/agents/android-cli) and the Android SDK. To mirror devices, install [scrcpy](https://github.com/Genymobile/scrcpy) with \`brew install scrcpy\`. See the [README]($REPO_URL#readme) for more.
EOF
gh release create "$TAG" "$DMG" --title "AVDs $NAME" --notes-file "$NOTES" --generate-notes
echo "released $TAG"
