#!/bin/zsh
set -eu
SCRIPT_DIRECTORY="${0:A:h}"
exec /usr/bin/osascript -l JavaScript "$SCRIPT_DIRECTORY/request.js" "${1:-translateText}" "${2:-}"
