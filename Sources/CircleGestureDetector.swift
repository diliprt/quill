import Foundation
#if canImport(CoreGraphics) && os(macOS)
import CoreGraphics
#else
struct CGPoint: Equatable {
    var x: Double
    var y: Double
}
typealias CGFloat = Double
#endif

// Circle-gesture detection adapted from BetterVoice (MIT, TarunTomar122/better-voice).

struct CircleGesture: Equatable {
    let center: CGPoint
    let radius: CGFloat
}

/// Detects one closed, roughly circular mouse stroke at a time.
struct CircleGestureDetector {
    private struct Sample {
        let point: CGPoint
        let time: TimeInterval
    }

    private var samples: [Sample] = []
    private var cooldownUntil: TimeInterval = 0
    private var waitingForExit: CircleGesture?
    private let window: TimeInterval = 6

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        cooldownUntil = 0
        waitingForExit = nil
    }

    mutating func add(point: CGPoint, at time: TimeInterval) -> CircleGesture? {
        if let gesture = waitingForExit {
            guard Self.distance(point, gesture.center) > gesture.radius * 1.5 else {
                return nil
            }
            waitingForExit = nil
            samples.removeAll(keepingCapacity: true)
        }

        guard time >= cooldownUntil else { return nil }

        if let previous = samples.last, time - previous.time > 0.45 {
            samples.removeAll(keepingCapacity: true)
        }

        samples.append(Sample(point: point, time: time))
        let cutoff = time - window
        samples.removeAll { $0.time < cutoff }

        guard samples.count >= 18 else { return nil }
        guard let gesture = recognizedGesture() else { return nil }

        samples.removeAll(keepingCapacity: true)
        cooldownUntil = time + 0.65
        waitingForExit = gesture
        return gesture
    }

    private func recognizedGesture() -> CircleGesture? {
        guard let last = samples.last?.point else { return nil }
        for start in stride(from: samples.count - 18, through: 0, by: -1) {
            let first = samples[start].point
            guard Self.distance(first, last) < 160 else { continue }
            if let gesture = recognizedGesture(in: Array(samples[start...])) {
                return gesture
            }
        }
        return nil
    }

    private func recognizedGesture(in samples: [Sample]) -> CircleGesture? {
        guard let first = samples.first?.point, let last = samples.last?.point else { return nil }
        guard samples.count >= 18 else { return nil }
        guard Self.distance(first, last) < 160 else { return nil }

        let points = samples.map(\.point)
        let centerX = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let centerY = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let center = CGPoint(x: centerX, y: centerY)

        let distances = points.map { Self.distance($0, center) }
        let mean = distances.reduce(0, +) / CGFloat(distances.count)
        guard mean > 18 else { return nil }

        let varianceSum = distances.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
        let variance = varianceSum / CGFloat(distances.count)
        let std = variance.squareRoot()
        guard std / mean < 0.42 else { return nil }

        let perimeter = zip(points, points.dropFirst()).map { Self.distance($0, $1) }.reduce(0, +)
        let straight = Self.distance(last, first)
        guard straight > 0, perimeter / straight > 2.2 else { return nil }

        return CircleGesture(center: center, radius: mean)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
