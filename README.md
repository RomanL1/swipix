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
- The full-screen button opens a pinch/double-tap zoom preview. Live Photos also offer a Play Live Photo control with pinch zoom during playback. Cards fit the entire photo without cropping or an inset border, and colors adapt to light/dark appearance.
- Current-photo details show dimensions, megapixels and the byte size of locally available original photo resources (including paired video for Live Photos). An iCloud-only original is identified as size unavailable; this read does not download it or retain its data.
- SwiftData records a decision before advancing. An identifier can only receive one review decision until restored. Undo returns to the last decided asset during the current launch.
- The Bin supports multi-selection, select all, restore, and per-row restore actions. Restoring clears the local decision and makes the asset reviewable again.
- Deletion is available **only** from the Bin, with an explicit app confirmation immediately before the PhotoKit transaction. PhotoKit then applies its own authorization/confirmation rules. Selection is re-resolved before submission; if any selected asset is inaccessible the entire request is rejected before a mutation. Errors stay visible and local decisions remain unless the transaction succeeds.
- Successful deletion is checked against the accessible library before clearing local entries. If Photos still reports selected items, the Bin remains for investigation. If local persistence fails after a successful Photos deletion, the app explicitly explains that distinction.
- The app Bin is **not** Apple's Recently Deleted album. A confirmed PhotoKit request deletes from the Photos library (and may sync through iCloud); iOS may retain items in Recently Deleted according to system behavior. Third-party apps cannot promise immediate permanent erasure or bypass that album. Freed space is not guaranteed immediately.
- No misleading storage total is displayed: public PhotoKit APIs do not provide a reliable byte size for every original resource without reading it. Compression review shows exact downloaded-input and encoded-output byte sizes.

## Permissions, limited access and privacy

The read/write Photos permission is used to fetch chosen images, save copies, and request confirmed deletion. The generated Info.plist includes clear read/write and add usage descriptions. Access is requested only when onboarding's button is pressed.

Full and limited access work with the same flow. A native limited-library picker lets you choose more images from Review, Bin and Settings. Authorization is rechecked on foregrounding and library changes; denial/revocation returns to the permission screen and clears accessible assets/previews. Settings provides a link to iOS Settings. No placeholder library is presented as real Photos content.

Only asset identifiers, choices, dates, the random-order seed and the review cursor are stored in SwiftData; quality is persisted with AppStorage. Decisions for unresolved identifiers are retained because PhotoKit cannot reliably distinguish a removed asset from one hidden by a narrower limited selection. Inaccessible Bin entries are excluded from destructive actions, explained in the UI, and can be dismissed locally. Regranting access makes retained decisions available again. Externally edited assets refresh through `PHPhotoLibraryChangeObserver` and previews are invalidated. The active cursor is resolved against the current library, falling back safely when missing.

No analytics, uploads, backend, remote models, or custom network calls. PhotoKit may download iCloud previews/originals on demand. Temporary original and compressed files stay in the app sandbox and are removed after review closes or fails. Synthetic fixtures contain only invented metadata. The app contains no future intelligence feature or automatic deletion.

## Architecture

| File | Responsibility |
| --- | --- |
| `AppModel.swift` | App startup, review coordination, mutation/error state |
| `PhotoLibraryService.swift` | Authorization, change observation, asset lookup, preview caching and cancellation, PhotoKit transactions and resource export |
| `ReviewState.swift` | Pure review transitions, per-asset SwiftData records, persisted cursor and undo |
| `ImageCompressionService.swift` | Serial ImageIO encoding, format checks, dimensions/orientation checks, metadata comparison |
| `Views.swift` | Onboarding, custom swipe card, Bin, limited picker and Settings |
| `FullscreenPreview.swift` | Zoomable full-screen still preview and native Live Photo playback |
| `CompressionView.swift` | Download/encode/review/save workflow and temporary-file lifecycle |

Observable app state and SwiftData operations stay on the main actor. Encoding runs in a separate actor. PhotoKit callbacks bridge async operations; image request cancellation uses a lock to handle callback/request-ID races and resume continuations exactly once. Swift 6 language mode and complete concurrency checking are enabled. PhotoKit mutations are concentrated in the service; pure decisions and metadata comparisons are tested without a Photos library. There are no speculative service factories or third-party abstractions.

## Caching and memory

`PHCachingImageManager` caches the active asset plus up to five upcoming assets at screen-size/scale-derived preview dimensions (capped to a 1600-pixel long edge). Requests and prefetches use matching options and `aspectFit`, keeping the complete image visible. The service also explicitly requests and retains those six bounded previews so each next card can start with its image already available. A swipe waits with the current card visible if the next iCloud preview has not finished. The initial preview or a failed/offline download cannot be made instantaneous; failures have a retry action. Cache windows are replaced when the current asset or display dimensions change and invalidated on Photos changes. The deprecated `allowsCachingHighQualityImages` property is deliberately unused.

Swipe image previews never decode original image data. The separate size read streams local original-resource chunks only to count bytes, cancels when the card disappears and does not retain the chunks. Each card/thumbnail's SwiftUI task cancels its stale PhotoKit request when removed or invalidated. Preview failure can be retried or the photo can still be reviewed. Bin rows request 64-point thumbnails; off-screen tasks cancel normally. Library enumeration retains PHAsset references, not image pixels. There is no cache of full-resolution decoded images.

Compression exports one original resource to disk, avoids holding an original Data blob in memory, and uses ImageIO sources with caching disabled. The encoding actor serializes decode/encode work. An autorelease pool bounds temporary allocations. Output preview is a transformed thumbnail with a maximum 1200-pixel edge. Images above 50 megapixels are rejected visibly to cap worst-case processing; there is no silent resize. HEIC/JPEG encoding may still allocate substantial native buffers at that ceiling. Simulator validation does not replace real-device Instruments memory/gesture profiling; see STATUS.md.

## Compression and metadata

- The original is **always retained**. Compression creates a new asset only after a separate explicit save confirmation. There is no in-place editing or replacement API pretending to overwrite an original.
- Quality is 0.35–0.95 (default 0.8). Pixel dimensions and orientation must match the original or saving is blocked. If output is not smaller, saving it as a compressed copy is disabled; try a lower quality.
- Single-image JPEG remains JPEG. HEIC/HEIF is encoded as HEIC, with format identifiers shown. Unsupported encoders fail visibly. PNG, GIF, TIFF and other formats are deliberately rejected; animated/multi-frame files are rejected rather than discarding frames. RAW/ProRAW resources are rejected before export; compressed RAW derivatives are not implemented and no RAW conversion happens.
- Processing uses the original `.photo` resource. Photos edit history/adjustments are not rendered into the copy. A Live Photo creates a still derivative, leaving its paired video with the original. These limitations are explained before processing.
- `CGImageDestinationAddImageFromSource` inherits image properties. The source properties and exposed `CGImageMetadata` are supplied explicitly, preserving supported EXIF, IPTC, GPS, timestamps, orientation, color-space/profile information and XMP tags. Supported depth/disparity/portrait/semantic mattes are supplied as auxiliary dictionaries; HEIF gain-map preservation is requested.
- After encoding, every exposed source property leaf (including vendor dictionaries) is compared against output, excluding intentionally changed file size. Exposed metadata tag paths/values are compared separately. Supported auxiliary payload/description data is compared, and missing auxiliary data is reported. Changed/missing fields appear by path, **without displaying GPS values**. Output dimensions and orientation are checked as hard constraints.
- The review reports actual comparisons, not a blanket preservation promise. Unknown/proprietary metadata, unexposed maker notes, exact ICC profile bytes, auxiliary metadata, unsupported image features and Photos edit history cannot be guaranteed. Auxiliary copying and gain-map requests depend on encoder support. Visible quality is lossy and HDR rendering may change even if tag properties match.
- PhotoKit assigns the original asset's creation date and location when importing the copy. Verification is against the encoded file **before** import. Photos may normalize metadata on import; that normalization is not guaranteed or independently byte-verified after import. Original filename changes for the new asset; albums, favorites, hidden status, burst relations, depth relationships and Live Photo pairing are not duplicated.

ImageIO destination semantics are documented by [Apple's image destination reference](https://developer.apple.com/documentation/imageio/cgimagedestination). The deletion flow follows [PhotoKit's deleteAssets API](https://developer.apple.com/documentation/photos/phassetchangerequest/deleteassets(_:)).

## iOS 27 usage

The app targets and is tested with the installed stable Xcode 27 SDK. Core behavior uses stable PhotoKit, SwiftUI custom DragGesture, native secondary swipe actions, SwiftData and ImageIO APIs already available in iOS 26. No feature genuinely requires an iOS-27-only API. Lowering the deployment target to 26 should require validation rather than architectural changes. Drag/reordering and Foundation Models are omitted because the Bin has no meaningful ordering requirement and intelligence is outside this MVP.

## Tests and remaining validation

Core tests cover deterministic random ordering, seed persistence, duplicate prevention, transition/restore behavior, stale cursor handling, limited-access decision retention, memory/disk persistence recovery, undo, configuration bounds, nested metadata loss detection, real JPEG/HEIC encoding, original preservation, unsupported animation/format rejection and corrupt input. UI tests cover full-screen entry, pinch/double-tap zoom, returning to review, Review→Bin, undo, selection, cancelled deletion, relaunch persistence, restore, compression review and saving a copy.

Device-specific checklists and current build/test evidence are maintained in `STATUS.md`. Real Photos permission changes, iCloud errors, system deletion cancellation, HDR/Live Photo/RAW sources, and memory pressure must be checked on a physical device before release.
