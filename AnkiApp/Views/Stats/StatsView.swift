import Charts
import SwiftUI

struct StatsView: View {
    @Environment(AppModel.self) private var app
    @State private var deckID: Int64?
    @State private var stats = CollectionStats()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Scope", selection: $deckID) {
                        Text("Whole Collection").tag(Int64?.none)
                        ForEach(app.col?.allDecks ?? []) { deck in
                            Text(deck.name).tag(Int64?.some(deck.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    todayCard
                    countsCard
                    chartCard("Reviews, last 30 days", data: stats.reviewsByDay, color: .blue, xLabel: "Days ago")
                    chartCard("Forecast, next 30 days", data: stats.forecast, color: .green, xLabel: "Days from now")
                }
                .padding(16)
            }
            .background(
                LinearGradient(colors: [.blue.opacity(0.15), .purple.opacity(0.1), .clear],
                               startPoint: .topLeading, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle("Statistics")
            .onAppear(perform: reload)
            .onChange(of: deckID) { _, _ in reload() }
            .onChange(of: app.revision) { _, _ in reload() }
        }
    }

    private func reload() {
        guard let col = app.col else { return }
        stats = (try? CollectionStats.compute(col, deckID: deckID)) ?? CollectionStats()
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Today", systemImage: "calendar")
                .font(.headline)
            if stats.todayReviews == 0 {
                Text("No cards have been studied today.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Studied \(stats.todayReviews) cards in \(Self.duration(stats.todaySeconds)).")
                Text("Correct: \(Int(stats.todayCorrectPercent.rounded()))%  ·  Again: \(stats.todayAgain)")
                    .foregroundStyle(.secondary)
            }
            if stats.streak > 0 {
                Label("\(stats.streak)-day streak", systemImage: "flame.fill")
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var countsCard: some View {
        let items: [(String, Int, Color)] = [
            ("New", stats.newCards, .blue),
            ("Learning", stats.learningCards, .orange),
            ("Young", stats.youngCards, .green.opacity(0.6)),
            ("Mature", stats.matureCards, .green),
        ]
        let total = items.reduce(0) { $0 + $1.1 }
        return VStack(alignment: .leading, spacing: 12) {
            Label("Card Counts", systemImage: "rectangle.stack")
                .font(.headline)
            HStack(spacing: 20) {
                Chart(items, id: \.0) { item in
                    SectorMark(angle: .value("Cards", item.1), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(item.2)
                        .cornerRadius(4)
                }
                .frame(width: 120, height: 120)
                .overlay {
                    VStack(spacing: 0) {
                        Text("\(total)").font(.title3.bold().monospacedDigit())
                        Text("cards").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.0) { item in
                        HStack {
                            Circle().fill(item.2).frame(width: 8, height: 8)
                            Text(item.0)
                            Spacer()
                            Text("\(item.1)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    if stats.suspendedCards > 0 {
                        Text("\(stats.suspendedCards) suspended")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func chartCard(_ title: String, data: [DayValue], color: Color, xLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(data.reduce(0) { $0 + $1.count })")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Chart(data) { item in
                BarMark(x: .value(xLabel, item.day), y: .value("Cards", item.count))
                    .foregroundStyle(color.gradient)
                    .cornerRadius(3)
            }
            .frame(height: 160)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    static func duration(_ secs: Int) -> String {
        if secs < 60 { return "\(secs) seconds" }
        let minutes = secs / 60
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        return String(format: "%.1f hours", Double(secs) / 3600)
    }
}
