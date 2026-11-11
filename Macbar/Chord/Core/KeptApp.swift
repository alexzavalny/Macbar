import Foundation

/// An app whose windows are never hidden.
public struct KeptApp: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var appPath: String

    public init(bundleID: String, appName: String, appPath: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.appPath = appPath
    }
}

/// The never-hide list as stored in UserDefaults.
public enum KeptAppList {
    public static func decode(_ json: String) -> [KeptApp]? {
        JSONList.decode(json, as: KeptApp.self)
    }

    public static func encode(_ list: [KeptApp]) -> String {
        JSONList.encode(list)
    }
}

extension Array where Element == KeptApp {
    /// Adds `app`, replacing any entry for the same bundle ID. Sorted by name.
    public func adding(_ app: KeptApp) -> [KeptApp] {
        (removing(bundleID: app.bundleID) + [app])
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    public func removing(bundleID: String) -> [KeptApp] {
        filter { $0.bundleID != bundleID }
    }
}
