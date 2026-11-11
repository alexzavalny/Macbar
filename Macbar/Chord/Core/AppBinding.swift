import Foundation

/// A trigger key bound to an app.
public struct AppBinding: Codable, Hashable, Sendable {
    public var key: TriggerKey
    public var bundleID: String
    public var appName: String
    public var appPath: String

    public init(key: TriggerKey, bundleID: String, appName: String, appPath: String) {
        self.key = key
        self.bundleID = bundleID
        self.appName = appName
        self.appPath = appPath
    }
}

extension Array where Element == AppBinding {
    /// Adds `binding`, replacing any binding for the same key. Sorted by key.
    public func setting(_ binding: AppBinding) -> [AppBinding] {
        (removing(binding.key) + [binding]).sorted { $0.key < $1.key }
    }

    public func removing(_ key: TriggerKey) -> [AppBinding] {
        filter { $0.key != key }
    }

    public func binding(for key: TriggerKey) -> AppBinding? {
        first { $0.key == key }
    }
}

/// Bindings as stored in UserDefaults: a JSON string, so they can be seeded with `defaults write`.
public enum BindingList {
    /// nil when `json` is not a list; callers then leave the stored value alone. Entries that
    /// can't be read (such as digit keys, bindable in earlier versions) are skipped.
    public static func decode(_ json: String) -> [AppBinding]? {
        JSONList.decode(json, as: AppBinding.self)
    }

    public static func encode(_ list: [AppBinding]) -> String {
        JSONList.encode(list)
    }
}

public enum AppLocation {
    /// The app to open: the stored path if it still exists, else wherever the bundle ID is installed now.
    public static func resolve(_ binding: AppBinding, fileExists: (String) -> Bool, lookup: (String) -> URL?) -> URL? {
        if fileExists(binding.appPath) { return URL(fileURLWithPath: binding.appPath) }
        return lookup(binding.bundleID)
    }
}
