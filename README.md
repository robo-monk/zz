# ZZ


## Building for MacOS
First we need to copy macos native libraries for the build script to work. Used
[@mitchellh](https://github.com/mitchellh/zig-build-macos-sdk/tree/main) solution used to compile ghostty.

```sh
sh update-macosx-sdks.sh
zig build -Doptimize=ReleaseFast
```
