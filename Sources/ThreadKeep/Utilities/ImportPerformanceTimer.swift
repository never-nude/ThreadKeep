import Foundation
import os

struct ImportPerformanceTimer {
    private let label: String
    private let logger: Logger
    private let enabled: Bool
    private let startNanos: UInt64
    private var lastNanos: UInt64

    init(label: String, logger: Logger) {
        self.label = label
        self.logger = logger
        enabled = ProcessInfo.processInfo.environment["THREADKEEP_IMPORT_TIMING"] == "1"
        startNanos = DispatchTime.now().uptimeNanoseconds
        lastNanos = startNanos
    }

    mutating func mark(_ stage: String, items: Int? = nil) {
        guard enabled else { return }

        let now = DispatchTime.now().uptimeNanoseconds
        let delta = Double(now - lastNanos) / 1_000_000_000
        let total = Double(now - startNanos) / 1_000_000_000
        let itemText = items.map(String.init) ?? "-"
        let logLabel = label
        lastNanos = now

        logger.debug("[KastorImportTiming] \(logLabel, privacy: .public) \(stage, privacy: .public) delta=\(delta, privacy: .public)s total=\(total, privacy: .public)s items=\(itemText, privacy: .public)")
    }
}
