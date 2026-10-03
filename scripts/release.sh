#!/bin/bash
# Publishes a GitHub release: builds one app for Apple silicon and Intel, zips it, and uploads it with the
# notes in docs/release-notes/<version>.md. The version comes from the VERSION file.
#   scripts/release.sh            build, zip and publish
#   scripts/release.sh --dry-run  build and zip only (dist/)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
TAG="v$VERSION"
NOTES="docs/release-notes/$VERSION.md"
GH="$(command -v gh || echo "$HOME/.local/bin/gh")"
[[ -f "$NOTES" ]] || { echo "Write the release notes first: $NOTES"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first, so the release matches the code."; exit 1; }

UNIVERSAL=1 ./build.sh
mkdir -p dist
ZIP="dist/MacroClicker-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent MacroClicker.app "$ZIP"
echo "$(shasum -a 256 "$ZIP")"
lipo -info MacroClicker.app/Contents/MacOS/MacroClicker

if [[ "${1:-}" == "--dry-run" ]]; then echo "Dry run: $ZIP is ready, nothing published."; exit 0; fi
git tag -a "$TAG" -m "MacroClicker $VERSION" 2>/dev/null || echo "Tag $TAG already exists"
git push origin "$TAG"
"$GH" release create "$TAG" "$ZIP" --title "MacroClicker $VERSION" --notes-file "$NOTES"
