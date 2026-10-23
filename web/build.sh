#!/bin/sh
# Builds the site into web/dist: the page from web/public with its styles from web/styles compiled
# by Tailwind CSS and inlined, and drip's engine, DripCore compiled to WebAssembly from this
# checkout, named by its content so browsers can keep it for good.
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

# Tailwind's standalone CLI, which needs no Node. The checksums are from the release's
# sha256sums.txt.
TAILWIND_VERSION=4.3.3
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) tailwind_target=linux-x64 TAILWIND_SHA256=dc61b3ac6b8c9ca874c0cc4c57b2409791a64c5540404ca5f5367360babc313a ;;
    Linux-aarch64) tailwind_target=linux-arm64 TAILWIND_SHA256=55fd0b241214eff3de1e8ee4f22796662f2d2e7a49bcfca7477cfd0bac398195 ;;
    Darwin-arm64) tailwind_target=macos-arm64 TAILWIND_SHA256=cdf646702987a743464dff4d9c60fd4480d1c1e73dd819a9a67f1078815dce9d ;;
    Darwin-x86_64) tailwind_target=macos-x64 TAILWIND_SHA256=7922e0953f2110c05976e3bf58f14e643d90427575e766b7d433f5f80cbee7e1 ;;
    *) echo "No Tailwind CSS build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
tailwind_dir=tailwindcss-$TAILWIND_VERSION-$tailwind_target
provide_program "https://github.com/tailwindlabs/tailwindcss/releases/download/v$TAILWIND_VERSION/tailwindcss-$tailwind_target" \
    "$TAILWIND_SHA256" "$tailwind_dir" tailwindcss
tailwind=$tools/$tailwind_dir/tailwindcss

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
css=$(mktemp -d)
trap 'rm -rf "$css"' EXIT
# Each page marks where its styles go, naming its stylesheet in web/styles, and names its engine.
for page in "$web"/public/*.html; do
    style=$(sed -n 's/^<!-- \([a-z]*\)\.css: build\.sh puts the compiled styles here\. -->$/\1/p' "$page")
    if [ -z "$style" ]; then echo "${page##*/} does not mark where its styles go" >&2; exit 1; fi
    # Not minified: the minifier rewrites some values to shorter ones that compute differently.
    [ -f "$css/$style.css" ] || "$tailwind" --input "$web/styles/$style.css" --output "$css/$style.css"
    sed "s/__DRIP_WASM__/$wasm/g" "$page" | awk -v css="$css/$style.css" -v mark="<!-- $style.css: build.sh puts the compiled styles here. -->" '
        $0 == mark { printf "<style>"; while ((getline line < css) > 0) print line; print "</style>"; next }
        { print }' > "$dist/${page##*/}"
    grep -q "^<style>" "$dist/${page##*/}"
done
ls -l "$dist"
