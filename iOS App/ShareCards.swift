// ShareCards.swift
// MatchTracker
//
// The pictures people post. These are images, not screens: fixed sizes, always dark, and laid out
// for Stories' own controls to sit over the top and bottom.

import SwiftUI
import UniformTypeIdentifiers
import MatchTrackerKit

enum ShareCardStyle: String, CaseIterable, Identifiable {
    case pitch, photo, sticker
    var id: Self { self }

    var title: String {
        switch self {
        case .pitch: return "Pitch"
        case .photo: return "Photo"
        case .sticker: return "Sticker"
        }
    }
}

enum ShareCardFormat: String, CaseIterable, Identifiable {
    case story, portrait, square
    var id: Self { self }

    var title: String {
        switch self {
        case .story: return "Story"
        case .portrait: return "Portrait"
        case .square: return "Square"
        }
    }

    /// In points; rendered at 3x this is 1080 pixels wide.
    var size: CGSize {
        switch self {
        case .story: return CGSize(width: 360, height: 640)
        case .portrait: return CGSize(width: 360, height: 450)
        case .square: return CGSize(width: 360, height: 360)
        }
    }
}

struct ShareCard: View {
    var match: ShareMatch
    var style: ShareCardStyle
    var format: ShareCardFormat
    var photo: UIImage?
    var showsFieldName = true

    /// A sticker is its own shape: whoever pastes it decides how big it is.
    static func size(style: ShareCardStyle, format: ShareCardFormat) -> CGSize {
        style == .sticker ? CGSize(width: 360, height: 360) : format.size
    }

    var body: some View {
        let size = Self.size(style: style, format: format)
        Group {
            switch style {
            case .pitch: pitchCard.overlay(alignment: .bottom) { hem }
            case .photo: photoCard
            case .sticker: stickerCard
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(.large)
        .foregroundStyle(Theme.ivory)
    }

    private var subtitle: String { match.subtitle(showsFieldName: showsFieldName) }
    /// What the card is about when nobody kept score.
    private var lead: ShareNumber? { match.hasScore ? nil : match.numbers.first }
    private var numbers: [ShareNumber] { Array(match.numbers.dropFirst(lead == nil ? 0 : 1).prefix(3)) }

    // MARK: Pitch

    @ViewBuilder
    private var pitchCard: some View {
        if let pitch = match.pitch {
            switch format {
            case .story: storyPitch(pitch)
            case .portrait: portraitPitch(pitch)
            case .square: squarePitch(pitch)
            }
        } else {
            plainCard
        }
    }

    private func storyPitch(_ pitch: SharePitch) -> some View {
        heatPitch(pitch, insets: EdgeInsets(top: 152, leading: 36, bottom: 122, trailing: 36))
            .overlay(alignment: .top) {
                header(scoreSize: 74)
                    .padding(.horizontal, 28)
                    .padding(.top, 56)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 14) {
                    numberRow(valueSize: 30)
                    wordmark
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
            }
    }

    private func header(scoreSize: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 14) {
            hero(size: scoreSize)
            VStack(alignment: .trailing, spacing: 2) {
                titleText(size: scoreSize * 0.3).multilineTextAlignment(.trailing)
                Text(subtitle).font(.system(size: 14, weight: .medium)).opacity(0.7)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: scoreSize * 1.2)
    }

    private func portraitPitch(_ pitch: SharePitch) -> some View {
        let margin: CGFloat = 24, columnWidth: CGFloat = 92
        return heatPitch(pitch, insets: EdgeInsets(top: 104, leading: margin, bottom: margin + 4,
                                                   trailing: margin + columnWidth + 14))
            .overlay(alignment: .top) {
                header(scoreSize: 60).padding(.horizontal, margin).padding(.top, 16)
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(numbers) { number($0, valueSize: 27, alignment: .leading) }
                    }
                    Spacer(minLength: 0)
                    wordmark
                }
                .frame(width: columnWidth, height: format.size.height - 104 - margin, alignment: .leading)
                .padding(.trailing, margin)
                .padding(.bottom, margin)
            }
    }

    private func squarePitch(_ pitch: SharePitch) -> some View {
        let margin: CGFloat = 24, columnWidth: CGFloat = 122
        return heatPitch(pitch, insets: EdgeInsets(top: margin, leading: margin, bottom: margin,
                                                   trailing: columnWidth + margin + 16))
            .overlay(alignment: .trailing) {
                VStack(alignment: .leading, spacing: 0) {
                    hero(size: 56)
                    titleText(size: 17).padding(.top, lead == nil ? 2 : 10)
                    Text(match.dateText).font(.system(size: 12, weight: .medium)).opacity(0.7).padding(.top, 3)
                    if showsFieldName, let fieldName = match.fieldName {
                        Text(fieldName).font(.system(size: 12, weight: .medium)).opacity(0.7).lineLimit(2)
                    }
                    Spacer(minLength: 10)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(numbers) { number($0, valueSize: 25, alignment: .leading) }
                    }
                    Spacer(minLength: 10)
                    wordmark
                }
                .frame(width: columnWidth, height: format.size.height - margin * 2, alignment: .leading)
                .padding(.trailing, margin)
            }
    }

    private func heatPitch(_ pitch: SharePitch, insets: EdgeInsets?, surface: HeatPitch.Surface = .turf,
                           showsRun: Bool = true) -> some View {
        HeatPitch(heat: pitch.heat, size: pitch.size, marks: pitch.marks,
                  runs: showsRun ? [pitch.bestRun].compactMap { $0 } : [],
                  surface: surface, insets: insets, directionIsKnown: pitch.directionIsKnown, rendersImmediately: true)
    }

    /// Indoors, or without a route: the playing and resting as a hooped shirt, the length of the card.
    private var plainCard: some View {
        VStack(spacing: 0) {
            header(scoreSize: format == .story ? 84 : 64)
                .padding(.horizontal, 24)
                .padding(.top, format == .story ? 64 : 16)
                .padding(.bottom, 12)
            if let strip = match.strip {
                EffortStripView(levels: strip, hasTurf: false)
            } else {
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                numberRow(valueSize: 28)
                wordmark
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 26)
        }
        .background { Cloth(cornerRadius: 0, hasHem: false) }
    }

    // MARK: Photo

    private var photoCard: some View {
        ZStack(alignment: .bottom) {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: format.size.width, height: format.size.height)
                    .clipped()
            } else {
                LinearGradient(colors: [Color(red: 0.16, green: 0.27, blue: 0.23), Color(red: 0.05, green: 0.10, blue: 0.085)],
                               startPoint: .top, endPoint: .bottom)
            }
            // Dark enough for white type on a white sky, gone by the middle of the photo.
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.5), location: 0.45),
                                   .init(color: .black.opacity(0.86), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: format == .story ? 400 : format.size.height * 0.85)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        hero(size: format == .story ? 84 : 70)
                        titleText(size: 22)
                        Text(subtitle).font(.system(size: 14, weight: .medium)).opacity(0.8)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let pitch = match.pitch {
                        let width: CGFloat = format == .story ? 118 : 100
                        heatPitch(pitch, insets: nil, showsRun: false)
                            .frame(width: width, height: width / HeatPitch.aspectRatio(for: pitch.size))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                numberRow(valueSize: 25)
                wordmark.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, format == .story ? 40 : 20)
        }
    }

    // MARK: Sticker

    /// Transparent, for pasting over your own photo or video. The only backing is under the pitch.
    private var stickerCard: some View {
        HStack(alignment: .center, spacing: 18) {
            if let pitch = match.pitch {
                let height: CGFloat = 328
                heatPitch(pitch, insets: nil, surface: .clear)
                    .frame(width: height * HeatPitch.aspectRatio(for: pitch.size), height: height)
                    .background(Color(red: 0.02, green: 0.05, blue: 0.042).opacity(0.62),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let strip = match.strip {
                EffortStripView(levels: strip)
                    .frame(width: 180, height: 328)
                    .clipShape(.rect(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 10) {
                hero(size: 50)
                ForEach(numbers) { number($0, valueSize: 24, alignment: .leading, labelOpacity: 1) }
                wordmark
            }
            // Over an unknown background, white type needs its own edge.
            .shadow(color: .black.opacity(0.55), radius: 5, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 1)
            .frame(maxWidth: .infinity, alignment: match.pitch == nil ? .center : .leading)
        }
        .padding(16)
    }

    // MARK: Pieces

    /// The hem every piece of the app's cloth ends in.
    private var hem: some View {
        VStack(spacing: 3) {
            Theme.ivory.frame(height: 4)
            Theme.ivory.opacity(0.35).frame(height: 4)
        }
    }

    @ViewBuilder
    private func hero(size: CGFloat) -> some View {
        if match.hasScore {
            score(size: size)
        } else if let lead {
            VStack(alignment: .leading, spacing: -size * 0.06) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    KitNumber(lead.value, size: size)
                    Text(lead.unit).font(.system(size: max(size * 0.26, 14), weight: .semibold)).opacity(0.8)
                }
                Text(lead.label).font(.system(size: 13, weight: .medium)).opacity(0.85)
            }
            .fixedSize()
        }
    }

    private func score(size: CGFloat) -> some View {
        HStack(spacing: size * 0.09) {
            KitNumber("\(match.goalsUs ?? 0)", size: size)
            RoundedRectangle(cornerRadius: size * 0.04)
                .frame(width: size * 0.22, height: size * 0.08)
                .opacity(0.5)
            KitNumber("\(match.goalsThem ?? 0)", size: size).opacity(0.72)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(match.goalsUs ?? 0) to \(match.goalsThem ?? 0)")
    }

    private func titleText(size: CGFloat) -> some View {
        Text(match.title)
            .font(.system(size: size, weight: .heavy).width(.expanded))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
    }

    private func numberRow(valueSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ForEach(numbers) { entry in
                if entry != numbers.first { Spacer(minLength: 0) }
                number(entry, valueSize: valueSize, alignment: .leading)
            }
        }
    }

    private func number(_ entry: ShareNumber, valueSize: CGFloat, alignment: HorizontalAlignment,
                        labelOpacity: Double = 0.7) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(entry.value).font(.system(size: valueSize, weight: .heavy).width(.compressed)).monospacedDigit()
                if !entry.unit.isEmpty {
                    Text(entry.unit).font(.system(size: valueSize * 0.5, weight: .semibold))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(entry.label).font(.system(size: 13, weight: .medium)).opacity(labelOpacity)
        }
    }

    private var wordmark: some View {
        Text("MatchTracker")
            .font(.system(size: 12, weight: .semibold))
            .opacity(0.6)
    }
}

// MARK: - Rendering

/// A finished picture, ready for the share sheet or the photo library.
struct RenderedShareCard: Transferable, Sendable, Equatable {
    var data: Data
    var isTransparent: Bool
    var fileName: String
    var pixelSize: CGSize

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .exportingCondition { $0.isTransparent }
            .suggestedFileName { $0.fileName + ".png" }
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
            .exportingCondition { !$0.isTransparent }
            .suggestedFileName { $0.fileName + ".jpg" }
    }
}

extension ShareCard {
    /// Draws the card at 3x. Takes a few hundredths of a second once the heat is cached.
    @MainActor
    func render() -> RenderedShareCard? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 3
        renderer.isOpaque = style != .sticker
        guard let image = renderer.uiImage else { return nil }
        // Transparency needs PNG; a photograph as PNG would be ten times the size for nothing.
        guard let data = style == .sticker ? image.pngData() : image.jpegData(compressionQuality: 0.93) else { return nil }
        return RenderedShareCard(
            data: data, isTransparent: style == .sticker,
            fileName: "Match \(match.date.formatted(.iso8601.year().month().day()))",
            pixelSize: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))
    }
}
