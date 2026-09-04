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
let cases: [(String, () -> [CGPoint])] = [
    ("直線", makeLine), ("円", makeCircle), ("四角", makeRect),
    ("三角", makeTriangle), ("不定形", makeBlob),
    ("なぐり書き", makeScribble), ("波線", makeWave),
]
for (name, make) in cases {
    var hits: [String: Int] = [:]
    var scoreSum: CGFloat = 0
    var minScore: CGFloat = 1, maxScore: CGFloat = 0
    for _ in 0..<40 {
        if let v = r.recognise(make()) {
            hits[v.kind.rawValue, default: 0] += 1
            scoreSum += v.score
            minScore = min(minScore, v.score); maxScore = max(maxScore, v.score)
        }
    }
    let top = hits.max { $0.value < $1.value }
    print(String(format: "%-12@ → %-10@ (%d/40)  平均 %.2f  最小 %.2f  最大 %.2f",
                 name as NSString, (top?.key ?? "-") as NSString, top?.value ?? 0,
                 scoreSum / 40, minScore, maxScore))
}
