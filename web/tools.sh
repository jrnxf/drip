# Sourced by build.sh and test.sh: puts Swift and its WebAssembly SDK in reach, at the exact
# versions below, downloading them when they are missing.
#
# Swift comes from PATH when it is $SWIFT_VERSION; otherwise, on x86_64 Linux, as in Cloudflare's
# Workers Builds, from swift.org. The Wasm SDK must match the compiler exactly, so bump
# SWIFT_VERSION, TOOLCHAIN_SHA256 and WASM_SDK_SHA256 together. The checksums are swift.org's:
# the SDK's from https://www.swift.org/api/v1/install/releases.json, the toolchain's from its
# download, checked against its signature.
#
# The downloads are shared by every checkout of drip, as they are gigabytes: they live once per
# user, in $DRIP_WEB_TOOLS or else in drip/web-tools under $XDG_CACHE_HOME or ~/.cache. Each tool
# has a directory named for its version, and it is only used once it is whole and came from the
# archive its checksum pins. The builds themselves stay in each checkout's .build.

SWIFT_VERSION=6.4.1
TOOLCHAIN_SHA256=7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b
WASM_SDK_SHA256=783e6128d174d9f975b4eda68be02a5960681b723ef372e6876a7c2543a365d8

web=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$web")
tools=${DRIP_WEB_TOOLS:-${XDG_CACHE_HOME:-$HOME/.cache}/drip/web-tools}
sdks=$tools/sdks
sdk=swift-$SWIFT_VERSION-RELEASE_wasm
mkdir -p "$tools"

# Each checkout used to download its own tools into .build/web-tools.
if [ -d "$root/.build/web-tools" ] && [ "$tools" != "$root/.build/web-tools" ]; then
    echo "Removing $root/.build/web-tools: the tools are shared now, in $tools"
    rm -rf "$root/.build/web-tools"
fi

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d ' ' -f 1
}

# Runs "$@" holding the lock on $tools, so checkouts building at once download each tool once: the
# others wait, then find it there. The lock is a symlink to its holder's PID, and a lock whose
# holder has gone without letting go is taken over.
locked() {
    lock=$tools/.lock
    waiting=
    until ln -s "$$" "$lock" 2>/dev/null; do
        holder=$(readlink "$lock" 2>/dev/null) || continue
        if ! kill -0 "$holder" 2>/dev/null; then
            # Unless another process took the lock over first.
            if [ "$(readlink "$lock" 2>/dev/null)" = "$holder" ]; then rm -f "$lock"; fi
            continue
        fi
        if [ -z "$waiting" ]; then
            echo "Waiting for process $holder, which is downloading into $tools"
            waiting=1
        fi
        sleep 1
    done
    trap 'rm -f "$lock"' EXIT
    "$@"
    rm -f "$lock"
    trap - EXIT
}

# Downloads $1 to $3, and checks it is $2.
fetch() {
    echo "Downloading $1"
    # A stalled download aborts rather than hanging the build. curl's own retries do not cover
    # a speed-limit abort on every version, so the loop restarts the download, up to 3 times.
    attempt=1
    until curl -sSfL --connect-timeout 20 --speed-limit 100000 --speed-time 30 \
        --retry 5 --retry-delay 5 --retry-all-errors -o "$3" "$1"; do
        if [ "$attempt" -ge 3 ]; then
            echo "$1: download failed $attempt times" >&2
            exit 1
        fi
        attempt=$((attempt + 1))
        echo "Downloading $1 again, attempt $attempt of 3"
    done
    actual=$(sha256 "$3")
    if [ "$actual" != "$2" ]; then
        echo "$1: expected sha256 $2, got $actual" >&2
        rm -f "$3"
        exit 1
    fi
}

# Puts $tools/$3, the directory the archive at $1 holds, in place from that archive, which must
# have sha256 $2, unless it is there already. The directory keeps the checksum in .sha256.
provide() {
    if [ "$(cat "$tools/$3/.sha256" 2>/dev/null)" != "$2" ]; then
        locked unpack "$@"
    fi
}

unpack() {
    # Another checkout may have put it in place while this one waited for the lock.
    if [ "$(cat "$tools/$3/.sha256" 2>/dev/null)" = "$2" ]; then return; fi
    staging=$tools/.staging
    rm -rf "$staging" "${tools:?}/${3:?}"
    mkdir "$staging"
    archive=$staging/${1##*/}
    fetch "$1" "$2" "$archive"
    tar -xf "$archive" -C "$staging"
    echo "$2" > "$staging/$3/.sha256"
    mv "$staging/$3" "$tools/$3"
    rm -rf "$staging"
}

# Puts the program at $1, which must have sha256 $2, in place as $tools/$3/$4, unless it is there
# already. The directory keeps the checksum in .sha256.
provide_program() {
    if [ "$(cat "$tools/$3/.sha256" 2>/dev/null)" != "$2" ]; then
        locked place_program "$@"
    fi
}

place_program() {
    if [ "$(cat "$tools/$3/.sha256" 2>/dev/null)" = "$2" ]; then return; fi
    staging=$tools/.staging
    rm -rf "$staging" "${tools:?}/${3:?}"
    mkdir -p "$staging/$3"
    fetch "$1" "$2" "$staging/$3/$4"
    chmod +x "$staging/$3/$4"
    echo "$2" > "$staging/$3/.sha256"
    mv "$staging/$3" "$tools/$3"
    rm -rf "$staging"
}

if ! swift --version 2>/dev/null | grep -q "Swift version $SWIFT_VERSION "; then
    if [ "$(uname -s)-$(uname -m)" != Linux-x86_64 ]; then
        echo "Put Swift $SWIFT_VERSION on PATH: it is only downloaded on x86_64 Linux" >&2
        exit 1
    fi
    toolchain=swift-$SWIFT_VERSION-RELEASE-ubuntu24.04
    provide "https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/$toolchain.tar.gz" \
        "$TOOLCHAIN_SHA256" "$toolchain"
    PATH=$tools/$toolchain/usr/bin:$PATH
fi
swift --version 2>&1 | head -n 1

has_sdk() {
    swift sdk list --swift-sdks-path "$sdks" 2>/dev/null | grep -qx "$sdk"
}

install_sdk() {
    if has_sdk; then return; fi
    swift sdk install --swift-sdks-path "$sdks" --checksum "$WASM_SDK_SHA256" \
        "https://download.swift.org/swift-$SWIFT_VERSION-release/wasm-sdk/swift-$SWIFT_VERSION-RELEASE/${sdk}.artifactbundle.tar.gz"
}

if ! has_sdk; then
    locked install_sdk
fi
