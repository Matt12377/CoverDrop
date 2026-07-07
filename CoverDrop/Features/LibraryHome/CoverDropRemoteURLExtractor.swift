import Foundation

enum CoverDropRemoteURLExtractor {
    nonisolated static func firstRemoteURL(in error: Error) -> URL? {
        let nsError = error as NSError
        return firstRemoteURL(in: nsError, depth: 0)
    }

    nonisolated static func firstRemoteURL(in value: String) -> URL? {
        let normalizedValue = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(normalizedValue.startIndex ..< normalizedValue.endIndex, in: normalizedValue)
        guard let match = regex.firstMatch(in: normalizedValue, range: range),
              let matchRange = Range(match.range, in: normalizedValue) else {
            return nil
        }

        let candidate = String(normalizedValue[matchRange])
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)］】」”"))
        guard let url = URL(string: candidate),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }

        return url
    }

    nonisolated private static func firstRemoteURL(in value: Any, depth: Int) -> URL? {
        guard depth <= 4 else { return nil }

        if let url = value as? URL,
           ["http", "https"].contains(url.scheme?.lowercased()) {
            return url
        }

        if let string = value as? String {
            return firstRemoteURL(in: string)
        }

        if let string = value as? NSString {
            return firstRemoteURL(in: string as String)
        }

        if let error = value as? NSError {
            let candidates = [error.localizedDescription, error.localizedFailureReason, error.localizedRecoverySuggestion]
                .compactMap(\.self)
            if let url = candidates.lazy.compactMap(firstRemoteURL(in:)).first {
                return url
            }

            return firstRemoteURL(in: error.userInfo, depth: depth + 1)
        }

        if let error = value as? Error {
            return firstRemoteURL(in: error as NSError, depth: depth + 1)
        }

        if let values = value as? [Any] {
            return values.lazy.compactMap { firstRemoteURL(in: $0, depth: depth + 1) }.first
        }

        if let values = value as? [AnyHashable: Any] {
            return values.values.lazy.compactMap { firstRemoteURL(in: $0, depth: depth + 1) }.first
        }

        return nil
    }
}
