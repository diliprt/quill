#!/usr/bin/env bash
# Build a distributable Quill.zip and print its checksum.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./make-release.sh 0.1.0}"

# Stamp it before building so the app and the release tag can never disagree.
echo "$VERSION" > VERSION

./build.sh
rm -rf dist && mkdir -p dist

# ditto preserves the bundle's signature and symlinks; zip does not.
ditto -c -k --keepParent build/Quill.app dist/Quill.zip

echo
echo "✓ dist/Quill.zip  ($(du -h dist/Quill.zip | cut -f1))"
echo "  sha256: $(shasum -a 256 dist/Quill.zip | cut -d' ' -f1)"
echo "  arches: $(lipo -info build/Quill.app/Contents/MacOS/Quill | sed 's/.*are: //')"
echo
echo "Publish with:"
echo "  gh release create v$VERSION dist/Quill.zip --title \"Quill $VERSION\" --generate-notes"
