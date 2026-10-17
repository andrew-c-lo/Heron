import Foundation
import Vision

/// What "tap when stuck" checks before tapping (measured in bench/unstuck: the stuck tap kept tapping finished
/// runs, and tapped a shop).
enum StuckGuard {
    /// A price: a currency sign next to a number ("$0.99", "€4,99", "¥120", "1.99 £").
    static func isPrice(_ text: String) -> Bool {
        text.range(of: #"[$€£¥]\s?\d|\d[\d.,]*\s?[$€£¥]"#, options: .regularExpression) != nil
    }

    /// Two or more prices on screen: a shop or purchase screen, where a blind tap could spend money.
    static func looksLikeShop(_ lines: [TextFinder.Line]) -> Bool {
        lines.filter { isPrice($0.text) }.count >= 2
    }

    /// Below this, two screens are the same screen (Vision feature-print distance; set on the eval's practice set).
    static let sameScreen: Float = 0.30

    static func fingerprint(_ px: ScreenReader.WindowPixels) -> VNFeaturePrintObservation? {
        guard let cg = px.cgImage else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        return req.results?.first
    }

    static func same(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Bool {
        var d: Float = .infinity
        try? a.computeDistance(&d, to: b)
        return d < sameScreen
    }
}
