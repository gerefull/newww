import SwiftUI

enum NovaTheme {
    static let background = Color(red: 0.018, green: 0.032, blue: 0.059)
    static let backgroundDeep = Color(red: 0.006, green: 0.012, blue: 0.028)
    static let surface = Color(red: 0.055, green: 0.086, blue: 0.137)
    static let surfaceRaised = Color(red: 0.082, green: 0.125, blue: 0.19)
    static let line = Color.white.opacity(0.105)
    static let cyan = Color(red: 0.467, green: 0.906, blue: 0.949)
    static let electricBlue = Color(red: 0.18, green: 0.56, blue: 1.0)
    static let violet = Color(red: 0.655, green: 0.545, blue: 0.98)
    static let magenta = Color(red: 0.92, green: 0.32, blue: 0.92)
    static let green = Color(red: 0.29, green: 0.87, blue: 0.5)
    static let amber = Color(red: 0.984, green: 0.75, blue: 0.14)
    static let rose = Color(red: 0.984, green: 0.443, blue: 0.522)
    static let muted = Color(red: 0.58, green: 0.65, blue: 0.75)
    static let max = Color(red: 0.984, green: 0.855, blue: 0.286)
    static let maxHot = Color(red: 1.0, green: 0.45, blue: 0.18)
    static let prof = Color(red: 0.38, green: 0.66, blue: 1.0)
    static let profHot = Color(red: 0.56, green: 0.45, blue: 0.98)

    static let accentGradient = LinearGradient(
        colors: [cyan, Color(red: 0.22, green: 0.72, blue: 0.88), violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let maxGradient = LinearGradient(
        colors: [Color.white, max, maxHot],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let profGradient = LinearGradient(
        colors: [Color.white, prof, profHot],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let auroraGradient = LinearGradient(
        colors: [cyan.opacity(0.9), electricBlue, violet, magenta.opacity(0.82)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let panelGradient = LinearGradient(
        colors: [Color.white.opacity(0.105), surface.opacity(0.72), backgroundDeep.opacity(0.78)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct NovaGhostMark: View {
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NovaTheme.surfaceRaised, NovaTheme.backgroundDeep],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.72
                    )
                )
            Circle()
                .stroke(NovaTheme.auroraGradient, lineWidth: max(1, size * 0.025))
                .padding(size * 0.055)
                .opacity(0.65)
            GhostShape()
                .fill(NovaTheme.accentGradient)
                .padding(size * 0.23)
                .shadow(color: NovaTheme.cyan.opacity(0.42), radius: size * 0.12)
            HStack(spacing: size * 0.13) {
                Circle().fill(NovaTheme.background).frame(width: size * 0.075)
                Circle().fill(NovaTheme.background).frame(width: size * 0.075)
            }
            .offset(y: -size * 0.075)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 0.8))
        .shadow(color: NovaTheme.cyan.opacity(0.2), radius: size * 0.24)
    }
}

private struct GhostShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY
        path.move(to: CGPoint(x: minX, y: maxY * 0.83))
        path.addLine(to: CGPoint(x: minX, y: minY + rect.height * 0.35))
        path.addCurve(
            to: CGPoint(x: maxX, y: minY + rect.height * 0.35),
            control1: CGPoint(x: minX, y: minY),
            control2: CGPoint(x: maxX, y: minY)
        )
        path.addLine(to: CGPoint(x: maxX, y: maxY * 0.83))
        path.addLine(to: CGPoint(x: maxX * 0.75, y: maxY * 0.64))
        path.addLine(to: CGPoint(x: maxX * 0.5, y: maxY * 0.88))
        path.addLine(to: CGPoint(x: maxX * 0.25, y: maxY * 0.64))
        path.closeSubpath()
        return path
    }
}

struct NovaBackground: View {
    var maxEnabled = false
    var profEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 30)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let cyanX = CGFloat(sin(time * 0.18)) * 28
            let cyanY = CGFloat(cos(time * 0.21)) * 24
            let violetX = CGFloat(sin(time * 0.15)) * 36
            let violetY = CGFloat(cos(time * 0.17)) * 32
            let profX = CGFloat(sin(time * 0.22)) * 24
            let profY = CGFloat(cos(time * 0.19)) * 18
            let beamX = CGFloat(sin(time * 0.11)) * 34
            ZStack {
                LinearGradient(
                    colors: [NovaTheme.backgroundDeep, NovaTheme.background, Color(red: 0.012, green: 0.018, blue: 0.037), .black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RoundedRectangle(cornerRadius: 220, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, NovaTheme.electricBlue.opacity(0.09), NovaTheme.violet.opacity(0.055), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 150, height: 760)
                    .rotationEffect(.degrees(31))
                    .offset(x: 115 + beamX, y: -85)
                    .blur(radius: 28)
                Circle()
                    .fill(RadialGradient(colors: [NovaTheme.cyan.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 190))
                    .frame(width: 380, height: 380)
                    .offset(x: -175 + cyanX, y: -290 + cyanY)
                    .blur(radius: 18)
                Circle()
                    .fill(RadialGradient(colors: [NovaTheme.violet.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 210))
                    .frame(width: 420, height: 420)
                    .offset(x: 190 - violetX, y: 40 + violetY)
                    .blur(radius: 24)
                if maxEnabled {
                    Circle()
                        .fill(RadialGradient(colors: [NovaTheme.max.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 160))
                        .frame(width: 320, height: 320)
                        .offset(x: 145, y: 390)
                        .blur(radius: 28)
                }
                if profEnabled {
                    Circle()
                        .fill(RadialGradient(colors: [NovaTheme.prof.opacity(0.11), .clear], center: .center, startRadius: 0, endRadius: 175))
                        .frame(width: 350, height: 350)
                        .offset(x: 150 + profX, y: 360 + profY)
                        .blur(radius: 30)
                }
                DotGrid(phase: time)
                    .opacity(0.19)
                LinearGradient(
                    colors: [.black.opacity(0.42), .clear, .clear, .black.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        }
    }
}

private struct DotGrid: View {
    let phase: TimeInterval

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 30
            let yOffset = CGFloat(phase.truncatingRemainder(dividingBy: 12))
            var grid = Path()
            for x in stride(from: 12 as CGFloat, through: size.width, by: spacing) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: yOffset, through: size.height, by: spacing) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.085)), lineWidth: 0.35)
            for x in stride(from: 12 as CGFloat, through: size.width, by: spacing) {
                for y in stride(from: 12 + yOffset, through: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.78)))
                }
            }
        }
    }
}

struct GlassPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(NovaTheme.panelGradient))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), NovaTheme.cyan.opacity(0.12), NovaTheme.violet.opacity(0.08), Color.white.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(colors: [NovaTheme.cyan.opacity(0.55), NovaTheme.violet.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 92, height: 1)
                    .padding(.leading, 22)
            }
            .shadow(color: Color.black.opacity(0.34), radius: 18, x: 0, y: 10)
            .shadow(color: NovaTheme.electricBlue.opacity(0.035), radius: 22, x: 0, y: -3)
    }
}

struct NovaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.64), value: configuration.isPressed)
    }
}

extension View {
    func novaPressable() -> some View {
        buttonStyle(NovaPressStyle())
    }
}
