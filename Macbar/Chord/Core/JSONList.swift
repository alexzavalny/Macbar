import Foundation

/// Lists stored in UserDefaults as JSON strings, so they can be seeded with `defaults write`.
enum JSONList {
    /// nil when `json` is not a list. Entries that can't be read are skipped.
    static func decode<T: Decodable>(_ json: String, as type: T.Type) -> [T]? {
        (try? JSONDecoder().decode([Entry<T>].self, from: Data(json.utf8)))?.compactMap(\.value)
    }

    static func encode<T: Encodable>(_ list: [T]) -> String {
        let data = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private struct Entry<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) {
            value = try? T(from: decoder)
        }
    }
}
