#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$project_root/scripts/check-safety.py"
python3 "$project_root/scripts/check-publication.py"
bash "$project_root/scripts/swiftpm.sh" test
