import Foundation

@main
struct TemporalFreshnessRegression {
    static func main() throws {
        let service = TemporalFreshnessService()
        let analyzedAt = isoDate("2026-09-01T00:00:00Z")

        let postCutoff = service.assess(
            text: ["Aurora Browser 2026 release notes"],
            category: .coding,
            analyzedAt: analyzedAt
        )
        try require(postCutoff.status == .outsideKnowledgeWindow, "A 2026 event must be outside the configured knowledge window.")
        try require(postCutoff.detectedYears == [2026], "The explicit post-cutoff year was not extracted.")
        try require(!postCutoff.requiresLiveWebSearch, "A post-cutoff year alone must not force live evidence for stable coding content.")
        try require(postCutoff.trigger?.rule == "post_cutoff_year", "The post-cutoff rule must be inspectable.")
        try require(postCutoff.trigger?.matchingLine == "Aurora Browser 2026 release notes", "The exact freshness line must be preserved.")

        let currentProduct = service.assess(
            text: ["Aurora Phone 2026 current price"],
            category: .shopping,
            analyzedAt: analyzedAt
        )
        try require(currentProduct.requiresLiveWebSearch, "Current product pricing requires live evidence.")
        try require(currentProduct.trigger?.rule == "category_current_fact", "Product pricing must use a category-specific rule.")
        try require(currentProduct.trigger?.signal == "current price", "The exact current-fact signal must be reported.")

        let current = service.assess(
            text: ["Latest election results and live updates"],
            category: .news,
            analyzedAt: analyzedAt
        )
        try require(current.status == .currentInformationRequested, "Recency language must trigger the current-information route.")
        try require(current.requiresLiveWebSearch, "Current-information requests must require live evidence.")
        try require(current.trigger?.matchingLine == "Latest election results and live updates", "Developer diagnostics need the matching source line.")

        let stable = service.assess(
            text: ["Universal approximation theorem for shallow neural networks"],
            category: .learning,
            analyzedAt: analyzedAt
        )
        try require(stable.status == .stable, "Stable textbook material must remain local.")
        try require(!stable.requiresLiveWebSearch, "Stable textbook material must not force internet access.")

        let broadWords = service.assess(
            text: ["Transformer model architecture and flight dynamics"],
            category: .learning,
            analyzedAt: analyzedAt
        )
        try require(broadWords.status == .stable, "Bare words such as model and flight must not be freshness triggers.")
        try require(!broadWords.requiresLiveWebSearch, "Broad nouns must remain available to the local model.")

        let historical = service.assess(
            text: ["A review of transformer research published in 2023 and 2024"],
            category: .learning,
            analyzedAt: analyzedAt
        )
        try require(historical.status == .withinKnowledgeWindow, "Pre-cutoff years must remain inside the local knowledge window.")
        try require(historical.detectedYears == [2023, 2024], "All visible historical years should be preserved.")

        let copyrightOnly = service.assess(
            text: ["Copyright © 2026 Example Press", "Backpropagation fundamentals"],
            category: .learning,
            analyzedAt: analyzedAt
        )
        try require(copyrightOnly.status == .stable, "A copyright footer must not make stable content appear current.")

        print("Temporal freshness regression passed.")
    }

    private static func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TemporalRegressionError.failure(message) }
    }
}

private enum TemporalRegressionError: Error {
    case failure(String)
}
