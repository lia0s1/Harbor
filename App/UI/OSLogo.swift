import SwiftUI

/// In-code vector marks for the common distros, drawn in white to sit on the
/// host avatar's brand-color circle (Ubuntu's Circle of Friends, Arch's
/// triangle, Alpine's mountains, …). Distros without a hand-drawn mark fall back
/// to the colored initial (see `HostAvatarView`).
struct OSLogo: View {
    let osID: String

    /// Which ids have a real vector mark here.
    static func has(_ osID: String?) -> Bool {
        guard let osID else { return false }
        return drawable.contains(osID)
    }

    private static let drawable: Set<String> = ["ubuntu", "arch", "alpine", "debian", "fedora"]

    var body: some View {
        Canvas { ctx, size in
            let white = GraphicsContext.Shading.color(.white)
            switch osID {
            case "ubuntu": drawUbuntu(&ctx, size, white)
            case "arch": drawArch(&ctx, size, white)
            case "alpine": drawAlpine(&ctx, size, white)
            case "debian": drawDebian(&ctx, size, white)
            case "fedora": drawFedora(&ctx, size, white)
            default: break
            }
        }
    }

    // MARK: - Ubuntu: Circle of Friends

    private func drawUbuntu(_ ctx: inout GraphicsContext, _ size: CGSize, _ white: GraphicsContext.Shading) {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let orbit = r * 0.55
        let dotR = r * 0.165
        let hubR = r * 0.12
        let base = -CGFloat.pi * 0.34
        ctx.fill(circle(c, hubR), with: white)
        for i in 0..<3 {
            let a = base + CGFloat(i) * 2 * .pi / 3
            let p = CGPoint(x: c.x + cos(a) * orbit, y: c.y + sin(a) * orbit)
            let bw = r * 0.082
            let perp = a + .pi / 2
            let dx = cos(perp) * bw, dy = sin(perp) * bw
            var bar = Path()
            bar.move(to: CGPoint(x: c.x + dx, y: c.y + dy))
            bar.addLine(to: CGPoint(x: c.x - dx, y: c.y - dy))
            bar.addLine(to: CGPoint(x: p.x - dx, y: p.y - dy))
            bar.addLine(to: CGPoint(x: p.x + dx, y: p.y + dy))
            bar.closeSubpath()
            ctx.fill(bar, with: white)
            ctx.fill(circle(p, dotR), with: white)
        }
    }

    // MARK: - Arch: the "A" mountain

    private func drawArch(_ ctx: inout GraphicsContext, _ size: CGSize, _ white: GraphicsContext.Shading) {
        let w = size.width, h = size.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.16))
        path.addLine(to: CGPoint(x: w * 0.85, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.65, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.50, y: h * 0.55))
        path.addLine(to: CGPoint(x: w * 0.35, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.15, y: h * 0.84))
        path.closeSubpath()
        ctx.fill(path, with: white)
    }

    // MARK: - Alpine: mountains

    private func drawAlpine(_ ctx: inout GraphicsContext, _ size: CGSize, _ white: GraphicsContext.Shading) {
        let w = size.width, h = size.height
        var path = Path()
        // back peak
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.30))
        path.addLine(to: CGPoint(x: w * 0.82, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.74))
        path.closeSubpath()
        // front peak
        path.move(to: CGPoint(x: w * 0.33, y: h * 0.46))
        path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.08, y: h * 0.74))
        path.closeSubpath()
        ctx.fill(path, with: white)
    }

    // MARK: - Debian: the swirl (stylized)

    private func drawDebian(_ ctx: inout GraphicsContext, _ size: CGSize, _ white: GraphicsContext.Shading) {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // An open ring with a tail — reads as Debian's swirl on the red circle.
        var ring = Path()
        ring.addArc(center: c, radius: r * 0.42, startAngle: .degrees(50), endAngle: .degrees(330),
                    clockwise: false)
        ctx.stroke(ring, with: white, style: StrokeStyle(lineWidth: r * 0.18, lineCap: .round))
        ctx.fill(circle(CGPoint(x: c.x + r * 0.30, y: c.y - r * 0.26), r * 0.11), with: white)
    }

    // MARK: - Fedora: the "f"

    private func drawFedora(_ ctx: inout GraphicsContext, _ size: CGSize, _ white: GraphicsContext.Shading) {
        let w = size.width, h = size.height
        let stroke = StrokeStyle(lineWidth: min(w, h) * 0.13, lineCap: .round)
        var stem = Path()
        stem.move(to: CGPoint(x: w * 0.55, y: h * 0.80))
        stem.addLine(to: CGPoint(x: w * 0.55, y: h * 0.40))
        stem.addArc(center: CGPoint(x: w * 0.68, y: h * 0.40), radius: w * 0.13,
                    startAngle: .degrees(180), endAngle: .degrees(290), clockwise: false)
        ctx.stroke(stem, with: white, style: stroke)
        var bar = Path()
        bar.move(to: CGPoint(x: w * 0.40, y: h * 0.55))
        bar.addLine(to: CGPoint(x: w * 0.66, y: h * 0.55))
        ctx.stroke(bar, with: white, style: stroke)
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))
    }
}
