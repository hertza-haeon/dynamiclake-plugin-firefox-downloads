// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

// Firefox locks a profile while it has it open (toolkit/profile/
// nsProfileLock.cpp). On macOS that's an fcntl() write lock on the
// profile's ".parentlock" file -- or, on a disk that can't do those (a
// network volume), ".parentlock" made a symbolic link naming its process
// ("<ip>:+<pid>"), removed when it quits. (On Linux the link is called
// "lock".) The plugin only asks: it never locks anything, and writes
// nothing there.
enum ProfileLock {
    /// What the system says about a write lock on `path`: (held, by which
    /// process), or nothing if it can't be asked.
    static func query(_ path: String) -> (held: Bool, pid: Int32)? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &lock) != -1 else { return nil }
        return (lock.l_type != Int16(F_UNLCK), lock.l_pid)
    }

    /// Whether some process holds a write lock on `path` (nothing if it
    /// can't be asked).
    static func held(_ path: String) -> Bool? {
        query(path)?.held
    }

    /// The process a lock link names ("<ip>:+<pid>"), as written.
    private static func linkedPid(_ link: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = readlink(link, &buffer, buffer.count - 1)
        guard length >= 0 else { return nil }
        let target = String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return target.firstMatch(of: #/:\+?(\d+)$/#).map { String($0.1) }
    }

    /// Whether the process a lock link names is running; nothing when
    /// `link` isn't such a link.
    static func linkAlive(_ link: String) -> Bool? {
        guard let digits = linkedPid(link) else { return nil }
        guard let pid = Int32(digits) else { return nil }
        if kill(pid, 0) == 0 { return true }
        switch errno {
        case ESRCH: return false
        case EPERM: return true
        default: return nil
        }
    }

    /// The browser process that has this profile open: the one its lock
    /// names. Nothing when the profile isn't open, or that can't be told.
    static func profilePid(_ profile: String) -> Int32? {
        let parentlock = Paths.join(profile, ".parentlock")
        if let digits = linkedPid(parentlock) {
            guard let pid = Int32(digits) else { return nil }
            return linkAlive(parentlock) == true ? pid : nil
        }
        guard let answer = query(parentlock), answer.held, answer.pid > 0 else { return nil }
        return answer.pid
    }

    /// Whether a browser has this profile open right now; nothing when that
    /// can't be told.
    static func profileInUse(_ profile: String) -> Bool? {
        let parentlock = Paths.join(profile, ".parentlock")
        if let linked = linkAlive(parentlock) { return linked }
        let held = held(parentlock)
        let other = linkAlive(Paths.join(profile, "lock"))
        if held == true || other == true { return true }
        if held == false || other == false { return false }
        return nil
    }

    /// Whether process `pid` has this file open right now; nothing when
    /// that can't be told (the file is gone, or the process is). Asked of
    /// macOS (the list of the process's open files): nothing is opened,
    /// locked or changed.
    static func processHasOpen(_ pid: Int32, _ path: String) -> Bool? {
        var file = stat()
        guard stat(path, &file) == 0 else { return nil }
        let room = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard room > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // (and some, for files opened meanwhile)
        var table = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(room) / stride + 64)
        let got = table.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return nil }
        let size = Int32(MemoryLayout<vnode_fdinfo>.size)
        for entry in table.prefix(Int(got) / stride) where entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfo()
            guard proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEINFO, &info, size) == size else { continue }
            let status = info.pvi.vi_stat
            if status.vst_ino == file.st_ino && status.vst_dev == UInt32(truncatingIfNeeded: file.st_dev) {
                return true
            }
        }
        return false
    }
}

/// Is the browser a download belongs to still open? Asked only about
/// downloads that stopped receiving data; each answer is kept a second.
final class BrowserPresence {
    private var cache: [String: (at: Double, answer: Bool?)] = [:]
    private var pids: [String: (at: Double, pid: Int32?)] = [:]
    private let mac: MacAnswers

    init(mac: MacAnswers) {
        self.mac = mac
    }

    /// The browser process that has this profile open, or nothing.
    func pid(of profile: String, now: Double) -> Int32? {
        if let hit = pids[profile], now - hit.at < 1.0 { return hit.pid }
        let pid = mac.profilePid(profile)
        pids[profile] = (now, pid)
        return pid
    }

    func profileOpen(_ profile: String, now: Double) -> Bool? {
        if let hit = cache[profile], now - hit.at < 1.0 { return hit.answer }
        let answer = mac.profileInUse(profile)
        cache[profile] = (now, answer)
        return answer
    }

    /// An answer just asked for (not from the cache): kept like any other.
    func note(_ profile: String, now: Double, inUse: Bool?) {
        cache[profile] = (now, inUse)
        if inUse != true {
            pids.removeValue(forKey: profile)
        }
    }

    /// Closed when its profile (the one whose downloads.json lists it)
    /// isn't open. A download no downloads.json lists (a private window's,
    /// or a browser whose profile the plugin doesn't know) is never taken
    /// for closed: which browser it belongs to can't be told.
    func closed(for profile: String?, now: Double) -> Bool {
        guard let profile else { return false }
        return profileOpen(profile, now: now) == false
    }
}
