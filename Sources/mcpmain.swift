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
        MCP は外部からセッションを起こせないので、ユーザーの手書きを待つ唯一の方法がこれ。\
        時間切れになると「まだ」とだけ返るので、待ち続けるならそのまま呼び直すこと\
        （prompt は再表示され、押された瞬間を取り逃さない）。
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "ボードに表示する依頼文（例: この構成図の直したい所に赤で印を）"],
                "timeout_seconds": ["type": "number", "description": "1回あたりの最大待ち時間。既定 55、上限 600。クライアント側のツールタイムアウトより短くすること"],
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
            ],
            "additionalProperties": false,
        ],
    ],
    [
        "name": "set_pen",
        "description": """
        ボードの筆記具を変える。色を指定してから wait_for_board で書いてもらうと、\
        「赤で印を」と頼んだとおりの色で描いてもらえる。\
        color: black / red / blue / green / laser（laser はインクを残さない指し棒）。\
        width は 2〜140。eraser を true にすると消しゴムになる。すぐ反映される。
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "color": ["type": "string", "description": "black / red / blue / green / laser"],
                "width": ["type": "number", "description": "線の太さ 2〜140"],
                "eraser": ["type": "boolean", "description": "消しゴムにするか"],
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

func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
    switch name {
    case "set_pen":
        var payload: [String: Any] = [:]
        if let c = args["color"] as? String { payload["color"] = c }
        if let w = args["width"] as? Double { payload["width"] = w }
        if let e = args["eraser"] as? Bool { payload["eraser"] = e }
        guard !payload.isEmpty else { return failure("color / width / eraser のいずれかを指定してください") }
        guard let reply = command("set_pen", payload) else { return failure(notRunning) }
        if reply["ok"] as? Bool != true {
            return failure((reply["error"] as? String) ?? "変更できませんでした")
        }
        return ["content": [text("筆記具を変更しました（太さ \(Int((reply["width"] as? Double) ?? 0))）")]]

    case "read_board":
        let who = (FileManager.default.currentDirectoryPath as NSString).lastPathComponent
        guard let reply = command("capture", ["label": who]) else { return failure(notRunning) }
        if reply["ok"] as? Bool != true {
            return failure((reply["error"] as? String) ?? "取得できませんでした")
        }
        return boardContent(header: "筆談ボードの現在の内容")

    case "wait_for_board":
        let prompt = args["prompt"] as? String
        let limit = min(max((args["timeout_seconds"] as? Double) ?? 55, 5), 600)
        // Claude Code starts an MCP server in the session's own directory, so
        // the folder name is how the person recognises which session is asking.
        let cwd = FileManager.default.currentDirectoryPath
        let label = (cwd as NSString).lastPathComponent
        guard command("wait", ["label": label, "cwd": cwd, "prompt": prompt ?? ""]) != nil else {
            return failure(notRunning)
        }

        let before = boardSeq
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if boardSeq > before {
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
        for key in ["svg", "image_path", "text", "notice"] {
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
