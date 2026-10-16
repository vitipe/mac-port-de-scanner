#!/bin/bash
# Corre los tests. Con solo las Command Line Tools (sin Xcode), SwiftPM no encuentra
# solo el plugin de macros de Swift Testing, así que se le pasa la ruta.
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
    swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
    swift test "$@"
fi
