# zwtwm
ZigWindowsTilingWindowManager: Tiling window manager for windows, inspired by dwm.

## Using the prebuilt binaries
- `zwtwm.exe` is a release build.
- `zwtwm_debug.exe` is a debug build (makes is easier to see log output and more stuff gets logged).

## Building yourself
1. Clone the repository using `git clone --recurse-submodules https://github.com/Nimaoth/zwtwm.git`
2. Install zig.  I developed using zig version `0.8.0-dev.1140+9270aae07`, might not build with other versions.
3. For a release build (logs to file instead of console, ReleaseFast configuration), run `zig build --prefix dist -Drelease`
4. For a debug build (logs to the console, Debug configuration), run `zig build --prefix dist`
5. Use files in `<zwtwm-repository>/dist/bin`

## Configuration
Some settings/keybindings can be changed in config.json, which must be in the same folder as the zwtwm executable.

