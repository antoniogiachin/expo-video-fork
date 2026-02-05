package expo.modules.video.proxy

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * A lightweight local HTTP proxy server for injecting CMCD headers into video requests.
 * This proxy intercepts requests, adds dynamic CMCD headers, and forwards them to the CDN.
 *
 * Architecture:
 * ```
 * ExoPlayer → localhost:PORT/proxy?url=ENCODED_URL → CMCDProxy → CDN
 *                                                       ↓
 *                                                + CMCD Headers
 * ```
 */
class CMCDProxy {

  companion object {
    private const val TAG = "CMCDProxy"
    private const val BUFFER_SIZE = 8192
  }

  // MARK: - Properties

  private var serverSocket: ServerSocket? = null
  private var executor: ExecutorService? = null
  private val running = AtomicBoolean(false)
  private val httpClient = OkHttpClient.Builder()
    .connectTimeout(30, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .writeTimeout(30, TimeUnit.SECONDS)
    .build()

  var port: Int = 0
    private set

  val isRunning: Boolean
    get() = running.get()

  /** Provider for dynamic CMCD headers - called for each request */
  private val cmcdHeadersProvider = AtomicReference<(() -> Map<String, String>)?>(null)

  /** Static headers to add to all requests */
  private val staticHeaders = AtomicReference<Map<String, String>>(emptyMap())

  // MARK: - Lifecycle

  /**
   * Starts the proxy server on an available port.
   * @throws Exception if the server fails to start
   */
  @Throws(Exception::class)
  fun start() {
    if (running.get()) {
      Log.i(TAG, "Proxy already running on port $port")
      return
    }

    // Find available port
    serverSocket = ServerSocket(0).apply {
      reuseAddress = true
    }
    port = serverSocket!!.localPort

    executor = Executors.newCachedThreadPool()
    running.set(true)

    // Start accepting connections
    executor?.submit {
      acceptConnections()
    }

    Log.i(TAG, "Started on port $port")
  }

  /**
   * Stops the proxy server.
   */
  fun stop() {
    running.set(false)

    try {
      serverSocket?.close()
    } catch (e: Exception) {
      Log.e(TAG, "Error closing server socket", e)
    }

    executor?.shutdown()
    try {
      executor?.awaitTermination(5, TimeUnit.SECONDS)
    } catch (e: InterruptedException) {
      executor?.shutdownNow()
    }

    serverSocket = null
    executor = null
    port = 0

    Log.i(TAG, "Stopped")
  }

  /**
   * Sets the CMCD headers provider closure.
   */
  fun setCmcdHeadersProvider(provider: () -> Map<String, String>) {
    cmcdHeadersProvider.set(provider)
  }

  /**
   * Sets static headers to add to all requests.
   */
  fun setStaticHeaders(headers: Map<String, String>) {
    staticHeaders.set(headers)
  }

  // MARK: - Connection Handling

  private fun acceptConnections() {
    while (running.get()) {
      try {
        val socket = serverSocket?.accept() ?: break
        executor?.submit { handleConnection(socket) }
      } catch (e: Exception) {
        if (running.get()) {
          Log.e(TAG, "Error accepting connection", e)
        }
      }
    }
  }

  private fun handleConnection(socket: Socket) {
    try {
      socket.soTimeout = 30000

      val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
      val output = socket.getOutputStream()

      // Read request line
      val requestLine = reader.readLine() ?: return
      val parts = requestLine.split(" ")
      if (parts.size < 2) {
        sendError(output, 400, "Bad Request")
        return
      }

      val method = parts[0]
      val path = parts[1]

      // Read headers
      val requestHeaders = mutableMapOf<String, String>()
      var line = reader.readLine()
      while (!line.isNullOrEmpty()) {
        val colonIndex = line.indexOf(':')
        if (colonIndex > 0) {
          val key = line.substring(0, colonIndex).trim()
          val value = line.substring(colonIndex + 1).trim()
          requestHeaders[key] = value
        }
        line = reader.readLine()
      }

      // Extract target URL
      val targetUrl = extractTargetUrl(path)
      if (targetUrl == null) {
        sendError(output, 400, "Missing target URL")
        return
      }

      // Proxy the request
      proxyRequest(method, targetUrl, requestHeaders, output)

    } catch (e: Exception) {
      Log.e(TAG, "Error handling connection", e)
    } finally {
      try {
        socket.close()
      } catch (e: Exception) {
        // Ignore
      }
    }
  }

  private fun extractTargetUrl(path: String): String? {
    // Format: /proxy?url=ENCODED_URL
    val uri = try {
      URI(path)
    } catch (e: Exception) {
      return null
    }

    val query = uri.query ?: return null
    val params = query.split("&")

    for (param in params) {
      val keyValue = param.split("=", limit = 2)
      if (keyValue.size == 2 && keyValue[0] == "url") {
        return try {
          URLDecoder.decode(keyValue[1], "UTF-8")
        } catch (e: Exception) {
          null
        }
      }
    }

    return null
  }

  // MARK: - Request Proxying

  private fun proxyRequest(
    method: String,
    targetUrl: String,
    originalHeaders: Map<String, String>,
    output: OutputStream
  ) {
    try {
      val requestBuilder = Request.Builder()
        .url(targetUrl)
        .method(method, null)

      // Copy relevant headers
      val headersToCopy = listOf("Range", "Accept", "Accept-Encoding", "Accept-Language")
      for (header in headersToCopy) {
        originalHeaders[header]?.let { requestBuilder.addHeader(header, it) }
      }

      // Add static headers
      for ((key, value) in staticHeaders.get()) {
        requestBuilder.addHeader(key, value)
      }

      // Add dynamic CMCD headers
      cmcdHeadersProvider.get()?.invoke()?.let { cmcdHeaders ->
        for ((key, value) in cmcdHeaders) {
          requestBuilder.addHeader(key, value)
        }
        Log.d(TAG, "Added CMCD headers to request: ${targetUrl.substringAfterLast('/')}")
      }

      val response = httpClient.newCall(requestBuilder.build()).execute()

      // Check if this is an HLS manifest that needs rewriting
      val contentType = response.header("Content-Type")?.lowercase() ?: ""
      var body = response.body?.bytes() ?: ByteArray(0)

      if (contentType.contains("mpegurl") || contentType.contains("x-mpegurl")) {
        body = rewriteManifest(body, targetUrl)
      }

      // Send response
      sendResponse(
        output = output,
        statusCode = response.code,
        statusMessage = response.message,
        headers = response.headers.toMap(),
        body = body
      )

      response.close()

    } catch (e: Exception) {
      Log.e(TAG, "Error proxying request", e)
      sendError(output, 502, "Bad Gateway")
    }
  }

  // MARK: - Response Handling

  private fun sendResponse(
    output: OutputStream,
    statusCode: Int,
    statusMessage: String,
    headers: Map<String, String>,
    body: ByteArray
  ) {
    val sb = StringBuilder()
    sb.append("HTTP/1.1 $statusCode $statusMessage\r\n")
    sb.append("Content-Length: ${body.size}\r\n")
    sb.append("Connection: close\r\n")

    // Include relevant headers
    val headersToInclude = listOf("Content-Type", "Cache-Control", "Accept-Ranges", "Content-Range")
    for (header in headersToInclude) {
      headers[header]?.let { sb.append("$header: $it\r\n") }
    }

    sb.append("Access-Control-Allow-Origin: *\r\n")
    sb.append("\r\n")

    output.write(sb.toString().toByteArray(Charsets.UTF_8))
    output.write(body)
    output.flush()
  }

  private fun sendError(output: OutputStream, statusCode: Int, message: String) {
    val body = message.toByteArray(Charsets.UTF_8)
    val response = """
      HTTP/1.1 $statusCode $message
      Content-Type: text/plain
      Content-Length: ${body.size}
      Connection: close

      $message
    """.trimIndent()

    output.write(response.toByteArray(Charsets.UTF_8))
    output.flush()
  }

  // MARK: - Manifest Rewriting

  private fun rewriteManifest(data: ByteArray, baseUrlString: String): ByteArray {
    val manifest = String(data, Charsets.UTF_8)
    val baseUrl = try {
      URI(baseUrlString)
    } catch (e: Exception) {
      return data
    }

    val proxyBase = "http://127.0.0.1:$port/proxy?url="
    val lines = manifest.split("\n")
    val rewrittenLines = mutableListOf<String>()

    for (line in lines) {
      val trimmed = line.trim()

      when {
        trimmed.isEmpty() -> rewrittenLines.add(line)

        trimmed.startsWith("#") && trimmed.contains("URI=\"") -> {
          rewrittenLines.add(rewriteUriAttributes(line, baseUrl, proxyBase))
        }

        trimmed.startsWith("#") -> rewrittenLines.add(line)

        else -> {
          val proxyUrl = createProxyUrl(trimmed, baseUrl, proxyBase)
          rewrittenLines.add(proxyUrl ?: line)
        }
      }
    }

    Log.d(TAG, "Rewrote HLS manifest URLs (${lines.size} lines)")
    return rewrittenLines.joinToString("\n").toByteArray(Charsets.UTF_8)
  }

  private fun rewriteUriAttributes(line: String, baseUrl: URI, proxyBase: String): String {
    val pattern = Regex("URI=\"([^\"]+)\"")
    return pattern.replace(line) { match ->
      val uri = match.groupValues[1]
      val proxyUrl = createProxyUrl(uri, baseUrl, proxyBase)
      "URI=\"${proxyUrl ?: uri}\""
    }
  }

  private fun createProxyUrl(urlString: String, baseUrl: URI, proxyBase: String): String? {
    val trimmed = urlString.trim()

    val absoluteUrl = try {
      if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
        trimmed
      } else {
        baseUrl.resolve(trimmed).toString()
      }
    } catch (e: Exception) {
      return null
    }

    val encoded = try {
      URLEncoder.encode(absoluteUrl, "UTF-8")
    } catch (e: Exception) {
      return null
    }

    return proxyBase + encoded
  }
}

// Extension to convert OkHttp Headers to Map
private fun okhttp3.Headers.toMap(): Map<String, String> {
  val map = mutableMapOf<String, String>()
  for (i in 0 until size) {
    map[name(i)] = value(i)
  }
  return map
}
