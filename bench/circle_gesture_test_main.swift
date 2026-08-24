import Foundation

// Uses CircleGestureDetector.swift (Linux CGPoint shim lives there).

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

func circlePoints(center: CGPoint, radius: CGFloat, count: Int, startAngle: Double = 0) -> [CGPoint] {
    (0..<count).map { i in
        let t = startAngle + (Double(i) / Double(count - 1)) * 2 * Double.pi
        return CGPoint(x: center.x + radius * CGFloat(cos(t)),
                       y: center.y + radius * CGFloat(sin(t)))
    }
}

var detector = CircleGestureDetector()
let center = CGPoint(x: 400, y: 300)
let points = circlePoints(center: center, radius: 80, count: 36)
var recognized: CircleGesture?
var t: TimeInterval = 1.0
for p in points {
    if let g = detector.add(point: p, at: t) {
        recognized = g
        break
    }
    t += 0.02
}

expect(recognized != nil, "closed circular stroke recognizes a gesture")
if let g = recognized {
    let dx = abs(g.center.x - center.x)
    let dy = abs(g.center.y - center.y)
    expect(dx < 40 && dy < 40,
           "gesture center near stroke center (dx=\(Int(dx)) dy=\(Int(dy)))")
    expect(abs(g.radius - 80) < 25, "gesture radius near stroke radius")
}

// Straight line must not count as a circle.
detector.reset()
var lineHit: CircleGesture?
t = 10
for i in 0..<40 {
    let p = CGPoint(x: 100 + CGFloat(i) * 5, y: 200)
    if let g = detector.add(point: p, at: t) { lineHit = g; break }
    t += 0.02
}
expect(lineHit == nil, "straight line is not a circle")

// Too few samples → no gesture.
detector.reset()
var few: CircleGesture?
t = 20
for p in circlePoints(center: center, radius: 60, count: 10) {
    if let g = detector.add(point: p, at: t) { few = g; break }
    t += 0.02
}
expect(few == nil, "fewer than 18 samples → no gesture")

// Cooldown: second immediate circle after recognition is suppressed.
detector.reset()
t = 30
var first: CircleGesture?
var second: CircleGesture?
for p in circlePoints(center: center, radius: 70, count: 36) {
    if let g = detector.add(point: p, at: t) {
        if first == nil { first = g } else { second = g; break }
    }
    t += 0.02
}
for p in circlePoints(center: CGPoint(x: 500, y: 300), radius: 70, count: 36) {
    if let g = detector.add(point: p, at: t) {
        second = g
        break
    }
    t += 0.02
}
expect(first != nil, "first circle recognized")
expect(second == nil, "immediate second circle suppressed by cooldown/exit")

if failures == 0 {
    print("✓ circle gesture scenarios passed")
    exit(0)
} else {
    print("✗ \(failures) circle gesture scenario(s) failed")
    exit(1)
}
