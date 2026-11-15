#!/bin/sh
# Runs DripCore's tests compiled to WebAssembly under wasmtime, so a change that breaks the web
# page's engine fails before the page is built.
set -eu
. "$(dirname "$0")/tools.sh"

# The question pages are written by web/pages/build.mjs and committed: fail on a stale or broken one.
# The Swift CI image has no Node, so there CI's pages job and build.sh run the check instead.
if command -v node >/dev/null; then
    node "$web/pages/build.mjs" --check && node "$web/pages/check.mjs"
else
    echo "node not found: skipping the question page checks (CI's pages job and build.sh run them)" >&2
fi

WASMTIME_VERSION=50.0.0
WASMTIME_SHA256=77c19ee0437991f9ac7837b9c269d9c7076744f85dad263fea5214cc2723c7ff

if wasmtime --version 2>/dev/null | grep -q "wasmtime $WASMTIME_VERSION "; then
    wasmtime=wasmtime
else
    release=wasmtime-v$WASMTIME_VERSION-x86_64-linux
    provide "https://github.com/bytecodealliance/wasmtime/releases/download/v$WASMTIME_VERSION/$release.tar.xz" \
        "$WASMTIME_SHA256" "$release"
    wasmtime=$tools/$release/wasmtime
fi

# llms-full.txt is built from the docs and recipes: fail now if one is missing or a link stays relative.
llms_full=$(mktemp)
"$web/llms-full.sh" "$llms_full"
if grep -E '\]\((\.|[a-z0-9-]+/|[a-z0-9-]+\.md)' "$llms_full"; then
    echo "llms-full.txt has a relative link" >&2
    exit 1
fi
rm -f "$llms_full"

# The drip executable has nothing to do with these tests; see Package.swift.
export DRIP_WASM_TESTS=1

set -- --package-path "$root" --scratch-path "$root/.build/wasm-tests" \
    --swift-sdks-path "$sdks" --swift-sdk "$sdk"
swift build --build-tests "$@"
bin=$(swift build "$@" --show-bin-path)

# Files the tests write go to a directory of their own, mapped to /tmp.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
"$wasmtime" run -W max-wasm-stack=8388608 --dir "$scratch::/tmp" --env TMPDIR=/tmp/ --env HOME=/tmp \
    "$bin/DripCoreTests-test-runner.wasm" --testing-library swift-testing

# The page's engine must compile and link too: the same build build.sh ships.
compile_engine
