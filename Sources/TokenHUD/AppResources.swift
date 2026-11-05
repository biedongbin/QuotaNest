import Foundation

extension Bundle {
    /// Installed apps use the signed macOS Resources directory; SwiftPM CLI builds use .module.
    static let appResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("QuotaNest_QuotaNest.bundle"),
           let bundled = Bundle(url: url) {
            return bundled
        }
        return .module
    }()
}
