package expo.modules.video.proxy

import expo.modules.video.player.VideoPlayer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference

/**
 * Singleton manager that coordinates the CMCD proxy with VideoPlayers.
 */
object CMCDProxyManager {
  private var currentPlayer: WeakReference<VideoPlayer>? = null

  val isRunning: Boolean
    get() = CMCDProxy.shared.port > 0

  val port: Int
    get() = CMCDProxy.shared.port

  /**
   * Starts the proxy and waits until it's ready to accept connections.
   * @return true if the proxy started successfully
   */
  suspend fun start(): Boolean = withContext(Dispatchers.IO) {
    CMCDProxy.shared.startBlocking()
  }

  /**
   * Starts the proxy synchronously with a timeout.
   * @param timeoutMs Maximum time to wait for the server to be ready
   * @return true if the server started successfully
   */
  fun startBlocking(timeoutMs: Long = 5000): Boolean {
    return CMCDProxy.shared.startBlocking(timeoutMs)
  }

  /**
   * Stops the proxy server.
   */
  fun stop() {
    CMCDProxy.shared.stop()
  }

  /**
   * Configures the proxy to use headers from the specified player.
   */
  fun configureForPlayer(player: VideoPlayer) {
    currentPlayer = WeakReference(player)
    CMCDProxy.shared.dynamicHeadersProvider = WeakReference {
      currentPlayer?.get()?.dynamicRequestHeaders ?: emptyMap()
    }
  }

  /**
   * Sets static headers that will be added to all proxied requests.
   */
  fun setStaticHeaders(headers: Map<String, String>) {
    CMCDProxy.shared.staticHeaders = headers
  }

  /**
   * Creates a proxy URL for the given original URL.
   */
  fun createProxyUrl(originalUrl: String): String? {
    return CMCDProxy.shared.createProxyUrl(originalUrl)
  }
}
