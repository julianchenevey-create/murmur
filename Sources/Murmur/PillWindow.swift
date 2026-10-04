import AppKit
import SwiftUI

final class PillModel: ObservableObject {
    enum Phase { case hold, handsFree, processing, error }

    @Published var phase: Phase = .hold
    @Published var level: Float = 0
    @Published var elapsed = 0
    @Published var limit = 300
    @Published var status = ""
}

/// A small click-through capsule near the bottom of the screen the mouse is on.
/// It never takes focus, so the app you're dictating into stays active.
final class PillWindow {
    let model = PillModel()
    private let panel: NSPanel

    init() {
        let size = NSSize(width: 380, height: 44)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 28))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            if model.phase == .hold || model.phase == .handsFree {
                LevelBars(level: model.level)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var indicator: some View {
        switch model.phase {
        case .hold:
            PulsingDot(color: .red)
        case .handsFree:
            HStack(spacing: 4) {
                PulsingDot(color: .orange)
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
            }
        case .processing:
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(.yellow)
        }
    }

    private var label: String {
        switch model.phase {
        case .hold:
            return "Listening"
        case .handsFree:
            let remaining = model.limit - model.elapsed
            return remaining <= 30
                ? "Hands-free · stops in \(clock(max(0, remaining)))"
                : "Hands-free \(clock(model.elapsed))"
        case .processing, .error:
            return model.status
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]

    var body: some View {
        let l = CGFloat(min(1, max(0, level).squareRoot() * 3.2))
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 3 + 13 * l * weights[i])
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: l)
    }
}
