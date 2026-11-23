#!/bin/sh
# Builds the site into web/dist: the pages from web/public with their styles from web/styles
# compiled by Tailwind CSS and inlined, and drip's engine, DripCore compiled to WebAssembly from
# this checkout. The engine, its loader and the fonts are named by their content, so browsers can
# keep them for good, and _headers says so and tells Cloudflare which fonts each page needs first.
set -eu
. "$(dirname "$0")/tools.sh"

# The question pages are written by web/pages/build.mjs and committed: fail on a stale or broken one.
node "$web/pages/build.mjs" --check && node "$web/pages/check.mjs"

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

compile_engine
bin=$engine_bin

dist=$web/dist
rm -rf "$dist"
mkdir -p "$dist"
cp -R "$web/public/." "$dist/"
# llms-full.txt is built from the repo's Markdown on every deploy, so it never goes stale.
"$web/llms-full.sh" "$dist/llms-full.txt"
"$wasm_opt" -Oz --strip-debug --strip-producers --enable-bulk-memory --enable-sign-ext \
    --enable-mutable-globals --enable-nontrapping-float-to-int "$bin/DripWeb.wasm" -o "$dist/drip.wasm"

# Renames $dist/$1.$2 to $1.<the start of its sha256>.$2, and prints the new name.
content_named() {
    named=$1.$(sha256 "$dist/$1.$2" | cut -c 1-16).$2
    mv "$dist/$1.$2" "$dist/$named"
    echo "$named"
}
wasm=$(content_named drip wasm)
engine=$(content_named drip-engine js)
archivo=$(content_named archivo woff2)
martian=$(content_named martian-mono woff2)

# A file named by its content never changes, so a browser need not ask for it again.
headers=$dist/_headers
for file in "$wasm" "$engine" "$archivo" "$martian"; do
    printf '/%s\n  Cache-Control: public, max-age=31536000, immutable\n' "$file"
done > "$headers"
# Cloudflare sends a page's Link headers ahead of the page as 103 Early Hints, so the browser has
# the fonts by the time it has the page. They say what the page's own preload tags say.
link="</$archivo>; rel=preload; as=font; type=\"font/woff2\"; crossorigin, </$martian>; rel=preload; as=font; type=\"font/woff2\"; crossorigin"

css=$(mktemp -d)
trap 'rm -rf "$css"' EXIT
# Cloudflare Web Analytics counts visits without cookies. Every page gets its beacon before </body>.
beacon="<!-- Cloudflare Web Analytics --><script type='module' src='https://static.cloudflareinsights.com/beacon.min.js' data-cf-beacon='{\"token\": \"f46f3dc0630e4000b27c0c5ae6fd26c5\"}'></script><!-- End Cloudflare Web Analytics -->"

# Each page marks where its styles go, naming its stylesheet in web/styles, and names its engine,
# its loader and its fonts, which get their built names here.
for page in "$web"/public/*.html; do
    name=${page##*/}
    style=$(sed -n 's/^<!-- \([a-z]*\)\.css: build\.sh puts the compiled styles here\. -->$/\1/p' "$page")
    if [ -z "$style" ]; then echo "$name does not mark where its styles go" >&2; exit 1; fi
    # Not minified: the minifier rewrites some values to shorter ones that compute differently.
    [ -f "$css/$style.css" ] || "$tailwind" --input "$web/styles/$style.css" --output "$css/$style.css"
    awk -v css="$css/$style.css" -v beacon="$beacon" -v mark="<!-- $style.css: build.sh puts the compiled styles here. -->" '
        $0 == mark { printf "<style>"; while ((getline line < css) > 0) print line; print "</style>"; next }
        $0 == "</body>" { print beacon }
        { print }' "$page" |
        sed "s/__DRIP_WASM__/$wasm/g; s/drip-engine\.js/$engine/g; s/archivo\.woff2/$archivo/g; s/martian-mono\.woff2/$martian/g" > "$dist/$name"
    grep -q "^<style>" "$dist/$name"
    if [ "$(grep -c 'static.cloudflareinsights.com/beacon.min.js' "$dist/$name")" != 1 ]; then
        echo "$name does not load the Web Analytics beacon once" >&2; exit 1
    fi
    # A font the page asks for under its old name is a 404, and one it does not preload arrives
    # after the first paint, which then shows the fallback font.
    for font in "$archivo" "$martian"; do
        if ! grep -q "^<link rel=\"preload\" href=\"/\{0,1\}$font\" as=\"font\" type=\"font/woff2\" crossorigin>$" "$dist/$name"; then
            echo "$name does not preload $font" >&2; exit 1
        fi
        if [ "$(grep -c "url($font)" "$dist/$name")" != 1 ]; then
            echo "$name's styles do not load $font" >&2; exit 1
        fi
    done
    if grep -nE '(archivo|martian-mono)\.woff2' "$dist/$name"; then
        echo "$name names a font without its hash" >&2; exit 1
    fi
    if grep -nE '__DRIP_WASM__|drip-engine\.js' "$dist/$name"; then
        echo "$name names the engine or its loader without its hash" >&2; exit 1
    fi
    # Cloudflare serves index.html as / and every other page without its .html.
    case $name in index.html) path=/ ;; *) path=/${name%.html} ;; esac
    printf '%s\n  Link: %s\n' "$path" "$link" >> "$headers"
done
ls -l "$dist"
cat "$headers"
