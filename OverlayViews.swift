import SwiftUI

let hudAmber = Color(red: 1.0, green: 0.78, blue: 0.16)

// MARK: - Overlay frame: masker rasio + grid (hanya tampilan, tidak masuk rekaman)
struct FrameOverlay: View {
    let overlay: OverlaySettings

    var body: some View {
        Canvas { ctx, size in
            let frame = activeRect(in: size)

            if overlay.aspect != .source && overlay.showMask {
                var mask = Path(CGRect(origin: .zero, size: size))
                mask.addRect(frame)
                ctx.fill(mask, with: .color(.black.opacity(0.62)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(frame), with: .color(.white.opacity(0.9)), lineWidth: 1)
                ctx.draw(Text(overlay.aspect.label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(hudAmber),
                         at: CGPoint(x: frame.minX + 8, y: frame.minY + 12), anchor: .leading)
            }
            drawGrids(ctx, frame)
        }
        .allowsHitTesting(false)
    }

    /// Area rasio terpilih, di tengah frame monitor (sama dengan area yang direkam).
    private func activeRect(in size: CGSize) -> CGRect {
        guard let a = overlay.aspect.ratio else { return CGRect(origin: .zero, size: size) }
        let srcA = size.width / size.height
        var w = size.width, h = size.height
        if CGFloat(a) > srcA { h = w / CGFloat(a) } else { w = h * CGFloat(a) }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func line(_ ctx: GraphicsContext, _ a: CGPoint, _ b: CGPoint, _ opacity: Double = 0.55) {
        var p = Path(); p.move(to: a); p.addLine(to: b)
        ctx.stroke(p, with: .color(.white.opacity(opacity)), lineWidth: 1)
    }

    private func drawGrids(_ ctx: GraphicsContext, _ f: CGRect) {
        for kind in overlay.grids {
            switch kind {
            case .thirds:
                for i in 1...2 {
                    let x = f.minX + f.width * CGFloat(i) / 3, y = f.minY + f.height * CGFloat(i) / 3
                    line(ctx, CGPoint(x: x, y: f.minY), CGPoint(x: x, y: f.maxY))
                    line(ctx, CGPoint(x: f.minX, y: y), CGPoint(x: f.maxX, y: y))
                }
            case .golden:
                for r in [0.382, 0.618] {
                    let x = f.minX + f.width * CGFloat(r), y = f.minY + f.height * CGFloat(r)
                    line(ctx, CGPoint(x: x, y: f.minY), CGPoint(x: x, y: f.maxY), 0.4)
                    line(ctx, CGPoint(x: f.minX, y: y), CGPoint(x: f.maxX, y: y), 0.4)
                }
            case .center:
                let c = CGPoint(x: f.midX, y: f.midY)
                line(ctx, CGPoint(x: c.x - 14, y: c.y), CGPoint(x: c.x + 14, y: c.y), 0.9)
                line(ctx, CGPoint(x: c.x, y: c.y - 14), CGPoint(x: c.x, y: c.y + 14), 0.9)
            case .diagonals:
                line(ctx, CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.maxY), 0.35)
                line(ctx, CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), 0.35)
            case .safe90, .safe80:
                let k: CGFloat = kind == .safe90 ? 0.05 : 0.10
                let r = f.insetBy(dx: f.width * k, dy: f.height * k)
                ctx.stroke(Path(r), with: .color(.white.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
        }
    }
}

// MARK: - Komponen HUD
struct HUDField: View {
    let label: String
    let value: String
    var valueColor: Color = .white
    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Text(value).foregroundStyle(valueColor)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }
}

struct ToolLabel: View {
    let icon: String
    let title: String
    let on: Bool
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium))
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
        .frame(width: 64, height: 42)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? hudAmber : Color.white.opacity(0.09)))
        .contentShape(Rectangle())
    }
}

// MARK: - Scope
struct ScopeCell<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            content()
                .background(Color.black)
                .overlay(Rectangle().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
    }
}

struct WaveformGraticule: View {
    var body: some View {
        Canvas { ctx, size in
            for i in 0...4 {
                let y = size.height * (1 - CGFloat(i) / 4)
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                ctx.draw(Text("\(i * 25)").font(.system(size: 8, design: .monospaced)).foregroundColor(.white.opacity(0.6)),
                         at: CGPoint(x: 10, y: min(max(y, 7), size.height - 7)))
            }
        }.allowsHitTesting(false)
    }
}

struct HistogramGraticule: View {
    var body: some View {
        Canvas { ctx, size in
            for i in 1...3 {
                let x = size.width * CGFloat(i) / 4
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
            }
        }.allowsHitTesting(false)
    }
}

struct VectorscopeGraticule: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2
            for k in [0.5, 1.0] {
                let rr = r * 0.9 * k
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                           with: .color(.white.opacity(0.25)), lineWidth: 0.5)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: 0, y: c.y)); cross.addLine(to: CGPoint(x: size.width, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: 0)); cross.addLine(to: CGPoint(x: c.x, y: size.height))
            ctx.stroke(cross, with: .color(.white.opacity(0.2)), lineWidth: 0.5)
            let a = 123.0 * Double.pi / 180                       // garis skin-tone
            var skin = Path(); skin.move(to: c)
            skin.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r * 0.9, y: c.y - CGFloat(sin(a)) * r * 0.9))
            ctx.stroke(skin, with: .color(.orange.opacity(0.7)), lineWidth: 1)
        }.allowsHitTesting(false)
    }
}
