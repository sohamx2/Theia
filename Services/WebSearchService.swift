import Foundation

enum WebSearchError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case responseTooLarge
    case http(Int)
    case noResults

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "The web-search endpoint is invalid."
        case .invalidResponse:
            return "The web-search service returned an invalid response."
        case .responseTooLarge:
            return "The web-search response exceeded Theia's size limit."
        case .http(let status):
            return "The web-search service returned HTTP \(status)."
        case .noResults:
            return "The web-search service returned no usable results."
        }
    }
}

struct WebSearchResponse: Equatable {
    let query: String
    let results: [WebSearchResult]
    let startedAt: Date
    let durationMilliseconds: Int
}

protocol WebSearchProviding {
    func search(query: String, limit: Int) async throws -> WebSearchResponse
}

struct DisabledWebSearchService: WebSearchProviding {
    func search(query: String, limit: Int) async throws -> WebSearchResponse {
        throw WebSearchError.noResults
    }
}

final class DuckDuckGoWebSearchService: WebSearchProviding {
    private let endpoint: URL
    private let session: URLSession
    private let timeoutSeconds: TimeInterval
    private let maximumResponseBytes = 1_500_000

    init(
        endpoint: URL = URL(string: "https://html.duckduckgo.com/html/")!,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 12
    ) {
        self.endpoint = endpoint
        self.session = session
        self.timeoutSeconds = timeoutSeconds
    }

    func search(query: String, limit: Int = 8) async throws -> WebSearchResponse {
        let startedAt = Date()
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw WebSearchError.invalidEndpoint
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw WebSearchError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Theia/1.0.0-beta",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebSearchError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WebSearchError.http(httpResponse.statusCode)
        }
        guard data.count <= maximumResponseBytes else {
            throw WebSearchError.responseTooLarge
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw WebSearchError.invalidResponse
        }

        let results = parseResults(html: html, limit: max(1, min(limit, 10)))
        guard !results.isEmpty else { throw WebSearchError.noResults }
        return WebSearchResponse(
            query: query,
            results: results,
            startedAt: startedAt,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
        )
    }

    func parseResults(html: String, limit: Int) -> [WebSearchResult] {
        let titlePattern = #"<a[^>]*class=[\"'][^\"']*\bresult__a\b[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"'][^>]*>([\s\S]*?)</a>"#
        let snippetPattern = #"<a[^>]*class=[\"'][^\"']*\bresult__snippet\b[^\"']*[\"'][^>]*>([\s\S]*?)</a>"#
        guard let titleRegex = try? NSRegularExpression(
            pattern: titlePattern,
            options: [.caseInsensitive]
        ), let snippetRegex = try? NSRegularExpression(
            pattern: snippetPattern,
            options: [.caseInsensitive]
        ) else { return [] }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let titleMatches = titleRegex.matches(in: html, range: fullRange)
        var seenURLs = Set<String>()
        var seenTitles = Set<String>()
        var results: [WebSearchResult] = []

        for (index, match) in titleMatches.enumerated() {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html)
            else { continue }

            let nextLocation = index + 1 < titleMatches.count
                ? titleMatches[index + 1].range.location
                : fullRange.location + fullRange.length
            let snippetSearchRange = NSRange(
                location: match.range.location + match.range.length,
                length: max(0, nextLocation - match.range.location - match.range.length)
            )
            let snippetMatch = snippetRegex.firstMatch(in: html, range: snippetSearchRange)
            let snippetHTML = snippetMatch.flatMap { Range($0.range(at: 1), in: html) }
                .map { String(html[$0]) } ?? ""

            let title = cleanHTML(String(html[titleRange]))
            let snippet = cleanHTML(snippetHTML)
            let rawHref = decodeHTMLEntities(String(html[hrefRange]))
            guard let resultURL = resolvedResultURL(rawHref),
                  let host = URL(string: resultURL)?.host?.lowercased(),
                  title.count >= 3
            else { continue }

            let titleKey = ContentPhrasePolicy.compactKey(title)
            guard seenURLs.insert(resultURL).inserted,
                  seenTitles.insert(titleKey).inserted
            else { continue }

            results.append(
                WebSearchResult(
                    rank: results.count + 1,
                    title: String(title.prefix(240)),
                    snippet: String(snippet.prefix(700)),
                    sourceHost: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host,
                    url: resultURL
                )
            )
            if results.count >= limit { break }
        }
        return results
    }

    private func resolvedResultURL(_ rawHref: String) -> String? {
        let absolute = rawHref.hasPrefix("//") ? "https:\(rawHref)" : rawHref
        guard let url = URL(string: absolute) else { return nil }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let destination = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let destinationURL = URL(string: destination),
           destinationURL.scheme == "https" || destinationURL.scheme == "http" {
            return destinationURL.absoluteString
        }
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        return url.absoluteString
    }

    private func cleanHTML(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return decodeHTMLEntities(withoutTags)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
        let namedEntities = [
            "&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ]
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }

        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|[0-9]+);"#) else {
            return decoded
        }
        let matches = regex.matches(
            in: decoded,
            range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
        )
        for match in matches.reversed() {
            guard let matchRange = Range(match.range(at: 0), in: decoded),
                  let valueRange = Range(match.range(at: 1), in: decoded)
            else { continue }
            let encodedValue = String(decoded[valueRange])
            let scalarValue = encodedValue.lowercased().hasPrefix("x")
                ? UInt32(encodedValue.dropFirst(), radix: 16)
                : UInt32(encodedValue, radix: 10)
            guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { continue }
            decoded.replaceSubrange(matchRange, with: String(Character(scalar)))
        }
        return decoded
    }
}
