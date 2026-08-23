import CoreGraphics
import Foundation

// Trail segment helper adapted from BetterVoice (MIT, TarunTomar122/better-voice).

struct TrailSegment: Equatable {
    let from: Int
    let to: Int
}

/// Links only nearby samples so pauses and pointer jumps leave separate tail strokes.
func trailSegments(
    points: [CGPoint],
    times: [TimeInterval],
    maximumGap: TimeInterval = 0.18,
    maximumDistance: CGFloat = 160
) -> [TrailSegment] {
    guard points.count == times.count, points.count > 1 else { return [] }

    return (1..<points.count).compactMap { index in
        let gap = times[index] - times[index - 1]
        let distance = hypot(
            points[index].x - points[index - 1].x,
            points[index].y - points[index - 1].y
        )
        guard gap >= 0, gap <= maximumGap, distance <= maximumDistance else { return nil }
        return TrailSegment(from: index - 1, to: index)
    }
}
