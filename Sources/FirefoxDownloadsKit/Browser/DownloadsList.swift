// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Which version of a downloads.json an answer came from: a rewritten file
/// is another version.
struct ListVersion: Equatable {
    var file: String
    var modified: Int64
    var size: Int64
}

/// What one downloads.json says about one download.
struct ListEntry: Equatable {
    var total: Int?
    var state: String
}

/// How downloads are looked up in a downloads.json: by a file's full path,
/// or by its name alone.
struct ListKey: Hashable {
    enum Kind: Hashable { case path, name }
    var kind: Kind
    var key: String

    /// By full path, as Firefox writes it (`os.path.normpath`, composed form).
    static func path(_ path: String) -> ListKey {
        ListKey(kind: .path, key: Paths.normalized(path).precomposedStringWithCanonicalMapping)
    }

    /// By name.
    static func name(_ path: String) -> ListKey {
        ListKey(kind: .name, key: Paths.basename(path).precomposedStringWithCanonicalMapping)
    }
}

enum DownloadsListFile {
    private static let blockedFlags = ["becauseBlocked", "becauseBlockedByParentalControls",
                                       "becauseBlockedByReputationCheck", "becauseBlockedByContentAnalysis"]

    private static func isTrue(_ value: Any?) -> Bool {
        guard let value, let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    /// Whether a JSON value counts as something, as Python sees it (not
    /// null, false, 0, "", [] or {}).
    static func truthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let text = value as? String { return !text.isEmpty }
        if let items = value as? [Any] { return !items.isEmpty }
        if let pairs = value as? [String: Any] { return !pairs.isEmpty }
        return true
    }

    /// What one downloads.json entry says about its download:
    ///   "failed"  -- it stopped with an error and kept its partial data
    ///                (Firefox lists it with an "errorObj"; Retry continues it)
    ///   "paused"  -- stopped by a pause (in the browser, or by Firefox
    ///                itself when the Mac sleeps or goes offline): "canceled"
    ///                while keeping its partial data
    ///   "blocked" -- held back as a potential security risk, until you
    ///                decide in the browser
    ///   "active"  -- downloading
    ///   ""        -- in between (being canceled, just finished)
    static func state(of item: [String: Any]) -> String {
        let error = item["errorObj"]
        if isTrue(item["hasBlockedData"]) { return "blocked" }
        if let flags = error as? [String: Any] {
            return blockedFlags.contains { isTrue(flags[$0]) } ? "blocked" : "failed"
        }
        if truthy(error) { return "failed" }
        if isTrue(item["succeeded"]) { return "" }
        if isTrue(item["canceled"]) {
            return isTrue(item["hasPartialData"]) ? "paused" : ""
        }
        return "active"
    }

    /// The downloads listed in one downloads.json, keyed by the partial
    /// file's full path and by its name (and by the final file's, as a
    /// fallback). Firefox writes each download's target as {"path": ...,
    /// "partFilePath": ...}, includes "totalBytes" once the server has sent
    /// the size, and the fields that tell a paused or failed download apart
    /// (see `state(of:)`).
    static func read(_ path: String) -> [ListKey: ListEntry] {
        guard let data = FileManager.default.contents(atPath: path),
              String(data: data, encoding: .utf8) != nil,
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [:] }
        var entries: [ListKey: ListEntry] = [:]
        let items = (json as? [String: Any])?["list"] as? [Any] ?? []
        for case let item as [String: Any] in items {
            var total: Int?
            if let number = item["totalBytes"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue > 0 {
                total = CFNumberIsFloatType(number) ? Int(exactly: number.doubleValue.rounded(.towardZero)) : number.intValue
            }
            let state = state(of: item)
            var paths: [String] = []
            if let target = item["target"] as? String {
                paths.append(target)
            } else if let target = item["target"] as? [String: Any] {
                paths += ["partFilePath", "path"].compactMap { target[$0] as? String }
            }
            for found in paths {
                entries[.path(found)] = ListEntry(total: total, state: state)
                entries[.name(found)] = ListEntry(total: total, state: state)
            }
        }
        return entries
    }
}

/// Every profile's downloads.json. Firefox rewrites that file (atomically)
/// about 1.5 s after a download starts, gets its size, pauses, resumes,
/// fails or stops; it's only read again here when it changes.
final class DownloadsList {
    private struct Cached {
        var stamp: (Int64, Int64)
        var entries: [ListKey: ListEntry]
        var process: String
    }

    /// The files, in the order they were first read.
    private var order: [String] = []
    private var cache: [String: Cached] = [:]

    func refresh(_ profiles: [(path: String, process: String)]) {
        var live = Set<String>()
        for (profile, process) in profiles {
            let file = Paths.join(profile, "downloads.json")
            live.insert(file)
            var info = stat()
            guard stat(file, &info) == 0 else {
                remove(file)
                continue
            }
            let stamp = (Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec), Int64(info.st_size))
            if let cached = cache[file], cached.stamp == stamp { continue }
            if cache[file] == nil { order.append(file) }
            cache[file] = Cached(stamp: stamp, entries: DownloadsListFile.read(file), process: process)
        }
        for file in order where !live.contains(file) {
            remove(file)
        }
    }

    private func remove(_ file: String) {
        cache.removeValue(forKey: file)
        order.removeAll { $0 == file }
    }

    /// (total bytes or nothing, state, browser process, version of the
    /// file) for one download, or (nothing, "", "", nothing) when no
    /// downloads.json lists it. The version tells a rewritten file from the
    /// same one. A match on the final file's name alone (another folder's
    /// download may have the same name) gives the size but not the state.
    func lookup(_ download: Download) -> (total: Int?, state: String, process: String, version: ListVersion?) {
        let keys: [ListKey] = [.path(download.partPath), .name(download.partPath),
                               .path(download.finalPath), .name(download.finalPath)]
        for (index, key) in keys.enumerated() {
            for file in order {
                guard let cached = cache[file], let entry = cached.entries[key] else { continue }
                return (entry.total, index < 3 ? entry.state : "", cached.process,
                        ListVersion(file: file, modified: cached.stamp.0, size: cached.stamp.1))
            }
        }
        return (nil, "", "", nil)
    }

    /// Whether the downloads.json of the download's profile lists this very
    /// partial file (by its path or its name) -- not merely a download with
    /// the same final name.
    func listsPartialFile(_ download: Download) -> Bool {
        guard let profile = download.profile, let hit = cache[Paths.join(profile, "downloads.json")] else { return false }
        return hit.entries[.path(download.partPath)] != nil || hit.entries[.name(download.partPath)] != nil
    }

    /// The browser profile whose downloads.json lists this download (by its
    /// partial file, or its final file's full path), or nothing.
    func profile(of download: Download) -> String? {
        let keys: [ListKey] = [.path(download.partPath), .name(download.partPath), .path(download.finalPath)]
        for key in keys {
            for file in order where cache[file]?.entries[key] != nil {
                return Paths.parent(file)
            }
        }
        return nil
    }
}
