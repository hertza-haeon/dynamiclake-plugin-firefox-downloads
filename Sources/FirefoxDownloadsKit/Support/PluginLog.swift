// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The plugin's log, `~/Library/Logs/FirefoxDownloads/plugin.log`: one line
/// per event, outside the plugin's package (DynamicLake checks that package,
/// and nothing may be written into it). Writing to the log is never allowed
/// to break the plugin.
public final class PluginLog: @unchecked Sendable {
    /// The folder in ~/Library/Logs.
    public static let defaultFolder = "FirefoxDownloads"

    public let path: String
    /// Past this size the log is set aside as `plugin.log.1` and begun anew.
    public var maxBytes: Int
    /// Whether each line is printed as well.
    public let echo: Bool
    private let lock = NSLock()

    public init(path: String, maxBytes: Int = 256 * 1024, echo: Bool = false) {
        self.path = path
        self.maxBytes = maxBytes
        self.echo = echo
    }

    /// The log in ~/Library/Logs/`folder`.
    public static func inLibrary(folder: String = defaultFolder, echo: Bool = false) -> PluginLog {
        PluginLog(path: Paths.join(homeFolder(), "Library/Logs/\(folder)/plugin.log"), echo: echo)
    }

    /// Appends one line, after the date and time.
    public func write(_ message: String) {
        let line = Self.stamp(Date()) + "  " + message + "\n"
        lock.lock()
        defer { lock.unlock() }
        if echo {
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        try? FileManager.default.createDirectory(atPath: Paths.parent(path), withIntermediateDirectories: true)
        if let size = Paths.size(path), size > maxBytes {
            rename(path, path + ".1")
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// `2026-10-11 17:14:43`, in the Mac's own time zone, whatever its
    /// language and region are set to.
    static func stamp(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        func two(_ value: Int32) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(parts.tm_year + 1900)-\(two(parts.tm_mon + 1))-\(two(parts.tm_mday)) "
            + "\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec))"
    }
}
