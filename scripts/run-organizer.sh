#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$project_root/dist/Photo Triage Organizer 0.4.0.app"
if [[ ! -x "$bundle/Contents/MacOS/PhotoTriageMac" ]]; then
    echo "Build first: bash scripts/build-organizer-app.sh release" >&2; exit 2
fi
if pgrep -f '/Contents/MacOS/PhotoTriageMac' > /dev/null; then
    echo "請先在目前的相片整理程式按 ⌘Q，避免多個實例同時使用整理資料。" >&2; exit 3
fi
open -F "$bundle" --args "$@"
