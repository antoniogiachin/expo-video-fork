// Copyright 2024-present 650 Industries. All rights reserved.

import Foundation

/// Singleton manager that coordinates the CMCD proxy with VideoPlayers.
internal final class CMCDProxyManager {
  static let shared = CMCDProxyManager()

  private weak var currentPlayer: VideoPlayer?
  private let lock = NSLock()

  var isRunning: Bool {
    return CMCDProxy.shared.port > 0
  }

  var port: UInt16 {
    return CMCDProxy.shared.port
  }

  private init() {}

  /// Starts the proxy and waits until it's ready to accept connections.
  func startAndWait() async throws {
    try await CMCDProxy.shared.start()
  }

  /// Stops the proxy server.
  func stop() {
    CMCDProxy.shared.stop()
  }

  /// Configures the proxy to use headers from the specified player.
  func configureForPlayer(_ player: VideoPlayer) {
    lock.lock()
    currentPlayer = player
    lock.unlock()

    CMCDProxy.shared.dynamicHeadersProvider = { [weak player] in
      return player?.dynamicRequestHeaders ?? [:]
    }
  }

  /// Sets static headers that will be added to all proxied requests.
  func setStaticHeaders(_ headers: [String: String]) {
    CMCDProxy.shared.staticHeaders = headers
  }

  /// Creates a proxy URL for the given original URL.
  func createProxyUrl(for originalUrl: URL) -> URL? {
    return CMCDProxy.shared.createProxyUrl(for: originalUrl)
  }
}
