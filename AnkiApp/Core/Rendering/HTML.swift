import Foundation

enum HTML {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> NSRegularExpression {
        // patterns are compile-time constants
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let mediaTags = regex(#"<img[^>]*?src\s*=\s*(?:"([^"]+)"|'([^']+)'|([^ >]+))[^>]*>"#)
    private static let comments = regex(#"<!--.*?-->"#)
    private static let styleScript = regex(#"<(style|script)\b.*?</\1>"#)
    private static let tags = regex(#"<[^>]*>"#)
    private static let breaks = regex(#"<br\s*/?>|<div>|</div>|<p>|</p>"#)
    private static let emptyField = regex(#"^(?:[\s]|&nbsp;|</?(?:br|div)\s*/?>)*$"#)

    static func replace(_ re: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func strip(_ html: String) -> String {
        var s = replace(comments, in: html, with: "")
        s = replace(styleScript, in: s, with: "")
        s = replace(tags, in: s, with: "")
        return decodeEntities(s)
    }

    /// Strips HTML for sort fields and checksums, keeping image file names so
    /// image-only fields still sort and de-duplicate sensibly.
    static func stripPreservingMediaFilenames(_ html: String) -> String {
        let s = replace(mediaTags, in: html, with: " $1$2$3 ")
        return strip(s)
    }

    /// Converts HTML to plain text with line breaks, for editing previews.
    static func toPlainText(_ html: String) -> String {
        let s = replace(breaks, in: html, with: "\n")
        return strip(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isEmptyField(_ text: String) -> Bool {
        emptyField.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let entity = String(s[s.index(after: i)..<semi])
                if let decoded = decodeEntity(entity) {
                    out += decoded
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ e: String) -> String? {
        switch e {
        case "nbsp": return " "
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        default:
            if e.hasPrefix("#x") || e.hasPrefix("#X"), let v = UInt32(e.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                return String(Character(u))
            }
            if e.hasPrefix("#"), let v = UInt32(e.dropFirst()), let u = Unicode.Scalar(v) {
                return String(Character(u))
            }
            return nil
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Converts plain text from an editor into field HTML.
    static func fromPlainText(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Media file names referenced by a field: images, sounds, and other
    /// `src` attributes.
    static func mediaReferences(_ html: String) -> [String] {
        var out: [String] = []
        let range = NSRange(html.startIndex..., in: html)
        let srcRe = regex(#"<(?:img|audio|video|source)\b[^>]*?src\s*=\s*(?:"([^"]+)"|'([^']+)'|([^ >]+))"#)
        for m in srcRe.matches(in: html, range: range) {
            for g in 1...3 {
                if let r = Range(m.range(at: g), in: html) { out.append(String(html[r])) }
            }
        }
        let soundRe = regex(#"\[sound:([^\]]+)\]"#, [])
        for m in soundRe.matches(in: html, range: range) {
            if let r = Range(m.range(at: 1), in: html) { out.append(String(html[r])) }
        }
        return out
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { !$0.contains("://") && !$0.hasPrefix("data:") && !$0.contains("/") }
    }
}
