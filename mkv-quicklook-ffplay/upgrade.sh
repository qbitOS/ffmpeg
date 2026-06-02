#!/bin/zsh
set -euo pipefail
exec "$(dirname "$0")/bin/mkvql" upgrade "$@"
