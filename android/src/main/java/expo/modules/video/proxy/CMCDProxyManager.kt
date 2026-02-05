package expo.modules.video.proxy

import android.util.Log
import expo.modules.video.player.VideoPlayer
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Singleton manager for the CMCD proxy server.
 * Provides high-level interface for starting/stopping the proxy and creating proxy URLs.
 *
 * Usage:
 * ```kotlin
 * // Start proxy
 * CMCDProxyManager.start()
 *
 * // Set CMCD headers provider (called for each request)
 * CMCDProxyManager.setCmcdHeadersProvider { player.dynamicRequestHeaders }
 *
 * // Get proxy URL for a video
 * val proxyUrl = CMCDProxyManager.createProxyUrl(originalVideoUrl)
 *
 * // Stop proxy
 * CMCDProxyManager.stop()
 * ```
 */
object CMCDProxyManager {

  private const val TAG = "CMCDProxyManager"

  private var proxy: CMCDProxy? = null

  /**
   * Returns true if the proxy is currently running.
   */
  val isRunning: Boolean
    get() = proxy?.isRunning ?: false

  /**
   * Returns the current proxy port, or 0 if not running.
   */
  val port: Int
    get() = proxy?.port ?: 0

  /**
   * Returns the base URL for the proxy (e.g., "http://127.0.0.1:8080").
   */
  val baseUrl: String?
    get() {
      val p = proxy
      return if (p != null && p.isRunning) {
        "http://127.0.0.1:${p.port}"
      } else {
        null
      }
    }

  // MARK: - Proxy Control

  /**
   * Starts the proxy server.
   * @throws Exception if the proxy fails to start
   */
  @Throws(Exception::class)
  @Synchronized
  fun start() {
    if (proxy != null && isRunning) {
      Log.i(TAG, "Proxy already running on port $port")
      return
    }

    val newProxy = CMCDProxy()
    newProxy.start()
    proxy = newProxy

    Log.i(TAG, "Proxy started on port ${newProxy.port}")
  }

  /**
   * Stops the proxy server.
   */
  @Synchronized
  fun stop() {
    proxy?.stop()
    proxy = null
    Log.i(TAG, "Proxy stopped")
  }

  // MARK: - Configuration

  /**
   * Sets the provider function that returns current CMCD headers.
   * This function is called for each proxied request.
   * @param provider Function returning current CMCD headers map
   */
  fun setCmcdHeadersProvider(provider: () -> Map<String, String>) {
    proxy?.setCmcdHeadersProvider(provider)
  }

  /**
   * Sets static headers to add to all requests (e.g., authorization tokens).
   * @param headers Map of static headers
   */
  fun setStaticHeaders(headers: Map<String, String>) {
    proxy?.setStaticHeaders(headers)
  }

  // MARK: - URL Creation

  /**
   * Creates a proxy URL for the given video URL.
   * The returned URL routes through the local proxy which adds CMCD headers.
   *
   * @param url Original video URL
   * @return Proxy URL, or null if proxy is not running
   */
  fun createProxyUrl(url: String): String? {
    val base = baseUrl ?: return null

    val encoded = try {
      URLEncoder.encode(url, "UTF-8")
    } catch (e: Exception) {
      Log.e(TAG, "Failed to encode URL", e)
      return null
    }

    return "$base/proxy?url=$encoded"
  }

  /**
   * Creates a proxy URL for the given URI.
   *
   * @param uri Original video URI
   * @return Proxy URL string, or null if proxy is not running
   */
  fun createProxyUrl(uri: URI): String? {
    return createProxyUrl(uri.toString())
  }

  /**
   * Extracts the original URL from a proxy URL.
   *
   * @param proxyUrl Proxy URL string
   * @return Original URL, or null if not a valid proxy URL
   */
  fun extractOriginalUrl(proxyUrl: String): String? {
    return try {
      val uri = URI(proxyUrl)
      val query = uri.query ?: return null

      val params = query.split("&")
      for (param in params) {
        val keyValue = param.split("=", limit = 2)
        if (keyValue.size == 2 && keyValue[0] == "url") {
          return URLDecoder.decode(keyValue[1], "UTF-8")
        }
      }
      null
    } catch (e: Exception) {
      null
    }
  }

  // MARK: - VideoPlayer Integration

  /**
   * Configures the proxy for use with a VideoPlayer.
   * Sets up the headers provider to read from player's dynamicRequestHeaders.
   *
   * @param player VideoPlayer instance to get headers from
   */
  fun configureForPlayer(player: VideoPlayer) {
    setCmcdHeadersProvider { player.dynamicRequestHeaders }
  }

  /**
   * Creates a proxy URL for a video source, ready for CMCD injection.
   * Also configures the headers provider for the given player.
   *
   * @param originalUrl Original video URL
   * @param player VideoPlayer to associate for CMCD headers
   * @return Proxy URL, or original URL if proxy not available
   */
  fun createProxiedUrl(originalUrl: String, player: VideoPlayer): String {
    if (!isRunning) {
      Log.w(TAG, "Proxy not running, returning original URL")
      return originalUrl
    }

    configureForPlayer(player)

    val proxyUrl = createProxyUrl(originalUrl)
    if (proxyUrl != null) {
      Log.i(TAG, "Created proxied URL for: ${originalUrl.substringAfterLast('/')}")
      return proxyUrl
    }

    return originalUrl
  }
}
