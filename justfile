# Window Manager build recipes

build_dir := "build"
binary := build_dir / "agate"

cc := "clang"
cflags := "-g -O3 -Wall -Wextra -fobjc-arc"

frameworks := "-framework Foundation -framework AppKit -framework ApplicationServices -framework CoreGraphics -F /System/Library/PrivateFrameworks -framework SkyLight"

# Build the binary, linking against Lua provided by nixpkgs.
build:
    mkdir -p {{build_dir}}
    {{cc}} {{cflags}} {{frameworks}} \
        $(pkg-config --cflags lua) \
        -Isrc \
        -o {{binary}} \
        $(find src -name '*.c' -o -name '*.m') \
        $(pkg-config --libs lua)

# Build then run (e.g. `just run list`)
run *args: build
    ./{{binary}} {{args}}

# Build then run with debug logging (AGATE_DEBUG) enabled
debug *args: build
    AGATE_DEBUG=1 ./{{binary}} {{args}}

# Remove build artifacts
clean:
    rm -rf {{build_dir}}

# Generate the Lua type defs and the wiki reference (zig-out/Configuration.md)
docs:
    zig build docs

# Generate docs and push the configuration reference to the GitHub wiki
publish-docs: docs
    #!/usr/bin/env bash
    set -euo pipefail
    wiki_dir=$(mktemp -d)
    trap 'rm -rf "$wiki_dir"' EXIT
    git clone https://github.com/frostplexx/agate-wm.wiki.git "$wiki_dir"
    cp zig-out/Configuration.md "$wiki_dir/Configuration.md"
    cp zig-out/Debugging.md "$wiki_dir/Debugging.md"
    cd "$wiki_dir"
    git add Configuration.md Debugging.md
    if git diff --cached --quiet; then
        echo "Wiki already up to date."
    else
        git commit -m "Update wiki"
        git push
    fi
