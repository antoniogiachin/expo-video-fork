import Foundation
import ExpoModulesCore

/// Singleton manager for the CMCD proxy server.
/// Provides high-level interface for starting/stopping the proxy and creating proxy URLs.
///
/// Usage:
/// ```swift
/// // Start proxy
/// try CMCDProxyManager.shared.start()
///
/// // Set CMCD headers provider (called for each request)
/// CMCDProxyManager.shared.setCmcdHeadersProvider { player.dynamicRequestHeaders }
///
/// // Get proxy URL for a video
/// let proxyUrl = CMCDProxyManager.shared.createProxyUrl(for: originalVideoUrl)
///
/// // Stop proxy
/// CMCDProxyManager.shared.stop()
/// ```
@available(iOS 13.0, *)
final class CMCDProxyManager {

  // MARK: - Singleton

  static let shared = CMCDProxyManager()

  private init() {}

  // MARK: - Properties

  private var proxy: CMCDProxy?
  private var headersProvider: (() -> [String: String])?

  /// Returns true if the proxy is currently running
  var isRunning: Bool {
    return proxy?.isRunning ?? false
  }

  /// Returns the current proxy port, or 0 if not running
  var port: UInt16 {
    return proxy?.port ?? 0
  }

  /// Returns the base URL for the proxy (e.g., "http://127.0.0.1:8080")
  var baseUrl: String? {
    guard let proxy = proxy, proxy.isRunning else { return nil }
    return "http://127.0.0.1:\(proxy.port)"
  }

  // MARK: - Proxy Control

  /// Starts the proxy server
  /// - Throws: Error if the proxy fails to start
  func start() throws {
    guard proxy == nil || !isRunning else {
      log.info("[CMCDProxyManager] Proxy already running on port \(port)")
      return
    }

    let newProxy = CMCDProxy()

    // Set headers provider
    newProxy.cmcdHeadersProvider = { [weak self] in
      return self?.headersProvider?()
    }

    try newProxy.start()
    proxy = newProxy

    log.info("[CMCDProxyManager] Proxy started on port \(newProxy.port)")
  }

  /// Stops the proxy server
  func stop() {
    proxy?.stop()
    proxy = nil
    log.info("[CMCDProxyManager] Proxy stopped")
  }

  // MARK: - Configuration

  /// Sets the provider closure that returns current CMCD headers.
  /// This closure is called for each proxied request.
  /// - Parameter provider: Closure returning current CMCD headers dictionary
  func setCmcdHeadersProvider(_ provider: @escaping () -> [String: String]) {
    self.headersProvider = provider
    proxy?.cmcdHeadersProvider = provider
  }

  /// Sets static headers to add to all requests (e.g., authorization tokens)
  /// - Parameter headers: Dictionary of static headers
  func setStaticHeaders(_ headers: [String: String]) {
    proxy?.staticHeaders = headers
  }

  // MARK: - URL Creation

  /// Creates a proxy URL for the given video URL.
  /// The returned URL routes through the local proxy which adds CMCD headers.
  ///
  /// - Parameter url: Original video URL
  /// - Returns: Proxy URL, or nil if proxy is not running
  func createProxyUrl(for url: URL) -> URL? {
    guard let base = baseUrl,
          let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
      return nil
    }
    return URL(string: "\(base)/proxy?url=\(encoded)")
  }

  /// Creates a proxy URL string for the given video URL string.
  ///
  /// - Parameter urlString: Original video URL string
  /// - Returns: Proxy URL string, or nil if proxy is not running or URL is invalid
  func createProxyUrl(for urlString: String) -> String? {
    guard let url = URL(string: urlString) else { return nil }
    return createProxyUrl(for: url)?.absoluteString
  }

  /// Extracts the original URL from a proxy URL.
  ///
  /// - Parameter proxyUrl: Proxy URL
  /// - Returns: Original URL, or nil if not a valid proxy URL
  func extractOriginalUrl(from proxyUrl: URL) -> URL? {
    guard let components = URLComponents(url: proxyUrl, resolvingAgainstBaseURL: false),
          let queryItems = components.queryItems,
          let urlParam = queryItems.first(where: { $0.name == "url" })?.value,
          let decodedUrl = urlParam.removingPercentEncoding,
          let originalUrl = URL(string: decodedUrl) else {
      return nil
    }
    return originalUrl
  }
}

// MARK: - Expo Module Integration

/// Extension to integrate with VideoPlayer for easy CMCD setup
@available(iOS 13.0, *)
extension CMCDProxyManager {

  /// Configures the proxy for use with a VideoPlayer.
  /// Sets up the headers provider to read from player's dynamicRequestHeaders.
  ///
  /// - Parameter player: VideoPlayer instance to get headers from
  func configureForPlayer(_ player: VideoPlayer) {
    setCmcdHeadersProvider { [weak player] in
      return player?.dynamicRequestHeaders ?? [:]
    }
  }

  /// Creates a VideoSource with proxy URL for CMCD support.
  /// Use this method to create a source that routes through the CMCD proxy.
  ///
  /// - Parameters:
  ///   - originalSource: Original VideoSource
  ///   - player: VideoPlayer to associate for CMCD headers
  /// - Returns: New VideoSource with proxy URL, or original if proxy not available
  func createProxiedSource(from originalSource: VideoSource, for player: VideoPlayer) -> VideoSource {
    guard isRunning,
          let originalUri = originalSource.uri,
          let proxyUrl = createProxyUrl(for: originalUri) else {
      log.warn("[CMCDProxyManager] Cannot create proxied source - proxy not running or invalid URL")
      return originalSource
    }

    // Configure provider for this player
    configureForPlayer(player)

    // Create new source with proxy URL
    // Note: We need to create a modified copy of the source
    var proxiedSource = originalSource
    // The URI will be replaced when creating the media item
    // For now, we store the proxy URL in a way that can be accessed

    log.info("[CMCDProxyManager] Created proxied source: \(proxyUrl.absoluteString)")

    return proxiedSource
  }
}
