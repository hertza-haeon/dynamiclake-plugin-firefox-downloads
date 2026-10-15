// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Seconds on a clock that only counts while the Mac is awake: it stands
/// still while the Mac sleeps (see `SleepWatch`), and never goes back.
public func monotonic() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
}

/// Seconds since 1970 on the wall clock, which goes on while the Mac sleeps.
public func wallClock() -> Double {
    Date().timeIntervalSince1970
}

/// The home folder: `HOME`, as for any program run from a shell, else the
/// account's own.
public func homeFolder() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
        return home
    }
    return NSHomeDirectory()
}

/// Paths written as the Python plugin's `Path` writes them.
enum Paths {
    /// `folder/name`.
    static func join(_ folder: String, _ name: String) -> String {
        folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    /// The folder a path is in.
    static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    /// The last part of a path.
    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The same path with another last part.
    static func withName(_ path: String, _ name: String) -> String {
        join(parent(path), name)
    }

    /// `os.path.exists`: something is there, following links.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    /// `os.path.lexists`: something is there, a broken link too.
    static func lexists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// The size of a file (following links), or nothing when it can't be read.
    static func size(_ path: String) -> Int? {
        var info = stat()
        return stat(path, &info) == 0 ? Int(info.st_size) : nil
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func isFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// `~` at the start of a path, made the home folder (`expanduser`).
    static func expandingTilde(_ path: String) -> String {
        if path == "~" { return homeFolder() }
        if path.hasPrefix("~/") { return join(homeFolder(), String(path.dropFirst(2))) }
        return (path as NSString).expandingTildeInPath
    }

    /// A path as Python's `Path` keeps it: no doubled slash, no `.` part,
    /// no slash at the end (`..` stays).
    static func clean(_ path: String) -> String {
        if path.isEmpty { return "." }
        let absolute = path.hasPrefix("/")
        let initial = absolute ? (path.hasPrefix("//") && !path.hasPrefix("///") ? 2 : 1) : 0
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        let result = String(repeating: "/", count: initial) + parts.joined(separator: "/")
        return result.isEmpty ? "." : result
    }

    /// `Path(base) / other`: `other` itself when it's a full path.
    static func joining(_ base: String, _ other: String) -> String {
        clean(other.hasPrefix("/") ? other : join(base, other))
    }

    /// `os.path.basename`: what follows the last slash (nothing after a
    /// slash at the end).
    static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// `os.path.normpath`: no `.`, no `..` that can be resolved, no doubled
    /// or trailing slash.
    static func normalized(_ path: String) -> String {
        if path.isEmpty { return "." }
        let absolute = path.hasPrefix("/")
        // (POSIX keeps exactly two leading slashes; Python does too)
        let initial = absolute ? (path.hasPrefix("//") && !path.hasPrefix("///") ? 2 : 1) : 0
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !absolute {
                    parts.append(part)
                }
                continue
            }
            parts.append(part)
        }
        let joined = parts.joined(separator: "/")
        let result = String(repeating: "/", count: initial) + joined
        return result.isEmpty ? "." : result
    }
}

/// Python's `str.rstrip(chars)`: the text without any of `chars` at its end.
func stripTrailing<S: Sequence>(_ text: S, _ chars: Set<Unicode.Scalar>) -> String where S.Element == Unicode.Scalar {
    var scalars = Array(text)
    while let last = scalars.last, chars.contains(last) { scalars.removeLast() }
    return String(String.UnicodeScalarView(scalars))
}

/// A text from Unicode characters.
func text<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
    String(String.UnicodeScalarView(scalars))
}

/// Python's `divmod` of two numbers: (the whole times `b` goes into `a`,
/// what is left), worked out the way Python works them out.
func pythonDivmod(_ a: Double, _ b: Double) -> (Double, Double) {
    var mod = fmod(a, b)
    var div = (a - mod) / b
    if mod != 0 {
        if (b < 0) != (mod < 0) {
            mod += b
            div -= 1.0
        }
    } else {
        mod = copysign(0.0, b)
    }
    var floordiv: Double
    if div != 0 {
        floordiv = div.rounded(.down)
        if div - floordiv > 0.5 { floordiv += 1.0 }
    } else {
        floordiv = copysign(0.0, a / b)
    }
    return (floordiv, mod)
}
