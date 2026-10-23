import SwiftUI

struct DeckOptionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let deckID: Int64

    @State private var presetID: Int64 = 1
    @State private var conf: JSON = [:]
    @State private var learnSteps = ""
    @State private var relearnSteps = ""
    @State private var newPresetName = ""
    @State private var showNewPreset = false
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $presetID) {
                    ForEach(app.col?.allDeckConfigs ?? []) { c in
                        Text(c.name).tag(c.id)
                    }
                }
                Button("Add Preset", systemImage: "plus") {
                    newPresetName = ""
                    showNewPreset = true
                }
            } footer: {
                Text("A preset can be shared by several decks. Changes apply to every deck using it.")
            }

            Section("Daily Limits") {
                intRow("New cards/day", ["new", "perDay"], 0...9999)
                intRow("Maximum reviews/day", ["rev", "perDay"], 0...99999)
            }

            Section {
                TextField("Learning steps", text: $learnSteps)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                intRow("Graduating interval (days)", ["new", "ints", "0"], 1...365)
                intRow("Easy interval (days)", ["new", "ints", "1"], 1...365)
                Picker("Insertion order", selection: binding(["new", "order"], 1)) {
                    Text("Sequential").tag(1)
                    Text("Random").tag(0)
                }
            } header: {
                Text("New Cards")
            } footer: {
                Text("Steps are separated by spaces, e.g. “1m 10m 1d”.")
            }

            Section("Lapses") {
                TextField("Relearning steps", text: $relearnSteps)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                intRow("Minimum interval (days)", ["lapse", "minInt"], 1...365)
                intRow("Leech threshold", ["lapse", "leechFails"], 1...99)
                Picker("Leech action", selection: binding(["lapse", "leechAction"], 1)) {
                    Text("Tag Only").tag(1)
                    Text("Suspend Card").tag(0)
                }
            }

            Section("Burying") {
                boolRow("Bury new siblings", ["new", "bury"])
                boolRow("Bury review siblings", ["rev", "bury"])
                boolRow("Bury interday learning siblings", ["buryInterdayLearning"])
            }

            Section("Audio & Timer") {
                boolRow("Play audio automatically", ["autoplay"], default: true)
                intRow("Maximum answer seconds", ["maxTaken"], 30...3600)
            }

            Section("Advanced") {
                intRow("Maximum interval (days)", ["rev", "maxIvl"], 1...36500)
                doubleRow("Starting ease", ["new", "initialFactor"], scale: 1000, range: 1.31...5)
                doubleRow("Easy bonus", ["rev", "ease4"], range: 1...5)
                doubleRow("Interval modifier", ["rev", "ivlFct"], range: 0.5...2)
                doubleRow("Hard interval", ["rev", "hardFactor"], range: 0.5...2)
                doubleRow("New interval", ["lapse", "mult"], range: 0...1)
            }
        }
        .navigationTitle("Options")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") { save() }
                    .buttonStyle(.glassProminent)
            }
        }
        .onAppear(perform: load)
        .onChange(of: presetID) { _, id in
            guard loaded, let c = app.col?.dconf[id] else { return }
            setConf(c)
        }
        .alert("New Preset", isPresented: $showNewPreset) {
            TextField("Name", text: $newPresetName)
            Button("Add") { addPreset() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Rows

    private func value(_ path: [String]) -> JSON {
        var v = conf
        for key in path {
            if let idx = Int(key) { v = v[idx] } else { v = v[key] }
        }
        return v
    }

    private func setValue(_ path: [String], _ newValue: JSON) {
        conf = JSON.setting(conf, path: path[...], to: newValue)
    }

    private func binding(_ path: [String], _ fallback: Int) -> Binding<Int> {
        Binding(get: { Int(value(path).int ?? Int64(fallback)) }, set: { setValue(path, JSON($0)) })
    }

    private func intRow(_ title: String, _ path: [String], _ range: ClosedRange<Int>) -> some View {
        let b = binding(path, range.lowerBound)
        return Stepper(value: b, in: range) {
            HStack {
                Text(title)
                Spacer()
                TextField("", value: b, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func doubleRow(_ title: String, _ path: [String], scale: Double = 1, range: ClosedRange<Double>) -> some View {
        let b = Binding<Double>(
            get: { (value(path).double ?? range.lowerBound * scale) / scale },
            set: {
                let clamped = min(max($0, range.lowerBound), range.upperBound)
                setValue(path, scale == 1 ? JSON(clamped) : JSON(Int((clamped * scale).rounded())))
            })
        return HStack {
            Text(title)
            Spacer()
            TextField("", value: b, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
                .foregroundStyle(.secondary)
        }
    }

    private func boolRow(_ title: String, _ path: [String], default fallback: Bool = false) -> some View {
        Toggle(title, isOn: Binding(get: { value(path).bool ?? fallback }, set: { setValue(path, .bool($0)) }))
    }

    // MARK: Load / save

    private func load() {
        guard !loaded, let col = app.col, let deck = col.deck(deckID) else { return }
        presetID = deck.configID
        setConf(col.dconf[deck.configID] ?? col.deckConfig(1).json)
        loaded = true
    }

    private func setConf(_ c: JSON) {
        conf = c
        learnSteps = StepFormat.format(c["new"]["delays"].doubleArray)
        relearnSteps = StepFormat.format(c["lapse"]["delays"].doubleArray)
    }

    private func addPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let col = app.col else { return }
        do {
            let id = try col.addDeckConfig(named: name, cloning: conf)
            presetID = id
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let col = app.col, var deck = col.deck(deckID) else { return }
        guard let learn = StepFormat.parse(learnSteps), let relearn = StepFormat.parse(relearnSteps) else {
            app.errorMessage = "Steps must be numbers followed by s, m, h or d, separated by spaces."
            return
        }
        var c = conf
        c["new"]["delays"] = JSON(learn)
        c["lapse"]["delays"] = JSON(relearn)
        c["id"] = .int(presetID)
        do {
            try col.updateDeckConfig(c)
            if deck.configID != presetID {
                deck.json["conf"] = .int(presetID)
                try col.updateDeck(deck)
            }
        } catch {
            app.errorMessage = error.localizedDescription
        }
        app.refresh()
        dismiss()
    }
}

extension JSON {
    /// Returns a copy with the value at `path` replaced; numeric keys index arrays.
    static func setting(_ base: JSON, path: ArraySlice<String>, to value: JSON) -> JSON {
        guard let key = path.first else { return value }
        let rest = path.dropFirst()
        if let idx = Int(key), case .array(var arr) = base {
            while arr.count <= idx { arr.append(.int(0)) }
            arr[idx] = setting(arr[idx], path: rest, to: value)
            return .array(arr)
        }
        var copy = base
        copy[key] = setting(base[key], path: rest, to: value)
        return copy
    }
}

/// Learning steps are stored in minutes and shown like Anki: "1m 10m 1d".
enum StepFormat {
    static func format(_ minutes: [Double]) -> String {
        minutes.map { m -> String in
            let secs = m * 60
            if secs < 60 { return "\(Int(secs.rounded()))s" }
            if m.truncatingRemainder(dividingBy: 1440) == 0 { return "\(Int(m / 1440))d" }
            if m.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(m / 60))h" }
            return m == m.rounded() ? "\(Int(m))m" : String(format: "%gm", m)
        }.joined(separator: " ")
    }

    static func parse(_ text: String) -> [Double]? {
        var out: [Double] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "," }) {
            var t = token.lowercased()
            var unit = 1.0
            if let last = t.last, last.isLetter {
                switch last {
                case "s": unit = 1.0 / 60
                case "m": unit = 1
                case "h": unit = 60
                case "d": unit = 1440
                default: return nil
                }
                t.removeLast()
            }
            guard let v = Double(t), v > 0 else { return nil }
            out.append(v * unit)
        }
        return out
    }
}
