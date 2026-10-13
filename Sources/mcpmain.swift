import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// hitsudan-mcp — a stdio MCP server that lets a Claude session use the pen
// tablet as a two-way surface: read what was handwritten, and put its own work
// back in front of the person to be marked up.
//
// It talks to the running app through ~/.hitsudan (see BoardBridge.swift).
// stdout carries JSON-RPC only; anything else goes to stderr.

let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".hitsudan", isDirectory: true)
let inbox = root.appendingPathComponent("inbox", isDirectory: true)
let outbox = root.appendingPathComponent("outbox", isDirectory: true)
let boardPNG = root.appendingPathComponent("board.png")
let boardMeta = root.appendingPathComponent("board.json")
let stateFile = root.appendingPathComponent("state.json")
let requestsDir = root.appendingPathComponent("requests", isDirectory: true)
let repliesDir = root.appendingPathComponent("replies", isDirectory: true)
let proposalsDir = root.appendingPathComponent("proposals", isDirectory: true)

// MARK: - Who is asking

let environment = ProcessInfo.processInfo.environment
/// Symlinks resolved, so /tmp/x and /private/tmp/x are one project — the key
/// below hashes this string, and Tools/board-wake.sh must arrive at the same
/// one. realpath(3) rather than URL.resolvingSymlinksInPath(): the latter
/// strips a leading /private, which Python's os.path.realpath (the hook's
/// side) keeps.
let projectDir: String = {
    let given = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? FileManager.default.currentDirectoryPath
    guard let resolved = realpath(given, nil) else { return given }
    defer { free(resolved) }
    return String(cString: resolved)
}()

/// Shown on the board, for people only: ~/x/app and ~/y/app both read "app".
let sessionLabel: String = {
    let name = (projectDir as NSString).lastPathComponent
    return name.isEmpty || name == "/" ? "セッション" : name
}()

func fileSafe(_ s: String) -> String {
    String(String.UnicodeScalarView(s.unicodeScalars.map {
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
            || $0 == "-" || $0 == "_" ? $0 : "_"
    }))
}

/// What this session's files are keyed by. Claude Code gives MCP servers the
/// session id in the environment, so two sessions in one repo stay apart;
/// without it the full project path is the best there is. Tools/board-wake.sh
/// builds the same candidates from what a hook receives and uses whichever has
/// a request file — keep the two rules in step.
let sessionKey: String = {
    if let id = environment["CLAUDE_CODE_SESSION_ID"], !id.isEmpty { return fileSafe(id) }
    let digest = SHA256.hash(data: Data(projectDir.utf8))
    return "cwd-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}()

/// This session's outstanding request, kept on disk so it survives the server
/// process being restarted between asking and collecting.
let requestFile = requestsDir.appendingPathComponent("\(sessionKey).json")
/// What the person sent to this session. Only 送る writes here — read_board
/// republishes board.png, so an answer kept there could be overwritten before
/// it is collected.
let replyMeta = repliesDir.appendingPathComponent("\(sessionKey).json")
let replyPNG = repliesDir.appendingPathComponent("\(sessionKey).png")

// MARK: - Files

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Readers (the app, the Stop hook, other servers) must never see half a file,
/// and the rename is also what fires the watchers on the directory.
@discardableResult
func writeAtomically(_ object: [String: Any], to url: URL) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return false }
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
    guard (try? data.write(to: tmp)) != nil else { return false }
    guard rename(tmp.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: tmp)
        return false
    }
    return true
}

func remove(_ urls: URL...) {
    for url in urls { try? FileManager.default.removeItem(at: url) }
}

// MARK: - Waiting without polling

/// Wakes a waiter when an entry is added to, removed from or renamed in a
/// directory. Every writer on both sides renames finished files into place, so
/// an arrival is always one of those.
final class DirectoryWatch {
    private static let queue = DispatchQueue(label: "hitsudan.watch")
    private let url: URL
    private let wake: DispatchSemaphore
    private var source: DispatchSourceFileSystemObject?
    private let lock = NSLock()
    private var lost = false

    init(_ url: URL, wake: DispatchSemaphore) {
        self.url = url
        self.wake = wake
        open()
    }

    deinit { source?.cancel() }

    /// A directory that was deleted and recreated is a different vnode; the old
    /// descriptor would never fire again.
    func reopenIfLost() {
        lock.lock()
        let gone = lost || source == nil
        lost = false
        lock.unlock()
        guard gone else { return }
        source?.cancel()
        source = nil
        open()
    }

    private func open() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .delete, .rename],
                                                          queue: Self.queue)
        s.setEventHandler { [weak self, weak s] in
            if let self, let s, !s.data.isDisjoint(with: [.delete, .rename]) {
                self.lock.lock(); self.lost = true; self.lock.unlock()
            }
            self?.wake.signal()
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }
}

/// One tools/call in flight. Cancelling wakes whatever it is blocked on.
final class ToolCall {
    private let lock = NSLock()
    private var cancelled = false
    private var wakers: [DispatchSemaphore] = []

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = wakers
        lock.unlock()
        for w in pending { w.signal() }
    }

    func onCancel(_ wake: DispatchSemaphore) { lock.lock(); wakers.append(wake); lock.unlock() }
    func offCancel(_ wake: DispatchSemaphore) { lock.lock(); wakers.removeAll { $0 === wake }; lock.unlock() }
}

/// Block until `check` yields something, the deadline passes, or the call is
/// cancelled. Sleeps on directory events; the slow re-check is only there in
/// case an event is ever missed.
func waitFor<T>(_ dirs: [URL], until deadline: Date, call: ToolCall? = nil, _ check: () -> T?) -> T? {
    let wake = DispatchSemaphore(value: 0)
    // Armed before the first check, so nothing landing in between is missed.
    let watches = dirs.map { DirectoryWatch($0, wake: wake) }
    call?.onCancel(wake)
    defer { call?.offCancel(wake) }
    while true {
        if let found = check() { return found }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 || call?.isCancelled == true { return nil }
        _ = wake.wait(timeout: .now() + min(left, 3))
        for w in watches { w.reopenIfLost() }
    }
}

// MARK: - Talking to the app

/// Hand a command to the board and wait for its reply. Nil means the app is not
/// running (or is wedged) — the caller turns that into a readable error.
@discardableResult
func command(_ op: String, _ args: [String: Any] = [:], timeout: TimeInterval = 6) -> [String: Any]? {
    let id = UUID().uuidString
    var payload = args
    payload["op"] = op
    let file = inbox.appendingPathComponent("\(id).json")
    // Written under a temporary name and renamed in, so the app's drain can
    // never pick up half a command, fail to parse it and throw it away.
    guard writeAtomically(payload, to: file) else { return nil }

    let reply = outbox.appendingPathComponent("\(id).json")
    if let answer = waitFor([outbox], until: Date().addingTimeInterval(timeout), { readJSON(reply) }) {
        remove(reply)
        return answer
    }
    // If the app answers after all, its reply is swept as an orphan app-side.
    remove(file)
    return nil
}

/// Claude sees no more detail above ~1.15 megapixels; shrink before encoding.
func imageBase64(_ url: URL) -> String? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 1568,
              kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary) else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return (data as Data).base64EncodedString()
}

// MARK: - JSON-RPC plumbing

/// Tool calls run on their own threads, so whole lines must not interleave.
let output = NSLock()

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let line = String(data: data, encoding: .utf8) else { return }
    output.lock()
    print(line)
    fflush(stdout)
    output.unlock()
}

func respond(id: Any, result: [String: Any]) {
    emit(["jsonrpc": "2.0", "id": id, "result": result])
}

func respond(id: Any, code: Int, message: String) {
    emit(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func text(_ body: String) -> [String: Any] { ["type": "text", "text": body] }

func failure(_ message: String) -> [String: Any] {
    ["isError": true, "content": [text(message)]]
}

let notRunning = "筆談ボードが応答しません。アプリが起動しているか確認してください（~/Developer/hitsudan/Hitsudan.app）。"

func imageContent(_ url: URL, header: String) -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return failure("ボードがまだ公開されていません。アプリで「送る」を押すか read_board を使ってください。")
    }
    guard let base64 = imageBase64(url) else {
        return failure("\(url.lastPathComponent) を画像として読めませんでした")
    }
    return ["content": [text(header), ["type": "image", "data": base64, "mimeType": "image/png"]]]
}

/// Tool output plus any side notes (a pen that could not be lent, a board that
/// was not brought forward), so a partial success is never reported as clean.
func reply(_ body: String, notes: [String] = []) -> [String: Any] {
    ["content": [text(([body] + notes).joined(separator: "\n"))]]
}

// MARK: - Tools

let tools: [[String: Any]] = [
    [
        "name": "read_board",
        "description": """
        ペンタブの手書きボードの「今」の内容を画像で取得する。アプリに最新化させてから読むので、\
        ユーザーが「送る」を押していなくても現在の書き込みが見える。\
        ユーザーが「ボード」「手書き」「書いたやつ」「タブレット」に言及したら、まずこれを呼ぶ。
        """,
        "inputSchema": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
    ],
    [
        "name": "wait_for_board",
        "description": """
        ボードを前面に出し、ユーザーが手書きして「送る」を押すまで待ってから、その内容を画像で返す。\
        図や指示を手で描いてほしいときに使う。prompt を渡すとボード上部に見出しとして表示される。\
        「赤で印を」と頼むなら color: red も一緒に渡す。その色の筆記具を依頼の間だけ借りられる。\
        借りた筆記具は依頼が終わると元に戻る（間にユーザーが自分で選び直していればそちらが優先）。\
        MCP は外部からセッションを起こせないので、ユーザーの手書きを待つ唯一の方法がこれ。\
        時間切れになると「まだ」とだけ返るので、待ち続けるならそのまま呼び直すこと\
        （返信は回収されるまで保存されるので、呼び直すまでの間に押されても取り逃さない）。\
        ボードに出せる依頼は一度に1つ。別のセッションの依頼が出ている間はエラーになる。
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "ボードに表示する依頼文（例: この構成図の直したい所に赤で印を）"],
                "timeout_seconds": ["type": "number", "description": "1回あたりの最大待ち時間。既定 55、上限 600。クライアント側のツールタイムアウトより短くすること"],
                "color": ["type": "string", "description": "依頼の間だけ借りる筆記具: black / red / blue / green / laser"],
                "width": ["type": "number", "description": "同じく線の太さ 2〜140"],
                "eraser": ["type": "boolean", "description": "同じく消しゴムにするか"],
                "retain": ["type": "string", "description": "返信を描いたページをどうするか: keep=ノートに残す（既定） / temporary=送ったら消して元のページに戻る / ask=送ったあとユーザーに選ばせる"],
            ],
            "additionalProperties": false,
        ],
    ],
    [
        "name": "request_board",
        "description": """
        手書きを依頼して**すぐ返る**。ボードに依頼文が出て「送る」ボタンが現れるが、\
        こちらは待たずに他の作業を続けられる。書けたかどうかは collect_board で回収する。\
        wait_for_board と違ってセッションを塞がないので、時間のかかる依頼はこちらを使う。\
        color を渡せばその筆記具を借りられる。\
        ボードに出せる依頼は一度に1つ。別のセッションの依頼が出ている間はエラーになる。
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "ボードに表示する依頼文"],
                "lease_seconds": ["type": "number", "description": "依頼を掲示しておく秒数。既定・上限とも 1800（Stop フックが見張れる長さに合わせてある）。過ぎると依頼はボードから消える"],
                "color": ["type": "string", "description": "借りる筆記具: black / red / blue / green / laser"],
                "width": ["type": "number", "description": "線の太さ 2〜140"],
                "eraser": ["type": "boolean", "description": "消しゴムにするか"],
                "retain": ["type": "string", "description": "返信を描いたページをどうするか: keep=ノートに残す（既定） / temporary=送ったら消して元のページに戻る / ask=送ったあとユーザーに選ばせる"],
            ],
            "additionalProperties": false,
        ],
    ],
    [
        "name": "collect_board",
        "description": """
        request_board で出した依頼の答えを回収する。ユーザーが「送る」を押していれば\
        その手書きを画像で返し、まだなら「まだ」とだけ返る（エラーではない）。\
        待たずに何度でも呼べるので、他の作業の合間に確認するのに向く。\
        wait_seconds を渡せばその秒数だけ待ってから返る。\
        依頼が期限切れなどでボードから消えていれば、そう返る（そのときは request_board で出し直す）。
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "wait_seconds": ["type": "number", "description": "回収前に待つ秒数。既定 0、上限 300"],
            ],
            "additionalProperties": false,
        ],
    ],
    [
        "name": "show_on_board",
        "description": """
        AI が生成したものをボードに送り、ユーザーが上からペンで指示を描き込めるようにする。\
        svg / image_path / text のいずれかを渡す。SVG は macOS がそのまま描画するので、\
        図・表・レイアウト案を渡すのに向く。\
        color を渡せば、書き込んでほしい色の筆記具を判断が済むまで借りられる。\
        送った内容は半透明のプレビューとして表示され、ユーザーが「適用」を押すまで確定しない\
        （勝手に上書きしない）。適用されたかは board_status で確認できる。\
        判断される前に別の提案が届くと、古い提案は取り下げられる（wait_seconds で待っていればそう返る）。
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "svg": ["type": "string", "description": "SVG ソースそのもの"],
                "image_path": ["type": "string", "description": "画像ファイルの絶対パス"],
                "text": ["type": "string", "description": "下敷きとして敷くテキスト"],
                "notice": ["type": "string", "description": "ボード上部に出す一行"],
                "clear_ink": ["type": "boolean", "description": "適用時に既存の手書きを消す。既定 false"],
                "wait_seconds": ["type": "number", "description": "ユーザーの判断を待つ秒数。既定 0（待たずに返る）。上限 300"],
                "color": ["type": "string", "description": "書き込んでほしい色を借りる: black / red / blue / green / laser"],
                "width": ["type": "number", "description": "同じく線の太さ 2〜140"],
                "eraser": ["type": "boolean", "description": "同じく消しゴムにするか"],
                "retain": ["type": "string", "description": "返信を描いたページをどうするか: keep=ノートに残す（既定） / temporary=送ったら消して元のページに戻る / ask=送ったあとユーザーに選ばせる"],
            ],
            "additionalProperties": false,
        ],
    ],
    [
        "name": "clear_board",
        "description": "ボードの消去をユーザーに提案する。実際に消えるのはユーザーが「適用」を押したとき。",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
    ],
    [
        "name": "board_status",
        "description": "タブレットの接続、ストローク数、下敷きの有無、未処理の提案があるかを返す。",
        "inputSchema": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
    ],
]

// MARK: - Requests and replies
//
// The board shows one request at a time. A second session asking while
// another's request is up is turned away rather than queued: a queue needs a
// way to pick whom 送る answers, and a pen user cannot see or manage one. Being
// told "busy" is something the second session can act on; having its prompt
// silently replaced is not.

/// The reply waiting for this session, if it is newer than what the request was
/// posted at. Replies are addressed: another session's answer never shows up here.
func pendingReply(after asked: Int) -> [String: Any]? {
    guard let meta = readJSON(replyMeta), let seq = meta["seq"] as? Int, seq > asked else { return nil }
    return meta
}

/// Calls of one session can run side by side (collect_board next to a
/// wait_for_board); only one of them may hand a given reply over.
let replyLock = NSLock()

/// This session's most recent proposal, so board_status can say what became
/// of it even when the session did not wait and another proposal replaced it.
let proposalLock = NSLock()
var myLastProposal = ""

func rememberProposal(_ id: String) {
    guard !id.isEmpty else { return }
    proposalLock.lock(); myLastProposal = id; proposalLock.unlock()
}

func lastProposal() -> String {
    proposalLock.lock(); defer { proposalLock.unlock() }; return myLastProposal
}

/// applied / rejected / superseded once decided, filed by the app per proposal.
func proposalOutcome(_ id: String) -> String? {
    readJSON(proposalsDir.appendingPathComponent("\(fileSafe(id)).json"))?["outcome"] as? String
}

/// Hand the reply over, and only then forget it — a reply exists on disk
/// precisely so it survives until it is collected. Nil means the call was
/// cancelled while the image was being read: its result may never reach the
/// session, so the reply is left on disk for the next collection.
func takeReply(_ meta: [String: Any], call: ToolCall) -> [String: Any]? {
    replyLock.lock()
    defer { replyLock.unlock() }
    guard let current = readJSON(replyMeta), (current["seq"] as? Int) == (meta["seq"] as? Int) else {
        return reply("この返信は、同時に動いていた別の呼び出しがすでに回収しました。")
    }
    let content = imageContent(replyPNG, header: "ユーザーが送信した手書き（\((meta["savedAt"] as? String) ?? "")）")
    if call.isCancelled { return nil }
    // Normally already cleared by 送る; this covers a request re-posted just
    // after the answer was sent, which would otherwise stay on the board.
    defer { command("wait_end", ["key": sessionKey], timeout: 3) }
    if content["isError"] != nil {
        // An unreadable reply can never be collected. Keeping it (and the
        // request) would leave the Stop hook watching it until it gives up.
        remove(replyMeta, replyPNG, requestFile)
        return failure("ユーザーは「送る」を押しましたが、返信の画像を読めませんでした。"
            + "依頼は取り下げたので、必要なら出し直してください。")
    }
    remove(replyMeta, replyPNG, requestFile)
    return content
}

/// Hand an outstanding request from a blocking call back to the Stop hook.
func clearWaiter() {
    guard var record = readJSON(requestFile), record["waiter"] != nil else { return }
    record.removeValue(forKey: "waiter")
    writeAtomically(record, to: requestFile)
}

/// Take this session's request off the board when the call waiting for it is
/// cancelled — unless a later call of the same session has re-posted it since
/// (its record carries a different token), which is not this call's to undo.
/// The app ignores a key that is not the one up.
func withdrawRequest(token: String, asked: Int) {
    guard (readJSON(requestFile)?["token"] as? String) == token else { return }
    // Down first, so no 送る can land after the look below.
    command("wait_end", ["key": sessionKey], timeout: 3)
    if pendingReply(after: asked) != nil {
        // Answered just as the wait was cancelled. Dropping the request would
        // orphan the reply, and the next request would discard it as stale;
        // keep it for collect_board and the Stop hook instead.
        clearWaiter()
    } else {
        remove(requestFile)
    }
}

enum BoardHolds { case yes, no, unknown }

/// Whether the board still shows this session's request. The app drops it when
/// the lease runs out or it restarts, and a session must hear about that
/// instead of being told "まだ" for ever.
func boardHoldsRequest() -> BoardHolds {
    guard let status = command("status", [:], timeout: 3) else { return .unknown }
    return (status["waitingKey"] as? String) == sessionKey ? .yes : .no
}

enum Posted {
    case posted(seq: Int, token: String, notes: [String])
    /// An earlier request of this session was answered and not yet collected.
    case answered([String: Any])
    case failed([String: Any])
}

/// Post the request to the board and remember where the counter stood, so a
/// later collection can tell "they answered" from "nothing has happened yet".
/// `waiter` marks a call that will block for the answer itself, so a Stop hook
/// left over from an earlier turn stays out of its way.
func postRequest(_ args: [String: Any], lease: Double, waiter: Bool) -> Posted {
    let existing = readJSON(requestFile)
    let asked = existing?["seq"] as? Int
    if let asked, let meta = pendingReply(after: asked) { return .answered(meta) }
    if waiter, var record = existing {
        record["waiter"] = Int(getpid())
        writeAtomically(record, to: requestFile)
    }
    // Where the counter stood before asking: any 送る after this may be an
    // answer to the request below, even if its acknowledgement never arrives.
    let floor = [boardMeta, stateFile].compactMap { readJSON($0)?["seq"] as? Int }.max() ?? 0

    let prompt = (args["prompt"] as? String) ?? ""
    var request: [String: Any] = ["key": sessionKey, "label": sessionLabel, "cwd": projectDir,
                                  "prompt": prompt, "lease": lease]
    if let retain = args["retain"] as? String, !retain.isEmpty { request["retain"] = retain }
    let answer = command("wait", request)
    guard let answer, answer["ok"] as? Bool == true else {
        if let existing {
            writeAtomically(existing, to: requestFile)
        } else if answer == nil, let settled = settleUnconfirmedRequest(prompt: prompt, lease: lease, floor: floor) {
            return settled
        }
        return .failed(failure(answer.map { ($0["error"] as? String) ?? "依頼を出せませんでした" } ?? notRunning))
    }

    // The baseline is the seq the app held when it put the request up, not one
    // read afterwards: a 送る in between would otherwise be taken as old. A
    // re-post keeps the original baseline for the same reason.
    let shownAt = (answer["seq"] as? Int) ?? 0
    var record: [String: Any] = ["seq": min(asked ?? shownAt, shownAt),
                                 "label": sessionLabel,
                                 "prompt": prompt,
                                 "at": ISO8601DateFormatter().string(from: Date()),
                                 "until": Date().timeIntervalSince1970 + lease,
                                 "token": UUID().uuidString]
    if waiter { record["waiter"] = Int(getpid()) }
    writeAtomically(record, to: requestFile)
    // A reply left from a session that never came back for it is not removed
    // here: its seq is at or below the baseline above, so pendingReply never
    // takes it for this request's answer, the next 送る replaces it, and the
    // app sweeps it after a week. Removing it would race a 送る landing now,
    // which is this request's answer.

    var notes: [String] = []
    if let note = lendPen(args) { notes.append(note) }
    if answer["tabletPresent"] as? Bool == false {
        notes.append("タブレットが接続されていないので、ボードはまだ表に出していません。依頼は登録済みで、つながると表示されます。")
    }
    return .posted(seq: record["seq"] as? Int ?? shownAt, token: record["token"] as? String ?? "", notes: notes)
}

/// The app may have put the request up and only answered too late: it reads
/// the inbox file and replies, and a slow reply looks exactly like none. Take
/// it down so the board does not hold a request this session has no record of
/// (an answer to it would be thrown away by the next request as an orphan).
/// If an answer already landed, or the withdrawal cannot be confirmed, keep a
/// record based on the counter from before asking so the answer can still be
/// collected. Nil when it was withdrawn cleanly and the plain failure stands.
func settleUnconfirmedRequest(prompt: String, lease: Double, floor: Int) -> Posted? {
    let withdrawn = command("wait_end", ["key": sessionKey], timeout: 3) != nil
    let answered = pendingReply(after: floor)
    guard !withdrawn || answered != nil else { return nil }
    writeAtomically(["seq": floor,
                     "label": sessionLabel,
                     "prompt": prompt,
                     "at": ISO8601DateFormatter().string(from: Date()),
                     "until": Date().timeIntervalSince1970 + lease,
                     "token": UUID().uuidString], to: requestFile)
    if let answered { return .answered(answered) }
    return .failed(failure(notRunning + " 依頼がボードに出ていた場合に備えて記録は残したので、"
        + "アプリが戻れば collect_board で確かめられます。"))
}

/// The pen is borrowed as part of a request, never on its own — nobody wants
/// their colour changed while they are simply writing. Returns why it could not
/// be lent, so the session does not assume the person has the colour it asked for.
func lendPen(_ args: [String: Any]) -> String? {
    var pen: [String: Any] = [:]
    if let c = args["color"] as? String, !c.isEmpty { pen["color"] = c }
    if let w = args["width"] as? Double, w > 0 { pen["width"] = w }
    if let e = args["eraser"] as? Bool { pen["eraser"] = e }
    guard !pen.isEmpty else { return nil }
    guard let answer = command("set_pen", pen, timeout: 3) else {
        return "筆記具は借りられませんでした（アプリが応答しません）。"
    }
    guard answer["ok"] as? Bool == true else {
        return "筆記具は借りられませんでした: \((answer["error"] as? String) ?? "理由不明")"
    }
    return nil
}

/// Nil means the call was cancelled: the client has stopped listening, so no
/// response is sent.
func runTool(_ name: String, _ args: [String: Any], _ call: ToolCall) -> [String: Any]? {
    switch name {
    case "read_board":
        guard let answer = command("capture", ["label": sessionLabel]) else { return failure(notRunning) }
        if answer["ok"] as? Bool != true {
            return failure((answer["error"] as? String) ?? "取得できませんでした")
        }
        return imageContent(boardPNG, header: "筆談ボードの現在の内容")

    case "request_board":
        // The Stop hook gives up after 1800 s; a longer lease would leave the
        // request on the board with nobody left to wake the session.
        let lease = min(max((args["lease_seconds"] as? Double) ?? 1800, 30), 1800)
        switch postRequest(args, lease: lease, waiter: false) {
        case .failed(let error):
            return error
        case .answered:
            return reply("まだ回収されていない返信があります。先に collect_board で回収してください。")
        case .posted(_, _, let notes):
            return reply("ボードに依頼を出しました（\(sessionLabel)）。"
                + "ユーザーが書いて「送る」を押したら collect_board で回収してください。"
                + "こちらは待っていないので、先に別の作業を進めて構いません。", notes: notes)
        }

    case "collect_board":
        guard let record = readJSON(requestFile), let asked = record["seq"] as? Int else {
            return failure("回収できる依頼がありません。先に request_board を呼んでください。")
        }
        let wait = min(max((args["wait_seconds"] as? Double) ?? 0, 0), 300)
        if let meta = waitFor([repliesDir], until: Date().addingTimeInterval(wait), call: call, {
            pendingReply(after: asked)
        }) {
            // A cancelled call's result never reaches the session, so the
            // reply stays on disk for the next collection.
            return call.isCancelled ? nil : takeReply(meta, call: call)
        }
        // Cancelling a collection only stops this look; the request was made
        // by request_board and stays up until it is answered or expires.
        if call.isCancelled { return nil }
        switch boardHoldsRequest() {
        case .yes:
            return reply("まだ書かれていません。依頼はボードに出したままなので、"
                + "他の作業を進めてからもう一度 collect_board を呼んでください。")
        case .no:
            // 送る writes the reply before it takes the request down, so look
            // once more before calling the request lost.
            if let meta = pendingReply(after: asked) { return takeReply(meta, call: call) }
            remove(requestFile)
            return reply("この依頼はもうボードに出ていません（掲示期限が切れたか、アプリが再起動しました）。"
                + "まだ必要なら request_board で出し直してください。")
        case .unknown:
            return failure(notRunning + " 依頼の記録は残してあるので、アプリが戻れば collect_board で回収できます。")
        }

    case "wait_for_board":
        let limit = min(max((args["timeout_seconds"] as? Double) ?? 55, 5), 600)
        let asked: Int
        let token: String
        let notes: [String]
        switch postRequest(args, lease: limit + 60, waiter: true) {
        case .failed(let error): return error
        case .answered(let meta): return takeReply(meta, call: call)
        case .posted(let seq, let t, let n): asked = seq; token = t; notes = n
        }

        if let meta = waitFor([repliesDir], until: Date().addingTimeInterval(limit), call: call, {
            pendingReply(after: asked)
        }) {
            guard !call.isCancelled else {
                // Answered, but nobody is listening any more: leave the reply
                // for collect_board, and let the Stop hook announce it.
                clearWaiter()
                return nil
            }
            guard let content = takeReply(meta, call: call) else {
                clearWaiter()
                return nil
            }
            return content
        }
        if call.isCancelled {
            withdrawRequest(token: token, asked: asked)
            return nil
        }
        // From here on nobody in this process is waiting, so an answer that
        // lands now is the Stop hook's to report.
        clearWaiter()
        // Not an error — a plain "not yet", so waiting longer is just another
        // call rather than something the model has to recover from.
        return reply("""
        まだ「送る」は押されていません（\(Int(limit))秒待機）。\
        依頼はあと約60秒ボードに表示されます。待ち続けるなら wait_for_board をもう一度呼んでください\
        （その間に押されても返信は保存されているので、取り逃しはありません）。
        """, notes: notes)

    case "show_on_board":
        var payload: [String: Any] = ["key": sessionKey]
        for key in ["svg", "image_path", "text", "notice", "retain"] {
            if let value = args[key] as? String, !value.isEmpty { payload[key] = value }
        }
        if let clear = args["clear_ink"] as? Bool { payload["clear_ink"] = clear }
        guard payload["svg"] != nil || payload["image_path"] != nil || payload["text"] != nil else {
            return failure("svg / image_path / text のいずれかが必要です")
        }
        let wait = min(max((args["wait_seconds"] as? Double) ?? 0, 0), 300)
        guard let answer = command("show", payload) else { return failure(notRunning) }
        if answer["ok"] as? Bool != true {
            return failure((answer["error"] as? String) ?? "ボードに送れませんでした")
        }
        var notes: [String] = []
        if let note = lendPen(args) { notes.append(note) }
        if answer["tabletPresent"] as? Bool == false {
            notes.append("タブレットが接続されていないので、ボードはまだ表に出していません。")
        }
        let id = (answer["proposalID"] as? String) ?? ""
        rememberProposal(id)
        guard wait > 0, !id.isEmpty else {
            return reply("ボードにプレビューとして送りました。ユーザーが「適用」か「破棄」を押すまで確定しません。"
                + "結果は board_status で確認できます。", notes: notes)
        }

        // The app files the outcome, so this sleeps on a directory instead of
        // asking for status several times a second. The file is left for
        // board_status; the app sweeps it later.
        let outcome = waitFor([proposalsDir], until: Date().addingTimeInterval(wait), call: call) {
            proposalOutcome(id)
        }
        if call.isCancelled { return nil }
        guard let outcome else {
            return reply("まだ判断されていません。board_status で結果を確認できます。", notes: notes)
        }
        switch outcome {
        case "applied":
            return reply("ユーザーが適用しました。内容は新しいページに置かれています。", notes: notes)
        case "superseded":
            return reply("判断される前に別の提案が届いたため、この提案は取り下げられました。ボードは変わっていません。", notes: notes)
        default:
            return reply("ユーザーが破棄しました。ボードは変わっていません。", notes: notes)
        }

    case "clear_board":
        guard let answer = command("clear", ["key": sessionKey]) else { return failure(notRunning) }
        if answer["ok"] as? Bool != true {
            return failure((answer["error"] as? String) ?? "消去を提案できませんでした")
        }
        rememberProposal((answer["proposalID"] as? String) ?? "")
        return reply("消去を提案しました。ユーザーが「適用」を押すと消えます。")

    case "board_status":
        let live = command("status", [:], timeout: 3)
        let snapshot = live ?? readJSON(stateFile)
        guard let snapshot else { return failure(notRunning) }
        func describe(_ outcome: String) -> String {
            switch outcome {
            case "pending": return "判断待ち"
            case "applied": return "適用された"
            case "rejected": return "破棄された"
            case "superseded": return "別の提案で取り下げられた"
            default: return "なし"
            }
        }
        let proposalText = describe(snapshot["proposalOutcome"] as? String ?? "")
        // The board's "last proposal" may be another session's; this one's own
        // is looked up by id, so a proposal replaced unseen still reads as such.
        let mineProposed = lastProposal()
        let myProposalText: String
        if mineProposed.isEmpty {
            myProposalText = "なし"
        } else if let outcome = proposalOutcome(mineProposed) {
            myProposalText = describe(outcome)
        } else if (snapshot["proposalID"] as? String) == mineProposed {
            myProposalText = proposalText
        } else {
            // The app sweeps outcomes after an hour; older ones are unknown.
            myProposalText = "不明（記録が残っていません）"
        }
        let mine: String
        if let record = readJSON(requestFile), let asked = record["seq"] as? Int {
            if pendingReply(after: asked) != nil {
                mine = "返信あり（未回収）"
            } else if (snapshot["waitingKey"] as? String) == sessionKey {
                mine = "掲示中"
            } else {
                mine = "ボードから消えている（出し直しが必要）"
            }
        } else {
            mine = "なし"
        }
        let lines = [
            "アプリ: \(live != nil ? "応答あり" : "無応答（state.json の最終値）")",
            "タブレット: \((snapshot["tabletPresent"] as? Bool ?? false) ? "接続" : "未接続")",
            "ストローク数: \(snapshot["strokes"] as? Int ?? 0)",
            "下敷き: \((snapshot["hasBackground"] as? Bool ?? false) ? "あり" : "なし")",
            "未処理の提案: \((snapshot["pendingProposal"] as? Bool ?? false) ? "あり" : "なし")",
            "待機中のセッション: \({ let w = snapshot["waitingFor"] as? String ?? ""; return w.isEmpty ? "なし" : w }())",
            "このセッションの依頼: \(mine)",
            "直前の提案: \(proposalText)",
            "このセッションの直前の提案: \(myProposalText)",
            "ペン: \((snapshot["penSeized"] as? Bool ?? false) ? "ボード専用（排他確保）" : "排他なし")",
            "\(snapshot["mouseBarrier"] as? String ?? "マウス制限 不明")",
            "公開済み seq: \(snapshot["seq"] as? Int ?? 0)",
        ]
        return reply(lines.joined(separator: "\n"))

    default:
        return failure("unknown tool: \(name)")
    }
}

// MARK: - Loop
//
// stdin is read here and nothing else blocks this thread: tool calls run on
// their own threads, so a long wait_for_board can still be cancelled and a
// ping still gets its answer.

/// Versions this server speaks, newest first. Only tools are used, which have
/// not changed shape across them.
let supportedProtocols = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

let inFlightLock = NSLock()
var inFlight: [String: ToolCall] = [:]
let workers = DispatchGroup()

/// JSON-RPC ids may be numbers or strings; 1 and "1" are different requests.
func idKey(_ id: Any) -> String { (id as? String).map { "s:" + $0 } ?? "n:\(id)" }

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

    let method = message["method"] as? String ?? ""
    if method == "notifications/cancelled" {
        if let requestID = (message["params"] as? [String: Any])?["requestId"] {
            inFlightLock.lock()
            let target = inFlight[idKey(requestID)]
            inFlightLock.unlock()
            target?.cancel()
        }
        continue
    }
    guard let id = message["id"] else { continue }   // notifications get no reply

    switch method {
    case "initialize":
        let params = message["params"] as? [String: Any]
        // Record what the client says it can do — whether it offers sampling
        // decides if the board can ever ask Claude something on its own.
        if let params,
           let dump = try? JSONSerialization.data(withJSONObject: params, options: [.prettyPrinted]) {
            try? dump.write(to: root.appendingPathComponent("mcp-client.json"))
        }
        // Echo the client's version only when it is one this server speaks;
        // otherwise offer ours and let the client decide.
        let asked = params?["protocolVersion"] as? String
        respond(id: id, result: [
            "protocolVersion": asked.flatMap { supportedProtocols.contains($0) ? $0 : nil } ?? supportedProtocols[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "hitsudan", "version": "2.0"],
        ])
    case "ping":
        respond(id: id, result: [:])
    case "tools/list":
        respond(id: id, result: ["tools": tools])
    case "resources/list":
        respond(id: id, result: ["resources": []])
    case "prompts/list":
        respond(id: id, result: ["prompts": []])
    case "tools/call":
        let params = message["params"] as? [String: Any]
        let name = (params?["name"] as? String) ?? ""
        let args = (params?["arguments"] as? [String: Any]) ?? [:]
        let call = ToolCall()
        let key = idKey(id)
        inFlightLock.lock()
        inFlight[key] = call
        inFlightLock.unlock()
        workers.enter()
        Thread.detachNewThread {
            defer {
                inFlightLock.lock()
                inFlight[key] = nil
                inFlightLock.unlock()
                workers.leave()
            }
            // runTool returns nil when it saw the cancellation itself. A result
            // it produced anyway (cancelled after the reply was taken) is still
            // sent: the spec lets the client ignore it, and dropping it here
            // would throw away the person's handwriting for certain.
            if let result = runTool(name, args, call) {
                respond(id: id, result: result)
            }
        }
    default:
        respond(id: id, code: -32601, message: "method not found: \(method)")
    }
}

// stdin is closed. Short calls get to finish, so a piped one-shot still gets
// its answer (the grace covers one command timeout). Anything still waiting
// after that would leave its request on the board with nobody to collect it,
// so cancel it (which withdraws) before leaving.
if workers.wait(timeout: .now() + 7) == .timedOut {
    inFlightLock.lock()
    let stillRunning = Array(inFlight.values)
    inFlightLock.unlock()
    for call in stillRunning { call.cancel() }
    _ = workers.wait(timeout: .now() + 8)
}
