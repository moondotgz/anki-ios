import Foundation

/// Parses and renders Anki card templates: `{{Field}}`, `{{#Field}}…{{/Field}}`,
/// `{{^Field}}…{{/Field}}`, and filters such as `cloze:`, `text:`, `hint:`,
/// `type:` and the furigana family.
enum TemplateNode {
    case text(String)
    case replacement(field: String, filters: [String])
    case conditional(field: String, negated: Bool, children: [TemplateNode])
}

enum TemplateParser {
    static func parse(_ template: String) -> [TemplateNode] {
        var tokens: [(isTag: Bool, text: String)] = []
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            if open.lowerBound > rest.startIndex { tokens.append((false, String(rest[..<open.lowerBound]))) }
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                tokens.append((false, String(rest[open.lowerBound...])))
                rest = ""
                break
            }
            tokens.append((true, String(afterOpen[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)))
            rest = afterOpen[close.upperBound...]
        }
        if !rest.isEmpty { tokens.append((false, String(rest))) }

        var index = 0
        return parseNodes(tokens, &index, closing: nil)
    }

    private static func parseNodes(_ tokens: [(isTag: Bool, text: String)], _ i: inout Int, closing: String?) -> [TemplateNode] {
        var nodes: [TemplateNode] = []
        while i < tokens.count {
            let tok = tokens[i]
            i += 1
            guard tok.isTag else {
                nodes.append(.text(tok.text))
                continue
            }
            let t = tok.text
            if t.hasPrefix("#") || t.hasPrefix("^") {
                let name = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                let children = parseNodes(tokens, &i, closing: name)
                nodes.append(.conditional(field: name, negated: t.hasPrefix("^"), children: children))
            } else if t.hasPrefix("/") {
                let name = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                if closing == name { return nodes }
                // stray close tag: keep it visible like Anki does
                nodes.append(.text("{{\(t)}}"))
            } else if t.hasPrefix("!") {
                continue
            } else {
                var parts = t.components(separatedBy: ":")
                let field = parts.removeLast().trimmingCharacters(in: .whitespaces)
                nodes.append(.replacement(field: field, filters: parts.map { $0.trimmingCharacters(in: .whitespaces) }))
            }
        }
        return nodes
    }
}

struct RenderContext {
    var fields: [String: String]
    var cardOrd: Int
    var isQuestion: Bool
    var frontSide: String = ""
    var tags: [String] = []
    var notetypeName = ""
    var deckName = ""
    var templateName = ""
    var flag = 0
    var cardID: Int64 = 0

    func field(_ name: String) -> String? {
        if let v = fields[name] { return v }
        return fields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct TemplateRenderer {
    var context: RenderContext
    /// Set when a non-empty note field was output, which is how Anki
    /// decides whether a card should exist for a template.
    private(set) var usedNonEmptyField = false
    private var hintCounter = 0

    init(context: RenderContext) { self.context = context }

    mutating func render(_ template: String) -> String {
        render(TemplateParser.parse(template))
    }

    mutating func render(_ nodes: [TemplateNode]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let s):
                out += s
            case .conditional(let field, let negated, let children):
                let nonEmpty = isNonEmpty(field)
                if nonEmpty != negated { out += render(children) }
            case .replacement(let field, let filters):
                out += replacement(field: field, filters: filters)
            }
        }
        return out
    }

    private func isNonEmpty(_ field: String) -> Bool {
        if let special = specialField(field) { return !special.isEmpty }
        guard let value = context.field(field) else { return false }
        return !HTML.isEmptyField(value)
    }

    private func specialField(_ name: String) -> String? {
        switch name {
        case "FrontSide": return context.frontSide
        case "Tags": return context.tags.joined(separator: " ")
        case "Type": return context.notetypeName
        case "Deck": return context.deckName
        case "Subdeck": return context.deckName.components(separatedBy: "::").last ?? ""
        case "Card": return context.templateName
        case "CardFlag": return context.flag == 0 ? "" : "flag\(context.flag)"
        case "CardID": return String(context.cardID)
        default: return nil
        }
    }

    private mutating func replacement(field: String, filters: [String]) -> String {
        var value: String
        if let special = specialField(field) {
            value = special
        } else if let v = context.field(field) {
            value = v
            if !HTML.isEmptyField(v) {
                if filters.contains("cloze") {
                    if Cloze.ordinals(in: v).contains(context.cardOrd + 1) { usedNonEmptyField = true }
                } else {
                    usedNonEmptyField = true
                }
            }
        } else if field.isEmpty {
            value = ""
        } else {
            return "<span style=\"color:red\">{{\(field)}}: unknown field</span>"
        }

        // filters apply right to left
        for (i, filter) in filters.enumerated().reversed() {
            switch filter {
            case "type":
                let inner = filters[(i + 1)...].joined(separator: ":")
                return "[[type:\(inner.isEmpty ? "" : inner + ":")\(field)]]"
            case "cloze":
                value = Cloze.render(value, ord: context.cardOrd + 1, question: context.isQuestion)
            case "cloze-only":
                value = Cloze.activeTexts(value, ord: context.cardOrd + 1).joined(separator: ", ")
            case "text":
                value = HTML.strip(value)
            case "hint":
                value = hint(value, field: field)
            case "furigana":
                value = Furigana.ruby(value)
            case "kana":
                value = Furigana.kana(value)
            case "kanji":
                value = Furigana.kanji(value)
            default:
                if filter.hasPrefix("tts") { value = HTML.strip(value) }
            }
        }
        return value
    }

    private mutating func hint(_ text: String, field: String) -> String {
        guard !HTML.isEmptyField(text) else { return "" }
        hintCounter += 1
        let id = "hint\(abs(text.hashValue) % 100_000)\(hintCounter)"
        return """
            <a class=hint href="#" onclick="this.style.display='none';document.getElementById('\(id)').style.display='block';return false;" draggable=false>\(HTML.escape(field))</a><div id="\(id)" class=hint style="display: none">\(text)</div>
            """
    }
}

// MARK: - Cloze

enum Cloze {
    indirect enum Node {
        case text(String)
        case cloze(ords: [Int], children: [Node], hint: String?)
    }

    static func parse(_ text: String) -> [Node] {
        struct Open {
            var ords: [Int]
            var children: [Node] = []
            var hint: String?
            var raw: String
        }
        var stack: [Open] = []
        var root: [Node] = []
        let chars = Array(text)
        var i = 0
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            if stack.isEmpty {
                root.append(.text(buffer))
            } else if stack[stack.count - 1].hint != nil {
                stack[stack.count - 1].hint! += buffer
            } else {
                stack[stack.count - 1].children.append(.text(buffer))
            }
            buffer = ""
        }

        while i < chars.count {
            if chars[i] == "{", i + 3 < chars.count, chars[i + 1] == "{", chars[i + 2] == "c" || chars[i + 2] == "C",
               chars[i + 3].isNumber
            {
                var j = i + 3
                var numText = ""
                while j < chars.count, chars[j].isNumber || chars[j] == "," {
                    numText.append(chars[j])
                    j += 1
                }
                if j + 1 < chars.count, chars[j] == ":", chars[j + 1] == ":" {
                    flush()
                    let ords = numText.split(separator: ",").compactMap { Int($0) }
                    stack.append(Open(ords: ords, raw: String(chars[i..<(j + 2)])))
                    i = j + 2
                    continue
                }
            }
            if !stack.isEmpty, chars[i] == ":", i + 1 < chars.count, chars[i + 1] == ":", stack[stack.count - 1].hint == nil {
                flush()
                stack[stack.count - 1].hint = ""
                i += 2
                continue
            }
            if !stack.isEmpty, chars[i] == "}", i + 1 < chars.count, chars[i + 1] == "}" {
                flush()
                let open = stack.removeLast()
                let node = Node.cloze(ords: open.ords, children: open.children, hint: open.hint)
                if stack.isEmpty {
                    root.append(node)
                } else if stack[stack.count - 1].hint != nil {
                    stack[stack.count - 1].hint! += reconstruct(node)
                } else {
                    stack[stack.count - 1].children.append(node)
                }
                i += 2
                continue
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
        // unclosed clozes are output as text
        while let open = stack.popLast() {
            var nodes: [Node] = [.text(open.raw)]
            nodes += open.children
            if let hint = open.hint { nodes.append(.text("::" + hint)) }
            if stack.isEmpty {
                root += nodes
            } else {
                stack[stack.count - 1].children += nodes
            }
        }
        return root
    }

    private static func reconstruct(_ node: Node) -> String {
        switch node {
        case .text(let s): return s
        case .cloze(let ords, let children, let hint):
            let body = children.map(reconstruct).joined()
            return "{{c\(ords.map(String.init).joined(separator: ","))::\(body)\(hint.map { "::" + $0 } ?? "")}}"
        }
    }

    static func ordinals(in text: String) -> Set<Int> {
        var out = Set<Int>()
        func walk(_ nodes: [Node]) {
            for n in nodes {
                if case .cloze(let ords, let children, _) = n {
                    out.formUnion(ords)
                    walk(children)
                }
            }
        }
        walk(parse(text))
        return out
    }

    private static func plain(_ nodes: [Node]) -> String {
        nodes.map { n -> String in
            switch n {
            case .text(let s): return s
            case .cloze(_, let children, _): return plain(children)
            }
        }.joined()
    }

    static func render(_ text: String, ord: Int, question: Bool) -> String {
        render(parse(text), ord: ord, question: question)
    }

    private static func render(_ nodes: [Node], ord: Int, question: Bool) -> String {
        var out = ""
        for n in nodes {
            switch n {
            case .text(let s):
                out += s
            case .cloze(let ords, let children, let hint):
                if ords.contains(ord) {
                    if question {
                        let shown = hint.map { "[\($0)]" } ?? "[...]"
                        let encoded = HTML.escape(plain(children))
                        out += "<span class=\"cloze\" data-cloze=\"\(encoded)\" data-ordinal=\"\(ord)\">\(shown)</span>"
                    } else {
                        out += "<span class=\"cloze\" data-ordinal=\"\(ord)\">\(render(children, ord: ord, question: question))</span>"
                    }
                } else {
                    let inner = render(children, ord: ord, question: question)
                    out += "<span class=\"cloze-inactive\" data-ordinal=\"\(ords.map(String.init).joined(separator: ","))\">\(inner)</span>"
                }
            }
        }
        return out
    }

    static func activeTexts(_ text: String, ord: Int) -> [String] {
        var out: [String] = []
        func walk(_ nodes: [Node]) {
            for n in nodes {
                if case .cloze(let ords, let children, _) = n {
                    if ords.contains(ord) { out.append(plain(children)) } else { walk(children) }
                }
            }
        }
        walk(parse(text))
        return out
    }
}

// MARK: - Furigana

enum Furigana {
    private static let re = try! NSRegularExpression(pattern: #" ?([^ >]+?)\[(.+?)\]"#)

    private static func apply(_ text: String, _ transform: (String, String) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let base = ns.substring(with: m.range(at: 1))
            let reading = ns.substring(with: m.range(at: 2))
            if reading.hasPrefix("sound:") {
                out += ns.substring(with: m.range)
            } else {
                out += transform(base, reading)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func ruby(_ text: String) -> String { apply(text) { "<ruby><rb>\($0)</rb><rt>\($1)</rt></ruby>" } }
    static func kana(_ text: String) -> String { apply(text) { $1 } }
    static func kanji(_ text: String) -> String { apply(text) { b, _ in b } }
}

// MARK: - Card generation

enum CardGenerator {
    /// Template ordinals that should have cards for this note.
    static func ordinalsToGenerate(note: Note, notetype nt: Notetype) -> [Int] {
        var fields: [String: String] = [:]
        for (i, name) in nt.fieldNames.enumerated() where i < note.fields.count { fields[name] = note.fields[i] }

        if nt.isCloze {
            guard let qfmt = nt.templates.first?["qfmt"].string else { return [] }
            var ords = Set<Int>()
            for node in TemplateParser.parse(qfmt) { collectClozeFields(node, into: &ords, fields: fields) }
            return ords.filter { $0 > 0 }.map { $0 - 1 }.sorted()
        }

        var out: [Int] = []
        for (ord, tmpl) in nt.templates.enumerated() {
            var r = TemplateRenderer(context: RenderContext(fields: fields, cardOrd: ord, isQuestion: true))
            _ = r.render(tmpl["qfmt"].string(or: ""))
            if r.usedNonEmptyField { out.append(ord) }
        }
        return out
    }

    private static func collectClozeFields(_ node: TemplateNode, into ords: inout Set<Int>, fields: [String: String]) {
        switch node {
        case .replacement(let field, let filters):
            if filters.contains("cloze"), let text = fields[field] { ords.formUnion(Cloze.ordinals(in: text)) }
        case .conditional(_, _, let children):
            for c in children { collectClozeFields(c, into: &ords, fields: fields) }
        case .text:
            break
        }
    }
}
