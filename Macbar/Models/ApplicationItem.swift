import AppKit

struct ApplicationItem: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let icon: NSImage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.url == rhs.url }

    static func matches(_ name: String, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy {
            name.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

struct ApplicationSearchSelection {
    private(set) var selectedID: String?

    mutating func reset(in results: [ApplicationItem]) {
        selectedID = results.first?.id
    }

    mutating func reconcile(_ results: [ApplicationItem]) {
        if !results.contains(where: { $0.id == selectedID }) { reset(in: results) }
    }

    mutating func move(by offset: Int, in results: [ApplicationItem]) {
        guard !results.isEmpty else { selectedID = nil; return }
        guard let index = results.firstIndex(where: { $0.id == selectedID }) else {
            reset(in: results)
            return
        }
        selectedID = results[min(max(index + offset, 0), results.count - 1)].id
    }

    func selected(in results: [ApplicationItem]) -> ApplicationItem? {
        results.first(where: { $0.id == selectedID }) ?? results.first
    }
}
