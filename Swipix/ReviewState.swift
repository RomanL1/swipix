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

@MainActor @Observable final class ReviewStore {
    private let context: ModelContext
    private var records: [String: ReviewRecord] = [:]
    private var session: ReviewSession
    private(set) var ledger = ReviewLedger()
    private(set) var lastDecision: String?
    var binIDs: [String] {
        records.values.filter { $0.choice == ReviewChoice.bin.rawValue }
            .sorted { $0.date > $1.date }.map(\.assetID)
    }
    var shuffleSeed: String { session.shuffleSeed }
    var reviewedCount: Int { ledger.decisions.count }

    init(container: ModelContainer) throws {
        context = ModelContext(container)
        context.autosaveEnabled = false
        session = try context.fetch(FetchDescriptor<ReviewSession>()).first ?? ReviewSession()
        if session.modelContext == nil { context.insert(session) }
        if session.shuffleSeed.isEmpty { session.shuffleSeed = UUID().uuidString }
        try context.save()
        for record in try context.fetch(FetchDescriptor<ReviewRecord>()) {
            guard let choice = ReviewChoice(rawValue: record.choice) else { continue }
            records[record.assetID] = record
            ledger.decide(record.assetID, choice)
        }
        ledger.currentID = session.currentID
    }
    func setCurrent(_ id: String?) throws {
        guard session.currentID != id else { return }
        session.currentID = id
        do { try context.save(); ledger.currentID = id }
        catch { context.rollback(); throw error }
    }
    func decide(_ id: String, _ choice: ReviewChoice) throws {
        guard ledger.decisions[id] == nil else { return }
        let record = ReviewRecord(assetID: id, choice: choice)
        context.insert(record)
        do { try context.save() }
        catch { context.rollback(); throw error }
        records[id] = record; ledger.decide(id, choice); lastDecision = id
    }
    func restore(_ ids: Set<String>) throws {
        for id in ids { if let record = records[id] { context.delete(record) } }
        do { try context.save() }
        catch { context.rollback(); throw error }
        ids.forEach { records.removeValue(forKey: $0) }
        ledger.restore(ids)
        if let lastDecision, ids.contains(lastDecision) { self.lastDecision = nil }
    }
    func undo() throws {
        guard let id = lastDecision else { return }
        try restore([id]); try setCurrent(id)
    }
}
