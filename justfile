# Window Manager build recipes

build_dir := "build"
binary := build_dir / "wm"

cc := "clang"
cflags := "-g -O0 -Wall -Wextra -fobjc-arc"

# Public + private frameworks. SkyLight / WindowManagement live in
# PrivateFrameworks; the -F path makes the bridged symbols in src/extern link.
frameworks := "-framework Foundation -framework AppKit -framework ApplicationServices -framework CoreGraphics -F /System/Library/PrivateFrameworks -framework SkyLight"

# Build the binary, auto-collecting every .c and .m under src/.
build:
    mkdir -p {{build_dir}}
    {{cc}} {{cflags}} {{frameworks}} -Isrc -o {{binary}} $(find src -name '*.c' -o -name '*.m')

# Build then run (e.g. `just run list`)
run *args: build
    ./{{binary}} {{args}}

# Remove build artifacts
clean:
    rm -rf {{build_dir}}
