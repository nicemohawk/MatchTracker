// ShareSheet.swift
// MatchTracker

import AVKit
import CoreTransferable
import PhotosUI
import SwiftUI
import MatchTrackerKit

/// Pick a picture of the match, or its replay, and send it somewhere.
struct ShareMatchSheet: View {
    private let load: @MainActor () -> (ShareMatch, ActivityExport?)
    @State private var match: ShareMatch?
    @State private var export: ActivityExport?
    @State private var showsExport = false
    @State private var kind = Kind.picture
    @AppStorage("shareShowsFieldName") private var showsFieldName = true
    @Environment(\.dismiss) private var dismiss

    private enum Kind: Hashable { case picture, replay }

    init(match: ShareMatch, export: ActivityExport? = nil) {
        load = { (match, export) }
        _match = State(initialValue: match)
        _export = State(initialValue: export)
    }

    /// - Parameter detail: Must have finished loading.
    init(detail: MatchDetailModel, summary: MatchSummary, teamName: String? = nil) {
        load = { (ShareMatch(detail: detail, teamName: teamName), ActivityExport(detail: detail, summary: summary)) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let match {
                    VStack(spacing: 0) {
                        if match.replay != nil {
                            Picker("Share", selection: $kind) {
                                Text("Picture").tag(Kind.picture)
                                Text("Replay").tag(Kind.replay)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        switch kind {
                        case .picture: SharePictureView(match: match, showsFieldName: $showsFieldName)
                        case .replay: ShareReplayView(match: match, showsFieldName: $showsFieldName)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showsExport) {
                if let export { ExportDataView(export: export) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let export, !export.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showsExport = true } label: { Label("Export Data", systemImage: "arrow.up.doc") }
                    }
                }
            }
        }
        .task {
            guard match == nil else { return }
            let result = load()
            if let pitch = result.0.pitch {
                // Warm the heat so the first card draws in one go.
                let key = HeatImage.Key(heat: pitch.heat, size: pitch.size, pixelWidth: 540)
                _ = await Task.detached(priority: .userInitiated) { HeatImage.make(key) }.value
            }
            match = result.0
            export = result.1
        }
    }
}

// MARK: - Picture

private struct SharePictureView: View {
    let match: ShareMatch
    @Binding var showsFieldName: Bool

    @AppStorage("shareCardFormat") private var format = ShareCardFormat.story
    @AppStorage("shareCardStyle") private var style = ShareCardStyle.pitch
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var photoFailed = false
    @State private var rendered: RenderedShareCard?

    /// Changes whenever the picture would.
    private struct RenderKey: Hashable {
        var style: ShareCardStyle
        var format: ShareCardFormat
        var showsFieldName: Bool
        var photo: ObjectIdentifier?
        var pitch: SharePitch?
    }

    private var renderKey: RenderKey {
        RenderKey(style: style, format: format, showsFieldName: showsFieldName,
                  photo: photo.map(ObjectIdentifier.init), pitch: match.pitch)
    }

    private func card(_ style: ShareCardStyle) -> ShareCard {
        ShareCard(match: match, style: style, format: format, photo: photo, showsFieldName: showsFieldName)
    }

    var body: some View {
        VStack(spacing: 12) {
            TabView(selection: $style) {
                ForEach(ShareCardStyle.allCases) { style in
                    page(style).tag(style)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 12) {
                Picker("Style", selection: $style) {
                    ForEach(ShareCardStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if style == .sticker {
                    Text("A transparent picture. Copy it, then paste it over your own photo or video.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Shape", selection: $format) {
                        ForEach(ShareCardFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if match.fieldName != nil, style != .sticker {
                    Toggle("Show Field Name", isOn: $showsFieldName)
                }
                ShareActions(isReady: rendered != nil) {
                    if let rendered, let preview = UIImage(data: rendered.data) {
                        ShareLink(item: rendered, preview: SharePreview(match.title, image: Image(uiImage: preview))) {
                            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button {} label: { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                            .disabled(true)
                    }
                } save: {
                    guard let rendered else { return }
                    try await PhotoLibrary.save(imageData: rendered.data)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .animation(.default, value: style)
        .task(id: renderKey) {
            rendered = nil
            // Let a swipe settle before spending the main thread on a full-size picture.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            rendered = card(style).render()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let image = try? await item.loadTransferable(type: Data.self).flatMap(UIImage.init(data:))
                    .flatMap { $0.preparingThumbnail(of: $0.size.fitting(longestSide: 2400)) }
                photo = image ?? photo
                photoFailed = image == nil
            }
        }
        .alert("That photo couldn't be opened.", isPresented: $photoFailed) {}
    }

    private func page(_ style: ShareCardStyle) -> some View {
        GeometryReader { proxy in
            let size = ShareCard.size(style: style, format: format)
            let scale = min((proxy.size.width - 48) / size.width, proxy.size.height / size.height)
            card(style)
                .background {
                    // Something for the sticker to sit on; not part of the picture.
                    if style == .sticker { Checkerboard() }
                }
                .overlay {
                    if style == .photo { photoPicker }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18 / max(scale, 0.1), style: .continuous))
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    @ViewBuilder
    private var photoPicker: some View {
        PhotosPicker(selection: $photoItem, matching: .images) {
            if photo == nil {
                Label("Choose a Photo", systemImage: "photo.on.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, format.size.height * 0.35)
            } else {
                Color.clear
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(photo == nil ? "Choose a photo" : "Change photo")
    }
}

// MARK: - Replay

private struct ShareReplayView: View {
    let match: ShareMatch
    @Binding var showsFieldName: Bool

    @State private var stage = Stage.working(0)
    @State private var poster: UIImage?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    /// Nil once stopped. Changing it restarts the render task, which cancels the film being made.
    @State private var attempt: Int? = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Stage {
        case working(Double)
        case stopped
        case ready(URL)
        case failed(String)
    }

    private struct RenderKey: Hashable {
        var showsFieldName: Bool
        var pitch: SharePitch?
        var attempt: Int?
    }

    var body: some View {
        VStack(spacing: 12) {
            screen
                .aspectRatio(9.0 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)
            VStack(spacing: 12) {
                if match.fieldName != nil { Toggle("Show Field Name", isOn: $showsFieldName) }
                switch stage {
                case .working(let progress):
                    HStack(spacing: 16) {
                        ProgressView(value: progress) { Text("Making your replay") }
                        Button("Stop") { attempt = nil }
                    }
                    .frame(minHeight: 50)
                case .stopped:
                    Button { attempt = (attempt ?? 0) + 1 } label: { Text("Make Replay").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                    Button { attempt = (attempt ?? 0) + 1 } label: { Text("Try Again").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                case .ready(let url):
                    ShareActions(isReady: true) {
                        ShareLink(item: ShareableMovie(url: url),
                                  preview: SharePreview(match.title, image: Image(uiImage: poster ?? UIImage()))) {
                            Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                    } save: {
                        try await PhotoLibrary.save(videoAt: url)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .task(id: RenderKey(showsFieldName: showsFieldName, pitch: match.pitch, attempt: attempt)) { await make() }
        .onDisappear { stopPlaying() }
    }

    @ViewBuilder
    private var screen: some View {
        if let player {
            VideoPlayer(player: player)
                .accessibilityLabel("Replay of the match")
        } else if let poster {
            Image(uiImage: poster).resizable().scaledToFit()
                .accessibilityLabel("Replay of the match")
        } else {
            Color(red: 0.03, green: 0.066, blue: 0.056)
        }
    }

    private func make() async {
        stopPlaying()
        guard attempt != nil else {
            stage = .stopped
            return
        }
        stage = .working(0)
        let renderer = MatchReplayRenderer(match: match, showsFieldName: showsFieldName)
        poster = await Task.detached(priority: .userInitiated) {
            (try? renderer.image(at: MatchReplayRenderer.posterTime)).map { UIImage(cgImage: $0) }
        }.value
        do {
            let url = try await renderer.render { progress in
                Task { @MainActor in
                    // Steps of a percent: the bar can't show finer, and each one redraws the sheet.
                    if case .working(let shown) = stage, progress >= shown + 0.01 { stage = .working(progress) }
                }
            }
            guard !Task.isCancelled else { return }
            stage = .ready(url)
            play(url)
        } catch is CancellationError {
            return
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func play(_ url: URL) {
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        player = queue
        if !reduceMotion { queue.play() }
    }

    private func stopPlaying() {
        player?.pause()
        player = nil
        looper = nil
    }
}

private struct ShareableMovie: Transferable {
    var url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Movie) { SentTransferredFile($0.url) }
    }
}

// MARK: - Shared pieces

private struct ShareActions<Link: View>: View {
    var isReady: Bool
    @ViewBuilder var link: Link
    var save: () async throws -> Void

    @State private var isSaving = false
    @State private var saved = 0
    @State private var didSave = false
    @State private var problem: String?

    private var shareButton: some View { link.buttonStyle(.borderedProminent) }

    private var saveButton: some View {
        Button {
            isSaving = true
            Task {
                defer { isSaving = false }
                do {
                    try await save()
                    didSave = true
                    saved += 1
                } catch {
                    problem = error.localizedDescription
                }
            }
        } label: {
            Label(didSave ? "Saved" : "Save", systemImage: didSave ? "checkmark" : "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!isReady || isSaving)
        .accessibilityLabel(didSave ? "Saved to Photos" : "Save to Photos")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { saveButton; shareButton }
            VStack(spacing: 10) { shareButton; saveButton }
        }
        .controlSize(.large)
        .onChange(of: isReady) { _, _ in didSave = false }
        .sensoryFeedback(.success, trigger: saved)
        .alert("It wasn't saved", isPresented: .init(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            if problem == PhotoLibrary.Failure.notAllowed.localizedDescription {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }
}

private enum PhotoLibrary {
    enum Failure: LocalizedError {
        case notAllowed
        var errorDescription: String? { "MatchTracker isn't allowed to add to your photos. You can change that in Settings." }
    }

    static func save(imageData: Data) async throws {
        try await add { $0.addResource(with: .photo, data: imageData, options: nil) }
    }

    static func save(videoAt url: URL) async throws {
        try await add { $0.addResource(with: .video, fileURL: url, options: nil) }
    }

    private static func add(_ addResource: @escaping @Sendable (PHAssetCreationRequest) -> Void) async throws {
        // Add-only: the app never needs to see anyone's photos.
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        try await PHPhotoLibrary.shared().performChanges { addResource(PHAssetCreationRequest.forAsset()) }
    }
}

/// The usual stand-in for transparency.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.36)))
            let cell: CGFloat = 12
            var squares = Path()
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) where (row + column).isMultiple(of: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.42)))
        }
        .accessibilityHidden(true)
    }
}

private extension CGSize {
    func fitting(longestSide: CGFloat) -> CGSize {
        let scale = min(1, longestSide / max(width, height, 1))
        return CGSize(width: width * scale, height: height * scale)
    }
}
