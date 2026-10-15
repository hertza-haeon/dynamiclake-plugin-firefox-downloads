// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing
@testable import FirefoxDownloadsKit

/// Stop without any permission, with a download announced the way Firefox
/// announces one (nsMacFinderProgress.mm) by a program standing in for the
/// browser.
struct BrowserProgressTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set = false
        func raise() { lock.withLock { set = true } }
        var isRaised: Bool { lock.withLock { set } }
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    @Test func aDownloadAnnouncedForItsFileIsCanceledAndNoOtherIs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fd-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("movie.mp4"), other = folder.appendingPathComponent("other.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let progress = BrowserProgress()
        progress.watch([folder.path])
        let canceled = Flag()
        let announced = Progress(parent: nil, userInfo: [.fileURLKey: file,
                                                         .fileOperationKindKey: Progress.FileOperationKind.downloading])
        announced.kind = .file
        announced.isCancellable = true
        announced.cancellationHandler = { canceled.raise() }
        announced.totalUnitCount = 100
        announced.publish()
        defer { announced.unpublish() }

        try #require(waitUntil(5) { progress.count == 1 }, "the announcement never arrived")
        #expect(progress.cancel([other.path]) == false)                  // another file: nothing
        #expect(!canceled.isRaised)
        #expect(progress.cancel([folder.path + "/./movie.mp4"]) == true)  // its own file, however written
        #expect(waitUntil(5) { canceled.isRaised })
    }

    @Test func twoAnnouncementsForOneFileOneThatCantBeCanceledOrACopyCancelNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fd-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let twice = folder.appendingPathComponent("twice.zip"), fixed = folder.appendingPathComponent("fixed.zip")
        let copied = folder.appendingPathComponent("copied.zip")
        let progress = BrowserProgress()
        progress.watch([folder.path])
        let canceled = Flag()
        var published: [Progress] = []
        for (file, cancellable, operation) in [(twice, true, Progress.FileOperationKind.downloading),
                                               (twice, true, .downloading), (fixed, false, .downloading), (copied, true, .copying)] {
            let announced = Progress(parent: nil, userInfo: [.fileURLKey: file, .fileOperationKindKey: operation])
            announced.kind = .file
            announced.isCancellable = cancellable
            announced.cancellationHandler = { canceled.raise() }
            announced.publish()
            published.append(announced)
        }
        defer { published.forEach { $0.unpublish() } }
        try #require(waitUntil(5) { progress.count == 4 }, "the announcements never arrived")
        #expect(progress.cancel([twice.path]) == false)
        #expect(progress.cancel([fixed.path]) == false)
        #expect(progress.cancel([copied.path]) == false)              // a copy, not a download
        #expect(!waitUntil(0.5) { canceled.isRaised })
    }
}
