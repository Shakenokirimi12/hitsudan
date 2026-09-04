import AppKit

/// The link between the board and whatever Claude session is talking to
/// `hitsudan-mcp`. A directory of one-shot command files plus a state file the
/// server can read without asking: no sockets, no ports, and either side can
/// restart without the other noticing.
///
///   ~/.hitsudan/inbox/<id>.json    command from the session
///   ~/.hitsudan/outbox/<id>.json   this app's reply
///   ~/.hitsudan/board.png          the sheet, as last published
///   ~/.hitsudan/board.json         { seq, savedAt, note } — seq rises on 送る
///   ~/.hitsudan/state.json         connection and canvas state, refreshed here
final class BoardBridge {

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hitsudan", isDirectory: true)
    static let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    static let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    static let boardPNG = root.appendingPathComponent("board.png")
    static let boardMeta = root.appendingPathComponent("board.json")
    static let stateFile = root.appendingPathComponent("state.json")

    /// Runs on the main thread. Returns the reply payload for the session.
    var onCommand: ((String, [String: Any]) -> [String: Any])?
    var onActivity: ((String) -> Void)?

    private var timer: Timer?
    private(set) var seq: Int

    init() {
        let fm = FileManager.default
        for dir in [Self.root, Self.inbox, Self.outbox] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Pick up where a previous run left off, so a restart does not make an
        // old board look new to a waiting session.
        if let data = try? Data(contentsOf: Self.boardMeta),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let stored = meta["seq"] as? Int {
            seq = stored
        } else {
            seq = 0
        }
        sweepStale()
    }

    func start() {
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.drain() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Anything left in the boxes from a previous run is meaningless now.
    private func sweepStale() {
        let fm = FileManager.default
        for dir in [Self.inbox, Self.outbox] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    private func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.inbox, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) else { return }

        for file in files {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = request["op"] as? String else { continue }

            var reply = onCommand?(op, request) ?? ["ok": false, "error": "no handler"]
            reply["seq"] = seq
            onActivity?(op)

            let out = Self.outbox.appendingPathComponent(file.lastPathComponent)
            if let encoded = try? JSONSerialization.data(withJSONObject: reply, options: []) {
                try? encoded.write(to: out)
            }
        }
    }

    /// Publish the sheet. `bump` marks it as a new answer for a waiting session.
    func publish(png: Data, note: String, bump: Bool) {
        if bump { seq += 1 }
        try? png.write(to: Self.boardPNG)
        let meta: [String: Any] = [
            "seq": seq,
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "note": note,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? data.write(to: Self.boardMeta)
        }
    }

    func publish(state: [String: Any]) {
        var payload = state
        payload["seq"] = seq
        payload["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: Self.stateFile)
        }
    }
}
