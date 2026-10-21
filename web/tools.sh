# Sourced by build.sh and test.sh: puts Swift and its WebAssembly SDK in reach, at the exact
# versions below, downloading them into $tools when they are missing.
#
# Swift comes from PATH when it is $SWIFT_VERSION; otherwise, on x86_64 Linux, as in Cloudflare's
# Workers Builds, from swift.org. The Wasm SDK must match the compiler exactly, so bump
# SWIFT_VERSION, TOOLCHAIN_SHA256 and WASM_SDK_SHA256 together. The checksums are swift.org's:
# the SDK's from https://www.swift.org/api/v1/install/releases.json, the toolchain's from its
# download, checked against its signature.

SWIFT_VERSION=6.4.1
TOOLCHAIN_SHA256=7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b
WASM_SDK_SHA256=783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8

web=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$web")
tools=${DRIP_WEB_TOOLS:-$root/.build/web-tools}
sdks=$tools/sdks
sdk=swift-$SWIFT_VERSION-RELEASE_wasm
mkdir -p "$tools"

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}

# Downloads $1 to $3 unless it is there already, and checks it is $2.
fetch() {
    if [ -f "$3" ] && [ "$(sha256 "$3")" = "$2" ]; then return; fi
    echo "Downloading $1"
    # A stalled download aborts rather than hanging the build. curl's own retries do not cover
    # a speed-limit abort on every version, so the loop restarts the download, up to 3 times.
    attempt=1
    until curl -sSfL --connect-timeout 20 --speed-limit 100000 --speed-time 30 \
        --retry 5 --retry-delay 5 --retry-all-errors -o "$3.part" "$1"; do
        if [ "$attempt" -ge 3 ]; then
            echo "$1: download failed $attempt times" >&2
            exit 1
        fi
        attempt=$((attempt + 1))
        echo "Downloading $1 again, attempt $attempt of 3"
    done
    actual=$(sha256 "$3.part")
    if [ "$actual" != "$2" ]; then
        echo "$1: expected sha256 $2, got $actual" >&2
        exit 1
    fi
    mv "$3.part" "$3"
}

if ! swift --version 2>/dev/null | grep -q "Swift version $SWIFT_VERSION "; then
    if [ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]; then
        echo "Put Swift $SWIFT_VERSION on PATH: it is only downloaded on x86_64 Linux" >&2
        exit 1
    fi
    toolchain=swift-$SWIFT_VERSION-RELEASE-ubuntu24.04
    fetch "https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/$toolchain.tar.gz" \
        "$TOOLCHAIN_SHA256" "$tools/$toolchain.tar.gz"
    if [ ! -d "$tools/$toolchain" ]; then
        tar -xzf "$tools/$toolchain.tar.gz" -C "$tools"
    fi
    PATH=$tools/$toolchain/usr/bin:$PATH
fi
swift --version 2>&1 | head -n 1

if ! swift sdk list --swift-sdks-path "$sdks" 2>/dev/null | grep -qx "$sdk"; then
    swift sdk install --swift-sdks-path "$sdks" --checksum "$WASM_SDK_SHA256" \
        "https://download.swift.org/swift-$SWIFT_VERSION-release/wasm-sdk/swift-$SWIFT_VERSION-RELEASE/${sdk}.artifactbundle.tar.gz"
fi
