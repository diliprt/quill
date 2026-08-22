#!/usr/bin/env bash
# Build the two harness binaries:
#   harness-before  — STT/Cleaner exactly as on main (plus mechanical Linux shims)
#   harness-after   — the working-tree sources, with speculative support compiled in
set -euo pipefail
cd "$(dirname "$0")"

SWIFTC="${SWIFTC:-$HOME/swift/usr/bin/swiftc}"
BASELINE_REF="${BASELINE_REF:-main}"

rm -rf build
mkdir -p build/src-before build/src-after

git -C .. show "$BASELINE_REF:Sources/STT.swift"     > build/src-before/STT.swift
git -C .. show "$BASELINE_REF:Sources/Cleaner.swift" > build/src-before/Cleaner.swift
cp ../Sources/STT.swift ../Sources/Cleaner.swift ../Sources/SpeculativeCleanup.swift build/src-after/

cp harness_main.swift build/main.swift
python3 patch_linux.py build/src-before/*.swift build/src-after/*.swift

echo "→ compiling harness-before (baseline $BASELINE_REF)"
"$SWIFTC" -swift-version 5 -O build/src-before/*.swift Support.swift build/main.swift -o build/harness-before

echo "→ compiling harness-after (working tree, speculative enabled)"
"$SWIFTC" -swift-version 5 -O -D SPECULATIVE build/src-after/*.swift Support.swift build/main.swift -o build/harness-after

echo "→ governor unit test"
mkdir -p build/gov
cp governor_test_main.swift build/gov/main.swift
"$SWIFTC" -swift-version 5 build/src-after/Cleaner.swift build/src-after/SpeculativeCleanup.swift \
  Support.swift build/gov/main.swift -o build/governor-test
./build/governor-test

echo "→ vocabulary correction-learning test"
mkdir -p build/vocab
cp ../Sources/Vocabulary.swift build/vocab/Vocabulary.swift
python3 patch_linux.py build/vocab/Vocabulary.swift
cp vocab_test_main.swift build/vocab/main.swift
"$SWIFTC" -swift-version 5 build/vocab/Vocabulary.swift log_stub.swift build/vocab/main.swift \
  -o build/vocab-test
./build/vocab-test

echo "✓ built build/harness-before and build/harness-after"
