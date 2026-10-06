import Foundation
import SwiftData
import Observation
import CryptoKit

enum ReviewOrder {
    static func randomized(_ ids: [String], seed: String) -> [String] {
        let ranked = ids.map { ($0, Array(SHA256.hash(data: Data((seed + ":" + $0).utf8)))) }
        return ranked.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
    }
}

enum ReviewChoice: String, Codable, Sendable { case keep, bin }

/// Pure transition logic; unknown identifiers remain recorded when Photos access narrows.
struct ReviewLedger: Sendable {
    private(set) var decisions: [String: ReviewChoice] = [:]
    var currentID: String?

    @discardableResult mutating func decide(_ id: String, _ choice: ReviewChoice) -> Bool {
        guard decisions[id] == nil else { return false }
        decisions[id] = choice
        return true
    }
    mutating func recordReplacement(original: String, compressed: String) {
        decisions[original] = .bin; decisions[compressed] = .keep
    }
    mutating func restore(_ ids: Set<String>) { ids.forEach { decisions.removeValue(forKey: $0) } }
    func next(in accessible: [String]) -> String? {
        if let currentID, accessible.contains(currentID), decisions[currentID] == nil { return currentID }
        return accessible.first { decisions[$0] == nil }
    }
}

@Model final class ReviewRecord {
    @Attribute(.unique) var assetID: String
    var choice: String
    var date: Date
    init(assetID: String, choice: ReviewChoice) {
        self.assetID = assetID; self.choice = choice.rawValue; date = .now
    }
}

@Model final class ReviewSession {
    @Attribute(.unique) var key: String
    var currentID: String?
    var shuffleSeed: String = ""
    init() { key = "main" }
}

/// Owns its context on a background executor; persistent models never cross actors.
private actor ReviewPersistence {
    private nonisolated let queue = DispatchSerialQueue(label: "com.swipix.review-persistence", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private let container: ModelContainer
    private lazy var modelContext: ModelContext = {
        assert(!Thread.isMainThread, "Create the review context off the UI thread")
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }()
    init(container: ModelContainer) { self.container = container }
    private func record(_ id: String) throws -> ReviewRecord? {
        var descriptor = FetchDescriptor<ReviewRecord>(predicate: #Predicate { $0.assetID == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
    private func session() throws -> ReviewSession {
        guard let session = try modelContext.fetch(FetchDescriptor<ReviewSession>()).first else {
            throw PhotoFailure(message: "Review history is unavailable. Reopen Swipix before continuing.")
        }
        return session
    }
    private func save() throws {
        assert(!Thread.isMainThread, "Review writes must stay off the UI thread")
        modelContext.autosaveEnabled = false
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
    }
    func setCurrent(_ id: String?) throws {
        let session = try session()
        guard session.currentID != id else { return }
        session.currentID = id
        try save()
    }
    func decide(_ id: String, _ choice: ReviewChoice, currentID: String?) throws {
        guard try record(id) == nil else { return }
        let session = try session()
        modelContext.insert(ReviewRecord(assetID: id, choice: choice))
        session.currentID = currentID
        try save()
    }
    func recordReplacement(original: String, compressed: String) throws {
        let source = try record(original) ?? ReviewRecord(assetID: original, choice: .bin)
        let replacement = try record(compressed) ?? ReviewRecord(assetID: compressed, choice: .keep)
        if source.modelContext == nil { modelContext.insert(source) }
        if replacement.modelContext == nil { modelContext.insert(replacement) }
        source.choice = ReviewChoice.bin.rawValue; source.date = .now
        replacement.choice = ReviewChoice.keep.rawValue
        try save()
    }
    func restore(_ ids: Set<String>, currentID: String? = nil) throws {
        let records = try ids.compactMap { try record($0) }
        let session = try session()
        records.forEach { modelContext.delete($0) }
        if let currentID { session.currentID = currentID }
        try save()
    }
}

@MainActor @Observable final class ReviewStore {
    private let persistence: ReviewPersistence
    // Serialize writes and their UI publication, including actions from different screens.
    @ObservationIgnored private var pending: Task<Void, Never>?
    private(set) var ledger = ReviewLedger()
    private(set) var lastDecision: String?
    let shuffleSeed: String
    private(set) var binIDs: [String] = []
    private(set) var decisionsRevision = 0
    var reviewedCount: Int { ledger.decisions.count }

    init(container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let session = try context.fetch(FetchDescriptor<ReviewSession>()).first ?? ReviewSession()
        if session.modelContext == nil { context.insert(session) }
        if session.shuffleSeed.isEmpty { session.shuffleSeed = UUID().uuidString }
        try context.save()
        shuffleSeed = session.shuffleSeed
        persistence = ReviewPersistence(container: container)
        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        binIDs = records.filter { $0.choice == ReviewChoice.bin.rawValue }.sorted { $0.date > $1.date }.map(\.assetID)
        for record in records {
            guard let choice = ReviewChoice(rawValue: record.choice) else { continue }
            ledger.decide(record.assetID, choice)
        }
        ledger.currentID = session.currentID
    }
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = pending
        let next = Task { await previous?.value; try await operation() }
        pending = Task { _ = try? await next.value }
        try await next.value
    }
    func setCurrent(_ id: String?) async throws {
        try await enqueue {
            guard self.ledger.currentID != id else { return }
            if let id, self.ledger.decisions[id] != nil { return }
            try await self.persistence.setCurrent(id)
            self.ledger.currentID = id
        }
    }
    func decide(_ id: String, _ choice: ReviewChoice, currentID: String? = nil) async throws {
        try await enqueue {
            guard self.ledger.decisions[id] == nil else { return }
            try await self.persistence.decide(id, choice, currentID: currentID)
            if choice == .bin { self.binIDs.insert(id, at: 0) }
            self.decisionsRevision += 1
            self.ledger.decide(id, choice); self.ledger.currentID = currentID; self.lastDecision = id
        }
    }
    func recordReplacement(original: String, compressed: String) async throws {
        try await enqueue {
            guard original != compressed, !compressed.isEmpty else { throw PhotoFailure(message: "Photos returned an invalid replacement identifier. The original is unchanged.") }
            try await self.persistence.recordReplacement(original: original, compressed: compressed)
            self.binIDs.removeAll { $0 == original || $0 == compressed }
            self.binIDs.insert(original, at: 0)
            self.decisionsRevision += 1
            self.ledger.recordReplacement(original: original, compressed: compressed)
            self.lastDecision = nil
        }
    }
    func restore(_ ids: Set<String>) async throws {
        try await enqueue {
            try await self.persistence.restore(ids)
            self.binIDs.removeAll { ids.contains($0) }
            self.decisionsRevision += 1
            self.ledger.restore(ids)
            if let lastDecision = self.lastDecision, ids.contains(lastDecision) { self.lastDecision = nil }
        }
    }
    func undo() async throws {
        try await enqueue {
            guard let id = self.lastDecision else { return }
            try await self.persistence.restore([id], currentID: id)
            self.binIDs.removeAll { $0 == id }; self.ledger.restore([id])
            self.decisionsRevision += 1
            self.ledger.currentID = id; self.lastDecision = nil
        }
    }
}
