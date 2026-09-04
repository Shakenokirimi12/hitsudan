import Foundation

// sampling が本当に使えないのかを、宣言ではなく実際に投げて確かめる探査サーバ。
//   swiftc -O Tools/samplingprobe.swift -o /tmp/samplingprobe
// stdout は JSON-RPC 専用。記録は /tmp/sampling-probe.log へ。

let log = URL(fileURLWithPath: "/tmp/sampling-probe.log")
var logText = ""
func note(_ line: String) {
    logText += line + "\n"
    try? logText.write(to: log, atomically: true, encoding: .utf8)
}

func emit(_ object: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: object),
          let s = String(data: d, encoding: .utf8) else { return }
    print(s); fflush(stdout)
}

/// Send a request *to* the client and read until its answer comes back.
func askClient(_ method: String, _ params: [String: Any], id: Int) -> [String: Any]? {
    emit(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    note("→ \(method) を送信")
    while let line = readLine(strippingNewline: true) {
        guard let d = line.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
        if let rid = m["id"] as? Int, rid == id {
            note("← 応答: \(line.prefix(600))")
            return m
        }
        note("← 別のメッセージ: \(line.prefix(200))")
    }
    note("← stdin が閉じた（応答なし）")
    return nil
}

while let line = readLine(strippingNewline: true) {
    guard let d = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { continue }

    switch method {
    case "initialize":
        let params = msg["params"] as? [String: Any] ?? [:]
        if let caps = params["capabilities"],
           let d = try? JSONSerialization.data(withJSONObject: caps, options: [.prettyPrinted]),
           let s = String(data: d, encoding: .utf8) {
            note("クライアントの申告 capabilities:\n\(s)")
        }
        emit(["jsonrpc": "2.0", "id": id, "result": [
            "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "samplingprobe", "version": "1.0"],
        ]])
    case "tools/list":
        emit(["jsonrpc": "2.0", "id": id, "result": ["tools": [[
            "name": "try_sampling",
            "description": "サーバから sampling/createMessage を投げて、クライアントが応じるか確かめる。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any], "additionalProperties": false],
        ]]]])
    case "tools/call":
        let answer = askClient("sampling/createMessage", [
            "messages": [["role": "user", "content": ["type": "text", "text": "1+1は？数字だけ答えて。"]]],
            "maxTokens": 16,
        ], id: 9001)
        var verdict: String
        if let answer {
            if let err = answer["error"] as? [String: Any] {
                verdict = "sampling は拒否された: \(err)"
            } else if let result = answer["result"] as? [String: Any] {
                verdict = "sampling が通った: \(result)"
            } else {
                verdict = "不明な応答: \(answer)"
            }
        } else {
            verdict = "応答なし（クライアントが無視した）"
        }
        note("判定: \(verdict)")
        emit(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": verdict]]]])
    default:
        emit(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no"]])
    }
}
