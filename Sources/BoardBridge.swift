import AppKit

/// The link between the board and whatever Claude session is talking to
/// `hitsudan-mcp`. A directory of one-shot command files plus a state file the
/// server can read without asking: no sockets, no ports, and either side can
/// restart without the other noticing.
///
///   ~/.hitsudan/inbox/<id>.json      command from the session
///   ~/.hitsudan/outbox/<id>.json     this app's reply
///   ~/.hitsudan/board.png            the sheet, as last published
///   ~/.hitsudan/board.json           { seq, savedAt, note } — seq rises on 送る
///   ~/.hitsudan/replies/<key>.png    what 送る sent to one session, kept until it collects
///   ~/.hitsudan/replies/<key>.json   { seq, savedAt, label } for that reply
///   ~/.hitsudan/proposals/<id>.json  { outcome } for a proposal a session is waiting on
///   ~/.hitsudan/state.json           connection and canvas state, refreshed here
///
/// Every file is written under a temporary name and renamed into place, so no
/// reader ever sees half of one, and so each arrival is a directory event: the
/// inbox is watched with kqueue rather than polled.
final class BoardBridge {

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".hitsudan", isDirectory: true)
    static let inbox = root.appendingPathComponent("inbox", isDirectory: true)
    static let outbox = root.appendingPathComponent("outbox", isDirectory: true)
    static let replies = root.appendingPathComponent("replies", isDirectory: true)
    static let proposals = root.appendingPathComponent("proposals", isDirectory: true)
    static let boardPNG = root.appendingPathComponent("board.png")
    static let boardMeta = root.appendingPathComponent("board.json")
    static let stateFile = root.appendingPathComponent("state.json")

    /// Runs on the main thread. Returns the reply payload for the session.
    var onCommand: ((String, [String: Any]) -> [String: Any])?
    var onActivity: ((String) -> Void)?

    private var inboxWatch: DispatchSourceFileSystemObject?
    /// The 5 s tick retries a watch that could not be opened; logging every
    /// retry would bury the log, so only the first failure in a row is noted.
    private var reportedWatchFailure = false
    private var safetyTimer: Timer?
    private(set) var seq: Int

    init() {
        let fm = FileManager.default
        for dir in [Self.root, Self.inbox, Self.outbox, Self.replies, Self.proposals] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        seq = Self.recoverSeq()
        sweepStale()
    }

    /// Pick up where a previous run left off, so a restart does not make an old
    /// board look new to a waiting session. board.json alone is not enough: if
    /// it is lost or unreadable, starting again from 0 would make every later
    /// 送る look older than what sessions already hold, and none would be seen.
    private static func recoverSeq() -> Int {
        let fm = FileManager.default
        let replyMetas = ((try? fm.contentsOfDirectory(at: replies, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        return ([boardMeta, stateFile] + replyMetas).compactMap { url -> Int? in
            guard let data = try? Data(contentsOf: url),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return meta["seq"] as? Int
        }.max() ?? 0
    }

    func start() {
        watchInbox()
        // Directory events do the work. This slow tick only catches an event
        // that was somehow missed, re-arms a watch that could not be opened,
        // and clears out files nobody came back for.
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.inboxWatch == nil { self.watchInbox() }
            self.drain()
            self.sweepOrphans()
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t
        drain()
    }

    private func watchInbox() {
        inboxWatch?.cancel()
        inboxWatch = nil
        try? FileManager.default.createDirectory(at: Self.inbox, withIntermediateDirectories: true)
        let fd = open(Self.inbox.path, O_EVTONLY)
        guard fd >= 0 else {
            if !reportedWatchFailure {
                reportedWatchFailure = true
                NSLog("hitsudan: could not watch the inbox (errno \(errno)); polling every 5 s until it opens")
            }
            return
        }
        reportedWatchFailure = false
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                               eventMask: [.write, .delete, .rename],
                                                               queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // Deleted or moved away: the descriptor now points at a directory
            // nobody writes to. Watch the new one.
            if !source.data.isDisjoint(with: [.delete, .rename]) { self.watchInbox() }
            self.drain()
        }
        source.setCancelHandler { close(fd) }
        inboxWatch = source
        source.resume()
    }

    /// Anything left in the boxes from a previous run is meaningless now.
    private func sweepStale() {
        let fm = FileManager.default
        for dir in [Self.inbox, Self.outbox] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files { try? fm.removeItem(at: f) }
        }
    }

    /// A reply is orphaned when the server gave up before it arrived, a
    /// proposal outcome when its waiter timed out, a sent reply when its
    /// session never came back, a temporary file when its writer died before
    /// the rename. Each gets far longer than anyone waits.
    private func sweepOrphans() {
        let fm = FileManager.default
        let now = Date()
        for (dir, age) in [(Self.inbox, 60.0), (Self.outbox, 60.0),
                           (Self.proposals, 3600.0), (Self.replies, 7 * 86400.0)] {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))
                ?? []
            for f in files {
                let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, now.timeIntervalSince(modified) > age { try? fm.removeItem(at: f) }
            }
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

            // A reply that cannot be written leaves the session to time out,
            // which it reports as the app not answering.
            do {
                let encoded = try JSONSerialization.data(withJSONObject: reply, options: [])
                Self.writeAtomically(encoded, to: Self.outbox.appendingPathComponent(file.lastPathComponent))
            } catch {
                NSLog("hitsudan: could not encode the reply to \(op): \(error)")
            }
        }
    }

    /// Publish the sheet. `bump` marks it as a new answer for a waiting session.
    /// `false` when board.png or board.json did not reach the disk.
    @discardableResult
    func publish(png: Data, note: String, bump: Bool) -> Bool {
        if bump { seq += 1 }
        let meta: [String: Any] = [
            "seq": seq,
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "note": note,
        ]
        // The meta is only written over a sheet that landed: a new seq beside
        // the old picture would hand a waiting session the wrong board.
        return Self.writeAtomically(png, to: Self.boardPNG) && Self.writeJSON(meta, to: Self.boardMeta, pretty: true)
    }

    /// 送る: the sheet goes to the session that asked, under its own key, where
    /// a later read_board (which republishes board.png) cannot overwrite it
    /// before it is collected. board.png/json are updated too, for the
    /// clipboard path and for servers that predate per-session replies.
    /// `false` when the copy the session reads did not reach the disk: for a
    /// keyed session its reply files, otherwise board.png/json.
    func publishReply(png: Data, key: String, label: String) -> Bool {
        let published = publish(png: png, note: label, bump: true)
        let safe = Self.fileSafe(key)
        guard !safe.isEmpty else { return published }
        guard Self.writeAtomically(png, to: Self.replies.appendingPathComponent("\(safe).png")) else { return false }
        // The meta goes last: it is what the session waits for.
        let meta: [String: Any] = [
            "seq": seq,
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "label": label,
        ]
        return Self.writeJSON(meta, to: Self.replies.appendingPathComponent("\(safe).json"))
    }

    /// How a proposal ended, for a session that asked to be told. `false` when
    /// it could not be filed.
    @discardableResult
    func publishOutcome(proposal id: String, outcome: String) -> Bool {
        let safe = Self.fileSafe(id)
        guard !safe.isEmpty else { return false }
        return Self.writeJSON(["outcome": outcome], to: Self.proposals.appendingPathComponent("\(safe).json"))
    }

    func publish(state: [String: Any]) {
        var payload = state
        payload["seq"] = seq
        payload["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        Self.writeJSON(payload, to: Self.stateFile, pretty: true)
    }

    /// Same rule as hitsudan-mcp's `fileSafe`, so both sides name a session's
    /// files identically and a key can never climb out of its directory.
    static func fileSafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_" ? $0 : "_"
        }))
    }

    @discardableResult
    private static func writeJSON(_ object: [String: Any], to url: URL, pretty: Bool = false) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: pretty ? [.prettyPrinted] : [])
            return writeAtomically(data, to: url)
        } catch {
            NSLog("hitsudan: could not encode \(url.lastPathComponent): \(error)")
            return false
        }
    }

    /// `false` when the file did not land; the previous version, if any, is
    /// left in place.
    @discardableResult
    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do { try data.write(to: tmp) } catch {
            NSLog("hitsudan: could not write \(url.lastPathComponent): \(error)")
            return false
        }
        guard rename(tmp.path, url.path) == 0 else {
            NSLog("hitsudan: could not move \(url.lastPathComponent) into place (errno \(errno))")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        return true
    }
}
