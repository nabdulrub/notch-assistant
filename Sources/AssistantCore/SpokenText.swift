import Foundation

public enum SpokenText {
    /// Rime reads `spell(AB12)` letter by letter. A voice that does not know the
    /// directive would read the word "spell" out, so for those it is unwrapped
    /// into spaced characters.
    public static func plain(_ text: String) -> String {
        var output = text
        while let range = output.range(of: #"spell\(([^()]*)\)"#, options: .regularExpression) {
            let inner = output[range].dropFirst(6).dropLast()
            output.replaceSubrange(range, with: inner.map(String.init).joined(separator: " "))
        }
        return output
    }
}
