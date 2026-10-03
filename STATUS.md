# Swipix status

Updated 2026-10-03 (Europe/Zurich).

## Implemented

- Native Xcode 27 project, Swift 6 concurrency checking, no dependencies, iOS 27 target.
- Authorization/onboarding, full and limited access, native limited picker, foreground and Photos-change reconciliation.
- Custom animated swipe card, keep/Bin decisions, buttons, VoiceOver actions, Reduce Motion, undo.
- Random photo order from a persistent session seed; per-asset SwiftData decisions and persisted cursor; unresolved decisions retained across access changes.
- PHCachingImageManager window of current + next five previews, plus an explicit bounded image cache; next-card readiness before dismissal, matching options and stale-request cancellation.
- Adaptive light/dark contrast, cards matching photo proportions without cropping, dimensions/megapixels and streamed local-resource sizes.
- Full-screen preview with pinch/double-tap zoom and native Live Photo playback control with pinch zoom.
- Bin multi-selection, restore, local dismissal of unavailable entries and confirmed PhotoKit deletion/error recovery.
- JPEG/HEIC compression to a separately confirmed copy; original untouched; original dimensions/orientation checked.
- ImageIO property/XMP copying and comparison; supported auxiliary-data copying, gain-map preservation request and verification.
- Temporary-file cleanup, serial encoding, 50 MP ceiling, bounded output thumbnail, quality persistence and result invalidation.
- Unit/integration/UI tests, synthetic fixtures, app icon and setup/architecture/limitations documentation.

## Validation

- Simulator Debug and unsigned iPhone Release builds pass with Swift 6 complete concurrency checking. No unresolved source warnings; Xcode emits the informational App Intents metadata warning for targets without App Intents.
- 22 tests passed on the dedicated iOS 27 QA simulator with dark appearance: 16 core/integration tests and 6 UI workflows. The random-order regression checks fetch-order independence, stable seed behavior, complete membership and different-seed variation. Disk recovery verifies the seed and review cursor survive reopening.
- UI workflows exercise review/undo/Bin restoration/relaunch, both app and Photos deletion cancellation, confirmed PhotoKit deletion, compression/save with the original retained, permission denial/recovery, limited access/native picker, full-screen pinch/double-tap zoom and return.
- Light appearance and the photo-shaped card were separately checked with the preview workflow and core suite; screenshots were visually inspected in both appearances. Final contrast refinements use explicit readable secondary text and white Keep-button text.
- 12 MP encoding is sampled for resident memory with a 256 MiB incremental ceiling; the recorded dark-run result was a 12 MiB increase, 451 MiB test-process peak and about 0.202 seconds encoding. The process peak includes the test runtime and fixture construction; it is not an isolated production-app memory measurement.
- Test evidence: `/tmp/SwipixFinalAppearance.xcresult` (final dark suite), `/tmp/SwipixLightPreview.xcresult` (light preview/core checks), `/tmp/SwipixFinalLight.xcresult` (final light contrast), `/tmp/SwipixLiveZoomFinal.xcresult` (preview check after Live Photo zoom integration). Build logs: `/tmp/swipix-final-appearance.log`, `/tmp/swipix-device-final.log`.
- QA library mutations use simulator fixtures and stock simulator assets only; no personal device library was changed.

## Platform limits and device checks before release

- PhotoKit deletion is not an immediate permanent erase: iOS controls Recently Deleted and iCloud synchronization. No background/automatic deletion.
- File metadata is compared before Photos import; import normalization, unknown/maker-note data, exact ICC bytes, auxiliary metadata and unsupported HDR features cannot be guaranteed.
- RAW/ProRAW derivatives, PNG/TIFF transcoding, animated/multi-image compression and Photos-edit rendering are intentionally unsupported, with visible errors/explanations.
- Current-photo size reads only locally available original resources; cloud-only size is explicitly unavailable. Initial previews and failed/offline downloads cannot be instantaneous. The current card remains visible while an upcoming successful preview is prepared.
- No accurate Bin storage estimate without reading resources; exact sizes are shown for locally available current-photo resources and during compression.
- iCloud-original download via PHAssetResourceManager.writeData has no cancellation token. Cancelled workflows wait for that native request to finish, then remove their temporary files. Encoding is serialized and UI stays responsive.
- Physical-device release validation remains (including real Live Photo playback and iCloud prefetch under offline/slow networks): permission denial/revocation and limited-set changes, iCloud/offline failures, Photos system deletion cancellation, multiple-device sync behavior, real Live Photo/HDR/RAW samples, and Instruments memory/gesture profiling at 12/48 MP and large library sizes. A paired personal iPhone is present, but no development team/provisioning is configured in this project; QA mutations are confined to synthetic simulator photos.
- No iOS-27-only core API. iOS 26 support requires deployment-target and device validation, not new architecture.
