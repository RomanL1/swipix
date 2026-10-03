import SwiftUI
import Photos
import SwiftData
import Observation

enum PhotoSheet: Identifiable {
    case compression(PHAsset), info(PHAsset)
    var id: String {
        switch self {
        case .compression(let asset): "compression-" + asset.localIdentifier
        case .info(let asset): "info-" + asset.localIdentifier
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
    private var orderedIDs: [String] = []
    private var orderedRevision = -1
    var current: PHAsset? { store.ledger.next(in: orderedIDs).flatMap(library.asset) }
    var remaining: [PHAsset] { orderedIDs.filter { store.ledger.decisions[$0] == nil }.compactMap(library.asset) }
    var upcoming: [PHAsset] {
        guard let current else { return remaining }
        return [current] + remaining.filter { $0.localIdentifier != current.localIdentifier }
    }
    var binAssets: [PHAsset] { store.binIDs.compactMap(library.asset) }
    var unavailableBinCount: Int { store.binIDs.count - binAssets.count }
    init(container: ModelContainer) throws { store = try ReviewStore(container: container) }
    func reconcile() {
        if orderedRevision != library.revision {
            orderedIDs = ReviewOrder.randomized(library.assets.map(\.localIdentifier), seed: store.shuffleSeed)
            orderedRevision = library.revision
        }
        do { try store.setCurrent(current?.localIdentifier) } catch { self.error = error.localizedDescription }
    }
    func decide(_ asset: PHAsset, _ choice: ReviewChoice) {
        guard !deleting, current?.localIdentifier == asset.localIdentifier else { return }
        do { try store.decide(asset.localIdentifier, choice); reconcile() }
        catch { self.error = "The decision was not saved: \(error.localizedDescription)" }
    }
    func restore(_ ids: Set<String>) {
        do { try store.restore(ids); reconcile() } catch { self.error = error.localizedDescription }
    }
    func undo() {
        do { try store.undo() } catch { self.error = error.localizedDescription }
    }
    func delete(_ ids: Set<String>) async {
        guard !deleting, !ids.isEmpty else { return }
        guard ids.isSubset(of: Set(store.binIDs)) else {
            error = "The Bin selection changed. Select the photos again before deleting. Nothing was deleted."
            return
        }
        deleting = true; defer { deleting = false }
        do {
            let deleted = try await library.delete(ids: ids)
            do { try store.restore(deleted) }
            catch { throw PhotoFailure(message: "Photos deleted the selected items, but local state could not be updated. Their unavailable Bin entries remain until you dismiss them. \(error.localizedDescription)") }
            reconcile()
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
