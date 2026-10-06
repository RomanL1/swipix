# Swipix status

Updated 2026-10-04 (Europe/Zurich).

## Implemented

- Native Xcode 27 project, Swift 6 concurrency checking, no dependencies, iOS 27 target.
- Authorization/onboarding, full and limited access, native limited picker, foreground and Photos-change reconciliation.
- Custom animated swipe card, keep/Bin decisions, buttons, VoiceOver actions, Reduce Motion, undo.
- Random photo order from a persistent session seed; per-asset SwiftData decisions and persisted cursor; unresolved decisions retained across access changes.
- PHCachingImageManager window of current + next five previews, plus an explicit bounded image cache; two cards rendered beneath the current card, immediate dismissal without waiting for the next iCloud preview, matching options and stale-request cancellation. Shared original-resource downloads for the same six-photo window; successful byte counts cached, removed/edited assets invalidated, unchanged caches retained across refreshes.
- Native bottom tabs, system colors/fonts and Liquid Glass action buttons: blue primary, grey secondary, green Keep, purple Compress, red Bin, grey Preview; compact circular Info/Undo/X controls and top-right Bin swipe indicator.
- Photos-style metadata sheet with automatic iCloud original-file reads and download retry, available camera/exposure/profile/caption/GPS fields and clear original-vs-Photos distinctions.
- System light/dark appearance, cards matching photo proportions without cropping, dimensions/megapixels and streamed original-resource sizes, including automatic iCloud downloads.
- Full-screen preview with pinch/double-tap zoom and native Live Photo playback control with pinch zoom.
- Bin multi-selection, restore, local dismissal of unavailable entries and confirmed PhotoKit deletion/error recovery.
- Two-tap compression: open popup, then choose High (80%, full resolution), Medium (40%, full resolution, default) or Low (60%, two-thirds dimensions). Last preset/format persist; HEIC defaults when supported, JPEG available.
- Automatic replacement-style saving: compressed asset marked Keep and original moved into the in-app Bin after successful Photos save; original remains recoverable. Bin retry after a persistence failure avoids duplicate copies.
- One-time Live Photo warning with OK plus persistent yellow warning triangles for motion/audio and metadata loss. Nonmodal success notice opens size/metadata details.
- Original dimensions/orientation checked for High/Medium; Low dimensions and EXIF dimension tags verified, intentional resize reported separately.
- ImageIO property/XMP copying and comparison; supported auxiliary-data copying, gain-map preservation request and verification.
- Temporary-file cleanup, serial encoding, 50 MP ceiling, bounded Low resize, preset/format persistence and failure recovery.
- Unit/integration/UI tests, synthetic fixtures, app icon and setup/architecture/limitations documentation.

## Validation

- Light-mode fullscreen/stack/original-size and information-sheet workflows also passed in `/tmp/SwipixStackLight.xcresult`; inspected screenshots show black action text on white and no toolbar button capsule.
- The earlier background-free action/photo-stack revision passed all 31 simulator tests in dark mode in `/tmp/SwipixStackDark.xcresult`, including original-size display, fullscreen zoom, metadata, compression, Bin workflows and permissions. Unsigned iPhone Release build passed (`/tmp/swipix-stack-device.log`). Dark-mode screenshots confirm white action text, no Done capsule and visible underlying photos.

- Simulator Debug and unsigned iPhone Release builds pass with Swift 6 complete concurrency checking. No unresolved source warnings; only Xcode's informational App Intents metadata message remains.
- The dark-mode suite passed all 31 tests (24 core/integration tests + 7 UI workflows) in `/tmp/SwipixReplacementUI.xcresult`. Earlier light-mode navigation/preview workflows also passed in `/tmp/SwipixNativeUI2.xcresult`. Screenshots of native review controls and info sheets were inspected in both appearances.
- The final light-mode compression run plus all 24 core tests passed in `/tmp/SwipixCompressionFinal.xcresult`; it verifies automatic saving, original Bin restoration after relaunch, persistent preset and warning acknowledgement.
- The corrected completion-notice layout and readable format labels passed the final light-mode UI workflow in `/tmp/SwipixCompressionLayoutFinal.xcresult`; popup, notice and report screenshots were inspected.
- Metadata tests verify camera/exposure/GPS formatting, absent fields, reading JPEG metadata/file size without changing the original, and malformed exposure values. The final parser guard was rechecked with the complete core suite in `/tmp/SwipixMetadataRobust.xcresult`.
- UI coverage includes native tab navigation, the information sheet, full-screen pinch/double-tap zoom, review/undo/Bin restoration/relaunch, app and Photos deletion cancellation, confirmed deletion, automatic compression replacement, Bin restoration after relaunch, saved preset and one-time warning, permission denial/recovery and limited access/native picker.
- Random-order tests check fetch-order independence, stable seed behavior, complete membership and different-seed variation. Disk recovery verifies the seed and review cursor survive reopening.
- The 12 MP encoding test samples resident memory with a 256 MiB incremental ceiling. The native dark-run measurement was a 12 MiB increase, 396 MiB test-process peak and about 0.215 seconds encoding. The peak includes the test runtime and fixture construction; it is not an isolated production-app memory measurement.
- Final logs: `/tmp/swipix-replacement-ui.log`, `/tmp/swipix-compression-final.log`, `/tmp/swipix-compression-layout-final.log`, `/tmp/swipix-compression-device-final2.log`.
- The configured development team and bundle identifier are preserved. QA library mutations use simulator fixtures and stock simulator assets only; no personal device library was changed.

## Liquid Glass button update — 4 October 2026

- Replaced the earlier background-free action style with native SwiftUI glass/glassProminent buttons and minimum 44-point hit targets. Primary actions are blue; secondary actions are grey. Review buttons use green Keep, purple Compress, red Bin and grey Preview. Sheet/full-screen dismiss controls display an X.
- Simulator Debug build passed in `/tmp/swipix-glass-build.log`. Both targeted UI tests (photo information/native actions and fullscreen zoom/return) passed with zero failures in `/tmp/swipix-glass-tests.xcresult`. Exported Review and Photo Information screenshots were visually inspected for colors, visible button surfaces and circular X dismissal.

## Swipe responsiveness update — 4 October 2026

- Review mutations and cursor saves use a SwiftData context confined to an actor with an explicit background serial Dispatch executor. Decisions save the next cursor in the same transaction; UI publication follows successful saves. Queued writes remain durable when a view task is cancelled. Debug assertions check that context creation and writes run off the main thread.
- Library fetch/index construction, deterministic ordering and remaining-photo filtering run in background tasks. UI uses a cached remaining count and only builds a six-photo window; Bin IDs are cached instead of sorting all review records during rendering.
- PhotoKit cache changes run on a background serial queue and retain overlapping assets. Preview request setup and image preparation run off the main actor; original-size requests use concurrent work at utility priority. Swipe animations start immediately, without awaiting the next iCloud preview.
- Final simulator build and 29 selected tests passed (26 core/integration plus 3 UI workflows), zero failures, in `/tmp/swipix-concurrency-verified.xcresult`; log: `/tmp/swipix-concurrency-verified.log`. Runtime assertions verified off-main context creation and writes. New coverage checks atomic decision/cursor saves, concurrent/cancelled-write durability, stale-cursor protection, three successive drag swipes, Undo, information-sheet interaction and Bin restoration. Existing Bin/relaunch/cancel-deletion and compression replacement workflows also passed.
- These checks verify threading and workflow behavior on the dedicated QA simulator; physical-device frame-time profiling with a large/iCloud library remains unmeasured.

## Platform limits and device checks before release

- PhotoKit deletion is not an immediate permanent erase: iOS controls Recently Deleted and iCloud synchronization. No background/automatic deletion.
- File metadata is compared before Photos import; import normalization, unknown/maker-note data, exact ICC bytes, auxiliary metadata and unsupported HDR features cannot be guaranteed.
- RAW/ProRAW derivatives, PNG/TIFF transcoding, animated/multi-image compression and Photos-edit rendering are intentionally unsupported, with visible errors/explanations.
- Current-photo size downloads cloud originals automatically; offline failures remain visible with a retry action. Initial previews and failed/offline downloads cannot be instantaneous. Swipes do not wait for an upcoming preview; a cloud-only next photo can show a placeholder until its preview arrives.
- No accurate Bin storage estimate without reading resources; exact sizes are shown for successfully downloaded current-photo resources and during compression.
- iCloud-original download via PHAssetResourceManager.writeData has no cancellation token. Cancelled workflows wait for that native request to finish, then remove their temporary files. Encoding is serialized and UI stays responsive.
- Physical-device release validation remains (including real Live Photo playback and iCloud prefetch under offline/slow networks): permission denial/revocation and limited-set changes, iCloud/offline failures, Photos system deletion cancellation, multiple-device sync behavior, real Live Photo/HDR/RAW samples, and Instruments memory/gesture profiling at 12/48 MP and large library sizes. The project’s configured development team and bundle identifier are preserved; physical-device provisioning/run validation is outside these unsigned builds, and QA mutations are confined to synthetic simulator photos.
- No iOS-27-only core API. iOS 26 support requires deployment-target and device validation, not new architecture.
