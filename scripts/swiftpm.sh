#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_root/.build/module-cache" "$project_root/.build/cache" "$project_root/.build/config" "$project_root/.build/security"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
cd "$project_root"
action="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
exec swift "$action" --scratch-path "$project_root/.build" --cache-path "$project_root/.build/cache" \
    --config-path "$project_root/.build/config" --security-path "$project_root/.build/security" \
    --disable-sandbox "$@"
