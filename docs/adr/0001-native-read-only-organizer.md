# ADR 0001: Native, local and read-only first

Status: accepted for MVP.

The user accepted organizing through a Mac interface and authorized app creation, not real Photos library mutations. A browser upload UI cannot enumerate the existing Apple Photos library. Use the installed Swift toolchain, SwiftUI/AppKit and public PhotoKit APIs; Swift is appropriate here despite the personal Python-first default. No additional dependency or runtime service is introduced.

Separate a pure Swift `PhotoTriageCore` from the native app. PhotoKit supplies metadata, user album membership and small local thumbnails after native authorization. `PHImageRequestOptions.isNetworkAccessAllowed` stays false. Original-image, video-file, private-library and mutation APIs are excluded and checked by `scripts/check-safety.py`.

Human review decisions are a separate JSON document with batch transactions, a 100-operation persisted undo history, and separate demo/live files. Save a private temporary file, then atomically rename it. A failed load blocks changes rather than replacing an unreadable file. Missing asset IDs stay in the document.

All album operations and deletion choices are staged. A confirmation view for adding deletion candidates clarifies its local-only effect. There is no activation path for real album writes or deletion in this version. A later implementation requires separately reviewed scope and explicit human confirmation.

The app starts in fictional demo mode, never requests Photos authorization at startup, and only requests native authorization from the user's connect action. PhotoKit's read/write authorization is necessary for metadata reads; application behavior remains read-only.

Tradeoffs: metadata is loaded in a background task; thumbnails and sidebar rows are lazy. No reverse geocoding, pixel duplicate detection, video playback, original fetching, background synchronization or automatic garbage classification. Multiple running instances sharing one review file are outside this MVP; run one instance per review directory.

## 2026-10-12: User-opened video playback exception (0.5.4)

The user explicitly authorized direct playback of the selected Photos video without a separate download action. A single active preview may request its current edited representation through `requestPlayerItem` with `PHVideoRequestOptions.current/automatic`, network enabled and progress/cancellation callbacks. When the app remains active and playback intent has not been cancelled, readiness continues muted playback. PhotoKit may transfer and cache data; zero download or cache size is not guaranteed.

This exception supersedes the MVP's video-playback restriction only for a user-opened video. Thumbnail, comparison, OCR and travel reads remain network-disabled. No video export, original-resource API, whole-library prefetch, private path, Photos mutation, privacy-setting change or media upload is introduced. The source safety guard permits only the exact reviewed video-options helper and rejects other non-false network assignments. Review, album, workspace and undo persistence remain independent and unchanged.

## 2026-10-13: Display preferences and derived review state (0.5.5)

ReviewDecision.hasBeenReviewed is derived from K/D/legacy O or the persisted temporary flag T. Existing documents and O-only history are not migrated or reclassified. The UI removes the O operation; an explicit add-and-keep compound action assigns K only to undecided items. U clears status and T together, preserving membership/group/plans and transaction undo.

An optional reviewedOnly filter field preserves decoding of old workspace files. One review/decision picker replaces the duplicated temporary control; old custom intersections remain visible as removable chips. Album classification stays independent. Display preferences are stored separately with version validation, optimistic concurrency, private atomic replacement and corrupt-file preservation. Inspector enabling is independent of selection. The grid only mounts the inspector for an enabled selected focus and preserves an asset anchor during size/panel reflow. No new dependency, permission, network scope or Photos mutation was introduced.
