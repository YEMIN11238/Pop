#!/bin/zsh
# @raycast.schemaVersion 1
# @raycast.title Pop 剪贴板 OCR
# @raycast.mode silent
# @raycast.packageName Pop
# @raycast.icon icon.png
# @raycast.description 通过本地 com.local.pop request 提交请求，结果显示于 Pop。
set -eu
SCRIPT_DIRECTORY="${0:A:h}"
exec /usr/bin/osascript -l JavaScript "$SCRIPT_DIRECTORY/request.js" pasteboardOCR
