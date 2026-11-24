// KitPickerView.swift
// MatchTracker
//
// The team's color. It dyes the cloth, the heat, the tint, the widgets and the watch.

import SwiftUI
import WidgetKit
import MatchTrackerKit

struct KitPickerView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                KitPreview().id(settings.kitID)
                KitRack()
                MatchingIconButton().id(settings.kitID)
            }
            .padding(20)
            .readableWidth(560)
        }
        .canvasBackground()
        .navigationTitle("Team Color")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.turf)
    }
}

/// A match as it would look.
private struct KitPreview: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saturday").font(.name(.title2)).lineLimit(1).minimumScaleFactor(0.6)
                Text("Won").font(.headline).opacity(0.8)
                KitNumber("3–1", size: 88).accessibilityLabel("3 to 1")
            }
            Spacer(minLength: 0)
            HeatPitch(heat: ExampleMatch.heat, surface: .clear, insets: EdgeInsets())
                .background(Theme.cloth)
                .aspectRatio(HeatPitch.aspectRatio(for: .standard), contentMode: .fit)
                .frame(width: 124)
        }
        .foregroundStyle(Theme.ivory)
        .padding(22)
        .padding(.bottom, 10)
        .background { Cloth() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(KitColors.title(of: KitColors.current.id))")
    }
}

/// Every kit on its own shirt, and any other color there is.
struct KitRack: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isCustom: Bool { !KitColors.presets.contains { $0.id == settings.kitID } }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 130 : 96), spacing: 12)], spacing: 20) {
            ForEach(KitColors.presets) { preset in
                if let kit = KitColors(id: preset.id) {
                    Button { settings.wear(kit) } label: {
                        KitShirt(kit: kit, title: preset.title, isWorn: settings.kitID == preset.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.kitID == preset.id ? .isSelected : [])
                }
            }
            VStack(spacing: 6) {
                ColorPicker("Another color", selection: custom, supportsOpacity: false)
                    .labelsHidden()
                    .scaleEffect(1.5)
                    .frame(height: 76)
                Text("Another").font(.subheadline.weight(isCustom ? .bold : .regular)).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isCustom ? .isSelected : [])
        }
        .sensoryFeedback(.selection, trigger: settings.kitID)
    }

    /// What's worn, so choosing the same color again after trying a kit still counts.
    private var custom: Binding<Color> {
        Binding {
            Color(cgColor: (KitColors.RGB(hex: settings.kitID) ?? KitColors.current.cloth).cgColor)
        } set: { color in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let parts = UIColor(color).cgColor.converted(to: space, intent: .defaultIntent, options: nil)?.components,
                  parts.count >= 3 else { return }
            let channels = parts.prefix(3).map { Double(min(max($0, 0), 1)) }
            let hex = KitColors.RGB(channels[0], channels[1], channels[2]).hex
            if hex != settings.kitID, let kit = KitColors(id: hex) { settings.wear(kit) }
        }
    }
}

private struct KitShirt: View {
    let kit: KitColors
    let title: String
    let isWorn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Canvas { context, size in
                    let shirt = ShirtShape().path(in: CGRect(origin: .zero, size: size))
                    context.clip(to: shirt)
                    context.fill(shirt, with: .color(Color(cgColor: kit.cloth.cgColor)))
                    // A sash, knitted.
                    let width = size.width / 15, rise = width * Knit.rise
                    for row in 0..<Int(size.height / rise) + 1 {
                        for column in 0..<16 {
                            let offset = abs(Double(column) - (13 - Double(row) * 0.72))
                            guard offset < 3.4 else { continue }
                            let stitch = CGMutablePath()
                            Knit.addStitch(to: stitch, column: column, row: row, width: width)
                            context.fill(Path(stitch), with: .color(Color(cgColor: kit.yarns[offset < 1.2 ? 3 : offset < 2.4 ? 2 : 1].cgColor)))
                        }
                    }
                    context.fill(Path(CGRect(x: 0, y: size.height - 4, width: size.width, height: 2.5)), with: .color(Theme.ivory))
                }
                ShirtShape().stroke(.primary.opacity(0.18), lineWidth: 1)
            }
            .frame(width: 76, height: 76)
            .scaleEffect(isWorn ? 1.1 : 1)
            .animation(reduceMotion ? nil : .bouncy, value: isWorn)
            .overlay(alignment: .bottomTrailing) {
                if isWorn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.onTurf, Theme.turf)
                        .offset(x: 6, y: 4)
                }
            }
            Text(title)
                .font(.subheadline.weight(isWorn ? .bold : .regular))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}

/// Short sleeves and a round neck.
private struct ShirtShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        var path = Path()
        path.move(to: point(0.36, 0.06))
        path.addQuadCurve(to: point(0.64, 0.06), control: point(0.5, 0.2))
        path.addLine(to: point(0.80, 0.12))
        path.addLine(to: point(1.0, 0.36))
        path.addLine(to: point(0.86, 0.48))
        path.addLine(to: point(0.77, 0.40))
        path.addLine(to: point(0.77, 1))
        path.addLine(to: point(0.23, 1))
        path.addLine(to: point(0.23, 0.40))
        path.addLine(to: point(0.14, 0.48))
        path.addLine(to: point(0, 0.36))
        path.addLine(to: point(0.20, 0.12))
        path.closeSubpath()
        return path
    }
}

/// The Home Screen icon in the same kit. Asked for, because iOS announces the change.
private struct MatchingIconButton: View {
    @State private var iconName = UIApplication.shared.alternateIconName

    private var matching: String? { KitColors.current.id == "green" ? nil : "AppIcon-\(KitColors.current.id)" }

    var body: some View {
        if UIApplication.shared.supportsAlternateIcons, KitColors.presets.contains(where: { $0.id == KitColors.current.id }), iconName != matching {
            Button("Use the Matching App Icon") {
                Task {
                    try? await UIApplication.shared.setAlternateIconName(matching)
                    iconName = UIApplication.shared.alternateIconName
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

extension KitColors {
    static func title(of id: String) -> String { presets.first { $0.id == id }?.title ?? "Your own" }
}

extension SettingsStore {
    /// On screen at once. The widgets and the watch hear once the finger has settled.
    @MainActor
    func wear(_ kit: KitColors) {
        KitColors.wear(kit)
        kitID = kit.id
        kitAnnouncement?.cancel()
        kitAnnouncement = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
            AppEnvironment.current?.settingsChanged()
        }
    }
}
