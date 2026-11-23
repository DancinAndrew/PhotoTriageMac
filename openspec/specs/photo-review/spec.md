# Local Photos review requirements

## Read-only data boundary

The application SHALL use native PhotoKit authorization and public metadata/thumbnail APIs. It SHALL NOT mutate Photos, use private library databases or packages, upload photos, or export original-image/video resources. Thumbnail requests SHALL disable network access. App startup SHALL use fictional demo data without requesting authorization.

Acceptance: denied access remains understandable and demo remains usable. Native authorization is user-controlled. Cloud-only thumbnail failures show placeholders. A static source safety guard excludes mutation/original-resource APIs.

## Fast human review

The application SHALL provide thumbnail browsing, batch/range selection, keep and organized states, temporary-purpose flags, album plans, event reassignment, a deletion-candidate queue, keyboard controls and persisted batch undo. Real deletion SHALL NOT be implemented in this MVP. Queue staging SHALL require an explanatory checkbox confirmation.

Acceptance: repeated status/album actions are idempotent; undo restores mixed prior decisions; undo survives a relaunch. Filters include screenshots, videos/photos, dates, unknown date, unreviewed, unclassified and visible user album membership. Empty states do not crash.

## Suggestions and missing metadata

The application SHALL suggest events from the local calendar day, a three-hour adjacent gap and two-kilometer adjacent distance. It SHALL state unknown dates/locations. Location unknown SHALL NOT inherit a known location. Dense capture SHALL be presented as a review hint, not duplicate or garbage detection.

Acceptance: suggestions cover each visible asset once, stable manual destinations adopt all existing members without duplicate group IDs, and full reassignment is undoable. Dense capture excludes screenshots and videos and respects missing/far location.

## Review persistence

The application SHALL store its decisions separately from Photos, with separate demo/live documents, private file permissions, atomic replacement and at most 100 undo transactions. Failed/corrupt/future-version documents SHALL be preserved and changes blocked. Unavailable photo decisions SHALL survive refresh and be explicit in exports.

Acceptance: round-trip and relaunch undo work; failed replacement preserves the previous target; export includes manual event names and unavailable identifiers, with no image bytes.


## User-opened video playback (0.5.4)

A user's explicit Open Video, double-click or Space action SHALL prepare only that visible asset through PhotoKit requestPlayerItem with current/automatic options. This single playback request MAY allow network to obtain necessary iCloud data without a separate download button. Merely selecting, hovering, filtering or browsing the grid SHALL NOT start video network requests. Thumbnails and other image reads SHALL remain network-disabled.

The preview SHALL show actual finite progress when supplied, allow cancellation/close/switch, reject stale callbacks, and continue muted playback only while the same preview and playback intent remain active. Pause or losing app focus SHALL clear pending autoplay intent. The app SHALL distinguish permission, connection, missing/unavailable resources, unsupported decoding, library availability and stalled preparation using documented errors; it SHALL NOT infer deletion or codec failure from a nil result alone. A slow-load notice SHALL not itself cancel a request that is making progress.

Acceptance: isolated sample auto-play/time advancement/seek/release and injected progress/error/cancel/switch cases pass; static safety tests reject network enabling outside the reviewed options helper. Real local Photos and iCloud playback SHALL be reported separately from fixtures. A user authorization prompt SHALL be handled by the human, not approved or bypassed by the app or test agent. No guarantee of zero transfer, zero cache or immediate streaming is made.

## Display and review simplification (0.5.5)

The app SHALL provide small/medium/large thumbnails and persist the chosen size. Information-panel enabling SHALL be user-controlled and saved independently of current selection; the panel SHALL only mount when enabled with a selected focused asset. Selection, select-all, navigation, reset filters and batch review SHALL NOT force the panel open. Intentional reflow SHALL preserve selected IDs and the visible asset anchor in normal and minimum-width windows.

K/T/D SHALL each derive reviewed status without rewriting existing decisions on read. Legacy O-only records SHALL preserve raw values, timestamps and undo history; no new O UI action SHALL exist. U SHALL clear status and temporary purpose in one undoable transaction, preserving albums/groups/plans. Compound add-and-keep SHALL assign K only to currently undecided items and preserve existing K/T/D/O. The review picker SHALL consolidate temporary-purpose filtering, retain album classification as a separate dimension and expose old filter intersections without duplicate chip identities.

Acceptance: isolated unit/native fixture tests cover each size and restart, scroll/selection, minimum width, inspector closed selection, K/T/D/O compatibility, U and undo, combined filters/reset and video playback/cancel regression. Source and user data hashes SHALL be retained; real Photos and human operation SHALL be reported separately. Install SHALL back up the previous app and swap the bundle without truncating or forcibly quitting the running user app.
