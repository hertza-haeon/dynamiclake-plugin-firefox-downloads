// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// DynamicLake closed the connection (it quit, or stopped the plugin): the
/// plugin ends.
public struct LakeClosed: Error {}

/// The link to DynamicLake: JSON messages, each behind its length written
/// on four bytes, the highest first, in both directions. The plugin sleeps
/// waiting on it, so a button press is handled the moment it arrives
/// instead of at the next look.
public final class DynamicLake {
    private let descriptor: Int32
    private var buffer: [UInt8] = []
    /// The card that must stay the one updated last (see "Places")...
    var keepLast = ""
    /// ...and whether another download's card got a message after it.
    var overtaken = false

    public init(path: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LakeClosed() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            throw LakeClosed()
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw LakeClosed()
        }
        self.descriptor = descriptor
        // Writing to a connection DynamicLake has closed must come back as
        // an error, not end the plugin with a signal.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Takes over a socket that is already connected (tests).
    init(descriptor: Int32) {
        self.descriptor = descriptor
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close(descriptor)
    }

    func send(_ payload: JSON) throws {
        let card = payload["activityID"]?.string ?? ""
        if !keepLast.isEmpty && payload["type"]?.string != "dismiss" && !card.hasSuffix(Plugin.statusCardSuffix) {
            overtaken = card != keepLast
        }
        let json = Array(payload.text.utf8)
        var bytes = withUnsafeBytes(of: UInt32(json.count).bigEndian) { Array($0) }
        bytes += json
        // Each piece goes out once, in order, waiting for room while
        // DynamicLake reads: a frame begun is always finished, or every one
        // after it would be unreadable.
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { raw -> Int in
                Darwin.send(descriptor, raw.baseAddress! + sent, bytes.count - sent, 0)
            }
            if wrote < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    var watched = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&watched, 1, 1_000)
                    continue
                }
                throw LakeClosed()
            }
            sent += wrote
        }
    }

    /// Sleeps up to `timeout` seconds, waking early as soon as DynamicLake
    /// sends something (a button press).
    func waitReadable(_ timeout: Double) {
        var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        _ = poll(&watched, 1, Int32(max(0, min(timeout, 3_600)) * 1_000))
    }

    /// The messages that have come, read without waiting.
    func pollIncoming() throws -> [[String: Any]] {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let got = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            if got > 0 {
                buffer += chunk.prefix(got)
            } else if got == 0 {
                throw LakeClosed()
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                throw LakeClosed()
            }
        }
        var messages: [[String: Any]] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 4 + length else { break }
            let frame = Data(buffer[4..<(4 + length)])
            buffer.removeFirst(4 + length)
            if let message = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] {
                messages.append(message)
            }
        }
        return messages
    }
}
