import XCTest
import SwiftData
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import Darwin
@testable import Swipix

final class ReviewLedgerTests: XCTestCase {
    func testRandomOrderIsStableAcrossFetchOrderAndContainsEveryPhoto() {
        let ids = (0..<100).map(String.init)
        let order = ReviewOrder.randomized(ids, seed: "session-one")
        XCTAssertEqual(order, ReviewOrder.randomized(ids.reversed(), seed: "session-one"))
        XCTAssertEqual(Set(order), Set(ids)); XCTAssertEqual(order.count, ids.count)
        XCTAssertNotEqual(order, ids)
        XCTAssertNotEqual(order, ReviewOrder.randomized(ids, seed: "session-two"))
    }

    func testDuplicateDecisionCannotChangeChoice() {
        var ledger = ReviewLedger()
        XCTAssertTrue(ledger.decide("a", .bin))
        XCTAssertFalse(ledger.decide("a", .keep))
        XCTAssertEqual(ledger.decisions["a"], .bin)
    }
    func testRestoreMultipleAndResumeReview() {
        var ledger = ReviewLedger()
        ledger.decide("a", .bin); ledger.decide("b", .keep); ledger.decide("c", .bin)
        ledger.restore(["a", "c"])
        XCTAssertEqual(ledger.decisions, ["b": .keep])
        XCTAssertEqual(ledger.next(in: ["b", "a", "c"]), "a")
    }
    func testLimitedAccessRetainsInvisibleDecisionsAndSkipsStaleCursor() {
        var ledger = ReviewLedger()
        ledger.decide("hidden", .bin); ledger.currentID = "missing"
        XCTAssertEqual(ledger.next(in: ["visible"]), "visible")
        XCTAssertEqual(ledger.decisions["hidden"], .bin)
        XCTAssertNil(ledger.next(in: []))
        XCTAssertTrue(ledger.decide("visible", .keep))
        XCTAssertNil(ledger.next(in: ["visible"]))
    }
    func testSavedCursorWinsOverNewlyAddedPhotos() {
        var ledger = ReviewLedger(); ledger.currentID = "current"
        XCTAssertEqual(ledger.next(in: ["new", "current"]), "current")
    }
}

@MainActor final class ReviewStoreTests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: ReviewRecord.self, ReviewSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    func testPersistenceRecoveryBinRestoreAndDuplicate() async throws {
        let container = try container()
        let store = try ReviewStore(container: container)
        XCTAssertEqual(store.shuffleSeed, try ReviewStore(container: container).shuffleSeed)
        try await store.decide("a", .bin); try await store.decide("a", .keep); try await store.decide("b", .keep)
        try await store.setCurrent("stale")
        let recovered = try ReviewStore(container: container)
        XCTAssertEqual(recovered.binIDs, ["a"])
        XCTAssertEqual(recovered.reviewedCount, 2)
        XCTAssertEqual(recovered.ledger.next(in: ["b", "c"]), "c")
        try await recovered.restore(["a"])
        let reopened = try ReviewStore(container: container)
        XCTAssertTrue(reopened.binIDs.isEmpty)
        XCTAssertEqual(reopened.ledger.next(in: ["a", "b"]), "a")
    }
    func testCompressedReplacementIsAtomicIdempotentAndRecoverable() async throws {
        let container = try container()
        let store = try ReviewStore(container: container)
        try await store.decide("original", .keep)
        try await store.recordReplacement(original: "original", compressed: "compressed")
        try await store.recordReplacement(original: "original", compressed: "compressed")
        let recovered = try ReviewStore(container: container)
        XCTAssertEqual(recovered.binIDs, ["original"])
        XCTAssertEqual(recovered.ledger.decisions["compressed"], .keep)
        XCTAssertEqual(recovered.reviewedCount, 2)
        XCTAssertNil(store.lastDecision)
        try await recovered.restore(["original"])
        XCTAssertNil(recovered.ledger.decisions["original"])
        XCTAssertEqual(recovered.ledger.decisions["compressed"], .keep)
    }
    func testInvalidReplacementCannotBinTheOriginal() async throws {
        let store = try ReviewStore(container: container())
        try await store.decide("original", .keep)
        do {
            try await store.recordReplacement(original: "original", compressed: "original")
            XCTFail("Invalid replacement must be rejected")
        } catch { }
        XCTAssertTrue(store.binIDs.isEmpty)
        XCTAssertEqual(store.ledger.decisions["original"], .keep)
    }
    func testDecisionAndNextCursorPersistTogether() async throws {
        let container = try container()
        let store = try ReviewStore(container: container)
        try await store.decide("a", .bin, currentID: "b")
        let recovered = try ReviewStore(container: container)
        XCTAssertEqual(recovered.ledger.decisions["a"], .bin)
        XCTAssertEqual(recovered.ledger.currentID, "b")
        // A stale reconciliation must not move the cursor back onto a reviewed photo.
        try await store.setCurrent("a")
        XCTAssertEqual(store.ledger.currentID, "b")
    }
    func testConcurrentAndCancelledWritesRemainDurable() async throws {
        let container = try container()
        let store = try ReviewStore(container: container)
        let first = Task { try await store.decide("a", .bin) }
        let second = Task { try await store.decide("b", .keep) }
        first.cancel()
        try await first.value; try await second.value
        let recovered = try ReviewStore(container: container)
        XCTAssertEqual(recovered.ledger.decisions, ["a": .bin, "b": .keep])
        XCTAssertEqual(store.ledger.decisions, recovered.ledger.decisions)
        XCTAssertEqual(store.binIDs, ["a"])
    }
    func testUndoReturnsToExactAsset() async throws {
        let store = try ReviewStore(container: container())
        try await store.decide("a", .keep); try await store.setCurrent("b")
        try await store.undo()
        XCTAssertEqual(store.ledger.currentID, "a")
        XCTAssertNil(store.ledger.decisions["a"])
        XCTAssertNil(store.lastDecision)
    }
    func testDiskStoreReopensWithDecisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("review.store")
        let schema = Schema([ReviewRecord.self, ReviewSession.self])
        let config = ModelConfiguration(schema: schema, url: url)
        var seed = ""
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            let store = try ReviewStore(container: container)
            seed = store.shuffleSeed
            try await store.decide("persisted", .bin); try await store.setCurrent("next")
        }
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let store = try ReviewStore(container: reopened)
        XCTAssertEqual(store.shuffleSeed, seed)
        XCTAssertEqual(store.binIDs, ["persisted"])
        XCTAssertEqual(store.ledger.currentID, "next")
    }
}

final class CompressionTests: XCTestCase {
    func testCompressionPresetValues() {
        XCTAssertEqual(CompressionPreset.high.quality, 0.8)
        XCTAssertEqual(CompressionPreset.medium.quality, 0.4)
        XCTAssertEqual(CompressionPreset.low.quality, 0.6)
        XCTAssertEqual(CompressionPreset.high.scale, 1)
        XCTAssertEqual(CompressionPreset.medium.scale, 1)
        XCTAssertEqual(CompressionPreset.low.scale, 2.0 / 3.0)
        XCTAssertEqual(CompressionConfiguration(preset: .medium, format: .heic), .init(quality: 0.4, scale: 1, format: .heic))
    }
    func testLowPresetResizesJPEGAndHEICAndKeepsOrientationAndGPS() async throws {
        for format in [CompressionFormat.jpeg, .heic] {
            if format == .heic && !CompressionFormat.supportsHEIC { continue }
            let (sourceURL, directory) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = try Data(contentsOf: sourceURL)
            let result = try await ImageCompressionService().compress(sourceURL: sourceURL, outputDirectory: directory,
                configuration: .init(preset: .low, format: format))
            XCTAssertLessThanOrEqual(abs(result.width - 170), 1)
            XCTAssertLessThanOrEqual(abs(result.height - 128), 1)
            XCTAssertEqual(result.outputFormat, format == .heic ? UTType.heic.identifier : UTType.jpeg.identifier)
            let image = CGImageSourceCreateWithURL(result.outputURL as CFURL, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
            XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6)
            let exif = props[kCGImagePropertyExifDictionary] as! NSDictionary
            XCTAssertEqual((exif[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue, result.width)
            XCTAssertEqual((exif[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue, result.height)
            let info = try PhotoFileInfo.read(url: result.outputURL)
            XCTAssertEqual(info.originalLocation, "47.30000, 8.50000")
            XCTAssertTrue(info.image.contains { $0.title == "Captured (EXIF)" && $0.value == "2026:10:03 12:34:56" })
            XCTAssertEqual(result.metadata.intentionalChanges.count, 1)
            XCTAssertFalse(result.metadata.differences.contains(String(kCGImagePropertyPixelWidth)))
            XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        }
    }
    func testHighAndMediumSupportFullResolutionJPEGAndHEIC() async throws {
        let formats: [CompressionFormat] = CompressionFormat.supportsHEIC ? [.jpeg, .heic] : [.jpeg]
        for format in formats {
            for preset in [CompressionPreset.high, .medium] {
                let (sourceURL, directory) = try fixture()
                defer { try? FileManager.default.removeItem(at: directory) }
                let result = try await ImageCompressionService().compress(sourceURL: sourceURL, outputDirectory: directory,
                    configuration: .init(preset: preset, format: format))
                XCTAssertEqual(result.width, 256); XCTAssertEqual(result.height, 192)
                XCTAssertEqual(result.outputFormat, format == .heic ? UTType.heic.identifier : UTType.jpeg.identifier)
                XCTAssertTrue(result.metadata.intentionalChanges.isEmpty)
            }
        }
    }
    func testConfigurationClampsInvalidValues() {
        XCTAssertEqual(CompressionConfiguration(quality: -.infinity).quality, 0.8)
        XCTAssertEqual(CompressionConfiguration(quality: .nan).quality, 0.8)
        XCTAssertEqual(CompressionConfiguration(quality: -1).quality, 0.35)
        XCTAssertEqual(CompressionConfiguration(quality: 2).quality, 0.95)
    }
    func testMetadataVerifierDetectsNestedLossWithoutComparingFileSize() {
        let before: NSDictionary = ["{GPS}": ["Latitude": 47.3], "{Exif}": ["DateTimeOriginal": "2026:10:03 12:00:00"], "FileSize": 100]
        let after: NSDictionary = ["{Exif}": ["DateTimeOriginal": "2026:10:03 12:00:00"], "FileSize": 50]
        XCTAssertEqual(MetadataVerifier.differences(before: before, after: after), ["{GPS}.Latitude"])
    }
    func testOpaqueXMPArrayValuesCompareByContent() {
        let namespace = "https://example.invalid/swipix" as CFString
        let first = CGImageMetadataTagCreate(namespace, "swipix" as CFString, "item" as CFString, .string, "caption" as CFString)!
        let second = CGImageMetadataTagCreate(namespace, "swipix" as CFString, "item" as CFString, .string, "caption" as CFString)!
        let changed = CGImageMetadataTagCreate(namespace, "swipix" as CFString, "item" as CFString, .string, "different caption" as CFString)!
        XCTAssertEqual(MetadataVerifier.normalized([first] as NSArray), MetadataVerifier.normalized([second] as NSArray))
        XCTAssertNotEqual(MetadataVerifier.normalized([first] as NSArray), MetadataVerifier.normalized([changed] as NSArray))
    }
    private func fixture(_ type: UTType = .jpeg, frames: Int = 1, width: Int = 256, height: Int = 192) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source")
        // Deterministic detailed pixels exercise actual lossy encoding rather than a blank image.
        let pixels = (0..<(width * height * 4)).map { UInt8(truncatingIfNeeded: ($0 * 73) ^ ($0 / 11)) }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL, type.identifier as CFString, frames, nil)!
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.99,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:03 12:34:56", kCGImagePropertyExifUserComment: "Swipix fixture"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.3, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 8.5, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "Metadata test"]
        ]
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (sourceURL, directory)
    }
    func testPhotoInformationReadsOriginalFileWithoutChangingIt() throws {
        let (sourceURL, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try Data(contentsOf: sourceURL)
        let info = try PhotoFileInfo.read(url: sourceURL)
        XCTAssertEqual(info.bytes, Int64(before.count))
        XCTAssertEqual(info.originalLocation, "47.30000, 8.50000")
        XCTAssertEqual(info.captions.first?.value, "Metadata test")
        XCTAssertTrue(info.image.contains { $0.title == "Captured (EXIF)" && $0.value == "2026:10:03 12:34:56" })
        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
    }
    func testJPEGCompressionPreservesDimensionsAndImportantMetadata() async throws {
        let (sourceURL, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ImageCompressionService().compress(sourceURL: sourceURL, outputDirectory: directory, configuration: .init(quality: 0.55))
        XCTAssertEqual(result.width, 256); XCTAssertEqual(result.height, 192)
        XCTAssertEqual(result.outputFormat, UTType.jpeg.identifier)
        XCTAssertLessThan(result.compressedBytes, result.originalBytes)
        let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)!
        let output = CGImageSourceCreateWithURL(result.outputURL as CFURL, nil)!
        let before = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        let after = CGImageSourceCopyPropertiesAtIndex(output, 0, nil)! as NSDictionary
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyOrientation, kCGImagePropertyProfileName] {
            XCTAssertNotNil(before[key], "Fixture must contain \(key)")
            XCTAssertEqual(before[key] as? NSObject, after[key] as? NSObject, "Field \(key)")
        }
        XCTAssertGreaterThan(result.metadata.checked, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }
    func testHEICCompressionUsesHEIC() async throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(UTType.heic.identifier) else {
            throw XCTSkip("HEIC encoder unavailable on this runtime")
        }
        let (sourceURL, directory) = try fixture(.heic)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ImageCompressionService().compress(sourceURL: sourceURL, outputDirectory: directory, configuration: .init(quality: 0.6))
        XCTAssertEqual(result.outputFormat, UTType.heic.identifier)
        XCTAssertEqual(result.width, 256); XCTAssertEqual(result.height, 192)
    }
    func testPNGAndAnimatedGIFAreRejectedWithoutModifyingOriginal() async throws {
        for (type, frames) in [(UTType.png, 1), (UTType.gif, 2)] {
            let (sourceURL, directory) = try fixture(type, frames: frames)
            defer { try? FileManager.default.removeItem(at: directory) }
            let before = try Data(contentsOf: sourceURL)
            do {
                _ = try await ImageCompressionService().compress(sourceURL: sourceURL, outputDirectory: directory, configuration: .init())
                XCTFail("Unsupported input should fail")
            } catch { XCTAssertTrue(error is PhotoFailure) }
            XCTAssertEqual(try Data(contentsOf: sourceURL), before)
        }
    }
    func testTwelveMegapixelCompressionMemoryBudget() async throws {
        let (url, directory) = try autoreleasepool { try fixture(width: 4032, height: 3024) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = residentBytes()
        XCTAssertGreaterThan(baseline, 0, "Memory sampling must be available")
        let sampler = Task.detached {
            var peak = residentBytes()
            while !Task.isCancelled {
                peak = max(peak, residentBytes())
                try? await Task.sleep(for: .milliseconds(10))
            }
            return peak
        }
        let start = ContinuousClock.now
        do {
            let result = try await ImageCompressionService().compress(sourceURL: url, outputDirectory: directory, configuration: .init(quality: 0.8))
            XCTAssertEqual(result.width, 4032); XCTAssertEqual(result.height, 3024)
        } catch { sampler.cancel(); _ = await sampler.value; throw error }
        sampler.cancel()
        let peak = await sampler.value
        let increase = peak > baseline ? peak - baseline : 0
        let measurement = "Swipix 12MP compression: resident peak \(peak / 1_048_576) MiB; increase \(increase / 1_048_576) MiB; elapsed \(start.duration(to: .now))"
        print(measurement)
        let attachment = XCTAttachment(string: measurement); attachment.name = "12MP memory measurement"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertLessThan(increase, 256 * 1_048_576, "12MP encoding should stay within the incremental memory budget")
    }
    func testCorruptInputIsRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken"); try Data("not an image".utf8).write(to: url)
        do {
            _ = try await ImageCompressionService().compress(sourceURL: url, outputDirectory: directory, configuration: .init())
            XCTFail("Corrupt input should fail")
        } catch { XCTAssertTrue(error is PhotoFailure) }
    }
}

private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
}

final class PhotoInformationTests: XCTestCase {
    func testCameraExposureAndGPSFormatting() {
        let info = PhotoFileInfo.parse([
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Fixture", kCGImagePropertyTIFFModel as String: "QA camera"],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 1.8,
                kCGImagePropertyExifExposureTime as String: 0.004,
                kCGImagePropertyExifISOSpeedRatings as String: [100],
                kCGImagePropertyExifFocalLength as String: 24.0],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 47.3,
                kCGImagePropertyGPSLatitudeRef as String: "S",
                kCGImagePropertyGPSLongitude as String: 8.5,
                kCGImagePropertyGPSLongitudeRef as String: "W"]
        ], bytes: 12345)
        let values = Dictionary(uniqueKeysWithValues: info.camera.map { ($0.title, $0.value) })
        XCTAssertEqual(values["Camera"], "QA camera")
        XCTAssertEqual(values["Aperture"], "ƒ/1.8")
        XCTAssertEqual(values["Shutter speed"], "1/250 s")
        XCTAssertEqual(values["ISO"], "100")
        XCTAssertEqual(values["Focal length"], "24 mm")
        XCTAssertEqual(info.originalLocation, "-47.30000, -8.50000")
        XCTAssertEqual(info.bytes, 12345)
    }
    func testMissingMetadataIsNeverInvented() {
        let info = PhotoFileInfo.parse([:], bytes: 10)
        XCTAssertTrue(info.camera.isEmpty); XCTAssertTrue(info.image.isEmpty); XCTAssertTrue(info.captions.isEmpty)
        XCTAssertNil(info.originalLocation)
        for exposure in [Double.nan, .infinity, -1, 0, .leastNonzeroMagnitude] {
            let unusual = PhotoFileInfo.parse([kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifExposureTime as String: exposure]], bytes: 1)
            if !exposure.isFinite || exposure <= 0 { XCTAssertTrue(unusual.camera.isEmpty) }
            else { XCTAssertFalse(unusual.camera.first?.value.contains("inf") ?? true) }
        }
    }
}
