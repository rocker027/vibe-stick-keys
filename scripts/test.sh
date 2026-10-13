#!/bin/sh
# 執行 swift test。只裝 Command Line Tools 時，Testing.framework 不在預設搜尋路徑，需補 -F 與 rpath；用 Xcode 時直接執行。
set -eu
FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
  exec swift test -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
fi
exec swift test "$@"
