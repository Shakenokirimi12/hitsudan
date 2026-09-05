// バージョン比較の判定テスト。桁上がり（1.9 < 1.10）と桁数違い（1.2 == 1.2.0）を
// 取り違えると、更新が出ているのに気づかない／既に新しいのに上書きする、の
// どちらかが起きる。
//   swiftc -O Sources/Version.swift Tools/versiontest.swift -o /tmp/versiontest
// （トップレベルコードなので main.swift という名前でコピーして渡すこと）

import Foundation

var failures = 0

func check(_ label: String, _ ok: Bool) {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(label)")
}

func v(_ s: String) -> Version {
    guard let parsed = Version(s) else {
        failures += 1
        print("FAIL \(s) を読めません")
        return Version("0")!
    }
    return parsed
}

// 読める形
check("v 付きを剥がす", v("v1.2.3").parts == [1, 2, 3])
check("v 無しも同じ", v("1.2.3").parts == [1, 2, 3])
check("前後の空白を無視", v("  1.2.3 ").parts == [1, 2, 3])
check("プレリリースは無視", v("1.0-beta.2") == v("1.0"))
check("ビルドメタデータも無視", v("1.0+abc") == v("1.0"))

// 大小関係。1.9 < 1.10 は文字列比較だと逆になる
check("1.9.0 < 1.10.0", v("1.9.0") < v("1.10.0"))
check("1.10.0 > 1.9.0", v("1.10.0") > v("1.9.0"))
check("2.0 > 1.99.99", v("2.0") > v("1.99.99"))
check("0.0.1 > 0.0.0", v("0.0.1") > v("0.0.0"))
check("桁数違いは 0 埋め", v("1.2") == v("1.2.0"))
check("1.2 < 1.2.1", v("1.2") < v("1.2.1"))
check("同じなら等しい", v("v1.0.0") == v("1.0.0"))
check("自分自身より大きくない", !(v("1.2.3") < v("1.2.3")))

// 受け付けてはいけない形。ここが緩いと、壊れたタグ名を 0 と読んで
// 「更新あり」と誤判定する
for bad in ["", "abc", "1..2", "1.", ".1", "1.x", "1.-2", "1.+2", "v", "１.２"] {
    check("『\(bad)』を拒む", Version(bad) == nil)
}

if failures > 0 {
    FileHandle.standardError.write("\n\(failures) 件が期待どおりではありません\n".data(using: .utf8)!)
    exit(1)
}
print("\nバージョン比較はすべて期待どおり")
