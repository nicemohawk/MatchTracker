//
//  FieldTrainingView.swift
//  MatchTracker
//

import SwiftUI
import MatchTrackerKit

/// Teach the app a pitch by walking its lines. The outline draws itself as you go, so a walk that
/// isn't landing is obvious at the field rather than at home.
struct FieldTrainingView: View {
    @Environment(ConnectivityManager.self) private var connectivity
    @Environment(\.dismiss) private var dismiss
    @State private var trainer = FieldTrainer()
    @State private var name = "New Field"

    var body: some View {
        Group {
            switch trainer.state {
            case .idle: idleContent
            case .walking: walkingContent
            case .finished: finishedContent
            }
        }
        .navigationTitle("Train Field")
        .navigationBarTitleDisplayMode(.inline)
        // If the player swipes back mid-walk, stop the location updates so no recording is left
        // running in the background.
        .onDisappear {
            if trainer.state == .walking { trainer.cancel() }
        }
    }

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start at a corner and walk the lines, all the way back to where you began.")
                    .font(.body)
                Button {
                    WatchHaptics.click()
                    trainer.start()
                } label: {
                    Label("Start Walking", systemImage: "figure.walk").font(.headline)
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 64, prominent: true))
            }
            .scenePadding(.horizontal)
        }
    }

    private var walkingContent: some View {
        VStack(spacing: 8) {
            ZStack {
                if trainer.sampleCount > 1 {
                    WalkOutline(points: trainer.outlinePoints)
                } else {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text("Finding GPS").font(.headline)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Walked \(walked.spoken)")

            if trainer.gpsWeak {
                Label("GPS is weak. Slow down.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.sprint)
            }
            HStack(spacing: 8) {
                Text(walked.text)
                    .font(.kit(.title3))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                Button("Finish") {
                    WatchHaptics.stop()
                    trainer.finish()
                }
                .font(.headline)
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.sprint, minHeight: 48))
            }
        }
        .scenePadding(.horizontal)
    }

    private var walked: UnitSystem.Measure { UnitSystem.current.shortDistance(trainer.distanceWalked) }

    private var finishedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WalkOutline(points: trainer.outlinePoints)
                    .frame(height: 90)
                if let rectangle = trainer.makeField(named: name)?.rectangle {
                    let length = UnitSystem.current.shortDistance(rectangle.lengthMeters)
                    let width = UnitSystem.current.shortDistance(rectangle.widthMeters)
                    Text("\(length.value) × \(width.text)")
                        .font(.kit(.title2))
                        .accessibilityLabel("\(length.spoken) by \(width.spoken)")
                }
                // A starved walk fits a guess, not a field — say so before the save.
                if trainer.walkLooksSparse {
                    Label("GPS missed much of this walk. Walking it again usually fixes that.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(WatchTheme.sprint)
                    Button {
                        WatchHaptics.click()
                        trainer.start()
                    } label: {
                        Text("Walk Again").font(.headline)
                    }
                    .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.pace, minHeight: 52))
                }
                TextField("Field name", text: $name)
                Button {
                    saveField()
                } label: {
                    Text("Save Field").font(.headline)
                }
                .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.turf, minHeight: 52, prominent: true))
                .disabled(trainer.makeField(named: name) == nil)
                Button("Discard") { dismiss() }
                    .font(.headline)
                    .buttonStyle(WatchTileButtonStyle(tint: WatchTheme.bench, minHeight: 52))
            }
            .scenePadding(.horizontal)
        }
    }

    private func saveField() {
        guard let field = trainer.makeField(named: name) else { return }
        try? AppGroupStorage.fieldStore.save(field)
        connectivity.send(field: field)
        trainer.logSavedField(field)
        WatchHaptics.success()
        dismiss()
    }
}

/// The walked line so far, fitted to the space, with the start marked as the place to return to.
private struct WalkOutline: View {
    let points: [CGPoint]   // meters east/north of the start

    var body: some View {
        Canvas { context, size in
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let left = xs.min(), let right = xs.max(), let bottom = ys.min(), let top = ys.max() else { return }
            let inset: CGFloat = 8
            let scale = min((size.width - inset * 2) / max(right - left, 20),
                            (size.height - inset * 2) / max(top - bottom, 20))
            func place(_ point: CGPoint) -> CGPoint {
                CGPoint(x: size.width / 2 + (point.x - (left + right) / 2) * scale,
                        y: size.height / 2 - (point.y - (bottom + top) / 2) * scale)
            }
            var path = Path()
            path.addLines(points.map(place))
            context.stroke(path, with: .color(WatchTheme.turf),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            if let start = points.first {
                let center = place(start)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12)),
                             with: .color(.white))
            }
        }
    }
}
