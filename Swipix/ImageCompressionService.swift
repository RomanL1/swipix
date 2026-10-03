import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CompressionConfiguration: Sendable, Equatable {
    var quality: Double
    init(quality: Double = 0.8) { self.quality = min(0.95, max(0.35, quality.isFinite ? quality : 0.8)) }
}

struct MetadataReport: Sendable {
    let checked: Int
    let differences: [String]
    let limitations: [String]
    var summary: String {
        differences.isEmpty ? "All \(checked) exposed metadata fields match." : "\(differences.count) of \(checked) exposed fields changed or are missing."
    }
}

struct CompressionResult: Sendable {
    let outputURL: URL
    let originalBytes: Int64
    let compressedBytes: Int64
    let originalFormat: String
    let outputFormat: String
    let fileExtension: String
    let width: Int
    let height: Int
    let metadata: MetadataReport
    var savings: Int64 { originalBytes - compressedBytes }
}

enum MetadataVerifier {
    /// Compare all ImageIO-exposed property leaves, including vendor dictionaries.
    static func flattened(_ dictionary: NSDictionary, prefix: String = "") -> [String: NSObject] {
        var result: [String: NSObject] = [:]
        for (key, value) in dictionary {
            let path = prefix.isEmpty ? String(describing: key) : "\(prefix).\(key)"
            if let nested = value as? NSDictionary { result.merge(flattened(nested, prefix: path)) { _, new in new } }
            else if let object = value as? NSObject { result[path] = object }
        }
        return result
    }
    static func differences(before: NSDictionary, after: NSDictionary) -> [String] {
        let before = flattened(before), after = flattened(after)
        // The byte length is intentionally changed; everything else is reported.
        return before.keys.filter { $0 != String(kCGImagePropertyFileSize) && !(after[$0]?.isEqual(before[$0]) ?? false) }.sorted()
    }
    /// XMP arrays can contain opaque CGImageMetadataTag objects. Compare their values,
    /// names, namespaces and qualifiers, never object descriptions containing addresses.
    static func normalized(_ value: Any) -> NSObject {
        let object = value as AnyObject
        if CFGetTypeID(object) == CGImageMetadataTagGetTypeID() {
            let tag = object as! CGImageMetadataTag
            let result = NSMutableDictionary()
            result["name"] = CGImageMetadataTagCopyName(tag) as String?
            result["namespace"] = CGImageMetadataTagCopyNamespace(tag) as String?
            result["type"] = CGImageMetadataTagGetType(tag).rawValue
            if let value = CGImageMetadataTagCopyValue(tag) { result["value"] = normalized(value) }
            if let qualifiers = CGImageMetadataTagCopyQualifiers(tag) { result["qualifiers"] = normalized(qualifiers) }
            return result
        }
        if let array = value as? NSArray { return NSArray(array: array.map { normalized($0) }) }
        if let dictionary = value as? NSDictionary {
            let result = NSMutableDictionary()
            for (key, value) in dictionary { result[String(describing: key)] = normalized(value) }
            return result
        }
        return value as? NSObject ?? String(describing: value) as NSString
    }
    static func tags(_ source: CGImageSource) -> [String: NSObject] {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [:] }
        var result: [String: NSObject] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            result[path as String] = normalized(tag)
            return true
        }
        return result
    }

}

/// A single actor serializes encoding so only one original is processed at a time.
actor ImageCompressionService {
    func compress(sourceURL: URL, outputDirectory: URL, configuration: CompressionConfiguration) throws -> CompressionResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, noCache),
                  let typeID = CGImageSourceGetType(source),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary? else {
                throw PhotoFailure(message: "ImageIO cannot read this original image.")
            }
            guard CGImageSourceGetCount(source) == 1 else {
                throw PhotoFailure(message: "Animated and multi-image files are not compressed because their additional frames could be lost.")
            }
            guard let originalType = UTType(typeID as String) else {
                throw PhotoFailure(message: "The original image format could not be identified.")
            }
            guard !originalType.conforms(to: .rawImage) else {
                throw PhotoFailure(message: "RAW and ProRAW require a separate derivative workflow and are not compressed.")
            }
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            guard width > 0, height > 0, Int64(width) * Int64(height) <= 50_000_000 else {
                throw PhotoFailure(message: "This image exceeds the 50-megapixel processing limit. The original is unchanged.")
            }
            let outputType: UTType
            if originalType.conforms(to: .heic) || originalType.conforms(to: .heif) { outputType = .heic }
            else if originalType.conforms(to: .jpeg) { outputType = .jpeg }
            else {
                throw PhotoFailure(message: "Only single-image JPEG and HEIC/HEIF originals can be compressed. PNG, GIF, TIFF and other formats remain unchanged.")
            }
            let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
            guard supported.contains(outputType.identifier) else {
                throw PhotoFailure(message: "The encoder for \(outputType.identifier) is unavailable on this device.")
            }
            let ext = outputType.preferredFilenameExtension ?? "jpg"
            let output = outputDirectory.appendingPathComponent("compressed.\(ext)")
            try? FileManager.default.removeItem(at: output)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, outputType.identifier as CFString, 1, nil) else {
                throw PhotoFailure(message: "Could not create a compressed image file.")
            }
            let copied = properties.mutableCopy() as! NSMutableDictionary
            copied[kCGImageDestinationLossyCompressionQuality] = configuration.quality
            copied[kCGImageDestinationPreserveGainMap] = true
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) { copied[kCGImageDestinationMetadata] = metadata }
            let auxiliaryTypes: [CFString] = [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte]
            // Decode/re-encode through ImageIO, keeping original pixel dimensions and orientation.
            CGImageDestinationAddImageFromSource(destination, source, 0, copied as CFDictionary)
            for type in auxiliaryTypes {
                if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) {
                    CGImageDestinationAddAuxiliaryDataInfo(destination, type, info)
                }
            }
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: output)
                throw PhotoFailure(message: "ImageIO could not finish compression. The original is unchanged.")
            }
            try Task.checkCancellation()
            guard let verified = CGImageSourceCreateWithURL(output as CFURL, noCache),
                  let after = CGImageSourceCopyPropertiesAtIndex(verified, 0, nil) as NSDictionary? else {
                throw PhotoFailure(message: "Could not verify the compressed file. It has not been saved to Photos.")
            }
            guard (after[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
                  (after[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else {
                throw PhotoFailure(message: "The encoder changed pixel dimensions. This output cannot be saved.")
            }
            guard ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) ==
                  ((after[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) else {
                throw PhotoFailure(message: "The encoder changed image orientation. This output cannot be saved.")
            }
            var differences = MetadataVerifier.differences(before: properties, after: after)
            var auxiliaryChecked = 0
            for type in auxiliaryTypes + [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
                if let beforeInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as NSDictionary? {
                    auxiliaryChecked += 2
                    guard let afterInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(verified, 0, type) as NSDictionary? else {
                        differences.append("Auxiliary.\(type).missing"); continue
                    }
                    for key in [kCGImageAuxiliaryDataInfoData, kCGImageAuxiliaryDataInfoDataDescription] {
                        if let value = beforeInfo[key] as? NSObject, !((afterInfo[key] as? NSObject)?.isEqual(value) ?? false) {
                            differences.append("Auxiliary.\(type).\(key)")
                        }
                    }
                }
            }
            let beforeTags = MetadataVerifier.tags(source), afterTags = MetadataVerifier.tags(verified)
            differences += beforeTags.keys.filter { beforeTags[$0] != afterTags[$0] }.map { "XMP.\($0)" }
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
            let originalBytes = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
            let compressedBytes = (outputAttributes[.size] as? NSNumber)?.int64Value ?? 0
            return CompressionResult(outputURL: output, originalBytes: originalBytes, compressedBytes: compressedBytes,
                originalFormat: originalType.identifier, outputFormat: outputType.identifier, fileExtension: ext,
                width: width, height: height,
                metadata: MetadataReport(checked: MetadataVerifier.flattened(properties).count + beforeTags.count + auxiliaryChecked,
                    differences: Array(Set(differences)).sorted(), limitations: [
                        "Only metadata exposed by ImageIO is compared. Unknown proprietary data, maker notes, and exact ICC profile bytes cannot be guaranteed.",
                        "Supported gain maps, depth and matte data are copied where ImageIO permits, then checked for presence and data changes. Auxiliary metadata and Photos edit history cannot be guaranteed.",
                        "A Live Photo saves as a still-image copy; its paired video stays with the original.",
                        "Photos may normalize metadata when importing. File verification happens before import; creation date and location are also assigned through PhotoKit."
                    ]))
        }
    }
}
