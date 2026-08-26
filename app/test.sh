#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -parse-as-library -o build/prbar-tests \
    PRCore.swift \
    Tests.swift \
    -target arm64-apple-macos13.0

./build/prbar-tests
