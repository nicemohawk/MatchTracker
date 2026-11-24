import SwiftUI
import WidgetKit
import MatchTrackerKit

// MARK: - Last match

struct LastMatchWidgetView: View {
    let snapshot: WidgetSnapshot?
    let family: WidgetFamily
    var monochrome = false

    var body: some View {
        // A widget can't grow, so past this the words would be cut off instead.
        content.dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder private var content: some View {
        if let snapshot, let match = snapshot.lastMatch {
            switch family {
            case .accessoryInline: LastMatchInline(match: match, units: snapshot.units)
            case .accessoryCircular: LastMatchCircular(match: match, units: snapshot.units)
            case .accessoryRectangular: LastMatchRectangular(match: match, units: snapshot.units)
            case .systemMedium: LastMatchMedium(snapshot: snapshot, match: match, monochrome: monochrome)
            case .systemLarge: LastMatchLarge(snapshot: snapshot, match: match, monochrome: monochrome)
            default: LastMatchSmall(snapshot: snapshot, match: match, monochrome: monochrome)
            }
        } else {
            WidgetEmptyView(family: family)
        }
    }
}

/// The scoreline, or the distance when nobody kept score.
private struct MatchHero: View {
    let match: MatchDigest
    let units: UnitSystem
    var font: Font

    var body: some View {
        Group {
            if let score = match.score {
                Text(score)
            } else if let distance = match.distanceMeters, distance > 0 {
                Text(units.roughDistance(distance).text)
            } else {
                Text(UnitSystem.minutes(match.secondsOnPitch).text)
            }
        }
        .font(font)
        .fontDesign(.rounded)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .widgetAccentable()
        .accessibilityLabel(match.spokenSummary)
    }
}

private struct MatchCaption: View {
    let match: MatchDigest
    var alignment: HorizontalAlignment = .leading
    var showsDate = true

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 4) {
                if let result = match.result {
                    Text(result.title).foregroundStyle(result.color).fixedSize()
                }
                Text(match.title).foregroundStyle(.primary)
            }
            .font(.subheadline.weight(.semibold))
            if showsDate {
                Text(match.startDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct LastMatchSmall: View {
    let snapshot: WidgetSnapshot
    let match: MatchDigest
    let monochrome: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let showsPitch = snapshot.hasPicture && !dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                MatchHero(match: match, units: snapshot.units,
                          font: .largeTitle.weight(.bold))
                if showsPitch {
                    Spacer(minLength: 4)
                    Text(match.startDate, format: .dateTime.month(.abbreviated).day())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            MatchCaption(match: match, showsDate: !showsPitch && !dynamicTypeSize.isAccessibilitySize)
            Spacer(minLength: 4)
            if showsPitch {
                MatchPicture(snapshot: snapshot, monochrome: monochrome)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LastMatchMedium: View {
    let snapshot: WidgetSnapshot
    let match: MatchDigest
    let monochrome: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 2 : 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    MatchHero(match: match, units: snapshot.units,
                              font: .largeTitle.weight(.bold))
                    MatchCaption(match: match, showsDate: !dynamicTypeSize.isAccessibilitySize)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if snapshot.hasPicture, !dynamicTypeSize.isAccessibilitySize {
                    MatchPicture(snapshot: snapshot, monochrome: monochrome)
                        .frame(maxWidth: 150, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
            MatchNumbers(match: match, units: snapshot.units)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct LastMatchLarge: View {
    let snapshot: WidgetSnapshot
    let match: MatchDigest
    let monochrome: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                MatchHero(match: match, units: snapshot.units,
                          font: .largeTitle.weight(.bold))
                Spacer(minLength: 0)
                MatchCaption(match: match, alignment: .trailing)
            }
            if snapshot.hasPicture {
                MatchPicture(snapshot: snapshot, monochrome: monochrome)
                    .frame(maxWidth: .infinity)
            }
            if let headline = snapshot.headline {
                Text(headline)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            MatchNumbers(match: match, units: snapshot.units)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Distance, minutes and top speed. A number nobody measured isn't shown.
private struct MatchNumbers: View {
    let match: MatchDigest
    let units: UnitSystem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if match.score != nil, let distance = match.distanceMeters, distance > 0 {
                number(units.roughDistance(distance), caption: "Distance")
            }
            number(UnitSystem.minutes(match.secondsOnPitch), caption: "Played")
            if dynamicTypeSize.isAccessibilitySize {
                EmptyView()
            } else if let speed = match.topSpeedMetersPerSecond {
                number(units.speed(speed), caption: "Top speed")
            } else if let sprints = match.sprintCount {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(sprints)").font(.headline).fontDesign(.rounded)
                    Text("Sprints").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private func number(_ measure: UnitSystem.Measure, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(measure.text)
                .font(.headline).fontDesign(.rounded)
                .monospacedDigit()
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("\(caption), \(measure.spoken)")
    }
}

// MARK: Last match, Lock Screen

private struct LastMatchInline: View {
    let match: MatchDigest
    let units: UnitSystem

    var body: some View {
        Label([MatchResultText.title(goalsUs: match.goalsUs, goalsThem: match.goalsThem) ?? match.title,
               match.distanceMeters.map { units.roughDistance($0).text }].compactMap { $0 }.joined(separator: " · "),
              systemImage: "soccerball")
    }
}

private struct LastMatchCircular: View {
    let match: MatchDigest
    let units: UnitSystem

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                MatchHero(match: match, units: units, font: .title2.weight(.bold))
                if let result = match.result {
                    Text(result.title).font(.caption2)
                }
            }
            .padding(4)
        }
    }
}

private struct LastMatchRectangular: View {
    let match: MatchDigest
    let units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "soccerball")
                Text(MatchResultText.title(goalsUs: match.goalsUs, goalsThem: match.goalsThem) ?? match.title)
            }
            .font(.headline)
            .widgetAccentable()
            Text([match.distanceMeters.map { units.roughDistance($0).text },
                  UnitSystem.minutes(match.secondsOnPitch).text].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
            Text([match.score == nil ? nil : match.title,
                  match.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Season

struct SeasonWidgetView: View {
    let snapshot: WidgetSnapshot?
    let family: WidgetFamily

    var body: some View {
        content.dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder private var content: some View {
        if let snapshot, let season = snapshot.season {
            switch family {
            case .accessoryInline:
                Label(season.hasResults ? season.recordLetters : season.matchesText, systemImage: "soccerball")
            case .accessoryCircular: SeasonCircular(season: season)
            case .accessoryRectangular: SeasonRectangular(season: season, units: snapshot.units)
            case .systemMedium: SeasonMedium(season: season, units: snapshot.units)
            default: SeasonSmall(season: season, units: snapshot.units)
            }
        } else {
            WidgetEmptyView(family: family)
        }
    }
}

extension WidgetSnapshot.Season {
    var recordLetters: String { "\(won)W \(drawn)D \(lost)L" }
    var matchesText: String { matchCount == 1 ? "1 match" : "\(matchCount) matches" }
    var spokenRecord: String { "\(title). \(won) won, \(drawn) drawn, \(lost) lost" }
}

private struct SeasonSmall: View {
    let season: WidgetSnapshot.Season
    let units: UnitSystem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(season.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if season.hasResults {
                RecordRow(season: season, font: .title.weight(.bold))
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize { FormRow(form: season.form) }
            } else {
                Text(season.matchesText)
                    .font(.title.weight(.bold)).fontDesign(.rounded)
                    .widgetAccentable()
                Spacer(minLength: 0)
            }
            if season.distanceMeters > 0 {
                Text(units.totalDistance(season.distanceMeters).text)
                    .font(.subheadline.weight(.medium))
                    .accessibilityLabel("\(units.totalDistance(season.distanceMeters).spoken) covered")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SeasonMedium: View {
    let season: WidgetSnapshot.Season
    let units: UnitSystem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: dynamicTypeSize.isAccessibilitySize ? 0 : 6) {
            HStack {
                Text(season.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                FormRow(form: season.form)
            }
            Spacer(minLength: 0)
            if season.hasResults {
                RecordRow(season: season, font: .largeTitle.weight(.bold), spread: true)
            } else {
                Text(season.matchesText)
                    .font(.largeTitle.weight(.bold)).fontDesign(.rounded)
                    .widgetAccentable()
            }
            Spacer(minLength: 0)
            Text(totals)
                .font(.subheadline.weight(.medium))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var totals: String {
        [season.distanceMeters > 0 ? units.totalDistance(season.distanceMeters).text : nil,
         season.hasResults ? season.matchesText : nil,
         season.goals > 0 ? (season.goals == 1 ? "1 goal" : "\(season.goals) goals") : nil,
         season.assists > 0 ? (season.assists == 1 ? "1 assist" : "\(season.assists) assists") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Won, drawn, lost, each number over its word.
private struct RecordRow: View {
    let season: WidgetSnapshot.Season
    let font: Font
    var spread = false

    var body: some View {
        HStack(spacing: spread ? 28 : 14) {
            column(season.won, spread ? "Won" : "W", .won)
            column(season.drawn, spread ? "Drawn" : "D", .drawn)
            column(season.lost, spread ? "Lost" : "L", .lost)
        }
        .accessibilityElement()
        .accessibilityLabel(season.spokenRecord)
    }

    private func column(_ count: Int, _ caption: String, _ result: MatchDigest.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(count)")
                .font(font)
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(result == .won ? AnyShapeStyle(SurfacePalette.us) : AnyShapeStyle(.primary))
                .widgetAccentable(result == .won)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The last five, oldest first, as letters.
private struct FormRow: View {
    let form: [MatchDigest.Result]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(form.enumerated()), id: \.offset) { _, result in
                Text(result.letter)
                    .foregroundStyle(result.color)
            }
        }
        .font(.subheadline.weight(.bold)).fontDesign(.rounded)
        .accessibilityElement()
        .accessibilityLabel("Recent results, oldest first: " + form.map(\.title).joined(separator: ", "))
    }
}

private struct SeasonCircular: View {
    let season: WidgetSnapshot.Season

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text("\(season.hasResults ? season.won : season.matchCount)")
                    .font(.title2.weight(.bold)).fontDesign(.rounded)
                    .widgetAccentable()
                Text(season.hasResults ? "Won" : "Played")
                    .font(.caption2)
            }
            .minimumScaleFactor(0.7)
        }
        .accessibilityElement()
        .accessibilityLabel(season.hasResults ? season.spokenRecord : "\(season.title), \(season.matchesText)")
    }
}

private struct SeasonRectangular: View {
    let season: WidgetSnapshot.Season
    let units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(season.hasResults ? season.recordLetters : season.matchesText)
                .font(.headline)
                .widgetAccentable()
            if season.hasResults {
                Text("Form " + season.form.map(\.letter).joined(separator: " "))
                    .font(.subheadline)
            }
            Text([season.title, season.distanceMeters > 0 ? units.totalDistance(season.distanceMeters).text : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Empty

private struct WidgetEmptyView: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline: Label("No matches yet", systemImage: "soccerball")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "soccerball").font(.title2)
            }
            .accessibilityLabel("No matches yet")
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "soccerball")
                    .font(.title2)
                    .foregroundStyle(SurfacePalette.us)
                    .widgetAccentable()
                Text("No matches yet")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if family != .accessoryRectangular {
                    Text("Record one on your Apple Watch.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private extension WidgetSnapshot {
    var hasPicture: Bool { heat != nil || lastMatch?.strip != nil }
}

/// Where it was played, or without a pitch to draw, when.
private struct MatchPicture: View {
    let snapshot: WidgetSnapshot
    let monochrome: Bool

    var body: some View {
        if snapshot.heat == nil, let strip = snapshot.lastMatch?.strip {
            EffortStripView(levels: strip, axis: .horizontal)
                .luminanceToAlpha(monochrome)
                .aspectRatio(PitchThumbnail.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            PitchThumbnail(heat: snapshot.heat, monochrome: monochrome)
        }
    }
}

private extension View {
    @ViewBuilder
    func luminanceToAlpha(_ applies: Bool) -> some View {
        if applies { luminanceToAlpha() } else { self }
    }
}
