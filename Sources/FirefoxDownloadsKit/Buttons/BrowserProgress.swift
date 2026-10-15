// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Stop without any permission. Firefox announces each download to macOS
/// as a cancellable file progress, the way the Finder knows a file is being
/// copied and draws its bar (browser/components/downloads/
/// DownloadsMacFinderProgress.sys.mjs, widget/cocoa/nsMacFinderProgress.mm):
/// for the final file's path, from the moment the download starts to the
/// moment it stops. Cancelling that announcement makes Firefox cancel the
/// download and remove its partial data, as its own Cancel does: the browser
/// isn't brought forward, its Downloads panel isn't opened, and nothing is
/// pressed. A download is cancelled this way only when exactly one
/// announcement names its file; otherwise the button script does it.
///
/// The announcements arrive on the main thread's run loop: the plugin's own
/// loop runs on a thread of its own (see the program's `main`).
public final class BrowserProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var announced: [Progress] = []
    /// The folders followed, and macOS's token for each (main thread only).
    private var subscriptions: [String: Any] = [:]

    public init() {}

    /// Follow the announcements for files in these folders (and no other).
    func watch(_ folders: [String]) {
        DispatchQueue.main.async { [self] in
            for (folder, token) in subscriptions where !folders.contains(folder) {
                Progress.removeSubscriber(token)
                subscriptions.removeValue(forKey: folder)
                // (and what was announced there: it would never be withdrawn)
                let gone = Self.key(folder)
                lock.withLock {
                    announced.removeAll { progress in Self.file(of: progress).map { Paths.parent($0) == gone } ?? true }
                }
            }
            for folder in folders where subscriptions[folder] == nil {
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                subscriptions[folder] = Progress.addSubscriber(forFileURL: url) { [self] progress in
                    add(progress)
                    return { [self] in remove(progress) }
                }
            }
        }
    }

    private func add(_ progress: Progress) {
        lock.withLock { announced.append(progress) }
    }

    private func remove(_ progress: Progress) {
        lock.withLock { announced.removeAll { $0 === progress } }
    }

    /// The file an announcement is for. (Its details carry it from the
    /// first moment; the `fileURL` property is only filled a moment later.)
    static func file(of progress: Progress) -> String? {
        let url = progress.userInfo[.fileURLKey] as? URL ?? progress.fileURL
        return url.map { key($0.path) }
    }

    private static func key(_ path: String) -> String {
        Paths.normalized(path).precomposedStringWithCanonicalMapping
    }

    /// Whether an announcement says it's a download (Firefox's do: another
    /// app's copy of a file is never taken for one).
    static func isDownload(_ progress: Progress) -> Bool {
        let kind = progress.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind ?? progress.fileOperationKind
        return kind == .downloading
    }

    /// Cancels the download announced for one of these paths (the final
    /// file's, as the card knows it): true when exactly one cancellable
    /// download announcement names it, and it was cancelled.
    func cancel(_ paths: [String]) -> Bool {
        let wanted = Set(paths.map(Self.key))
        let matching = lock.withLock {
            announced.filter { progress in
                guard let file = Self.file(of: progress) else { return false }
                return wanted.contains(file) && Self.isDownload(progress) && progress.isCancellable && !progress.isCancelled
            }
        }
        guard matching.count == 1 else { return false }
        matching[0].cancel()
        return true
    }

    /// How many announcements are followed now (for the log and tests).
    var count: Int { lock.withLock { announced.count } }
}
