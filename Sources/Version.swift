import Foundation

/// 更新判定のためだけの、ごく素朴なバージョン番号。
///
/// `v1.2.3` も `1.2` も受ける。ハイフン以降（`1.0-beta.2` のプレリリース部分）は
/// 比較に使わない。桁数が違うときは短いほうを 0 で埋めるので `1.2` と `1.2.0` は
/// 等しい。SemVer を完全に実装しないのは、このアプリのタグが `vX.Y.Z` しか
/// 取らないため。
struct Version: Comparable, CustomStringConvertible {

    /// 比較に使う数値。`1.2.3` なら `[1, 2, 3]`。
    let parts: [Int]
    /// 表示用に、渡された文字列をそのまま持っておく。
    let raw: String

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = Substring(trimmed)
        if body.first == "v" || body.first == "V" { body = body.dropFirst() }

        // プレリリース（-beta）とビルドメタデータ（+abc）は落とす
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) { body = body[..<cut] }

        let fields = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty else { return nil }

        var nums: [Int] = []
        for field in fields {
            // 空（"1..2" や "1."）も、数字以外も受け付けない。Int("+1") や
            // Int("-1") を通してしまわないよう、桁だけでできていることを見る。
            guard !field.isEmpty, field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(field) else { return nil }
            nums.append(n)
        }
        parts = nums
        raw = trimmed
    }

    static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    var description: String { raw }
}
