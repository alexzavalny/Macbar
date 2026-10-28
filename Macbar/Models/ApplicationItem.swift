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
