import SwiftUI
import Photos
import ImageIO
import UniformTypeIdentifiers

struct PhotoInfoField: Identifiable, Equatable, Sendable {
    let title: String
    let value: String
    var id: String { title }
}

/// Reads properties without decoding pixels. Missing tags remain absent rather than inferred.
struct PhotoFileInfo: Sendable {
    let bytes: Int64
    let camera: [PhotoInfoField]
    let image: [PhotoInfoField]
    let captions: [PhotoInfoField]
    let originalLocation: String?

    static func read(url: URL) throws -> PhotoFileInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw PhotoFailure(message: "This original does not expose image metadata through ImageIO.")
        }
        let bytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return parse(properties, bytes: bytes)
    }
    static func parse(_ properties: [String: Any], bytes: Int64) -> PhotoFileInfo {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        func field(_ title: String, _ dictionary: [String: Any], _ key: CFString) -> PhotoInfoField? {
            guard let value = dictionary[key as String] else { return nil }
            let text: String
            if let strings = value as? [String] { text = strings.joined(separator: ", ") }
            else if let string = value as? String { text = string }
            else if let number = value as? NSNumber { text = number.stringValue }
            else { return nil }
            guard !text.isEmpty else { return nil }
            return PhotoInfoField(title: title, value: text)
        }
        var camera = [
            field("Manufacturer", tiff, kCGImagePropertyTIFFMake), field("Camera", tiff, kCGImagePropertyTIFFModel),
            field("Lens", exif, kCGImagePropertyExifLensModel)
        ].compactMap { $0 }
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? NSNumber {
            camera.append(PhotoInfoField(title: "Aperture", value: "ƒ/" + String(format: "%g", aperture.doubleValue)))
        }
        if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber,
           exposure.doubleValue.isFinite, exposure.doubleValue > 0 {
            let seconds = exposure.doubleValue, reciprocal = 1 / exposure.doubleValue
            camera.append(PhotoInfoField(title: "Shutter speed", value: seconds < 1 && reciprocal.isFinite
                ? String(format: "1/%.0f s", reciprocal) : String(format: "%g s", seconds)))
        }
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], !iso.isEmpty {
            camera.append(PhotoInfoField(title: "ISO", value: iso.map(\.stringValue).joined(separator: ", ")))
        }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? NSNumber {
            camera.append(PhotoInfoField(title: "Focal length", value: String(format: "%g mm", focal.doubleValue)))
        }
        if let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber {
            camera.append(PhotoInfoField(title: "35 mm equivalent", value: "\(equivalent) mm"))
        }
        let image = [
            field("Captured (EXIF)", exif, kCGImagePropertyExifDateTimeOriginal),
            field("Color profile", properties, kCGImagePropertyProfileName),
            field("Color model", properties, kCGImagePropertyColorModel),
            field("Bits per component", properties, kCGImagePropertyDepth),
            field("Orientation tag", properties, kCGImagePropertyOrientation),
            field("Software", tiff, kCGImagePropertyTIFFSoftware)
        ].compactMap { $0 }
        let captions = [
            field("Caption", iptc, kCGImagePropertyIPTCCaptionAbstract),
            field("Keywords", iptc, kCGImagePropertyIPTCKeywords),
            field("Artist", tiff, kCGImagePropertyTIFFArtist),
            field("Copyright", tiff, kCGImagePropertyTIFFCopyright)
        ].compactMap { $0 }
        var location: String?
        if let latitude = gps[kCGImagePropertyGPSLatitude as String] as? NSNumber,
           let longitude = gps[kCGImagePropertyGPSLongitude as String] as? NSNumber {
            let lat = latitude.doubleValue * ((gps[kCGImagePropertyGPSLatitudeRef as String] as? String) == "S" ? -1 : 1)
            let lon = longitude.doubleValue * ((gps[kCGImagePropertyGPSLongitudeRef as String] as? String) == "W" ? -1 : 1)
            location = String(format: "%.5f, %.5f", lat, lon)
        }
        return PhotoFileInfo(bytes: bytes, camera: camera, image: image, captions: captions, originalLocation: location)
    }
}

extension PhotoLibraryService {
    func fileInformation(_ asset: PHAsset, allowDownload: Bool = false) async throws -> PhotoFileInfo {
        guard hasAccess, self.asset(asset.localIdentifier) != nil,
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
            throw PhotoFailure(message: "The original photo is no longer accessible. Check Photos access and try again.")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Swipix-info-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowDownload
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        return try PhotoFileInfo.read(url: url)
    }
}

struct PhotoInfoView: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss
    @State private var details: PhotoFileInfo?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var allowDownload = true
    @State private var loading = true
    @State private var retry = 0
    private var resource: PHAssetResource? { PHAssetResource.assetResources(for: asset).first { $0.type == .photo } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180)
                            .accessibilityLabel("Photo information preview")
                    }
                    if let date = asset.creationDate { Text(date.formatted(date: .complete, time: .shortened)).font(.headline) }
                    Text(resource?.displayFilename ?? "Photo").font(.subheadline).textSelection(.enabled)
                    Label(asset.mediaSubtypes.contains(.photoLive) ? "Live Photo" : "Photo", systemImage: "photo")
                }
                Section("File") {
                    LabeledContent("Format", value: resource.flatMap { UTType($0.uniformTypeIdentifier)?.localizedDescription } ?? "Unknown")
                    LabeledContent("Dimensions", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                    LabeledContent("Resolution", value: String(format: "%.1f MP", Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000))
                    if let details { LabeledContent("Original photo size", value: ByteCountFormatter.string(fromByteCount: details.bytes, countStyle: .file)) }
                    if let date = asset.modificationDate { LabeledContent("Modified in Photos", value: date.formatted(date: .abbreviated, time: .shortened)) }
                }
                if let location = asset.location {
                    Section("Location in Photos") {
                        LabeledContent("Coordinates", value: String(format: "%.5f, %.5f", location.coordinate.latitude, location.coordinate.longitude))
                        if location.verticalAccuracy >= 0 { LabeledContent("Altitude", value: String(format: "%.0f m", location.altitude)) }
                    }
                }
                if let details {
                    Section("Camera and exposure") {
                        if details.camera.isEmpty { Text("No camera or exposure information in the original.").foregroundStyle(.secondary) }
                        fields(details.camera)
                    }
                    if !details.image.isEmpty { Section("Original image") { fields(details.image) } }
                    if !details.captions.isEmpty { Section("Caption and attribution") { fields(details.captions) } }
                    if let location = details.originalLocation { Section("Location in original file") { LabeledContent("Coordinates", value: location) } }
                }
                if loading { Section { ProgressView("Reading original metadata…") } }
                if let error {
                    Section("Original metadata unavailable") {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button(allowDownload ? "Retry metadata" : "Download original metadata") { allowDownload = true; retry += 1 }
                            .disabled(loading)
                    }
                }
                Section {
                    Text("Only available metadata is shown. Photos dates and location can differ from original EXIF. Location stays on your device; no map or address service is contacted.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if asset.mediaSubtypes.contains(.photoLive) { Text("Original photo size excludes the paired Live Photo video.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Photo information").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle).accessibilityLabel("Done") }.sharedBackgroundVisibility(.hidden) }
            .buttonStyle(PhotoActionStyle()).textSelection(.enabled)
            .task {
                image = library.cachedPreview(asset)
                if image == nil { image = try? await library.preview(asset, size: CGSize(width: 600, height: 600)) }
            }
            .task(id: "\(allowDownload)-\(retry)") {
                loading = true; error = nil
                defer { loading = false }
                do { details = try await library.fileInformation(asset, allowDownload: allowDownload) }
                catch is CancellationError { }
                catch {
                    if !Task.isCancelled {
                        self.error = allowDownload ? error.localizedDescription : "The original could not be read locally. Download its original metadata to try again."
                    }
                }
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func fields(_ fields: [PhotoInfoField]) -> some View {
        ForEach(fields) { field in LabeledContent(field.title, value: field.value) }
    }
}

private extension PHAssetResource {
    var displayFilename: String {
        if #available(iOS 27, *) { filename ?? "Photo" } else { originalFilename }
    }
}
