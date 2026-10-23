import Foundation

struct RenderedCard {
    var questionHTML: String
    var answerHTML: String
    var css: String
    var questionSounds: [String]
    var answerSounds: [String]
    var typeAnswerExpected: String?
    var ord: Int
}

enum CardRenderer {
    static func render(card: Card, note: Note, collection col: Collection) -> RenderedCard {
        guard let nt = col.notetype(note.mid) else {
            return RenderedCard(questionHTML: "Missing notetype", answerHTML: "Missing notetype", css: "",
                                questionSounds: [], answerSounds: [], typeAnswerExpected: nil, ord: card.ord)
        }
        var fields: [String: String] = [:]
        for (i, name) in nt.fieldNames.enumerated() { fields[name] = i < note.fields.count ? note.fields[i] : "" }
        let templateIndex = nt.isCloze ? 0 : min(card.ord, max(0, nt.templates.count - 1))
        let tmpl = nt.templates.isEmpty ? JSON.object([:]) : nt.templates[templateIndex]
        let deckID = card.odid != 0 ? card.odid : card.did
        var ctx = RenderContext(fields: fields, cardOrd: card.ord, isQuestion: true)
        ctx.tags = note.tags
        ctx.notetypeName = nt.name
        ctx.deckName = col.deck(deckID)?.name ?? ""
        ctx.templateName = tmpl["name"].string(or: "")
        ctx.flag = card.flag
        ctx.cardID = card.id

        var qr = TemplateRenderer(context: ctx)
        var question = qr.render(tmpl["qfmt"].string(or: ""))
        ctx.isQuestion = false
        ctx.frontSide = stripTypeMarkers(question)
        var ar = TemplateRenderer(context: ctx)
        var answer = ar.render(tmpl["afmt"].string(or: ""))

        // type answer: remember what's expected, then substitute markers
        let expected = firstTypeMarker(in: question).flatMap { spec -> String? in
            typeAnswerExpected(spec: spec, fields: fields, ord: card.ord)
        }
        question = replaceTypeMarkers(question) { _ in
            "<center><input type=text id=typeans onkeypress=\"_typeAnsPress();\" autocomplete=off autocorrect=off autocapitalize=off spellcheck=false></center>"
        }
        answer = replaceTypeMarkers(answer) { _ in "<center><div id=typeansCompare></div></center>" }

        let (q, qSounds) = processSounds(question, side: "q")
        let (a, aSounds) = processSounds(answer, side: "a")
        // like Anki, sounds that came from {{FrontSide}} don't autoplay again
        let usesFrontSide = tmpl["afmt"].string(or: "").contains("{{FrontSide}}")
        let answerOnly = usesFrontSide ? Array(aSounds.dropFirst(qSounds.count)) : aSounds
        return RenderedCard(questionHTML: q, answerHTML: a, css: nt.css, questionSounds: qSounds,
                            answerSounds: answerOnly, typeAnswerExpected: expected, ord: card.ord)
    }

    private static let typeMarker = try! NSRegularExpression(pattern: #"\[\[type:(.+?)\]\]"#)

    private static func firstTypeMarker(in text: String) -> String? {
        let ns = text as NSString
        guard let m = typeMarker.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func stripTypeMarkers(_ text: String) -> String {
        HTML.replace(typeMarker, in: text, with: "")
    }

    private static func replaceTypeMarkers(_ text: String, _ make: (String) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        var first = true
        for m in typeMarker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if first { out += make(ns.substring(with: m.range(at: 1))) }
            first = false
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func typeAnswerExpected(spec: String, fields: [String: String], ord: Int) -> String? {
        var parts = spec.components(separatedBy: ":")
        let field = parts.removeLast()
        guard let value = fields[field] ?? fields.first(where: { $0.key.caseInsensitiveCompare(field) == .orderedSame })?.value
        else { return nil }
        if parts.contains("cloze") {
            return HTML.strip(Cloze.activeTexts(value, ord: ord + 1).joined(separator: ", "))
        }
        return HTML.strip(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let soundRe = try! NSRegularExpression(pattern: #"\[sound:([^\]]+)\]"#)

    /// Replaces `[sound:…]` tags with play buttons.
    private static func processSounds(_ html: String, side: String) -> (String, [String]) {
        let ns = html as NSString
        var out = ""
        var last = 0
        var sounds: [String] = []
        for m in soundRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let file = HTML.decodeEntities(ns.substring(with: m.range(at: 1)))
            let jsName = file.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            out += "<a class=\"replay-button soundLink\" href=\"#\" onclick=\"ankiPlay('\(HTML.escape(jsName))');return false;\"><svg class=\"playImage\" viewBox=\"0 0 64 64\" version=\"1.1\"><circle cx=\"32\" cy=\"32\" r=\"29\"/><path d=\"M56.502,32.301l-37.502,20.101l0.329,-40.804l37.173,20.703Z\"/></svg></a>"
            sounds.append(file)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return (out, sounds)
    }

    // MARK: Type answer comparison

    /// Produces Anki-style comparison HTML for typed answers.
    static func compareTyped(_ typed: String, expected: String) -> String {
        let given = Array(typed.trimmingCharacters(in: .whitespacesAndNewlines))
        let correct = Array(expected)
        if given == correct {
            return "<code id=typeans><span class=typeGood>\(HTML.escape(expected))</span></code>"
        }
        if given.isEmpty {
            return "<code id=typeans><span class=typeMissed>\(HTML.escape(expected))</span></code>"
        }
        // longest common subsequence alignment
        let n = given.count, m = correct.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = given[i] == correct[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var typedOut = "", expectedOut = ""
        var i = 0, j = 0
        func span(_ cls: String, _ c: Character) -> String { "<span class=\(cls)>\(HTML.escape(String(c)))</span>" }
        while i < n || j < m {
            if i < n, j < m, given[i] == correct[j] {
                typedOut += span("typeGood", given[i])
                expectedOut += span("typeGood", correct[j])
                i += 1; j += 1
            } else if j < m, i == n || dp[i][j + 1] >= dp[i + 1][j] {
                typedOut += span("typeMissed", "-")
                expectedOut += span("typeMissed", correct[j])
                j += 1
            } else {
                typedOut += span("typeBad", given[i])
                i += 1
            }
        }
        return "<code id=typeans>\(typedOut)<br><span id=typearrow>&darr;</span><br>\(expectedOut)</code>"
    }
}
