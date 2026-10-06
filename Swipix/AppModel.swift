import SwiftUI
import Photos
import SwiftData
import Observation

enum PhotoSheet: Identifiable {
    case compression(PHAsset), info(PHAsset), compressionReport(CompressionResult)
    var id: String {
        switch self {
        case .compression(let asset): "compression-" + asset.localIdentifier
        case .info(let asset): "info-" + asset.localIdentifier
        case .compressionReport(let result): "report-" + result.outputURL.path
        }
    }
}

@MainActor @Observable final class AppModel {
    let library = PhotoLibraryService()
    let store: ReviewStore
    let compressor = ImageCompressionService()
    var error: String?
    var deleting = false
    var photoSheet: PhotoSheet?
    var fullscreenAsset: PHAsset?
    var compressionNotice: CompressionResult?
    private var orderedIDs: [String] = []
    private var remainingIDs: [String] = []
    private var orderedRevision = -1
    private var reconciliation = 0
    private(set) var updatingReview = false
    var current: PHAsset? {
        if let id = store.ledger.currentID, store.ledger.decisions[id] == nil, let asset = library.asset(id) { return asset }
        return remainingIDs.first { store.ledger.decisions[$0] == nil }.flatMap(library.asset)
    }
    var remainingCount: Int { remainingIDs.count }
    var upcoming: [PHAsset] {
        guard let current else { return [] }
        return [current] + remainingIDs.lazy.filter { $0 != current.localIdentifier && self.store.ledger.decisions[$0] == nil }
            .prefix(5).compactMap(library.asset)
    }
    var binAssets: [PHAsset] { store.binIDs.compactMap(library.asset) }
    var unavailableBinCount: Int { store.binIDs.count - binAssets.count }
    init(container: ModelContainer) throws { store = try ReviewStore(container: container) }
    func reconcile() async {
        reconciliation += 1
        let request = reconciliation, revision = library.revision
        let needsOrder = orderedRevision != revision
        let ids = needsOrder ? library.assetIDs : orderedIDs
        let seed = store.shuffleSeed, decisions = store.ledger.decisions
        let decisionsRevision = store.decisionsRevision
        let result = await Task.detached(priority: .userInitiated) {
            let ordered = needsOrder ? ReviewOrder.randomized(ids, seed: seed) : ids
            return (ordered, ordered.filter { decisions[$0] == nil })
        }.value
        guard request == reconciliation, revision == library.revision, decisionsRevision == store.decisionsRevision else { return }
        orderedIDs = result.0; remainingIDs = result.1; orderedRevision = revision
        do { try await store.setCurrent(current?.localIdentifier) } catch { self.error = error.localizedDescription }
    }
    func decide(_ asset: PHAsset, _ choice: ReviewChoice) async {
        guard !deleting, !updatingReview, current?.localIdentifier == asset.localIdentifier else { return }
        updatingReview = true
        let next = upcoming.dropFirst().first?.localIdentifier
        do {
            // Save the decision and next cursor in one background transaction.
            try await store.decide(asset.localIdentifier, choice, currentID: next)
            updatingReview = false
            await reconcile()
        } catch {
            updatingReview = false
            self.error = "The decision was not saved: \(error.localizedDescription)"
        }
    }
    func finishCompression(original: PHAsset, compressedID: String, result: CompressionResult) async throws {
        try await store.recordReplacement(original: original.localIdentifier, compressed: compressedID)
        await reconcile()
        compressionNotice = result
    }
    func restore(_ ids: Set<String>) {
        guard !updatingReview, !deleting else { return }
        updatingReview = true
        Task {
            do { try await store.restore(ids) } catch { self.error = error.localizedDescription }
            updatingReview = false
            await reconcile()
        }
    }
    func undo() {
        guard !updatingReview, !deleting else { return }
        updatingReview = true
        Task {
            do { try await store.undo() } catch { self.error = error.localizedDescription }
            updatingReview = false
            await reconcile()
        }
    }
    func delete(_ ids: Set<String>) async {
        guard !deleting, !updatingReview, !ids.isEmpty else { return }
        guard ids.isSubset(of: Set(store.binIDs)) else {
            error = "The Bin selection changed. Select the photos again before deleting. Nothing was deleted."
            return
        }
        deleting = true; defer { deleting = false }
        do {
            let deleted = try await library.delete(ids: ids)
            do { try await store.restore(deleted) }
            catch { throw PhotoFailure(message: "Photos deleted the selected items, but local state could not be updated. Their unavailable Bin entries remain until you dismiss them. \(error.localizedDescription)") }
            await reconcile()
        } catch { self.error = error.localizedDescription }
    }
}

@main struct SwipixApp: App {
    private let model: AppModel?
    private let startupError: String?
    init() {
        do {
            let container = try ModelContainer(for: ReviewRecord.self, ReviewSession.self)
            model = try AppModel(container: container); startupError = nil
        } catch { model = nil; startupError = error.localizedDescription }
    }
    var body: some Scene {
        WindowGroup {
            if let model { RootView(model: model) }
            else {
                ContentUnavailableView("Review history could not open", systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("No photos have been changed. Close and reopen Swipix. \(startupError ?? "")"))
            }
        }
    }
}
