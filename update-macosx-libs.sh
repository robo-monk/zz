# https://github.com/mitchellh/zig-build-macos-sdk/blob/main/update.sh

set -euo pipefail
set -x

sdk="$(xcrun --show-sdk-path)"
frameworks="$sdk/System/Library/Frameworks"
libs="$sdk/usr/lib"

dest="./libs/macosx"

cp -R $libs/swift $dest/swift
cp -R $frameworks/Foundation.framework $dest/Foundation.framework
