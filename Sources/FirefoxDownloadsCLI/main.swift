// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import FirefoxDownloadsKit

// Firefox Downloads: what DynamicLake starts. It shows the downloads of
// Firefox and the browsers built on it in the notch.
//
//   firefox-downloads                       run as DynamicLake's plugin
//   firefox-downloads --log-folder NAME     with its log in ~/Library/Logs/NAME

let arguments = Array(CommandLine.arguments.dropFirst())
var logFolder = PluginLog.defaultFolder
if let index = arguments.firstIndex(of: "--log-folder"), index + 1 < arguments.count {
    logFolder = arguments[index + 1]
}

let environment = ProcessInfo.processInfo.environment
guard let socketPath = environment["DYNAMICLAKE_JSON_SOCKET"], !socketPath.isEmpty else {
    FileHandle.standardError.write(Data("DYNAMICLAKE_JSON_SOCKET is missing -- launch this from DynamicLake.\n".utf8))
    exit(1)
}

let shared = Shared(log: .inLibrary(folder: logFolder))
TestHooks.apply(to: shared)
guard let lake = try? DynamicLake(path: socketPath) else {
    FileHandle.standardError.write(Data("Firefox Downloads exiting: DynamicLake's socket can't be reached\n".utf8))
    exit(0)
}
let plugin = Plugin(shared: shared, lake: lake, features: Plugin.features(environment))
let runner = ScriptRunner(log: shared.log, timeout: { [shared] in shared.t.stopScriptTimeout })
let desk = Desk()
plugin.buttons = ButtonWork(requests: .real(runner: runner, desk: desk), desk: desk, progress: BrowserProgress())
plugin.precompile = { runner.startPrecompile() }
TestHooks.apply(to: plugin)

// The plugin's loop runs on a thread of its own. The main thread is left
// to its run loop, where macOS delivers the downloads' announcements that
// Stop cancels without any permission (see BrowserProgress).
final class Running: @unchecked Sendable {
    let plugin: Plugin
    init(_ plugin: Plugin) { self.plugin = plugin }
}
let running = Running(plugin)
Thread.detachNewThread {
    running.plugin.run()             // (until DynamicLake closes the connection)
    exit(0)
}
RunLoop.main.run()
