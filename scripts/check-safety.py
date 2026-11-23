"""Keep this organizer's public PhotoKit boundary read-only.

The only reviewed exception is network access for the single user-opened video player request.
"""
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
    r"Photos\.photoslibrary"
)
violations = []
# Reviewed exception: this exact helper is used only by the user-opened, single-video player request.
# Other network assignments must remain literal false; variables cannot bypass the guard.
video_preview = root / "Sources/PhotoTriageApp/VideoPreview.swift"
reviewed_video_options = (
    "    static func options(progressHandler: PHAssetVideoProgressHandler? = nil) -> PHVideoRequestOptions {\n"
    "        let options = PHVideoRequestOptions()\n"
    "        options.version = .current\n"
    "        options.deliveryMode = .automatic\n"
    "        options.isNetworkAccessAllowed = true\n"
    "        options.progressHandler = progressHandler\n"
    "        return options\n"
    "    }"
)
video_source = video_preview.read_text()
allowed_network_line = None
if video_source.count(reviewed_video_options) != 1:
    violations.append("The single user-opened video options helper differs from the reviewed current/automatic/progress options.")
else:
    start = video_source.index(reviewed_video_options)
    prefix = reviewed_video_options[:reviewed_video_options.index("options.isNetworkAccessAllowed = true")]
    allowed_network_line = video_source[:start].count("\n") + prefix.count("\n") + 1
network_assignment = re.compile(r"\bisNetworkAccessAllowed\s*=")
network_disabled = re.compile(r"\bisNetworkAccessAllowed\s*=\s*false\b")
for path in sorted((root / "Sources").rglob("*.swift")):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if network_assignment.search(line) and not network_disabled.search(line) \
                and not (path == video_preview and number == allowed_network_line):
            violations.append(f"{path.relative_to(root)}:{number}: network access outside the user-opened video helper")
        if forbidden.search(line):
            violations.append(f"{path.relative_to(root)}:{number}")
if violations:
    print("Photos API safety check FAILED:\n" + "\n".join(violations), file=sys.stderr)
    sys.exit(1)
print("PASS: no Photos mutations, private-library APIs or originals fetching; only the reviewed user-opened video helper may enable network.")
