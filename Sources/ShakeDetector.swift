import CoreGraphics
import Foundation

struct ShakeDetector {
    let minimumSegmentDistance: CGFloat
    let maximumDuration: TimeInterval
    let cooldownDuration: TimeInterval
    let requiredSegments: Int

    private(set) var segmentCount = 0
    private(set) var isCoolingDown = false
    private var activeDirection: CGFloat = 0
    private var candidateDirection: CGFloat = 0
    private var candidateDistance: CGFloat = 0
    private var startedAt: TimeInterval?
    private var cooldownUntil: TimeInterval = 0
    private var lastPoint: CGPoint?

    init(minimumSegmentDistance: CGFloat = 14,
         maximumDuration: TimeInterval = 0.75,
         cooldownDuration: TimeInterval = 0.8,
         requiredSegments: Int = 4) {
        self.minimumSegmentDistance = minimumSegmentDistance
        self.maximumDuration = maximumDuration
        self.cooldownDuration = cooldownDuration
        self.requiredSegments = max(2, requiredSegments)
    }

    mutating func update(point: CGPoint, inside: Bool, now: TimeInterval) -> Bool {
        guard inside else {
            resetSequence()
            lastPoint = nil
            isCoolingDown = now < cooldownUntil
            return false
        }
        if now < cooldownUntil {
            isCoolingDown = true
            lastPoint = point
            return false
        }
        isCoolingDown = false
        guard let last = lastPoint else {
            lastPoint = point
            return false
        }
        lastPoint = point
        let dx = point.x - last.x
        let dy = point.y - last.y
        guard abs(dx) >= abs(dy) * 1.35, abs(dx) > 0 else { return false }
        let direction: CGFloat = dx > 0 ? 1 : -1

        if let startedAt = startedAt, now - startedAt > maximumDuration {
            resetSequence()
        }
        if activeDirection == 0 {
            activeDirection = direction
            segmentCount = 1
            startedAt = now
            return false
        }
        if direction == activeDirection {
            candidateDirection = 0
            candidateDistance = 0
            return false
        }
        if candidateDirection != direction {
            candidateDirection = direction
            candidateDistance = abs(dx)
        } else {
            candidateDistance += abs(dx)
        }
        guard candidateDistance >= minimumSegmentDistance else { return false }
        activeDirection = direction
        candidateDirection = 0
        candidateDistance = 0
        segmentCount += 1
        guard segmentCount >= requiredSegments else { return false }
        cooldownUntil = now + cooldownDuration
        isCoolingDown = true
        resetSequence()
        return true
    }

    mutating func reset() {
        resetSequence()
        lastPoint = nil
        cooldownUntil = 0
        isCoolingDown = false
    }

    mutating func beginCooldown(now: TimeInterval) {
        resetSequence()
        cooldownUntil = now + cooldownDuration
        isCoolingDown = true
    }

    private mutating func resetSequence() {
        segmentCount = 0
        activeDirection = 0
        candidateDirection = 0
        candidateDistance = 0
        startedAt = nil
    }
}
