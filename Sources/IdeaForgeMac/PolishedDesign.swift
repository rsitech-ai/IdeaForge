import SwiftUI

struct MacAmbientBackdrop: View {
    var isActive: Bool
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    tint.opacity(isActive ? 0.14 : 0.09),
                    Color.indigo.opacity(isActive ? 0.09 : 0.06),
                    Color.orange.opacity(isActive ? 0.06 : 0.04),
                    Color(nsColor: .controlBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(.linearGradient(
                        colors: [
                            .white.opacity(0.10),
                            .clear,
                            tint.opacity(0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(maxWidth: .infinity)
                    .rotationEffect(.degrees(-9))
                    .blur(radius: 16)
                    .opacity(isActive ? 0.30 : 0.24)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MacGlassPanel<Content: View>: View {
    var tint: Color = .clear
    var interactive = false
    var isLive = false
    var allowsNativeGlass = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if allowsNativeGlass, #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 16) {
                    content()
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(tint.opacity(isLive ? 0.24 : 0.12))
                        }
                        .shadow(color: tint.opacity(interactive ? 0.10 : 0.05), radius: interactive ? 8 : 5, y: 3)
                }
            } else {
                content()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(isLive ? 0.24 : 0.12))
                    }
                    .shadow(color: tint.opacity(interactive ? 0.10 : 0.05), radius: interactive ? 8 : 5, y: 3)
            }
        }
    }
}

private struct MacGlassSheen: View {
    var tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.linearGradient(
                colors: [
                    .white.opacity(0.18),
                    tint.opacity(0.08),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct MacSignalField: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let active = isActive

            ZStack(alignment: .leading) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(.linearGradient(
                            colors: [
                                .clear,
                                tint.opacity(active ? 0.46 : 0.20),
                                .white.opacity(active ? 0.22 : 0.10),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: width * (0.36 + CGFloat(index) * 0.06), height: 2)
                        .offset(
                            x: width * (0.12 + CGFloat(index) * 0.17),
                            y: CGFloat(index) * 10 + 5
                        )
                        .opacity((active ? 0.72 : 0.48) - Double(index) * 0.08)
                }

                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(tint.opacity(active ? 0.34 : 0.16))
                        .frame(width: 5, height: 12 + CGFloat((index % 3) * 6))
                        .offset(
                            x: width * CGFloat(index + 1) / 6,
                            y: CGFloat((index % 2) * 6 + 7)
                        )
                        .opacity(active ? 0.72 : 0.48)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .leading)
            .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(active ? 0.20 : 0.12))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MacInputSurface: ViewModifier {
    var tint: Color = .indigo
    var cornerRadius: CGFloat = 13

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(0.16))
            }
    }
}

extension View {
    func macInputSurface(tint: Color = .indigo, cornerRadius: CGFloat = 13) -> some View {
        modifier(MacInputSurface(tint: tint, cornerRadius: cornerRadius))
    }
}

struct MacGlassMetricCard: View {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color

    var body: some View {
        MacGlassPanel(tint: tint.opacity(0.12), interactive: true) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .help("\(title): \(detail)")
    }
}

private struct MacLiveSurfaceFrame: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat
    var isActive: Bool

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(alignment: .topLeading) {
                MacGlassSheen(tint: tint)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tint.opacity(isActive ? 0.22 : 0.14))
            }
            .shadow(color: tint.opacity(isActive ? 0.10 : 0.05), radius: isActive ? 9 : 5, y: 3)
    }
}

extension View {
    func macLiveSurface(tint: Color, cornerRadius: CGFloat = 16, isActive: Bool = false) -> some View {
        modifier(MacLiveSurfaceFrame(tint: tint, cornerRadius: cornerRadius, isActive: isActive))
    }
}

struct MacSectionHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var symbol: String
    var subtitle: String
    var tint: Color
    var isLive: Bool

    var body: some View {
        MacGlassPanel(tint: tint.opacity(0.14), interactive: false, isLive: isLive) {
            HStack(alignment: .center, spacing: 14) {
                MacLiveIconBadge(
                    systemImage: symbol,
                    tint: tint,
                    isActive: isLive && !reduceMotion,
                    size: 46,
                    cornerRadius: 14
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 10) {
                    MacSignalRibbon(tint: tint, isActive: isLive && !reduceMotion)
                    MacSignalField(tint: tint, isActive: isLive && !reduceMotion)
                        .frame(width: 168, height: 48)
                    MacLiveFlowRibbon(tint: tint, isActive: isLive && !reduceMotion)
                        .frame(width: 156, height: 18)
                }
            }
        }
    }
}

struct MacLiveHealthPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var snapshot: MobileDashboardSnapshot

    private var tint: Color { snapshot.liveHealthTone.macTint }

    var body: some View {
        MacGlassPanel(
            tint: tint.opacity(0.14),
            interactive: snapshot.isLiveActivityActive,
            isLive: snapshot.isLiveActivityActive
        ) {
            HStack(alignment: .center, spacing: 14) {
                MacLiveIconBadge(
                    systemImage: snapshot.liveHealthTone.symbolName,
                    tint: tint,
                    isActive: snapshot.isLiveActivityActive && !reduceMotion,
                    size: 42,
                    cornerRadius: 14
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.liveHealthTitle)
                        .font(.headline)
                    Text(snapshot.liveHealthDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 8) {
                    MacSignalRibbon(
                        tint: tint,
                        isActive: snapshot.isLiveActivityActive && !reduceMotion
                    )
                    MacSignalField(
                        tint: tint,
                        isActive: snapshot.isLiveActivityActive && !reduceMotion
                    )
                    .frame(width: 150, height: 42)
                    MacLiveFlowRibbon(
                        tint: tint,
                        isActive: snapshot.isLiveActivityActive && !reduceMotion
                    )
                    .frame(width: 150, height: 18)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(snapshot.liveHealthTitle). \(snapshot.liveHealthDetail)")
    }
}

struct MacSidebarHealthRow: View {
    var snapshot: MobileDashboardSnapshot

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync: \(snapshot.liveHealthTitle)")
                    .font(.body)
                Text(snapshot.liveHealthDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            Image(systemName: snapshot.liveHealthTone.symbolName)
                .foregroundStyle(snapshot.liveHealthTone.macTint)
        }
        .accessibilityLabel("Sync. \(snapshot.liveHealthTitle). \(snapshot.liveHealthDetail)")
    }
}

struct MacProjectHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var project: IdeaProject
    var allowsLiveMotion = true

    private var tint: Color { project.macTint }
    private var symbol: String { project.macSymbol }
    private var liveMotionIsActive: Bool {
        allowsLiveMotion && project.isMacLive && !reduceMotion
    }

    var body: some View {
        MacGlassPanel(
            tint: tint.opacity(0.14),
            interactive: false,
            isLive: liveMotionIsActive,
            allowsNativeGlass: allowsLiveMotion
        ) {
            VStack(alignment: .leading, spacing: 16) {
                heroHeader

                if allowsLiveMotion {
                    MacLiveFlowRibbon(tint: tint, isActive: liveMotionIsActive)
                        .frame(height: 20)

                    MacSignalField(tint: tint, isActive: liveMotionIsActive)
                        .frame(height: 46)
                }

                MacReadinessPulseMeter(score: project.score, tint: tint, isActive: liveMotionIsActive)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac.overview.hero")
    }

    private var heroHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                iconBadge
                titleSummary
                    .layoutPriority(1)
                Spacer(minLength: 16)
                statusStack
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    iconBadge
                    titleSummary
                        .layoutPriority(1)
                }
                statusRow
            }
        }
    }

    private var iconBadge: some View {
        MacLiveIconBadge(
            systemImage: symbol,
            tint: tint,
            isActive: liveMotionIsActive,
            size: 48,
            cornerRadius: 15
        )
    }

    private var titleSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(project.title)
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(project.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusStack: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if allowsLiveMotion {
                MacSignalRibbon(tint: tint, isActive: liveMotionIsActive)
            }
            statusBadge
            if allowsLiveMotion {
                MacStatusRail(tint: tint, isActive: liveMotionIsActive)
                    .frame(width: 116, height: 7)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            statusBadge
            if allowsLiveMotion {
                MacStatusRail(tint: tint, isActive: liveMotionIsActive)
                    .frame(maxWidth: 116)
                    .frame(height: 7)
            }
        }
    }

    private var statusBadge: some View {
        Text(project.status.label)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(tint.opacity(0.20))
            }
    }
}

struct MacLiveIconBadge: View {
    var systemImage: String
    var tint: Color
    var isActive: Bool
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.linearGradient(
                    colors: [
                        tint.opacity(isActive ? 0.18 : 0.10),
                        Color.primary.opacity(0.035),
                        tint.opacity(isActive ? 0.10 : 0.06)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(tint.opacity(isActive ? 0.34 : 0.16), lineWidth: 1)

            Image(systemName: systemImage)
                .font(.system(size: size * 0.50, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(isActive ? 0.14 : 0.06), radius: isActive ? 8 : 4, y: isActive ? 4 : 2)
        .accessibilityHidden(true)
    }
}

extension WorkspaceLiveHealthTone {
    var symbolName: String {
        switch self {
        case .ready: "checkmark.seal"
        case .active: "dot.radiowaves.left.and.right"
        case .needsReview: "exclamationmark.triangle"
        case .syncConflict: "arrow.triangle.2.circlepath.circle"
        case .offline: "applewatch.slash"
        case .localFirst: "lock.shield"
        }
    }

    var macTint: Color {
        switch self {
        case .ready: .mint
        case .active: .cyan
        case .needsReview: .orange
        case .syncConflict: .red
        case .offline: .secondary
        case .localFirst: .indigo
        }
    }
}

struct MacToolbarLiveStatus: View {
    var snapshot: MobileDashboardSnapshot
    var isRecording: Bool

    private var tint: Color {
        isRecording ? .orange : snapshot.liveHealthTone.macTint
    }

    private var symbolName: String {
        isRecording ? "mic.circle.fill" : snapshot.liveHealthTone.symbolName
    }

    private var title: String {
        isRecording ? "Recording active" : snapshot.liveHealthTitle
    }

    private var detail: String {
        isRecording ? "Local capture is running on this Mac." : snapshot.liveHealthDetail
    }

    private var isActive: Bool {
        isRecording || snapshot.isLiveActivityActive
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            MacStatusRail(tint: tint, isActive: isActive)
                .frame(width: 72, height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(isActive ? 0.22 : 0.12))
        }
        .shadow(color: tint.opacity(isActive ? 0.10 : 0.04), radius: isActive ? 8 : 4, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityIdentifier("mac.toolbar.liveStatus")
        .help("\(title): \(detail)")
    }
}

struct MacStatusRail: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let active = isActive

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            tint.opacity(0.12),
                            Color.primary.opacity(0.035),
                            tint.opacity(0.18)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(active ? 0.24 : 0.14))
                    }

                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            .clear,
                            tint.opacity(active ? 0.62 : 0.20),
                            .white.opacity(active ? 0.42 : 0.12),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: min(72, width * 0.54))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(active ? 0.72 : 0.42)
            }
            .clipShape(Capsule())
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MacStatusDot: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        Circle()
            .fill(tint.gradient)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .strokeBorder(tint.opacity(0.26), lineWidth: 1)
            }
            .shadow(color: tint.opacity(isActive ? 0.28 : 0.12), radius: isActive ? 4 : 2)
            .opacity(isActive ? 1 : 0.58)
            .accessibilityHidden(true)
    }
}

private struct MacLiveNavigationRowStyle: ViewModifier {
    var tint: Color
    var isSelected: Bool
    var isActive: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let highlighted = isSelected || isActive || isHovering
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(isSelected ? 0.14 : (isHovering ? 0.09 : (isActive ? 0.055 : 0))))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(highlighted ? 0.16 : 0))
            }
            .onHover { isHovering = $0 }
    }
}

extension View {
    func macLiveNavigationRow(tint: Color, isSelected: Bool, isActive: Bool) -> some View {
        modifier(MacLiveNavigationRowStyle(tint: tint, isSelected: isSelected, isActive: isActive))
    }
}

struct MacLiveFlowRibbon: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            tint.opacity(0.10),
                            Color.primary.opacity(0.035),
                            tint.opacity(0.16)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .overlay {
                        Capsule().strokeBorder(tint.opacity(0.18))
                    }

                Capsule()
                    .fill(.linearGradient(
                        colors: [
                            .white.opacity(0),
                            tint.opacity(isActive ? 0.46 : 0.20),
                            .white.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: min(92, width * 0.48))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .blur(radius: isActive ? 3 : 2)
                    .opacity(isActive ? 0.72 : 0.42)
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}

private struct MacReadinessPulseMeter: View {
    var score: IdeaScore
    var tint: Color
    var isActive: Bool

    var body: some View {
        let active = isActive

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Readiness pulse", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 8)
                Text(overall, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            }

            VStack(spacing: 9) {
                MacPulseTrack(
                    title: "Confidence",
                    value: score.confidence,
                    tint: .cyan,
                    isActive: active
                )
                MacPulseTrack(
                    title: "Completeness",
                    value: score.completeness,
                    tint: .mint,
                    isActive: active
                )
                MacPulseTrack(
                    title: "Risk",
                    value: score.risk,
                    tint: .orange,
                    isActive: active
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(active ? 0.24 : 0.14))
        }
        .shadow(color: tint.opacity(active ? 0.12 : 0.04), radius: active ? 12 : 5, y: active ? 6 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness pulse. Confidence \(percent(score.confidence)), completeness \(percent(score.completeness)), risk \(percent(score.risk)).")
    }

    private var overall: Double {
        (score.confidence + score.completeness + (1 - score.risk)) / 3
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct MacPulseTrack: View {
    var title: String
    var value: Double
    var tint: Color
    var isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let fillWidth = max(8, width * min(max(value, 0), 1))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.055))
                    Capsule()
                        .fill(.linearGradient(
                            colors: [
                                tint.opacity(0.32),
                                tint.opacity(0.78),
                                .white.opacity(isActive ? 0.36 : 0.10)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: fillWidth)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
        }
    }
}

struct MacSignalRibbon: View {
    var tint: Color
    var isActive: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 5, height: height(for: index))
                    .opacity(isActive ? 0.92 : 0.48)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.18))
        }
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let resting = [12, 22, 16, 28, 18][index]
        return CGFloat(resting)
    }
}

extension SidebarSection {
    var accentColor: Color {
        switch self {
        case .inbox: .cyan
        case .ideas: .yellow
        case .workflows: .indigo
        case .templates: .mint
        case .exports: .orange
        case .integrations: .teal
        }
    }

    var subtitle: String {
        switch self {
        case .inbox: "Capture signals, transfer recordings, and keep upload work visible."
        case .ideas: "Review the active idea set and keep product context moving."
        case .workflows: "Run repeatable planning systems with traceable outputs."
        case .templates: "Shape reusable prompts, schemas, and review policies."
        case .exports: "Prepare local handoff artifacts before external execution."
        case .integrations: "Keep external systems explicit, permissioned, and fail-closed."
        }
    }

    var shortSignal: String {
        switch self {
        case .inbox: "Capture"
        case .ideas: "Review"
        case .workflows: "Run"
        case .templates: "Shape"
        case .exports: "Handoff"
        case .integrations: "Connect"
        }
    }
}

extension IdeaProject {
    var macTint: Color {
        switch source {
        case .watch: .cyan
        case .iphone: .orange
        case .mac: .indigo
        case .importFile: .mint
        }
    }

    var macSymbol: String {
        switch source {
        case .watch: "applewatch.radiowaves.left.and.right"
        case .iphone: "iphone.radiowaves.left.and.right"
        case .mac: "desktopcomputer"
        case .importFile: "doc.badge.plus"
        }
    }

    var isMacLive: Bool {
        status == .readyForBuild || !questions.isEmpty || recordings.contains { recording in
            recording.syncStatus == .failed || recording.syncStatus == .transcribing || recording.syncStatus == .uploaded
        }
    }
}
