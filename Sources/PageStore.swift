import AppKit

/// Pages are kept as the strokes themselves, not as flattened images — a page
/// you reopen has to stay erasable and addable, and a PNG cannot be un-drawn.
struct StoredPoint: Codable {
    var x: Double, y: Double, w: Double
}

struct StoredStroke: Codable {
    var r: Double, g: Double, b: Double, a: Double
    var erase: Bool
    var points: [StoredPoint]
}

struct PageData: Codable {
    var id: String
    var created: Date
    var updated: Date
    var strokes: [StoredStroke]
    /// File name of the underlay inside `assets/`, when the page has one.
    var background: String?
}

/// A flat notebook on disk: one JSON per page, plus an ordered index.
final class PageStore {

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hitsudan/pages", isDirectory: true)
    static let assets = root.appendingPathComponent("assets", isDirectory: true)
    private static let indexFile = root.appendingPathComponent("index.json")

    private(set) var order: [String] = []
    private(set) var current = 0

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.assets, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.indexFile),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            order = saved.filter { fm.fileExists(atPath: Self.file(for: $0).path) }
        }
        if order.isEmpty { _ = appendPage() }
        current = max(order.count - 1, 0)
    }

    private static func file(for id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    private func writeIndex() {
        if let data = try? JSONEncoder().encode(order) {
            try? data.write(to: Self.indexFile)
        }
    }

    var count: Int { order.count }
    var currentID: String? { order.indices.contains(current) ? order[current] : nil }

    @discardableResult
    func appendPage() -> String {
        let id = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-") + "-" + String(UUID().uuidString.prefix(4))
        let page = PageData(id: id, created: Date(), updated: Date(), strokes: [], background: nil)
        save(page)
        order.append(id)
        writeIndex()
        return id
    }

    func load(_ id: String) -> PageData? {
        guard let data = try? Data(contentsOf: Self.file(for: id)) else { return nil }
        return try? JSONDecoder().decode(PageData.self, from: data)
    }

    func save(_ page: PageData) {
        var copy = page
        copy.updated = Date()
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(copy) {
            try? data.write(to: Self.file(for: page.id))
        }
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: Self.file(for: id))
        order.removeAll { $0 == id }
        if order.isEmpty { _ = appendPage() }
        current = min(current, order.count - 1)
        writeIndex()
    }

    func go(to index: Int) { current = min(max(index, 0), order.count - 1) }

    /// Underlays live beside the pages so a reopened page still has its backdrop.
    func storeBackground(_ png: Data, for id: String) -> String {
        let name = "\(id).png"
        try? png.write(to: Self.assets.appendingPathComponent(name))
        return name
    }

    func background(named name: String) -> CGImage? {
        guard let image = NSImage(contentsOf: Self.assets.appendingPathComponent(name)) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
