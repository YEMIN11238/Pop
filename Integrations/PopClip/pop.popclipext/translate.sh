#!/bin/zsh
set -eu
SCRIPT_DIRECTORY="${0:A:h}"
exec /usr/bin/osascript -l JavaScript "$SCRIPT_DIRECTORY/request.js" translateText "${POPCLIP_TEXT:-}"
