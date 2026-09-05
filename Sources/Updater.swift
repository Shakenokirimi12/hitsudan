import AppKit
import Foundation

/// GitHub Releases を見て、新しければ自分を差し替える。
///
/// Sparkle を入れないのは、このアプリが依存ゼロで `swiftc` 直叩きだから。
/// フレームワークを抱えると、ビルドも配布も署名も一段複雑になる。やることは
/// 「latest を見る → zip を落とす → 検証する → 差し替えて再起動」だけなので、
/// 手で書いたほうが読める。
///
/// **落としたものをそのまま起動しないこと。** 配布経路（GitHub アカウント、
/// リリース資産）が乗っ取られたら、そのまま任意コード実行になる。差し替える
/// 前に署名・公証・Team ID の一致を確かめる。
enum Updater {

    static let repo = "Shakenokirimi12/hitsudan"
    static let assetName = "Hitsudan.app.zip"

    struct ReleaseInfo {
        let version: Version
        let notes: String
        let zip: URL
    }

    enum Failure: LocalizedError {
        case network(String)
        case malformed(String)
        case noAsset
        case rejected(String)
        case notWritable(String)
        case notBundled

        var errorDescription: String? {
            switch self {
            case .network(let why):    return "通信に失敗しました。\(why)"
            case .malformed(let why):  return "リリース情報を読めませんでした。\(why)"
            case .noAsset:             return "リリースに \(Updater.assetName) が含まれていません。"
            case .rejected(let why):   return "配布物を信用できないため中止しました。\(why)"
            case .notWritable(let at): return "\(at) に書き込めません。アプリを /Applications か ~/Applications に置いてから試してください。"
            case .notBundled:          return "アプリバンドルとして起動していないため、自動更新は使えません。"
            }
        }
    }

    /// 実行中の自分のバージョン。Info.plist の値はタグから焼き込まれる（build.sh）。
    static var current: Version {
        let text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return Version(text) ?? Version("0.0.0")!
    }

    // MARK: - 確認

    /// 成功して `nil` なら最新。新しいものがあれば `ReleaseInfo` を返す。
    static func check(completion: @escaping (Result<ReleaseInfo?, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(.failure(Failure.malformed("URL を組み立てられません")))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API は User-Agent が無いと 403 を返す
        request.setValue("Hitsudan/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(Failure.network(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // 非公開リポジトリだと匿名アクセスは 404 になる（403 ではない）。
                // トークンを焼き込むわけにいかないので、自動更新はリポジトリか
                // Release が公開されていることが前提。
                let detail = http.statusCode == 404
                    ? "リリースが見つかりません。リポジトリが非公開のままだと、この確認は必ず失敗します。"
                    : "HTTP \(http.statusCode) が返りました。"
                completion(.failure(Failure.network(detail)))
                return
            }
            guard let data else {
                completion(.failure(Failure.network("応答が空でした。")))
                return
            }
            do { completion(.success(try parse(data))) } catch { completion(.failure(error)) }
        }.resume()
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let url: String
            enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
        }
        let tag: String
        let notes: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", notes = "body", draft, prerelease, assets
        }
    }

    /// テストしやすいよう通信と分けてある。
    static func parse(_ data: Data) throws -> ReleaseInfo? {
        let release: APIRelease
        do {
            release = try JSONDecoder().decode(APIRelease.self, from: data)
        } catch {
            throw Failure.malformed(error.localizedDescription)
        }
        // /releases/latest は本来 draft と prerelease を返さないが、念のため。
        if release.draft == true || release.prerelease == true { return nil }

        guard let version = Version(release.tag) else {
            throw Failure.malformed("タグ『\(release.tag)』をバージョンとして読めません。")
        }
        guard version > current else { return nil }

        guard let asset = release.assets.first(where: { $0.name == assetName }),
              let zip = URL(string: asset.url), zip.scheme == "https" else {
            throw Failure.noAsset
        }
        return ReleaseInfo(version: version,
                           notes: (release.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                           zip: zip)
    }

    // MARK: - 適用

    static func install(_ release: ReleaseInfo, completion: @escaping (Result<Void, Error>) -> Void) {
        let running = Bundle.main.bundleURL
        guard running.pathExtension == "app" else {
            completion(.failure(Failure.notBundled))
            return
        }

        URLSession.shared.downloadTask(with: release.zip) { temp, response, error in
            if let error {
                completion(.failure(Failure.network(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                completion(.failure(Failure.network("ダウンロードが HTTP \(http.statusCode) で失敗しました。")))
                return
            }
            guard let temp else {
                completion(.failure(Failure.network("ダウンロードした中身がありません。")))
                return
            }
            do {
                try apply(downloaded: temp, over: running, expecting: release)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func apply(downloaded zip: URL, over running: URL,
                              expecting release: ReleaseInfo) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("hitsudan-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // downloadTask の一時ファイルは拡張子が無い。ditto は中身で判断するので
        // そのままで通るが、失敗時のログを読みやすくするため名前を付けておく。
        let archive = work.appendingPathComponent(assetName)
        try fm.moveItem(at: zip, to: archive)

        let unpacked = work.appendingPathComponent("unpacked")
        let extraction = try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
        guard extraction.status == 0 else {
            throw Failure.malformed("展開に失敗しました。\(extraction.output)")
        }

        let apps = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let fresh = apps.first else {
            throw Failure.malformed("展開した中に .app がちょうど 1 つありません（\(apps.count) 個）。")
        }

        try verify(fresh, against: running, expecting: release)
        try swap(fresh, over: running)
    }

    /// 差し替える前の関門。ここを緩めると、リリース資産を差し替えられただけで
    /// 任意のコードが動くことになる。
    private static func verify(_ candidate: URL, against running: URL,
                               expecting release: ReleaseInfo) throws {
        // 1. 署名そのものが壊れていないか。
        let signature = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        guard signature.status == 0 else {
            throw Failure.rejected("署名を検証できませんでした。\(signature.output)")
        }

        // 2. 公証まで通っているか。spctl はチケットを見るので、アドホック署名や
        //    公証前のビルドはここで落ちる。--verify だけでは通ってしまう。
        let gatekeeper = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", candidate.path])
        guard gatekeeper.status == 0 else {
            throw Failure.rejected("公証を確認できませんでした。\(gatekeeper.output)")
        }

        // 3. いま動いている自分と同じ開発者のものか。公証済みでも、別人の
        //    正規に公証されたアプリと差し替えられては意味がない。
        guard let mine = teamIdentifier(of: running) else {
            throw Failure.rejected("いま動いているアプリが Developer ID 署名ではありません（手元ビルドは自動更新の対象外です）。")
        }
        guard let theirs = teamIdentifier(of: candidate) else {
            throw Failure.rejected("配布物に Team ID がありません。")
        }
        guard theirs == mine else {
            throw Failure.rejected("配布物の Team ID（\(theirs)）が、いまのアプリ（\(mine)）と一致しません。")
        }

        // ここから先は、署名としては正しいものが「本当に期待した中身か」を見る。
        // 署名が通ることと、望んだアプリの望んだバージョンであることは別。
        guard let info = Bundle(url: candidate)?.infoDictionary else {
            throw Failure.rejected("配布物の Info.plist を読めません。")
        }

        // 4. そもそも筆談ボードか。同じ Team ID で公証された別のアプリが、
        //    同じ名前の資産として付いていた場合にそれで上書きしてしまわない。
        guard let theirID = info["CFBundleIdentifier"] as? String,
              let myID = Bundle.main.bundleIdentifier else {
            throw Failure.rejected("バンドル ID を確認できません。")
        }
        guard theirID == myID else {
            throw Failure.rejected("配布物のバンドル ID（\(theirID)）が、いまのアプリ（\(myID)）と違います。")
        }

        // 5. 中身が名乗るバージョンがタグと合っているか。タグと zip はいくらでも
        //    食い違いうる（古い zip を貼り直した、資産を差し替えた）。ここを見ない
        //    と、古いものを入れておいて「更新しました」と言い、次回もまた同じ更新を
        //    勧め続けることになる。
        guard let shipped = (info["CFBundleShortVersionString"] as? String).flatMap(Version.init) else {
            throw Failure.rejected("配布物のバージョンを読めません。")
        }
        guard shipped == release.version else {
            throw Failure.rejected("配布物のバージョン（\(shipped)）がタグ（\(release.version)）と一致しません。")
        }
        guard shipped > current else {
            throw Failure.rejected("配布物のバージョン（\(shipped)）が、いま動いている \(current) より新しくありません。")
        }
    }

    private static func teamIdentifier(of bundle: URL) -> String? {
        guard let result = try? run("/usr/bin/codesign", ["-dvv", bundle.path]) else { return nil }
        for line in result.output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = String(line.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespaces)
            return value == "not set" || value.isEmpty ? nil : value
        }
        return nil
    }

    private static func swap(_ fresh: URL, over running: URL) throws {
        let fm = FileManager.default
        let parent = running.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw Failure.notWritable(parent.path)
        }
        // replaceItemAt はボリュームを跨ぐと弱いので、まず同じ階層へ移す。
        let staged = parent.appendingPathComponent(".\(running.lastPathComponent).new-\(UUID().uuidString)")
        try fm.moveItem(at: fresh, to: staged)
        do {
            _ = try fm.replaceItemAt(running, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// 起動中の自分を終わらせて、差し替わったほうを開き直す。
    static func relaunch() {
        let target = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    // 新しいほうが起動しなかったのに古いほうを終わらせると、
                    // 書きかけのボードごと道連れになる。開き直せなかったこと
                    // だけ伝えて、いま動いているプロセスは残す。
                    let sheet = NSAlert()
                    sheet.messageText = "更新は済みましたが、開き直せませんでした"
                    sheet.informativeText = "このまま使い続けられます。あとで手動で終了して起動し直してください。\n\n"
                        + error.localizedDescription
                    sheet.alertStyle = .warning
                    sheet.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    sheet.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // waitUntilExit より先に読み切らないと、出力がパイプを埋めた時点で止まる。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// メニューから叩く側。確認 → 提示 → 適用 → 開き直し、をユーザーに見せる。
/// 起動時の自動チェックはしない（黙って通信しないため）。メニューを選んだ
/// ときだけ動く。
enum UpdatePrompt {

    /// 確認中・適用中はメニュー項目を無効にするために見る。
    private(set) static var isBusy = false
    /// 状態が変わったらメニューを組み直してもらう。
    static var onStateChange: (() -> Void)?

    static func check() {
        guard !isBusy else { return }
        setBusy(true)
        Updater.check { result in
            DispatchQueue.main.async {
                setBusy(false)
                switch result {
                case .failure(let error):
                    notify("更新を確認できませんでした", error.localizedDescription, .warning)
                case .success(.none):
                    notify("最新版です", "バージョン \(Updater.current) を使っています。", .informational)
                case .success(.some(let release)):
                    offer(release)
                }
            }
        }
    }

    private static func setBusy(_ value: Bool) {
        isBusy = value
        onStateChange?()
    }

    private static func offer(_ release: Updater.ReleaseInfo) {
        let sheet = NSAlert()
        sheet.messageText = "バージョン \(release.version) が公開されています"
        var body = "いま使っているのは \(Updater.current) です。"
        if !release.notes.isEmpty { body += "\n\n" + String(release.notes.prefix(800)) }
        sheet.informativeText = body
        sheet.alertStyle = .informational
        sheet.addButton(withTitle: "更新する")
        sheet.addButton(withTitle: "あとで")
        NSApp.activate(ignoringOtherApps: true)
        guard sheet.runModal() == .alertFirstButtonReturn else { return }

        setBusy(true)
        Updater.install(release) { result in
            DispatchQueue.main.async {
                setBusy(false)
                switch result {
                case .failure(let error):
                    notify("更新できませんでした", error.localizedDescription, .warning)
                case .success:
                    let done = NSAlert()
                    done.messageText = "バージョン \(release.version) に更新しました"
                    done.informativeText = "アプリを開き直します。同じ Developer ID で署名されているので、"
                        + "入力監視とアクセシビリティの許可は通常そのまま引き継がれます。"
                    done.addButton(withTitle: "開き直す")
                    NSApp.activate(ignoringOtherApps: true)
                    done.runModal()
                    Updater.relaunch()
                }
            }
        }
    }

    private static func notify(_ title: String, _ detail: String, _ style: NSAlert.Style) {
        let sheet = NSAlert()
        sheet.messageText = title
        sheet.informativeText = detail
        sheet.alertStyle = style
        sheet.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        sheet.runModal()
    }
}
