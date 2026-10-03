import Photos
import UIKit
import Observation
import UniformTypeIdentifiers

struct PhotoFailure: LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// Cancellation can race a synchronous PhotoKit completion or request-ID assignment.
private final class ImageRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var requestID: PHImageRequestID?
    private let manager: PHImageManager
    init(manager: PHImageManager) { self.manager = manager }
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func setID(_ id: PHImageRequestID) {
        lock.lock(); requestID = id
        let cancelled = result.map { if case .failure(let error) = $0 { return error is CancellationError }; return false } ?? false
        lock.unlock()
        if cancelled { manager.cancelImageRequest(id) }
    }
    func finish(_ value: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let continuation = continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: value)
    }
    func cancel() {
        finish(.failure(CancellationError()))
        lock.lock(); let id = requestID; lock.unlock()
        if let id { manager.cancelImageRequest(id) }
    }
}

@MainActor @Observable final class PhotoLibraryService: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets: [PHAsset] = []
    private(set) var revision = 0
    private var observing = false
    private var byID: [String: PHAsset] = [:]
    private let manager = PHCachingImageManager()
    private var cached: [PHAsset] = []
    private var cacheSize = CGSize.zero
    private var warmed: [String: UIImage] = [:]
    private var warming: [String: Task<UIImage, Error>] = [:]
    private var previewOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }
    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    override init() {
        super.init()
    }
    isolated deinit { if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) } }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.refresh() }
    }
    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        refresh()
    }
    func refresh() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        manager.stopCachingImagesForAllAssets(); cached = []
        warming.values.forEach { $0.cancel() }; warming = [:]; warmed = [:]
        guard hasAccess else {
            if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self); observing = false }
            assets = []; byID = [:]; revision += 1; return
        }
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var fetched: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in fetched.append(asset) }
        assets = fetched; byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.localIdentifier, $0) })
        revision += 1
    }
    func asset(_ id: String) -> PHAsset? { byID[id] }
    func prefetch(_ upcoming: [PHAsset], size: CGSize) {
        let next = Array(upcoming.prefix(6))
        guard cached.map(\.localIdentifier) != next.map(\.localIdentifier) || cacheSize != size else { return }
        manager.stopCachingImages(for: cached, targetSize: cacheSize, contentMode: .aspectFit, options: previewOptions)
        if cacheSize != size {
            warming.values.forEach { $0.cancel() }; warming = [:]; warmed = [:]
        }
        let ids = Set(next.map(\.localIdentifier))
        for id in Array(warming.keys) where !ids.contains(id) { warming.removeValue(forKey: id)?.cancel() }
        warmed = warmed.filter { ids.contains($0.key) }
        cached = next; cacheSize = size
        for asset in next where warmed[asset.localIdentifier] == nil && warming[asset.localIdentifier] == nil {
            let id = asset.localIdentifier
            warming[id] = Task { [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    let image = try await self.requestPreview(asset, size: size)
                    try Task.checkCancellation()
                    if self.cacheSize == size && self.cached.contains(where: { $0.localIdentifier == id }) { self.warmed[id] = image }
                    return image
                } catch { throw error }
            }
        }
        manager.startCachingImages(for: next, targetSize: size, contentMode: .aspectFit, options: previewOptions)
    }
    func cachedPreview(_ asset: PHAsset, size: CGSize? = nil) -> UIImage? {
        guard size == nil || size == cacheSize else { return nil }
        return warmed[asset.localIdentifier]
    }
    func preview(_ asset: PHAsset, size: CGSize) async throws -> UIImage {
        if size == cacheSize {
            if let image = warmed[asset.localIdentifier] { return image }
            if let task = warming[asset.localIdentifier] {
                let image = try await task.value
                try Task.checkCancellation()
                return image
            }
        }
        return try await requestPreview(asset, size: size)
    }
    func prepareNext(after id: String) async {
        guard let index = cached.firstIndex(where: { $0.localIdentifier == id }), cached.indices.contains(index + 1) else { return }
        // Keep the current card visible while an iCloud preview finishes downloading.
        _ = try? await warming[cached[index + 1].localIdentifier]?.value
    }
    func retryPreview(_ asset: PHAsset) {
        warming.removeValue(forKey: asset.localIdentifier)?.cancel()
        warmed.removeValue(forKey: asset.localIdentifier)
    }
    private func requestPreview(_ asset: PHAsset, size: CGSize) async throws -> UIImage {
        let request = ImageRequest<UIImage>(manager: manager)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                let options = previewOptions
                let id = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { @Sendable image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { request.finish(.failure(CancellationError())) }
                    else if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)) }
                    else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                        if let image { request.finish(.success(image)) }
                        else { request.finish(.failure(PhotoFailure(message: "Preview unavailable. Check iCloud connectivity or choose another photo."))) }
                    }
                }
                request.setID(id)
            }
        } onCancel: { request.cancel() }
    }
    func livePreview(_ asset: PHAsset) async throws -> PHLivePhoto {
        let request = ImageRequest<PHLivePhoto>(manager: manager)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                let options = PHLivePhotoRequestOptions()
                options.deliveryMode = .highQualityFormat; options.isNetworkAccessAllowed = true
                let id = manager.requestLivePhoto(for: asset, targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit, options: options) { @Sendable photo, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true { request.finish(.failure(CancellationError())) }
                    else if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)) }
                    else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                        if let photo { request.finish(.success(photo)) }
                        else { request.finish(.failure(PhotoFailure(message: "Live Photo is unavailable."))) }
                    }
                }
                request.setID(id)
            }
        } onCancel: { request.cancel() }
    }
    /// Public PhotoKit has no file-size property. Count local resource bytes without retaining them or downloading an original.
    func localSize(_ asset: PHAsset) async -> String {
        let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .pairedVideo }
        guard !resources.isEmpty else { return "Original size unavailable" }
        var total: Int64 = 0
        for resource in resources {
            guard !Task.isCancelled else { return "Original size unavailable" }
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
            let counter = ResourceByteCounter()
            let success = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let id = PHAssetResourceManager.default().requestData(for: resource, options: options,
                        dataReceivedHandler: { @Sendable data in counter.add(data.count) },
                        completionHandler: { @Sendable error in continuation.resume(returning: error == nil) })
                    counter.setID(id)
                }
            } onCancel: { counter.cancel() }
            guard success else { return "Original size unavailable · iCloud" }
            total += counter.value
        }
        let formatted = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(formatted) original\(asset.mediaSubtypes.contains(.photoLive) ? " · photo + video" : "")"
    }
    func delete(ids: Set<String>) async throws -> Set<String> {
        guard hasAccess else { throw PhotoFailure(message: "Photos access was revoked. Nothing was deleted.") }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var resolved: Set<String> = []
        fetched.enumerateObjects { asset, _, _ in resolved.insert(asset.localIdentifier) }
        guard resolved == ids else {
            refresh()
            throw PhotoFailure(message: "Some selected photos are no longer accessible. Refresh your Photos selection and try again. Nothing was deleted.")
        }
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest.deleteAssets(fetched)
        }
        refresh()
        let remaining = ids.filter { byID[$0] != nil }
        if !remaining.isEmpty { throw PhotoFailure(message: "Photos still reports \(remaining.count) selected items. They remain in the Bin; check Photos before retrying.") }
        return resolved
    }
    func exportOriginal(_ asset: PHAsset, to url: URL) async throws -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo }) else {
            throw PhotoFailure(message: "This photo does not have an accessible original image resource.")
        }
        let type = UTType(resource.uniformTypeIdentifier)
        guard type?.conforms(to: .rawImage) != true else {
            throw PhotoFailure(message: "RAW and ProRAW originals are protected. Compression of RAW derivatives is not supported in this version.")
        }
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        try Task.checkCancellation()
        return resource.uniformTypeIdentifier
    }
    func saveCopy(_ result: CompressionResult, from asset: PHAsset) async throws {
        guard hasAccess, self.asset(asset.localIdentifier) != nil else {
            throw PhotoFailure(message: "The source photo is no longer accessible. Restore Photos access before saving.")
        }
        let date = asset.creationDate, location = asset.location
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = date; request.location = location
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "Swipix-\(UUID().uuidString).\(result.fileExtension)"
            request.addResource(with: .photo, fileURL: result.outputURL, options: options)
        }
        refresh()
    }
}

private final class ResourceByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelled = false
    func setID(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); requestID = id; let cancelNow = cancelled; lock.unlock()
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = requestID; lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func add(_ bytes: Int) { lock.lock(); count += Int64(bytes); lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return count }
}
