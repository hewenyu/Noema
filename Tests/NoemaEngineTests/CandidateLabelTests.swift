import Darwin
@testable import NoemaEngine
import Testing

/// `RimeEngine.candidateLabel` over hand-built C label arrays: the `page_size` bound is
/// checked without librime, since real librime never reports more candidates than slots.
@Suite struct CandidateLabelTests {
    /// A C `char**` holding `slots`; nil entries stay NULL. Freed by `body`'s caller.
    static func withLabels<T>(_ slots: [String?], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: slots.count)
        for (index, slot) in slots.enumerated() { array[index] = slot.flatMap { strdup($0) } }
        defer {
            for index in slots.indices { free(array[index]) }
            array.deallocate()
        }
        return body(array)
    }

    @Test func readsOnlyTheFirstPageSizeSlots() {
        // Slots 2 and 3 exist in memory but lie past page_size 2: they must never be read.
        Self.withLabels(["甲", "乙", "TRAP", "TRAP"]) { labels in
            let read = (0..<4).map { RimeEngine.candidateLabel(at: $0, selectLabels: labels, pageSize: 2, selectKeys: []) }
            #expect(read == ["甲", "乙", "3", "4"])
        }
    }

    @Test func clampsANegativePageSizeAndIndex() {
        Self.withLabels(["TRAP"]) { labels in
            #expect(RimeEngine.candidateLabel(at: 0, selectLabels: labels, pageSize: -1, selectKeys: []) == "1")
            #expect(RimeEngine.candidateLabel(at: -1, selectLabels: labels, pageSize: 1, selectKeys: []) == "0")
        }
    }

    @Test func nullSlotsFallBackToSelectKeysThenNumbers() {
        Self.withLabels(["甲", nil, nil]) { labels in
            let read = (0..<3).map { RimeEngine.candidateLabel(at: $0, selectLabels: labels, pageSize: 3, selectKeys: ["a", "s"]) }
            #expect(read == ["甲", "s", "3"])
        }
        #expect(RimeEngine.candidateLabel(at: 9, selectLabels: nil, pageSize: 10, selectKeys: []) == "0")
        #expect(RimeEngine.candidateLabel(at: 0, selectLabels: nil, pageSize: 5, selectKeys: []) == "1")
    }
}
