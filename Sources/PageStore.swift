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
        // The page files are the truth and the index only orders them. An
        // unreadable index, or one written by a failed save, must not decide
        // that the pages beside it do not exist — the next write would then
        // replace it and orphan every one of them.
        let listed = Self.pageIDsOnDisk()
        var saved: [String] = []
        if let data = try? Data(contentsOf: Self.indexFile) {
            do {
                saved = try JSONDecoder().decode([String].self, from: data)
            } catch {
                NSLog("hitsudan: index.json is unreadable (\(error)); rebuilding it from the page files")
                Self.keepCopy(of: Self.indexFile)
            }
        }
        // A folder that cannot be listed says nothing about which pages exist,
        // so fall back to asking for each one and leave the assets alone.
        let onDisk = listed ?? Set(saved.filter { fm.fileExists(atPath: Self.file(for: $0).path) })
        // Ids only resolve to the second, so pages made in the same second are
        // put back in order by when the page itself says it was created.
        let created = { (id: String) in self.load(id)?.created ?? .distantFuture }
        let missing = onDisk.subtracting(saved).map { (id: $0, created: created($0)) }
            .sorted { ($0.created, $0.id) < ($1.created, $1.id) }.map(\.id)
        // An id listed twice would show one page twice, and deleting it would
        // leave the other entry pointing at nothing; the first place wins.
        var seen = Set<String>()
        order = saved.filter { onDisk.contains($0) && seen.insert($0).inserted } + missing
        if order.isEmpty { _ = appendPage() } else if order != saved { writeIndex() }
        current = max(order.count - 1, 0)
        if listed != nil { pruneAssets() }
    }

    private static func file(for id: String) -> URL {
        root.appendingPathComponent("\(id).json")
    }

    private static func backgroundFile(for id: String) -> URL {
        assets.appendingPathComponent("\(id).png")
    }

    private static func pageIDsOnDisk() -> Set<String>? {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: root.path) } catch {
            NSLog("hitsudan: could not list the pages folder: \(error)")
            return nil
        }
        return Set(names.filter { $0.hasSuffix(".json") && $0 != indexFile.lastPathComponent }
            .map { String($0.dropLast(".json".count)) })
    }

    /// Set a file that could not be read aside before anything overwrites it,
    /// so what was in it can still be recovered by hand.
    private static func keepCopy(of url: URL) {
        let fm = FileManager.default
        var copy = url.appendingPathExtension("broken")
        if fm.fileExists(atPath: copy.path) {
            // The same damage is met again on every save until it is replaced;
            // only a different breakage is worth another copy.
            if fm.contentsEqual(atPath: copy.path, andPath: url.path) { return }
            copy = url.appendingPathExtension("\(Int(Date().timeIntervalSince1970)).broken")
        }
        do { try fm.copyItem(at: url, to: copy) } catch {
            NSLog("hitsudan: could not keep a copy of \(url.lastPathComponent): \(error)")
        }
    }

    /// Atomic, so a crash or a full disk mid-write leaves the previous version
    /// rather than a truncated file.
    private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("hitsudan: could not write \(url.lastPathComponent): \(error)")
            return false
        }
    }

    private func writeIndex() {
        let data: Data
        do { data = try JSONEncoder().encode(order) } catch {
            NSLog("hitsudan: could not encode the page index: \(error)")
            return
        }
        _ = Self.write(data, to: Self.indexFile)
    }

    /// Underlays of pages that no longer exist — deleted before assets were
    /// cleaned up with them, or left by a scratch page.
    private func pruneAssets() {
        let fm = FileManager.default
        let keep = Set(order.map { "\($0).png" })
        for name in (try? fm.contentsOfDirectory(atPath: Self.assets.path)) ?? [] where !keep.contains(name) {
            do { try fm.removeItem(at: Self.assets.appendingPathComponent(name)) } catch {
                NSLog("hitsudan: could not remove stale asset \(name): \(error)")
            }
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
        let url = Self.file(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(PageData.self, from: data)
        } catch {
            NSLog("hitsudan: page \(id) is unreadable: \(error)")
            Self.keepCopy(of: url)
            return nil
        }
    }

    /// `false` when the page did not reach the disk.
    @discardableResult
    func save(_ page: PageData) -> Bool {
        var copy = page
        copy.updated = Date()
        guard let data = try? JSONEncoder().encode(copy) else { return false }
        return Self.write(data, to: Self.file(for: page.id))
    }

    /// `false` when the page file could not be removed; the page is then kept,
    /// since it would come back on the next launch without its underlay.
    @discardableResult
    func delete(_ id: String) -> Bool {
        let url = Self.file(for: id)
        do { try FileManager.default.removeItem(at: url) } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                NSLog("hitsudan: could not delete page \(id): \(error)")
                return false
            }
        }
        removeBackground(for: id)
        // Every occurrence: an index that lists an id twice would otherwise
        // keep a page whose file is gone.
        // Removing a page in front of the open one shifts it down; without
        // this, sweeping out pages lands you on a different page.
        current -= order.indices.filter { order[$0] == id && $0 < current }.count
        order.removeAll { $0 == id }
        if order.isEmpty { _ = appendPage() }
        current = min(current, order.count - 1)
        writeIndex()
        return true
    }

    func go(to index: Int) { current = min(max(index, 0), order.count - 1) }

    /// Underlays live beside the pages so a reopened page still has its backdrop.
    /// `nil` when the file could not be written.
    func storeBackground(_ png: Data, for id: String) -> String? {
        let url = Self.backgroundFile(for: id)
        return Self.write(png, to: url) ? url.lastPathComponent : nil
    }

    func removeBackground(for id: String) {
        let url = Self.backgroundFile(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) } catch {
            NSLog("hitsudan: could not remove \(url.lastPathComponent): \(error)")
        }
    }

    func background(named name: String) -> CGImage? {
        guard let image = NSImage(contentsOf: Self.assets.appendingPathComponent(name)) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
