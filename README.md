# Swipix

A native, on-device iPhone photo reviewer built with Swift 6, SwiftUI, PhotoKit, SwiftData and ImageIO. No third-party dependencies or network services.

## Build and run

- Xcode **27.0 (27A266a)**, iOS **27.0** deployment target; an iPhone simulator or device.
- Open `Swipix.xcodeproj`, select the **Swipix** scheme and an iPhone, then Run.
- For a physical device, select your development team in Signing & Capabilities and set a unique bundle identifier if needed. Signing credentials are not included.
- Run core tests on any iOS 27 simulator:

```sh
xcodebuild -project Swipix.xcodeproj -scheme Swipix \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:SwipixTests test
```

UI tests require a **dedicated, empty simulator** with synthetic images and Photos permission. They must not run against your personal library. See `Scripts/seed-simulator.sh`; pass the simulator UUID explicitly. The tests restore their Bin decisions after the workflow and save a new synthetic compressed copy. Repeated UI runs therefore add copies to that QA library.

```sh
Scripts/seed-simulator.sh YOUR_QA_SIMULATOR_UUID
xcodebuild -project Swipix.xcodeproj -scheme Swipix \
  -destination 'platform=iOS Simulator,id=YOUR_QA_SIMULATOR_UUID' \
  -parallel-testing-enabled NO test
```

## Review and Bin

- Drag the main card continuously: right keeps, left moves to the app Bin. A 100-point horizontal drag commits a decision; smaller gestures spring back. Buttons and VoiceOver actions provide the same behavior. Reduce Motion removes rotation and animated dismissal.
- Photos are presented in a random order generated from a persisted session seed. The order stays consistent across relaunches and fetch-order changes; newly accessible photos enter that random order. The saved current photo takes priority.
- Native bottom tabs separate Review, Bin and Settings. The app uses system colors, San Francisco text styles and native Liquid Glass buttons with 44-point hit targets. Primary actions are iOS blue and secondary actions are grey; Review uses green Keep, purple Compress, red Bin and grey Preview buttons. Sheets and full-screen preview use circular X dismiss buttons. The Bin swipe indicator appears in the top-right corner; Keep remains top-left.
- An Info button on Review and full-screen preview, plus the Bin photo menu, opens a native photo-information sheet. It shows filename, capture date, dimensions, resolution, format, file size, available camera/lens/exposure tags, color profile, caption/attribution and location. Original EXIF is distinguished from dates/location in Photos. No missing metadata is inferred. Original metadata is downloaded automatically when needed without decoding pixels; failed downloads have a retry action. Coordinates stay local and no map/address lookup is requested.
- The full-screen button opens a pinch/double-tap zoom preview. Live Photos also offer a Play Live Photo control with pinch zoom during playback. Cards fit the entire photo without cropping or an inset border, and colors adapt to light/dark appearance.
- Current-photo details show dimensions, megapixels and the original-resource byte size (including paired video for Live Photos). Original resources for the current photo and next five are streamed automatically from iCloud to count bytes without retaining their data. A failed download shows a connection message and Retry download action.
- SwiftData saves each decision and next-photo cursor together on a background serial executor before advancing. An identifier can only receive one review decision until restored. Undo returns to the last decided asset during the current launch.
- The Bin supports multi-selection, select all, restore, and per-row restore actions. Restoring clears the local decision and makes the asset reviewable again.
- Deletion is available **only** from the Bin, with an explicit app confirmation immediately before the PhotoKit transaction. PhotoKit then applies its own authorization/confirmation rules. Selection is re-resolved before submission; if any selected asset is inaccessible the entire request is rejected before a mutation. Errors stay visible and local decisions remain unless the transaction succeeds.
- Successful deletion is checked against the accessible library before clearing local entries. If Photos still reports selected items, the Bin remains for investigation. If local persistence fails after a successful Photos deletion, the app explicitly explains that distinction.
- The app Bin is **not** Apple's Recently Deleted album. A confirmed PhotoKit request deletes from the Photos library (and may sync through iCloud); iOS may retain items in Recently Deleted according to system behavior. Third-party apps cannot promise immediate permanent erasure or bypass that album. Freed space is not guaranteed immediately.
- No misleading storage total is displayed: public PhotoKit APIs do not provide a reliable byte size for every original resource without reading it. Compression review shows exact downloaded-input and encoded-output byte sizes.

## Permissions, limited access and privacy

The read/write Photos permission is used to fetch chosen images, save compressed replacements, and request confirmed deletion. The generated Info.plist includes clear read/write and add usage descriptions. Access is requested only when onboarding's button is pressed.

Full and limited access work with the same flow. A native limited-library picker lets you choose more images from Review, Bin and Settings. Authorization is rechecked on foregrounding and library changes; denial/revocation returns to the permission screen and clears accessible assets/previews. Settings provides a link to iOS Settings. No placeholder library is presented as real Photos content.

Only asset identifiers, choices, dates, the random-order seed and the review cursor are stored in SwiftData; the compression preset, output format and first-use warning acknowledgement are persisted with AppStorage. Decisions for unresolved identifiers are retained because PhotoKit cannot reliably distinguish a removed asset from one hidden by a narrower limited selection. Inaccessible Bin entries are excluded from destructive actions, explained in the UI, and can be dismissed locally. Regranting access makes retained decisions available again. Externally edited assets refresh through `PHPhotoLibraryChangeObserver` and previews are invalidated. The active cursor is resolved against the current library, falling back safely when missing.

No analytics, uploads, backend, remote models, or custom network calls. PhotoKit may download iCloud previews/originals on demand. Temporary original and compressed files stay in the app sandbox and are removed after review closes or fails. Synthetic fixtures contain only invented metadata. The app contains no future intelligence feature or automatic deletion.

## Architecture

| File | Responsibility |
| --- | --- |
| `AppModel.swift` | App startup, review coordination, mutation/error state |
| `PhotoLibraryService.swift` | Authorization, change observation, asset lookup, preview caching and cancellation, PhotoKit transactions and resource export |
| `ReviewState.swift` | Pure review transitions, per-asset SwiftData records, persisted cursor and undo |
| `ImageCompressionService.swift` | Serial ImageIO encoding, format checks, dimensions/orientation checks, metadata comparison |
| `Views.swift` | Onboarding, custom swipe card, Bin, limited picker and Settings |
| `PhotoInfoView.swift` | Original-file metadata extraction and native information sheet |
| `FullscreenPreview.swift` | Zoomable full-screen still preview and native Live Photo playback |
| `CompressionView.swift` | Preset popup, automatic save/Bin workflow, result report and temporary-file lifecycle |

Observable UI state stays on the main actor. Review writes use an actor with an explicit background serial executor and its own SwiftData context; only value data returns to the UI. Startup reads the saved review snapshot once. Writes and their UI publication are serialized, and each decision saves its next-photo cursor in the same transaction. Library enumeration, stable shuffling and remaining-photo filtering run off the main thread, while screen rendering uses a cached count and a bounded six-photo window. PhotoKit cache operations use a background serial queue, original-size requests run concurrently at utility priority, and preview images are asynchronously prepared for display before entering the UI cache. Encoding runs in a separate actor. PhotoKit callbacks bridge async operations; image request cancellation uses a lock to handle callback/request-ID races and resume continuations exactly once. Swift 6 language mode and complete concurrency checking are enabled. PhotoKit mutations are concentrated in the service; pure decisions and metadata comparisons are tested without a Photos library. There are no speculative service factories or third-party abstractions.

## Caching and memory

`PHCachingImageManager` caches the active asset plus up to five upcoming assets at screen-size/scale-derived preview dimensions (capped to a 1600-pixel long edge). Requests and prefetches use matching options and `aspectFit`, keeping the complete image visible. The service also explicitly requests and retains those six bounded previews so each next card can start with its image already available. A swipe starts its animation immediately and never waits for the next iCloud preview; a pending next photo can show a placeholder while its preview downloads. The initial preview or a failed/offline download cannot be made instantaneous; failures have a retry action. The next two cards are rendered beneath the active card, so dragging reveals the next photo immediately. Cache windows follow the current asset; a swipe stops caching only the departing asset and starts caching only the newly entering asset. Unchanged photos retain warmed images and shared size downloads across library refreshes, while removed/edited assets are invalidated. Display-size changes rebuild only preview caches. The deprecated `allowsCachingHighQualityImages` property is deliberately unused.

Swipe image previews never decode original image data. The separate size read streams iCloud original-resource chunks only to count bytes. Downloads and successful size strings are shared across the six-photo window; requests outside that window cancel and chunks are discarded. Photos manages its own downloaded resource cache; the app does not store or decode original bytes. Each card/thumbnail's SwiftUI task cancels its stale PhotoKit request when removed or invalidated. Preview failure can be retried or the photo can still be reviewed. Bin rows request 64-point thumbnails; off-screen tasks cancel normally. Library enumeration retains PHAsset references, not image pixels. There is no cache of full-resolution decoded images.

Compression exports one original resource to disk, avoids holding an original Data blob in memory, and uses ImageIO sources with caching disabled. The encoding actor serializes decode/encode work. An autorelease pool bounds temporary allocations. High and Medium retain full resolution; Low uses a bounded ImageIO resize to two-thirds of each pixel dimension. No additional full-resolution result preview is decoded. Images above 50 megapixels are rejected visibly to cap worst-case processing. HEIC/JPEG encoding may still allocate substantial native buffers at that ceiling. Simulator validation does not replace real-device Instruments memory/gesture profiling; see STATUS.md.

## Compression and metadata

- Compression takes two taps in normal use: tap Compress, then tap a preset in the popup. That preset starts downloading, encoding, verification and saving automatically; there is no slider, Prepare step or second Save confirmation. On success the popup closes and a nonmodal notice opens the detailed size/metadata report when wanted.
- The initial preset is **Medium**. The last used preset and output format are remembered and shown on the next popup. High uses 0.80 quality and full resolution; Medium uses 0.40 and full resolution; Low uses 0.60 and reduces **both width and height to two-thirds**, with unavoidable pixel rounding. Low therefore retains about 4/9 of the original pixel count.
- HEIC output is preferred when the installed ImageIO encoder supports it; JPEG is also selectable. JPEG and HEIC/HEIF originals can be encoded in either output format. The numerical quality value is the encoder setting, not a promise of equal visual quality or file size between JPEG and HEIC.
- This is a **replacement-style workflow**: the saved compressed asset is marked Keep and the original asset is moved into the in-app Bin only after Photos successfully saves the result. PhotoKit creates a new asset rather than overwriting the original file. The original remains recoverable from the Bin and in Photos until separately confirmed Bin deletion. No space is freed by adding the compressed asset alone.
- Creation date, location, favorite/hidden status and editable regular-album membership are copied through PhotoKit. Smart-album rules and shared/read-only albums are not copied by a sharing transaction. Local Keep/Bin decisions are saved together; repeated completion is idempotent. If Photos succeeds but the local save fails, the UI explicitly says both assets exist and offers to retry the Bin step without creating another copy.
- The first compression popup shows a Live Photo warning that must be acknowledged with **OK** (the one-time extra tap). A persistent yellow warning triangle explains that the compressed version contains a still image, with **no Live Photo motion or audio**. The original Live Photo and its paired video remain in the Bin; deleting the original removes that original from the Photos library, subject to iOS Recently Deleted behavior.
- JPEG/HEIC encoding is lossy. RAW/ProRAW, animated/multi-image originals, PNG/TIFF and other input formats remain unsupported with visible errors. If a preset does not produce a smaller file, nothing is saved or binned and the user can try another preset/format.
- Original dimensions and orientation are checked for High/Medium. Low uses a bounded ImageIO thumbnail for resizing, preserves the orientation tag, updates dimension metadata and verifies actual output dimensions. Expected dimension changes are reported separately from metadata loss.
- ImageIO copies exposed EXIF, IPTC, GPS, capture dates, orientation, color/profile information and XMP tags. Every exposed source property leaf and metadata-tag value is compared with the encoded file, excluding file length and verified intentional dimension changes. Detected changed/missing fields are listed without displaying GPS values in the compression report.
- Full-resolution encoding attempts to retain supported auxiliary depth/matte data and gain maps, then checks their presence and data. **Low does not preserve depth, portrait mattes or HDR gain maps**; detected missing auxiliary fields are reported. Photos edit history is not rendered; compression reads the original resource.
- A yellow metadata warning is visible before choosing a preset, and the completion notice/report still warns about unsupported data even when compared fields match. Unknown/proprietary metadata, maker notes, exact ICC bytes, auxiliary metadata, HDR rendering and Photos import normalization cannot be guaranteed. Verification happens before import; there is no blanket metadata-preservation claim.

ImageIO destination semantics are documented by [Apple's image destination reference](https://developer.apple.com/documentation/imageio/cgimagedestination). The deletion flow follows [PhotoKit's deleteAssets API](https://developer.apple.com/documentation/photos/phassetchangerequest/deleteassets(_:)).

## iOS 27 usage

The app targets and is tested with the installed stable Xcode 27 SDK. Core behavior uses stable PhotoKit, SwiftUI custom DragGesture, native secondary swipe actions, SwiftData and ImageIO APIs already available in iOS 26. No feature genuinely requires an iOS-27-only API. Lowering the deployment target to 26 should require validation rather than architectural changes. Drag/reordering and Foundation Models are omitted because the Bin has no meaningful ordering requirement and intelligence is outside this MVP.

## Tests and remaining validation

Core tests cover original-file info extraction, camera/exposure/GPS formatting, absent metadata, deterministic random ordering, seed persistence, duplicate prevention, transition/restore behavior, stale cursor handling, limited-access decision retention, memory/disk persistence recovery, atomic decision/cursor saves, concurrent/cancelled-write durability, stale-cursor protection, undo, configuration bounds, nested metadata loss detection, real JPEG/HEIC encoding, original preservation, unsupported animation/format rejection and corrupt input. UI tests cover successive drag swipes with Undo/information-sheet interaction and Bin restoration, native tab navigation and the information sheet, full-screen entry, pinch/double-tap zoom, returning to review, Review→Bin, undo, selection, cancelled deletion, relaunch persistence, restore, compression presets, automatic replacement, warning acknowledgement and last-used settings.

Device-specific checklists and current build/test evidence are maintained in `STATUS.md`. Real Photos permission changes, iCloud errors, system deletion cancellation, HDR/Live Photo/RAW sources, and memory pressure must be checked on a physical device before release.
