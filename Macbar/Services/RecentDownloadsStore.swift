import Foundation
import Combine

struct RecentDownload: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let date: Date
    let byteCount: Int64
    var id: URL { url }

    static func scan(directory: URL, limit: Int = 4) throws -> [RecentDownload] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .localizedNameKey,
            .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let incompleteExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp"]
        let files = urls.compactMap { url -> RecentDownload? in
            guard !incompleteExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true, values.isHidden != true else { return nil }
            return RecentDownload(url: url, name: values.localizedName ?? url.lastPathComponent,
                date: values.addedToDirectoryDate ?? values.creationDate ?? values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0))
        }
        return newest(files, limit: limit)
    }

    static func newest(_ files: [RecentDownload], limit: Int) -> [RecentDownload] {
        Array(files.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.url.path < $1.url.path
        }.prefix(max(0, limit)))
    }
}

@MainActor
final class RecentDownloadsStore: ObservableObject {
    @Published private(set) var files: [RecentDownload] = []
    @Published private(set) var isLoading = true
    @Published private(set) var error: String?
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.directory = directory
    }

    func refresh() async {
        isLoading = true
        error = nil
        let directory = directory
        let result = await Task.detached(priority: .userInitiated) {
            Result { try RecentDownload.scan(directory: directory) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let files): self.files = files
        case .failure:
            files = []
            error = "Downloads couldn’t be read. You can still open the folder in Finder."
        }
        isLoading = false
    }
}
