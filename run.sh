#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$ROOT/build/FinderHover.app" ]; then "$ROOT/build.sh"; fi
open "$ROOT/build/FinderHover.app" --args "$@"
