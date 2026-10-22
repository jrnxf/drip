#!/bin/sh
# Builds the site into web/dist: the page from web/public, and drip's engine, DripCore compiled to
# WebAssembly from this checkout, named by its content so browsers can keep it for good.
set -eu
. "$(dirname "$0")/tools.sh"

BINARYEN_VERSION=133
BINARYEN_SHA256=2dc9c7813f5375db93d96ead4b78222fcc3e2677bbb832297af4797782a37489

if wasm-opt --version 2>/dev/null | grep -q "version $BINARYEN_VERSION\b"; then
    wasm_opt=wasm-opt
else
    binaryen=binaryen-version_$BINARYEN_VERSION
    provide "https://github.com/WebAssembly/binaryen/releases/download/version_$BINARYEN_VERSION/$binaryen-x86_64-linux.tar.gz" \
        "$BINARYEN_SHA256" "$binaryen"
    wasm_opt=$tools/$binaryen/bin/wasm-opt
fi

# DripWeb is only part of the package for a Wasm build.
set -- -c release --package-path "$root" --scratch-path "$root/.build/web" \
    --swift-sdks-path "$sdks" --swift-sdk "$sdk" --product DripWeb
DRIP_WEB=1 swift build "$@"
bin=$(DRIP_WEB=1 swift build "$@" --show-bin-path)

dist=$web/dist
rm -rf "$dist"
mkdir -p "$dist"
cp -R "$web/public/." "$dist/"
"$wasm_opt" -Oz --strip-debug --strip-producers --enable-bulk-memory --enable-sign-ext \
    --enable-mutable-globals --enable-nontrapping-float-to-int "$bin/DripWeb.wasm" -o "$dist/drip.wasm"
wasm=drip.$(sha256 "$dist/drip.wasm" | cut -c 1-16).wasm
mv "$dist/drip.wasm" "$dist/$wasm"
sed "s/__DRIP_WASM__/$wasm/g" "$web/public/index.html" > "$dist/index.html"
ls -l "$dist"
