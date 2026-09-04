// 図形認識のしきい値を決めるための合成データ検証。
//   swiftc -O Sources/DollarRecognizer.swift Tools/rectest.swift -o /tmp/rectest && /tmp/rectest
// （トップレベルコードなので main.swift という名前でコピーして渡すこと）

import Foundation

func noisy(_ p: CGPoint, _ n: CGFloat) -> CGPoint {
    CGPoint(x: p.x + CGFloat.random(in: -n...n), y: p.y + CGFloat.random(in: -n...n))
}

func makeLine() -> [CGPoint] {
    (0..<70).map { noisy(CGPoint(x: CGFloat($0) * 6 + 100, y: CGFloat($0) * 2 + 200), 4) }
}
func makeCircle() -> [CGPoint] {
    (0..<90).map { i -> CGPoint in
        let t = CGFloat(i) / 90 * 2 * .pi
        return noisy(CGPoint(x: 400 + cos(t) * 150, y: 300 + sin(t) * 120), 7)
    }
}
func makeRect() -> [CGPoint] {
    let c = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 100),
             CGPoint(x: 400, y: 300), CGPoint(x: 100, y: 300)]
    var out: [CGPoint] = []
    for i in 0..<4 {
        let a = c[i], b = c[(i + 1) % 4]
        for s in 0..<25 {
            let t = CGFloat(s) / 25
            out.append(noisy(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), 8))
        }
    }
    out.append(noisy(c[0], 8))
    return out
}
func makeTriangle() -> [CGPoint] {
    let c = [CGPoint(x: 250, y: 80), CGPoint(x: 420, y: 340), CGPoint(x: 80, y: 340)]
    var out: [CGPoint] = []
    for i in 0..<3 {
        let a = c[i], b = c[(i + 1) % 3]
        for s in 0..<32 {
            let t = CGFloat(s) / 32
            out.append(noisy(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), 8))
        }
    }
    out.append(noisy(c[0], 8))
    return out
}
func makeBlob() -> [CGPoint] {
    (0..<80).map { i -> CGPoint in
        let t = CGFloat(i) / 80 * 2 * .pi
        let r = 120 + sin(t * 2.3) * 60 + cos(t * 4.7) * 45
        return noisy(CGPoint(x: 300 + cos(t) * r, y: 300 + sin(t) * r * 0.8), 6)
    }
}

func makeScribble() -> [CGPoint] {
    var p = CGPoint(x: 300, y: 300)
    var out: [CGPoint] = []
    for _ in 0..<90 {
        p = CGPoint(x: p.x + CGFloat.random(in: -30...30), y: p.y + CGFloat.random(in: -30...30))
        out.append(p)
    }
    return out
}

func makeWave() -> [CGPoint] {
    (0..<80).map { i -> CGPoint in
        let x = CGFloat(i) * 6
        return noisy(CGPoint(x: 80 + x, y: 260 + sin(x / 40) * 90), 4)
    }
}

let r = DollarRecognizer()
let threshold: CGFloat = 0.88

/// 正しく整形されるべき形と、整形してはいけない形。CI はここで落ちる。
let shouldSnap: [(String, Unistroke, () -> [CGPoint])] = [
    ("直線", .line, makeLine),
    ("円", .circle, makeCircle),
    ("四角", .rectangle, makeRect),
    ("三角", .triangle, makeTriangle),
]
let shouldNotSnap: [(String, () -> [CGPoint])] = [
    ("不定形", makeBlob),
    ("なぐり書き", makeScribble),
    ("波線", makeWave),
]

var failures = 0
let trials = 40

for (name, expected, make) in shouldSnap {
    var wrong = 0, below = 0
    var worst: CGFloat = 1
    for _ in 0..<trials {
        guard let v = r.recognise(make()) else { wrong += 1; continue }
        if v.kind != expected { wrong += 1 }
        if v.score <= threshold { below += 1 }
        worst = min(worst, v.score)
    }
    let ok = wrong == 0 && below == 0
    if !ok { failures += 1 }
    print(String(format: "%@ %-10@ → %@  誤判定 %d/%d  閾値割れ %d/%d  最小スコア %.3f",
                 (ok ? "PASS" : "FAIL") as NSString, name as NSString,
                 expected.rawValue as NSString, wrong, trials, below, trials, worst))
}

for (name, make) in shouldNotSnap {
    var snapped = 0
    var highest: CGFloat = 0
    for _ in 0..<trials {
        guard let v = r.recognise(make()) else { continue }
        if v.score > threshold { snapped += 1 }
        highest = max(highest, v.score)
    }
    let ok = snapped == 0
    if !ok { failures += 1 }
    print(String(format: "%@ %-10@ → 補正されない  誤補正 %d/%d  最大スコア %.3f",
                 (ok ? "PASS" : "FAIL") as NSString, name as NSString, snapped, trials, highest))
}

if failures > 0 {
    FileHandle.standardError.write("\n\(failures) 件の判定が期待どおりではありません\n".data(using: .utf8)!)
    exit(1)
}
print("\nすべて期待どおり（閾値 \(threshold)）")
