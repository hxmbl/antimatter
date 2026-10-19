import Foundation

/// The app's marketing version and build number, read off the bundle.
/// Backs `.version` and the stats report.
enum AppVersion {
    static var text: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        default: return "1.0"
        }
    }
}
