import Foundation

extension HikingRoute {
    public struct Progress: Sendable {
        public let offset: Double
        let position: MapPoint
        let shapeIndex: Double
        let distanceAlong: Double
    }

    /// Prefer the geometric nearest segment. When segments overlap, use recent progress
    /// and movement to choose the plausible leg without advancing at a stationary crossing.
    public func match(_ position: MapPoint, following previous: Progress? = nil) -> Progress? {
        guard points.count > 1 else { return nil }
        let latitudeScale = 111_195.0 / 1e7
        let longitudeScale = latitudeScale * cos(Double(position.latE7) * .pi / 1.8e9)
        func offset(_ point: MapPoint) -> (x: Double, y: Double) {
            ((Double(point.lonE7) - Double(position.lonE7)) * longitudeScale,
             (Double(point.latE7) - Double(position.latE7)) * latitudeScale)
        }

        let priorOffset = previous.map { offset($0.position) }
        let travelled = priorOffset.map { hypot($0.x, $0.y) } ?? 0
        var nearest: Progress?
        var consecutive: Progress?
        var score = Double.infinity
        var cumulative = 0.0
        var start = offset(points[0])
        for index in 1..<points.count {
            let end = offset(points[index])
            let x = end.x - start.x
            let y = end.y - start.y
            let length = hypot(x, y)
            let fraction = length == 0 ? 0 : min(1, max(0, -(start.x * x + start.y * y) / (length * length)))
            let candidate = Progress(offset: hypot(start.x + x * fraction, start.y + y * fraction),
                                     position: position, shapeIndex: Double(index - 1) + fraction,
                                     distanceAlong: cumulative + length * fraction)
            if nearest.map({ candidate.offset < $0.offset }) ?? true { nearest = candidate }
            if let previous, let priorOffset {
                let expected = previous.distanceAlong + travelled
                let gap = abs(candidate.distanceAlong - expected)
                if gap <= max(30, travelled * 3) {
                    let reverses = length > 0 && travelled > 5 && (priorOffset.x * x + priorOffset.y * y) > 0
                    let candidateScore = gap + candidate.offset * 2 + (reverses ? min(20, travelled) : 0)
                    if candidateScore < score {
                        consecutive = candidate
                        score = candidateScore
                    }
                }
            }
            cumulative += length
            start = end
        }
        if let nearest, let consecutive, consecutive.offset <= nearest.offset + 8 {
            return consecutive
        }
        return nearest
    }

    public func isAtDestination(_ progress: Progress, tolerance: Double) -> Bool {
        guard let end = points.last, progress.shapeIndex >= Double(points.count - 2) else { return false }
        return Self.meters(progress.position, end) <= tolerance
    }

    public func nextInstruction(at progress: Progress) -> String? {
        maneuvers.first {
            !$0.isArrival && $0.pointIndex < points.count - 1 && Double($0.pointIndex) >= progress.shapeIndex
        }?.instruction
    }
}
