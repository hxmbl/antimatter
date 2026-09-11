import Foundation

/// Flesch-Kincaid readability metrics.
enum ReadingMetrics {
    static func fleschKincaidEase(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let words = text.split(separator: /\s+/)
        let syllables = words.reduce(0) { $0 + countSyllables(String($1)) }
        guard sentences > 0, !words.isEmpty else { return 0 }
        let score = 206.835 - 1.015 * (Double(words.count) / Double(sentences)) - 84.6 * (Double(syllables) / Double(words.count))
        return max(0, min(100, score))
    }

    static func countSyllables(_ word: String) -> Int {
        let vowels = "aeiouy"
        let lowered = word.lowercased()
        var count = 0
        var prevVowel = false
        for char in lowered {
            let isVowel = vowels.contains(char)
            if isVowel && !prevVowel { count += 1 }
            prevVowel = isVowel
        }
        if lowered.hasSuffix("e") && count > 1 { count -= 1 }
        return max(1, count)
    }
}
