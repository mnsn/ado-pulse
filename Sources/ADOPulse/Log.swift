import os

/// Diagnostics: `log show --last 10m --predicate 'subsystem == "com.asaf.ADOPulse"'`
enum Log {
    static let app = Logger(subsystem: "com.asaf.ADOPulse", category: "app")
}
