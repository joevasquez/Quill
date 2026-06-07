import ComposableArchitecture
import Foundation
import HexCore

typealias UsageStats = HexCore.UsageStats

extension SharedReaderKey
    where Self == FileStorageKey<UsageStats>.Default
{
    static var usageStats: Self {
        Self[
            .fileStorage(.usageStatsURL),
            default: .init()
        ]
    }
}

extension URL {
    static var usageStatsURL: URL {
        URL.hexMigratedFileURL(named: "usage_stats.json")
    }
}
