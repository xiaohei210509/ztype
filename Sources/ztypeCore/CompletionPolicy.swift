import Foundation
import NaturalLanguage

public enum CompletionPolicy {
    public static func filter(_ raw: String, context: CompletionContext, limit: Int = 10) -> String? {
        guard context.eligible else { return nil }
        var result = raw.trimmingCharacters(in: .newlines)
        let prior = context.before.trimmingCharacters(in: .whitespacesAndNewlines)
        if prior.count >= 8, result.hasPrefix(prior) {
            result = String(result.dropFirst(prior.count))
        } else {
            let common = zip(prior, result).prefix(while: { $0.0 == $0.1 }).count
            if common >= 12 { return nil }
        }
        if context.before.last?.isWhitespace == true {
            result = String(result.drop(while: \.isWhitespace))
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NONE", trimmed != "<NONE>",
              !result.contains("<think>"), !result.contains("</think>"),
              !result.contains("```"), !result.contains("<|"),
              !result.contains("\n"), !result.contains("\t"),
              !trimmed.lowercased().hasPrefix("sure"),
              !trimmed.lowercased().hasPrefix("here is"),
              !trimmed.lowercased().hasPrefix("missing text:"),
              !trimmed.lowercased().hasPrefix("continuation:"),
              !trimmed.lowercased().hasPrefix("i'm sorry") else { return nil }
        if result.count > 160 { return nil }
        if context.language == .english,
           result.unicodeScalars.contains(where: CompletionLanguage.isHan) {
            return nil
        }
        if trimmed.hasPrefix("\"") || trimmed.hasSuffix("\"") { return nil }
        if context.before.count > 16, result.hasPrefix(String(context.before.suffix(16))) { return nil }

        let pieces = result.split(separator: " ", omittingEmptySubsequences: true)
        if pieces.count > limit {
            result = (result.hasPrefix(" ") ? " " : "") + pieces.prefix(limit).joined(separator: " ")
        }
        // Native continuation preserves word spacing; never guess a boundary from a word list.
        if !context.after.isEmpty {
            if result.trimmingCharacters(in: .whitespaces) ==
                context.after.trimmingCharacters(in: .whitespaces) { return nil }
            for index in result.indices {
                let suffix = String(result[index...])
                guard context.after.hasPrefix(suffix),
                      index == result.startIndex || result[index].isWhitespace || !result[index].isLetter else {
                    continue
                }
                let remaining = context.after.dropFirst(suffix.count)
                if suffix.last?.isLetter == true, remaining.first?.isLetter == true { continue }
                result = String(result[..<index])
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }

    public static func nextWord(in suggestion: String) -> String {
        guard let first = suggestion.firstIndex(where: { !$0.isWhitespace }) else { return suggestion }
        let remainder = suggestion[first...]
        if remainder.unicodeScalars.contains(where: CompletionLanguage.isHan) {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = suggestion
            var wordEnd: String.Index?
            tokenizer.enumerateTokens(in: first..<suggestion.endIndex) { range, _ in
                wordEnd = range.upperBound
                return false
            }
            if var end = wordEnd {
                // Keep closing punctuation with the accepted word, not as a separate Tab.
                while end < suggestion.endIndex, suggestion[end].isPunctuation {
                    end = suggestion.index(after: end)
                }
                return String(suggestion[..<end])
            }
            return String(suggestion[...first])
        }
        guard let boundary = remainder.firstIndex(where: \.isWhitespace) else { return suggestion }
        return String(suggestion[..<boundary])
    }
}
