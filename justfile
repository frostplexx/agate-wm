# Window Manager build recipes

build_dir := "build"
binary := build_dir / "wm"

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

# Remove build artifacts
clean:
    rm -rf {{build_dir}}
