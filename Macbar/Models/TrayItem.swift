import Foundation

enum TrayItem: String, CaseIterable, Identifiable {
    case aiLimits, inputLanguage, wifi, sound, battery, clock, settings

    var id: String { rawValue }
    var control: TaskbarControl? { TaskbarControl(rawValue: rawValue) }

    static func normalized(_ rawValues: [String]) -> [TrayItem] {
        var seen = Set<TrayItem>()
        return (rawValues.compactMap(TrayItem.init(rawValue:)) + allCases).filter { seen.insert($0).inserted }
    }

    static func moving(_ item: TrayItem, relativeTo target: TrayItem, after: Bool, in items: [TrayItem]) -> [TrayItem] {
        guard item != target, items.contains(item), items.contains(target) else { return items }
        var result = items.filter { $0 != item }
        guard let index = result.firstIndex(of: target) else { return items }
        result.insert(item, at: index + (after ? 1 : 0))
        return result
    }
}
