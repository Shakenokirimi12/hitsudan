import Foundation
import CoreGraphics
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

/// This session's outstanding request, kept on disk so it survives the server
/// process being restarted between asking and collecting.
var requestFile: URL {
    let who = (FileManager.default.currentDirectoryPath as NSString).lastPathComponent
    let safe = who.replacingOccurrences(of: "/", with: "_")
    return requestsDir.appendingPathComponent("\(safe.isEmpty ? "session" : safe).json")
}

// MARK: - Talking to the app

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Hand a command to the board and wait for its reply. Nil means the app is not
/// running (or is wedged) — the caller turns that into a readable error.
@discardableResult
func command(_ op: String, _ args: [String: Any] = [:], timeout: TimeInterval = 6) -> [String: Any]? {
    let id = UUID().uuidString
    var payload = args
    payload["op"] = op
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return nil }
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let file = inbox.appendingPathComponent("\(id).json")
    guard (try? data.write(to: file)) != nil else { return nil }

    let reply = outbox.appendingPathComponent("\(id).json")
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let answer = readJSON(reply) {
            try? FileManager.default.removeItem(at: reply)
            return answer
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    try? FileManager.default.removeItem(at: file)
    return nil
}

var boardSeq: Int { (readJSON(boardMeta)?["seq"] as? Int) ?? 0 }

/// Claude sees no more detail above ~1.15 megapixels; shrink before encoding.
func boardImageBase64() -> String? {
    guard let source = CGImageSourceCreateWithURL(boardPNG as CFURL, nil),
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

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
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

func boardContent(header: String) -> [String: Any] {
    guard FileManager.default.fileExists(atPath: boardPNG.path) else {
        return failure("ボードがまだ公開されていません。アプリで「送る」を押すか read_board を使ってください。")
    }
    guard let base64 = boardImageBase64() else {
        return failure("board.png を画像として読めませんでした")
    }
    return ["content": [text(header), ["type": "image", "data": base64, "mimeType": "image/png"]]]
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
        （prompt は再表示され、押された瞬間を取り逃さない）。
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
        color を渡せばその筆記具を借りられる。
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "ボードに表示する依頼文"],
                "lease_seconds": ["type": "number", "description": "依頼を掲示しておく秒数。既定 1800、上限 7200"],
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
        wait_seconds を渡せばその秒数だけ待ってから返る。
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
        （勝手に上書きしない）。適用されたかは board_status で確認できる。
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

/// Post the request to the board and remember where the counter stood, so a
/// later collection can tell "they answered" from "nothing has happened yet".
func postRequest(_ args: [String: Any], lease: Double) -> String? {
    let cwd = FileManager.default.currentDirectoryPath
    let label = (cwd as NSString).lastPathComponent
    var request: [String: Any] = ["label": label, "cwd": cwd,
                                  "prompt": (args["prompt"] as? String) ?? "",
                                  "lease": lease]
    if let retain = args["retain"] as? String, !retain.isEmpty { request["retain"] = retain }
    guard command("wait", request) != nil else { return nil }
    lendPen(args)
    try? FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
    let record: [String: Any] = ["seq": boardSeq,
                                 "prompt": (args["prompt"] as? String) ?? "",
                                 "at": ISO8601DateFormatter().string(from: Date())]
    if let data = try? JSONSerialization.data(withJSONObject: record) { try? data.write(to: requestFile) }
    return label
}

/// The pen is borrowed as part of a request, never on its own — nobody wants
/// their colour changed while they are simply writing.
func lendPen(_ args: [String: Any]) {
    var pen: [String: Any] = [:]
    if let c = args["color"] as? String, !c.isEmpty { pen["color"] = c }
    if let w = args["width"] as? Double, w > 0 { pen["width"] = w }
    if let e = args["eraser"] as? Bool { pen["eraser"] = e }
    guard !pen.isEmpty else { return }
    command("set_pen", pen, timeout: 3)
}

func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
    switch name {
    case "read_board":
        let who = (FileManager.default.currentDirectoryPath as NSString).lastPathComponent
        guard let reply = command("capture", ["label": who]) else { return failure(notRunning) }
        if reply["ok"] as? Bool != true {
            return failure((reply["error"] as? String) ?? "取得できませんでした")
        }
        return boardContent(header: "筆談ボードの現在の内容")

    case "request_board":
        let lease = min(max((args["lease_seconds"] as? Double) ?? 1800, 30), 7200)
        guard let label = postRequest(args, lease: lease) else { return failure(notRunning) }
        return ["content": [text("ボードに依頼を出しました（\(label)）。"
            + "ユーザーが書いて「送る」を押したら collect_board で回収してください。"
            + "こちらは待っていないので、先に別の作業を進めて構いません。")]]

    case "collect_board":
        guard let record = readJSON(requestFile), let asked = record["seq"] as? Int else {
            return failure("回収できる依頼がありません。先に request_board を呼んでください。")
        }
        let wait = min(max((args["wait_seconds"] as? Double) ?? 0, 0), 300)
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if boardSeq > asked {
                try? FileManager.default.removeItem(at: requestFile)
                command("wait_end", [:])
                let note = (readJSON(boardMeta)?["savedAt"] as? String) ?? ""
                return boardContent(header: "ユーザーが送信した手書き（\(note)）")
            }
            if wait > 0 { Thread.sleep(forTimeInterval: 0.3) }
        } while Date() < deadline
        return ["content": [text("まだ書かれていません。依頼はボードに出したままなので、"
            + "他の作業を進めてからもう一度 collect_board を呼んでください。")]]

    case "wait_for_board":
        let limit = min(max((args["timeout_seconds"] as? Double) ?? 55, 5), 600)
        guard postRequest(args, lease: limit + 60) != nil else { return failure(notRunning) }

        let before = boardSeq
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if boardSeq > before {
                // The record is what the Stop hook watches. Leaving it behind
                // after a synchronous wait would make every later stop look
                // like a fresh reply and wake the session for ever.
                try? FileManager.default.removeItem(at: requestFile)
                command("wait_end", [:])
                let note = (readJSON(boardMeta)?["savedAt"] as? String) ?? ""
                return boardContent(header: "ユーザーが送信した手書き（\(note)）")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // Not an error — a plain "not yet", so waiting longer is just another
        // call rather than something the model has to recover from. The notice
        // stays on the board so the request is still in front of the person.
        return ["content": [text("""
        まだ「送る」は押されていません（\(Int(limit))秒待機）。\
        依頼はボードに表示したままです。待ち続けるなら wait_for_board をもう一度呼んでください。
        """)]]

    case "show_on_board":
        var payload: [String: Any] = [:]
        for key in ["svg", "image_path", "text", "notice", "retain"] {
            if let value = args[key] as? String, !value.isEmpty { payload[key] = value }
        }
        if let clear = args["clear_ink"] as? Bool { payload["clear_ink"] = clear }
        guard payload["svg"] != nil || payload["image_path"] != nil || payload["text"] != nil else {
            return failure("svg / image_path / text のいずれかが必要です")
        }
        guard let reply = command("show", payload) else { return failure(notRunning) }
        if reply["ok"] as? Bool != true {
            return failure((reply["error"] as? String) ?? "ボードに送れませんでした")
        }
        lendPen(args)
        let id = (reply["proposalID"] as? String) ?? ""
        let wait = min(max((args["wait_seconds"] as? Double) ?? 0, 0), 300)
        guard wait > 0 else {
            return ["content": [text("ボードにプレビューとして送りました。ユーザーが「適用」か「破棄」を押すまで確定しません。"
                                     + "結果は board_status で確認できます。")]]
        }

        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let s = command("status", [:], timeout: 3),
               (s["proposalID"] as? String) == id,
               let outcome = s["proposalOutcome"] as? String, outcome != "pending" {
                return ["content": [text(outcome == "applied"
                    ? "ユーザーが適用しました。内容は新しいページに置かれています。"
                    : "ユーザーが破棄しました。ボードは変わっていません。")]]
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return ["content": [text("まだ判断されていません。board_status で結果を確認できます。")]]

    case "clear_board":
        guard let reply = command("clear") else { return failure(notRunning) }
        if reply["ok"] as? Bool != true {
            return failure((reply["error"] as? String) ?? "消去を提案できませんでした")
        }
        return ["content": [text("消去を提案しました。ユーザーが「適用」を押すと消えます。")]]

    case "board_status":
        let live = command("status", [:], timeout: 3)
        let snapshot = live ?? readJSON(stateFile)
        guard let snapshot else { return failure(notRunning) }
        let proposalText: String
        switch snapshot["proposalOutcome"] as? String ?? "" {
        case "pending": proposalText = "判断待ち"
        case "applied": proposalText = "適用された"
        case "rejected": proposalText = "破棄された"
        default: proposalText = "なし"
        }
        let lines = [
            "アプリ: \(live != nil ? "応答あり" : "無応答（state.json の最終値）")",
            "タブレット: \((snapshot["tabletPresent"] as? Bool ?? false) ? "接続" : "未接続")",
            "ストローク数: \(snapshot["strokes"] as? Int ?? 0)",
            "下敷き: \((snapshot["hasBackground"] as? Bool ?? false) ? "あり" : "なし")",
            "未処理の提案: \((snapshot["pendingProposal"] as? Bool ?? false) ? "あり" : "なし")",
            "待機中のセッション: \({ let w = snapshot["waitingFor"] as? String ?? ""; return w.isEmpty ? "なし" : w }())",
            "直前の提案: \(proposalText)",
            "カーソル操作: \((snapshot["pointerEnabled"] as? Bool ?? false) ? "ON" : "OFF")",
            "公開済み seq: \(snapshot["seq"] as? Int ?? 0)",
        ]
        return ["content": [text(lines.joined(separator: "\n"))]]

    default:
        return failure("unknown tool: \(name)")
    }
}

// MARK: - Loop

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

    let method = message["method"] as? String ?? ""
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
        respond(id: id, result: [
            "protocolVersion": (params?["protocolVersion"] as? String) ?? "2025-06-18",
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
        respond(id: id, result: call(name, args))
    default:
        respond(id: id, code: -32601, message: "method not found: \(method)")
    }
}
