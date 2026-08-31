import AppKit

enum SiloStatusIcon {
    enum State: Equatable, Sendable {
        case healthy
        case active
        case attention
        case critical
        case offline
    }

    static func state(
        health: MonitorHealth,
        runtimeRepairRequired: Bool,
        workspaces: [Workspace],
        hasActiveOperation: Bool
    ) -> State {
        if runtimeRepairRequired { return .attention }
        if health.severity == .critical { return .critical }
        if health.severity == .neutral || workspaces.contains(where: {
            $0.state == .unavailable || $0.freshness == .unavailable
        }) {
            return .offline
        }
        if health.severity == .attention { return .attention }
        if hasActiveOperation || workspaces.contains(where: {
            switch $0.state {
            case .running, .starting, .stopping, .restarting: return true
            default: return false
            }
        }) {
            return .active
        }
        return .healthy
    }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { bounds in
            drawMark(in: bounds)
            switch state {
            case .healthy:
                break
            case .active:
                drawRingDotBadge(in: bounds)
            case .attention:
                drawAttentionBadge(in: bounds)
            case .critical:
                drawCriticalBadge(in: bounds)
            case .offline:
                drawOfflineSlash(in: bounds)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Silo"
        return image
    }

    static func tint(for state: State) -> NSColor? {
        switch state {
        case .healthy: nil
        case .active: .systemBlue
        case .attention: .systemOrange
        case .critical: .systemRed
        case .offline: .tertiaryLabelColor
        }
    }

    private static func drawMark(in bounds: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        drawLevel(center: center, radius: 7.25, start: -28, sweep: 360 * 42 / 52, width: 1.45)
        drawLevel(center: center, radius: 4.9, start: 63, sweep: 360 * 27 / 35, width: 1.45)
        drawLevel(center: center, radius: 2.65, start: 154, sweep: 360 * 13 / 19, width: 1.45)
    }

    private static func drawLevel(center: NSPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, width: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + sweep)
        NSColor.black.setStroke()
        path.stroke()
    }

    private static func drawRingDotBadge(in bounds: NSRect) {
        let center = NSPoint(x: bounds.maxX - 3.7, y: bounds.maxY - 3.7)
        clearCircle(center: center, radius: 3.2)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 2.45, y: center.y - 2.45, width: 4.9, height: 4.9))
        ring.lineWidth = 1.15
        NSColor.black.setStroke()
        ring.stroke()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 0.7, y: center.y - 0.7, width: 1.4, height: 1.4)).fill()
    }

    private static func drawAttentionBadge(in bounds: NSRect) {
        let center = NSPoint(x: bounds.maxX - 3.7, y: bounds.maxY - 3.7)
        clearCircle(center: center, radius: 3.6)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2.9, y: center.y - 2.9, width: 5.8, height: 5.8)).fill()
        clearLine(from: NSPoint(x: center.x, y: center.y + 1.45), to: NSPoint(x: center.x, y: center.y - 0.35), width: 0.9)
        clearCircle(center: NSPoint(x: center.x, y: center.y - 1.55), radius: 0.45)
    }

    private static func drawCriticalBadge(in bounds: NSRect) {
        let center = NSPoint(x: bounds.maxX - 3.7, y: bounds.maxY - 3.7)
        clearCircle(center: center, radius: 3.6)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2.9, y: center.y - 2.9, width: 5.8, height: 5.8)).fill()
        clearLine(from: NSPoint(x: center.x - 1.15, y: center.y - 1.15), to: NSPoint(x: center.x + 1.15, y: center.y + 1.15), width: 0.9)
        clearLine(from: NSPoint(x: center.x - 1.15, y: center.y + 1.15), to: NSPoint(x: center.x + 1.15, y: center.y - 1.15), width: 0.9)
    }

    private static func drawOfflineSlash(in bounds: NSRect) {
        let start = NSPoint(x: bounds.minX + 4.1, y: bounds.maxY - 3.9)
        let end = NSPoint(x: bounds.maxX - 3.9, y: bounds.minY + 4.1)
        clearLine(from: start, to: end, width: 3.1)
        let slash = NSBezierPath()
        slash.move(to: start)
        slash.line(to: end)
        slash.lineWidth = 1.3
        slash.lineCapStyle = .round
        NSColor.black.setStroke()
        slash.stroke()
    }

    private static func clearCircle(center: NSPoint, radius: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        context.restoreGraphicsState()
    }

    private static func clearLine(from start: NSPoint, to end: NSPoint, width: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        let line = NSBezierPath()
        line.move(to: start)
        line.line(to: end)
        line.lineWidth = width
        line.lineCapStyle = .round
        line.stroke()
        context.restoreGraphicsState()
    }
}

extension AppModel {
    var statusIconState: SiloStatusIcon.State {
        SiloStatusIcon.state(
            health: health,
            runtimeRepairRequired: runtimeRepairRequired,
            workspaces: workspaces,
            hasActiveOperation: hasActiveBackupOperations || isMaintenanceOperationInFlight
        )
    }
}
