import SwiftUI

// MARK: - VoiceprintMapView

/// The speaker map (`docs/design/19-voiceprint-map.md` §5): a 2D scatter of the registered
/// voiceprints, where spatial closeness approximates voice closeness. Same-person-suspect pairs
/// (true 256-d distance under the match threshold, §4) get a dashed warning edge with the distance
/// value — drawn no matter how far apart the projection happens to place them, because the 2D
/// layout is only ever a hint (§4's invariant).
///
/// No axes or ticks are drawn — PCA axes carry no meaning (§4).
struct VoiceprintMapView: View {
    let points: [VoiceprintMapLayout.SpeakerPoint]
    let closePairs: [VoiceprintMapLayout.ClosePair]
    /// Display names looked up per speaker id (the layout types carry ids only).
    let namesById: [String: String]
    @Binding var selectedSpeakerId: String?

    /// How close (in view points) a tap must land to a dot to select it.
    private static let hitRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let positions = Self.screenPositions(for: points, in: geometry.size)
            Canvas { context, _ in
                drawEdges(context: context, positions: positions)
                drawPoints(context: context, positions: positions)
                drawLabels(context: context, positions: positions, bounds: geometry.size)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                selectedSpeakerId = Self.speakerId(
                    at: location, positions: positions, currentSelection: selectedSpeakerId
                )
            }
        }
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("話者マップ")
        .accessibilityValue("\(points.count) 人の話者")
    }

    // MARK: - Geometry

    /// Maps the layout's abstract coordinates into `size`, preserving the aspect ratio (both axes
    /// share one scale — the map's whole point is that distances are comparable, so stretching one
    /// axis would distort them). Degenerate extents (single point, or the 2-speaker 1D layout's
    /// flat y axis) center on that axis.
    static func screenPositions(
        for points: [VoiceprintMapLayout.SpeakerPoint], in size: CGSize
    ) -> [(id: String, position: CGPoint)] {
        guard !points.isEmpty else { return [] }
        let inset: CGFloat = 32
        let usableWidth = max(size.width - inset * 2, 1)
        let usableHeight = max(size.height - inset * 2, 1)

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return [] }
        let extentX = maxX - minX
        let extentY = maxY - minY
        let scale: CGFloat = {
            let scaleX = extentX > 0 ? usableWidth / CGFloat(extentX) : .infinity
            let scaleY = extentY > 0 ? usableHeight / CGFloat(extentY) : .infinity
            let combined = min(scaleX, scaleY)
            return combined.isFinite ? combined : 0
        }()

        return points.map { point in
            let offsetX = (usableWidth - CGFloat(extentX) * scale) / 2
            let offsetY = (usableHeight - CGFloat(extentY) * scale) / 2
            return (
                id: point.speakerId,
                position: CGPoint(
                    x: inset + offsetX + CGFloat(point.x - minX) * scale,
                    y: inset + offsetY + CGFloat(point.y - minY) * scale
                )
            )
        }
    }

    /// Nearest dot within `hitRadius`, or `nil` (tap on empty space clears the selection).
    /// Tapping the already-selected dot toggles it off.
    static func speakerId(
        at location: CGPoint,
        positions: [(id: String, position: CGPoint)],
        currentSelection: String?
    ) -> String? {
        let nearest = positions
            .map { (id: $0.id, distance: hypot($0.position.x - location.x, $0.position.y - location.y)) }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= hitRadius else { return nil }
        return nearest.id == currentSelection ? nil : nearest.id
    }

    // MARK: - Drawing

    private func drawEdges(
        context: GraphicsContext, positions: [(id: String, position: CGPoint)]
    ) {
        let positionById = Dictionary(uniqueKeysWithValues: positions.map { ($0.id, $0.position) })
        for pair in closePairs {
            guard let first = positionById[pair.firstId], let second = positionById[pair.secondId]
            else { continue }
            var path = Path()
            path.move(to: first)
            path.addLine(to: second)
            context.stroke(
                path, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            let midpoint = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
            let label = context.resolve(
                Text("⚠ \(Self.formatDistance(pair.distance))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            )
            context.draw(label, at: CGPoint(x: midpoint.x, y: midpoint.y - 9), anchor: .center)
        }
    }

    private func drawPoints(
        context: GraphicsContext, positions: [(id: String, position: CGPoint)]
    ) {
        for entry in positions {
            let isSelected = entry.id == selectedSpeakerId
            let radius: CGFloat = isSelected ? 7 : 5
            let rect = CGRect(
                x: entry.position.x - radius, y: entry.position.y - radius,
                width: radius * 2, height: radius * 2
            )
            if isSelected {
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                    with: .color(.accentColor.opacity(0.5)), lineWidth: 2
                )
            }
            context.fill(Path(ellipseIn: rect), with: .color(.accentColor))
        }
    }

    /// Names sit to the right of their dot, staggered downward whenever two label rects would
    /// overlap. The stagger is a general rule (§5) — projection collapse can pile up points whose
    /// true distances are large, not just the variance≈0 case.
    private func drawLabels(
        context: GraphicsContext,
        positions: [(id: String, position: CGPoint)],
        bounds: CGSize
    ) {
        var occupied: [CGRect] = []
        for entry in positions {
            let name = namesById[entry.id] ?? entry.id
            let resolved = context.resolve(
                Text(name)
                    .font(.caption)
                    .foregroundStyle(entry.id == selectedSpeakerId ? Color.primary : Color.secondary)
            )
            let size = resolved.measure(in: CGSize(width: 200, height: 40))
            var origin = CGPoint(x: entry.position.x + 9, y: entry.position.y - size.height / 2)
            if origin.x + size.width > bounds.width - 4 {
                origin.x = entry.position.x - 9 - size.width
            }
            var rect = CGRect(origin: origin, size: size)
            var attempts = 0
            while occupied.contains(where: { $0.intersects(rect) }), attempts < 6 {
                rect.origin.y += size.height + 2
                attempts += 1
            }
            occupied.append(rect)
            context.draw(resolved, in: rect)
        }
    }

    static func formatDistance(_ distance: Float) -> String {
        String(format: "%.2f", distance)
    }
}
