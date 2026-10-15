// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// One value of a browser's prefs.js.
enum PrefValue: Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)

    /// Compared with a number the way Python compares it (`true` is 1).
    func equals(_ number: Int) -> Bool {
        switch self {
        case .bool(let flag): (flag ? 1 : 0) == number
        case .int(let value): value == number
        case .string: false
        }
    }

    /// Whether it counts as something (not `false`, `0` or empty).
    var isTruthy: Bool {
        switch self {
        case .bool(let flag): flag
        case .int(let value): value != 0
        case .string(let text): !text.isEmpty
        }
    }
}

/// Browser profiles, the folders they download to, and their partial files.
enum Profiles {
    private static var prefLine: Regex<(Substring, Substring, Substring)> { #/user_pref\("([^"]+)",\s*(.*?)\);/# }

    /// Small, forgiving parser for Firefox-style prefs.js user_pref()
    /// lines. Only three keys are needed (folderList / dir /
    /// useDownloadDir), so this does not attempt to be a full JS parser --
    /// just enough to pull out string/bool/int literals from that one call
    /// pattern.
    static func parsePrefs(_ path: String) -> [String: PrefValue] {
        var values: [String: PrefValue] = [:]
        guard let data = FileManager.default.contents(atPath: path) else { return values }
        let text = String(decoding: data, as: UTF8.self)
        for match in text.matches(of: prefLine) {
            let key = String(match.1)
            let raw = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw == "true" {
                values[key] = .bool(true)
            } else if raw == "false" {
                values[key] = .bool(false)
            } else if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
                values[key] = .string(String(raw.dropFirst().dropLast()))
            } else if let number = pythonInt(raw) {
                values[key] = .int(number)
            } else {
                values[key] = .string(raw)
            }
        }
        return values
    }

    /// Python's `int(text)`: digits, a sign, underscores between digits.
    static func pythonInt(_ text: String) -> Int? {
        var body = Substring(text)
        var negative = false
        if body.first == "+" || body.first == "-" {
            negative = body.first == "-"
            body = body.dropFirst()
        }
        guard let first = body.first, first.isASCII, first.isNumber, body.last?.isNumber == true,
              !body.contains("__") else { return nil }
        let digits = body.filter { $0 != "_" }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else { return nil }
        return negative ? -value : value
    }

    static func downloadFolder(_ prefs: [String: PrefValue], home: String) -> String {
        let folderList = prefs["browser.download.folderList"] ?? .int(1)
        if folderList.equals(2), let custom = prefs["browser.download.dir"], custom.isTruthy, case .string(let dir) = custom {
            return Paths.clean(Paths.expandingTilde(dir))
        }
        if folderList.equals(0) {
            return Paths.join(home, "Desktop")
        }
        return Paths.join(home, "Downloads")
    }

    private static func listing(_ folder: String) -> [String]? {
        (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted()
    }

    /// Profile folders listed in profiles.ini, including ones stored outside
    /// the usual Profiles folder.
    static func iniPaths(_ appRoot: String) -> [String] {
        var found: [String] = []
        guard let data = FileManager.default.contents(atPath: Paths.join(appRoot, "profiles.ini")) else { return found }
        let text = String(decoding: data, as: UTF8.self)
        // The sections: split before each "[" that starts a line. (Lines
        // are split at "\n" alone: a "\r" before it stays on the line.)
        var sections: [[String]] = [[]]
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") {
                sections.append([String(line.dropFirst())])
            } else {
                sections[sections.count - 1].append(line)
            }
        }
        for section in sections {
            var fields: [String: String] = [:]
            for line in section {
                // name=value, the name made of letters, digits and "_"
                guard let equals = line.firstIndex(of: "=") else { continue }
                let name = line[..<equals]
                guard !name.isEmpty, name.unicodeScalars.allSatisfy({ $0 == "_" || CharacterSet.alphanumerics.contains($0) }) else {
                    continue
                }
                fields[String(name)] = String(line[line.index(after: equals)...])
            }
            let raw = (fields["Path"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }
            let relative = (fields["IsRelative"] ?? "1").trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            found.append(relative ? Paths.joining(appRoot, raw) : Paths.clean(raw))
        }
        return found
    }

    /// Every Firefox-family profile folder on this Mac, with the name of
    /// the browser process that owns it ("" when unknown). Folder names are
    /// matched without regard to case (LibreWolf's is "librewolf" on some
    /// Macs).
    static func discover() -> [(path: String, process: String)] {
        let home = homeFolder()
        let support = Paths.join(home, "Library/Application Support")
        var wanted: [String: String] = [:]
        for (name, process) in firefoxFamily { wanted[name.lowercased()] = process }
        var appRoots: [(String, String)] = []
        for entry in listing(support) ?? [] {
            let path = Paths.join(support, entry)
            if let process = wanted[entry.lowercased()], Paths.isDirectory(path) {
                appRoots.append((path, process))
            }
        }
        var found: [(path: String, process: String)] = []
        var seen = Set<[UInt64]>()
        func add(_ profile: String, _ process: String) {
            var info = stat()
            guard stat(profile, &info) == 0 else { return }
            let key = [UInt64(UInt32(bitPattern: info.st_dev)), info.st_ino]
            if (info.st_mode & S_IFMT) == S_IFDIR && !seen.contains(key) {
                seen.insert(key)
                found.append((profile, process))
            }
        }
        for (appRoot, process) in appRoots {
            for profile in iniPaths(appRoot) {
                add(profile, process)
            }
            let folder = Paths.join(appRoot, "Profiles")
            for entry in listing(folder) ?? [] {
                add(Paths.join(folder, entry), process)
            }
        }
        // Tor Browser ships a self-contained profile inside the .app bundle.
        for base in ["/Applications", Paths.join(home, "Applications")] {
            add(Paths.join(base, "Tor Browser.app/Contents/Resources/TorBrowser/Data/Browser/profile.default"), "")
        }
        return found
    }

    /// The folders to watch: ~/Downloads, and each profile's own download folder.
    static func watchFolders(_ profiles: [(path: String, process: String)]) -> [String] {
        let home = homeFolder()
        var folders: Set<String> = [Paths.join(home, "Downloads")]
        for (profile, _) in profiles {
            let prefs = Paths.join(profile, "prefs.js")
            if Paths.isFile(prefs) {
                folders.insert(downloadFolder(parsePrefs(prefs), home: home))
            }
        }
        return folders.filter(Paths.isDirectory).sorted()
    }

    /// The partial files in a folder (ordinary files only, not links).
    static func partFiles(in folder: String) -> Set<String> {
        guard let directory = opendir(folder) else { return [] }
        defer { closedir(directory) }
        var found: Set<String> = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            guard name.hasSuffix(".part") else { continue }
            let path = Paths.join(folder, name)
            var info = stat()
            let kind = entry.pointee.d_type
            if kind == DT_REG || (kind == DT_UNKNOWN && lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG) {
                found.insert(path)
            }
        }
        return found
    }
}
