# PhotoTriageMac

A local macOS organizer for fast human review of an Apple Photos library. The native interface uses SwiftUI, AppKit and public PhotoKit APIs. The interface is in Traditional Chinese. It starts with 43 fictional illustrated items, so the workflow can be tried without Photos permission.

Current version: **0.5.1, build 11**. The bundle filename stays `Photo Triage Organizer 0.4.0.app` to preserve the existing local launch entry.

## Current features

- Thumbnail browsing, a stable photo grid, batch and range selection, and a details inspector.
- Suggested events from dates, time gaps and nearby coordinates. Missing dates and locations stay explicit; suggestions can be reassigned manually.
- Combined album, date, media, screenshot, review-status, unclassified, temporary-purpose and dense-capture filters. Each active filter has a removable chip.
- Local album creation, renaming, hiding and membership changes. Existing visible Photos albums can be browsed; edits are local overlays.
- Separate keep, completed-review, temporary-purpose and deletion-candidate decisions. Classification membership and review completion are displayed separately.
- Recent target albums, quick repeat classification, and an explicit “加入並完成這批” action. Only selected unreviewed items become completed; existing keep/delete decisions are preserved.
- Resume the last album, combined filters, selection, inspector and gallery position. Demo and real-library workspaces remain separate; progress comes from saved review decisions.
- Compare 2–6 selected photos side by side, zoom the local preview, explicitly choose keepers, and stage the others as deletion candidates. A comparison is one persisted, undoable review action; it never deletes assets.
- Native text undo/redo in album name fields, with photo-review history kept separate.
- Persisted undo. A combined album-and-review action is undone together, including after a restart. Interrupted saves recover through the organizer's own transaction journal.
- Optional local travel analysis and on-device music screenshot OCR. These produce suggestions and local reports for human review.

“Temporary”, “useless” and deletion candidates are human judgments. Dense capture is a review hint, not duplicate detection. This version does not implement Photos deletion or album writes. Local album membership does not remove an item from All Photos or any Photos album.

## Build and run

Requirements: macOS 14 or later, a Swift 6 toolchain (Xcode or Command Line Tools), Python 3 for the source checks, and standard macOS build/signing tools. There are no third-party Swift packages or paid services.

```sh
git clone https://github.com/DancinAndrew/PhotoTriageMac.git
cd PhotoTriageMac
bash scripts/verify.sh
bash scripts/build-organizer-app.sh release
bash scripts/run-organizer.sh
```

The build creates `dist/Photo Triage Organizer 0.4.0.app` with a local ad-hoc signature. It is not notarized or distributed through the App Store. The build archives a previous local bundle before replacing it. A new ad-hoc signature may reset Photos authorization; approve any new native Photos prompt yourself. The run script prevents a second organizer process from sharing the review files.

For an isolated demo profile:

```sh
bash scripts/run-organizer.sh --review-root "$PWD/.qa-data/demo"
```

Use the complete `.app` for real-library access and offline travel resources. `swift run` is not a substitute for the application bundle's Photos usage description. Building and testing do not request Photos permission or enumerate your library.

## Photos permission and local data

Choose the connect-to-Photos action to request Apple's native permission prompt. On later launches, the last Photos profile resumes only if permission is already available; automatic resume never requests permission. Approve it yourself if you want library access. Denied or restricted access shows a clear state and the fictional demo remains available. Limited access displays only the assets PhotoKit exposes; counts do not represent inaccessible items. Access can be reviewed in System Settings → Privacy & Security → Photos.

PhotoKit uses its read/write authorization category for metadata reads; this application's source contains no Photos mutation APIs. Metadata, existing album references and small locally available thumbnails are read through public APIs. Network access for thumbnail and comparison requests is disabled. Comparison previews request at most 2048 × 2048 pixels; they are not original-resource requests. Low-resolution, iCloud-only, unavailable and failed previews are labeled explicitly. An iCloud-only or unavailable preview remains a placeholder; the app does not force original downloads.

Review decisions, local albums, recent destinations and workspace positions are saved separately in `~/Library/Application Support/PhotoTriageMac/`. Demo and real-library profiles use separate JSON files. Saves use private file permissions and atomic replacement. Unreadable, incompatible or externally changed data blocks writes instead of being overwritten. Missing asset references remain available for reconciliation. Use one running instance per profile.

These local files and optional analysis/export reports can contain Photos identifiers and personal metadata. Keep them private. The repository contains code, fictional fixtures, an original icon and public offline geography only. It contains no personal photos, Photos identifiers, song inventories, travel receipts or review databases. No library package is opened or copied, and no photo or metadata is uploaded by the app.

## Keyboard workflow

| Key | Action |
| --- | --- |
| ⌘A | Select the currently filtered items |
| C | Compare 2–6 selected images |
| 1–6 / Esc | Toggle explicit keepers in comparison / return or cancel |
| ⌘N | Create a local album |
| K / O | Keep / mark review completed |
| T / D / U | Toggle temporary / stage deletion candidate / restore unreviewed |
| A | Choose a target local album |
| ⇧A | Reuse the most recent valid target album |
| ⌘⇧A | Add to the recent target and complete selected unreviewed items |
| ⌘Z | Undo text when editing; otherwise undo the last local organizer action |
| ⌘⇧Z | Redo text while editing |
| ← / → / I | Previous / next / toggle photo details |

When no recent valid album exists, the complete-batch action opens the chooser. “只加入相簿” preserves review status; “加入並完成這批” is explicit. Editing text or using a modal prevents photo-review shortcuts from acting on the grid.

## Tests and limits

`bash scripts/verify.sh` runs read-only Photos API checks, publication-content checks and the Swift test suite. Tests use fictional data and temporary profiles. Coverage includes combined filters, recent targets, repeated actions, mixed review states, paired undo after restart, interrupted saves, stale writes, empty data, denied access, missing metadata and native view rendering offscreen. CI also builds and verifies the macOS app signature.

The full suite includes 117 tests. The physical Mac release also passed isolated actual-app UI checks for batch selection, comparison, numeric keeper/Escape bindings, zoom, native menu commands, album actions, denied/empty states, and restart positions at 310 and 1300 points. The original release checks use the app's own offscreen window/event queue and fictional profiles. Version 0.5.1 additionally passed 27 native foreground checks using macOS CGEvent input and accessibility observations, including copy/cut/paste, text undo/redo, comparison keepers, zoom, cancellation, atomic photo undo and repeated operations. Original clipboard types and bytes were restored. These foreground checks used fictional isolated profiles; they do not establish real-library authorization or preview availability on another Mac. The hosted Intel CI VM skips one GPU-dependent grid scroll/resize geometry test because its Metal driver has no usable target architecture. The other native offscreen view tests still run. Run the full suite on a physical Mac to verify that geometry test; it passes on the locally tested Apple Silicon Mac.

Optional actual-app UI verification (after building; use a fresh fictional profile):

```sh
mkdir -p "$PWD/.qa-data/ui-evidence"
bundle="$PWD/dist/Photo Triage Organizer 0.4.0.app/Contents/MacOS/PhotoTriageMac"
"$bundle" --review-root "$PWD/.qa-data/ui-profile" --ui-qa "$PWD/.qa-data/ui-evidence/first.json"
"$bundle" --review-root "$PWD/.qa-data/ui-profile" --ui-qa "$PWD/.qa-data/ui-evidence/resume.json" --ui-qa-resume
```

This mode rejects a Photos profile, never connects Photos, stays offscreen, and exits nonzero for a failed check. Reports distinguish passed, failed and not-tested cases. It does not replace a foreground keyboard or real-library permission check.

Event and travel suggestions are approximate and should be reviewed. No background synchronization, automatic deletion, pixel-level duplicate detection, original-resource fetching or video playback is implemented. Comparing and zooming do not assess quality automatically. Review completion, classification membership and deletion-candidate flags remain separate; a pure album addition or staged album plan preserves every review status. General Photos album writes or deletions would require a separately reviewed implementation and explicit user confirmation. Historical task-specific mutation jobs are intentionally absent from this public source.

## Attribution and licensing

Offline geography is adapted from the public-domain Natural Earth dataset; see [its attribution](Resources/Travel/ATTRIBUTION.txt). All other source is provided without an open-source license grant. Public visibility does not grant reuse rights beyond GitHub's applicable terms.
