"""Check all tracked content and reachable history without printing matched secrets."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
patterns = {
    "Photos local identifier": re.compile(rb"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}/L\d+/\d+"),
    "personal absolute path": re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "GitHub token": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    "AWS access key": re.compile(rb"(?:AKIA|ASIA)[A-Z0-9]{16}"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "OpenAI key": re.compile(rb"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}"),
}
allowed_roots = {"Sources", "Tests", "Resources", "scripts", ".github"}
allowed_top = {"Package.swift", "README.md", ".gitignore"}
private_parts = {".local-data", ".qa-data", ".build", "dist", "deliverables", "verification", ".env", "__pycache__"}

def allowed(path):
    parts = Path(path).parts
    if any(p in private_parts or p.endswith((".photoslibrary", ".app")) for p in parts):
        return False
    if len(parts) == 1:
        return path in allowed_top
    if parts[0] not in allowed_roots:
        return False
    if path.startswith("Resources/"):
        return path in {"Resources/AppIcon.icns", "Resources/OrganizerInfo.plist", "Resources/Travel/places.json", "Resources/Travel/ATTRIBUTION.txt"}
    if path.startswith(("Sources/", "Tests/")):
        return path.endswith(".swift")
    return path.endswith((".sh", ".py", ".yml", ".yaml"))

def git(*args):
    return subprocess.check_output(["git", *args], cwd=root)

violations = []
blobs = {}
if (root / ".git").exists():
    for path in git("ls-files", "-z").decode().split("\0"):
        if path:
            if not allowed(path):
                violations.append(f"unapproved tracked path: {path}")
            blobs[path] = (root / path).read_bytes()
            blobs[f"index:{path}"] = git("show", f":{path}")
    heads = git("rev-list", "--all").decode().splitlines()
    seen = set()
    for commit in heads:
        for entry in git("ls-tree", "-rz", "--full-tree", commit).split(b"\0"):
            if not entry:
                continue
            metadata, path_bytes = entry.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            path = path_bytes.decode()
            if kind != "blob" or mode not in {"100644", "100755"}:
                violations.append(f"unapproved object type: {path}")
            if not allowed(path):
                violations.append(f"unapproved historical path: {path}")
            if oid not in seen:
                blobs[f"history:{oid}:{path}"] = git("cat-file", "blob", oid)
                seen.add(oid)
        blobs[f"commit:{commit[:12]}"] = git("cat-file", "commit", commit)
else:
    for path in root.rglob("*"):
        if path.is_file() and allowed(str(path.relative_to(root))):
            blobs[str(path.relative_to(root))] = path.read_bytes()
for path, data in blobs.items():
    data = data.replace(b"\\/", b"/")
    for name, pattern in patterns.items():
        if pattern.search(data):
            violations.append(f"{path}: {name}")
if violations:
    print("Publication check FAILED:\n" + "\n".join(sorted(set(violations))), file=sys.stderr)
    sys.exit(1)
print(f"PASS: {len(blobs)} source/history objects checked; no unapproved paths or matching private identifiers/secrets.")
