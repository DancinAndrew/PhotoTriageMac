"""Keep this organizer's public PhotoKit boundary strictly read-only."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
forbidden = re.compile(
    r"\b(performChanges(?:AndWait)?|PHAssetChangeRequest|"
    r"PHAssetCollectionChangeRequest|PHCollectionListChangeRequest|"
    r"deleteAssets|deleteAssetCollections|removeAssets|"
    r"requestImageData(?:AndOrientation)?|requestAVAsset|"
    r"PHAssetResourceManager|sqlite3)\b|"
    r"Photos\.photoslibrary|isNetworkAccessAllowed\s*=\s*true"
)
violations = []
for path in sorted((root / "Sources").rglob("*.swift")):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if forbidden.search(line):
            violations.append(f"{path.relative_to(root)}:{number}")
if violations:
    print("Photos API safety check FAILED:\n" + "\n".join(violations), file=sys.stderr)
    sys.exit(1)
print("PASS: no Photos mutations, private-library APIs, originals fetching or network-enabled thumbnails.")
