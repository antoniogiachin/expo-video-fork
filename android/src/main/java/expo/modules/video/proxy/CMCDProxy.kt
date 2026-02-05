package expo.modules.video.proxy

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.lang.ref.WeakReference

/**
 * Local HTTP proxy server for injecting dynamic headers into video segment requests.
 * Uses ServerSocket for TCP handling and OkHttp for upstream requests.
 */
internal class CMCDProxy {
  private var serverSocket: ServerSocket? = null
  private var executor: ExecutorService? = null
  private val _port = AtomicInteger(0)
  private val isRunning = AtomicBoolean(false)
  private val readyLatch = CountDownLatch(1)

  private val httpClient = OkHttpClient.Builder()
    .followRedirects(true)
    .connectTimeout(30, TimeUnit.SECONDS)
    .readTimeout(30, TimeUnit.SECONDS)
    .build()

  /**
   * Provider for dynamic headers - typically set by the VideoPlayer
   */
  var dynamicHeadersProvider: WeakReference<(() -> Map<String, String>)>? = null

  /**
   * Static headers that are always added to proxied requests
   */
  private val _staticHeaders = AtomicReference<Map<String, String>>(emptyMap())
  var staticHeaders: Map<String, String>
    get() = _staticHeaders.get()
    set(value) = _staticHeaders.set(value)

  val port: Int get() = _port.get()

  val isReady: Boolean get() = _port.get() > 0

  /**
   * Starts the proxy server in a blocking manner with a timeout.
   * @param timeoutMs Maximum time to wait for the server to be ready
   * @return true if the server started successfully
   */
  fun startBlocking(timeoutMs: Long = 5000): Boolean {
    if (_port.get() > 0 && isRunning.get()) {
      return true
    }

    executor = Executors.newCachedThreadPool()
    executor?.submit {
      try {
        serverSocket = ServerSocket(0).also {
          _port.set(it.localPort)
          isRunning.set(true)
          readyLatch.countDown()
        }
        acceptConnections()
      } catch (e: Exception) {
        println("[CMCDProxy] Failed to start server: ${e.message}")
        readyLatch.countDown()
      }
    }

    return readyLatch.await(timeoutMs, TimeUnit.MILLISECONDS) && _port.get() > 0
  }

  /**
   * Stops the proxy server and closes all connections.
   */
  fun stop() {
    isRunning.set(false)
    try {
      serverSocket?.close()
    } catch (e: Exception) {
      // Ignore
    }
    executor?.shutdownNow()
    serverSocket = null
    executor = null
    _port.set(0)
  }

  /**
   * Creates a proxy URL for the given original URL.
   */
  fun createProxyUrl(originalUrl: String): String? {
    val currentPort = _port.get()
    if (currentPort == 0) return null
    val encoded = URLEncoder.encode(originalUrl, "UTF-8")
    return "http://127.0.0.1:$currentPort/proxy?url=$encoded"
  }

  private fun acceptConnections() {
    while (isRunning.get() && serverSocket?.isClosed == false) {
      try {
        val client = serverSocket?.accept() ?: break
        executor?.submit { handleClient(client) }
      } catch (e: Exception) {
        if (isRunning.get()) {
          println("[CMCDProxy] Accept error: ${e.message}")
        }
      }
    }
  }

  private fun handleClient(client: Socket) {
    try {
      client.use { socket ->
        val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
        val writer = PrintWriter(socket.getOutputStream(), true)

        // Read HTTP request line
        val requestLine = reader.readLine() ?: return
        val parts = requestLine.split(" ")
        if (parts.size < 2) {
          sendErrorResponse(writer, socket, 400, "Bad Request")
          return
        }

        val method = parts[0]
        val path = parts[1]

        // Read headers (we need to consume them to complete the request)
        while (true) {
          val line = reader.readLine()
          if (line.isNullOrEmpty()) break
        }

        // Only handle GET requests
        if (method != "GET") {
          sendErrorResponse(writer, socket, 405, "Method Not Allowed")
          return
        }

        // Extract original URL from /proxy?url=...
        if (!path.startsWith("/proxy?url=")) {
          sendErrorResponse(writer, socket, 400, "Invalid proxy path")
          return
        }

        val encodedUrl = path.substringAfter("/proxy?url=")
        val originalUrl = try {
          URLDecoder.decode(encodedUrl, "UTF-8")
        } catch (e: Exception) {
          sendErrorResponse(writer, socket, 400, "Invalid URL encoding")
          return
        }

        // Fetch and proxy the content
        fetchAndProxy(originalUrl, socket)
      }
    } catch (e: Exception) {
      println("[CMCDProxy] Handle client error: ${e.message}")
    }
  }

  private fun fetchAndProxy(originalUrl: String, client: Socket) {
    try {
      val requestBuilder = Request.Builder().url(originalUrl).get()

      // Add static headers
      for ((key, value) in staticHeaders) {
        requestBuilder.addHeader(key, value)
      }

      // Add dynamic headers from provider
      dynamicHeadersProvider?.get()?.invoke()?.forEach { (key, value) ->
        requestBuilder.addHeader(key, value)
      }

      val response = httpClient.newCall(requestBuilder.build()).execute()

      response.use { resp ->
        val contentType = resp.header("Content-Type") ?: ""
        val isManifest = contentType.contains("mpegurl", ignoreCase = true) ||
          contentType.contains("x-mpegURL", ignoreCase = true) ||
          originalUrl.lowercase().endsWith(".m3u8")

        var bodyBytes = resp.body?.bytes() ?: ByteArray(0)

        if (isManifest) {
          val manifestContent = String(bodyBytes, Charsets.UTF_8)
          val rewrittenContent = rewriteHLSManifest(manifestContent, originalUrl)
          bodyBytes = rewrittenContent.toByteArray(Charsets.UTF_8)
        }

        sendResponse(client, resp.code, resp.headers.toMap(), bodyBytes)
      }
    } catch (e: Exception) {
      println("[CMCDProxy] Fetch error for $originalUrl: ${e.message}")
      try {
        val writer = PrintWriter(client.getOutputStream(), true)
        sendErrorResponse(writer, client, 502, "Bad Gateway: ${e.message}")
      } catch (writeError: Exception) {
        // Ignore write errors
      }
    }
  }

  private fun rewriteHLSManifest(content: String, baseUrl: String): String {
    val baseUri = try {
      URI(baseUrl)
    } catch (e: Exception) {
      return content
    }

    val result = StringBuilder()
    val lines = content.split("\n")

    for (line in lines) {
      var newLine = line

      // Rewrite URI attributes in tags like #EXT-X-KEY, #EXT-X-MAP, etc.
      if (line.contains("URI=\"")) {
        newLine = rewriteURIAttributes(line, baseUri)
      }
      // Rewrite segment/playlist URLs (lines that don't start with #)
      else if (!line.startsWith("#") && line.trim().isNotEmpty()) {
        val segmentUrl = resolveUrl(line.trim(), baseUri)
        if (segmentUrl != null) {
          val proxyUrl = createProxyUrl(segmentUrl)
          if (proxyUrl != null) {
            newLine = proxyUrl
          }
        }
      }

      result.append(newLine).append("\n")
    }

    return result.toString()
  }

  private fun rewriteURIAttributes(line: String, baseUri: URI): String {
    val regex = Regex("""URI="([^"]*)"""")
    return regex.replace(line) { matchResult ->
      val uri = matchResult.groupValues[1]
      val resolvedUrl = resolveUrl(uri, baseUri)
      if (resolvedUrl != null) {
        val proxyUrl = createProxyUrl(resolvedUrl)
        if (proxyUrl != null) {
          return@replace "URI=\"$proxyUrl\""
        }
      }
      matchResult.value
    }
  }

  private fun resolveUrl(urlString: String, baseUri: URI): String? {
    return try {
      if (urlString.startsWith("http://") || urlString.startsWith("https://")) {
        urlString
      } else {
        baseUri.resolve(urlString).toString()
      }
    } catch (e: Exception) {
      null
    }
  }

  private fun sendResponse(client: Socket, statusCode: Int, headers: Map<String, String>, body: ByteArray) {
    try {
      val output = client.getOutputStream()
      val statusMessage = httpStatusMessage(statusCode)

      val headerBuilder = StringBuilder()
      headerBuilder.append("HTTP/1.1 $statusCode $statusMessage\r\n")
      headerBuilder.append("Access-Control-Allow-Origin: *\r\n")

      // Forward relevant headers, skip problematic ones
      for ((key, value) in headers) {
        val lowerKey = key.lowercase()
        if (lowerKey == "content-encoding" || lowerKey == "transfer-encoding" || lowerKey == "content-length") {
          continue
        }
        headerBuilder.append("$key: $value\r\n")
      }

      headerBuilder.append("Content-Length: ${body.size}\r\n")
      headerBuilder.append("\r\n")

      output.write(headerBuilder.toString().toByteArray(Charsets.UTF_8))
      output.write(body)
      output.flush()
    } catch (e: Exception) {
      println("[CMCDProxy] Send response error: ${e.message}")
    }
  }

  private fun sendErrorResponse(writer: PrintWriter, client: Socket, statusCode: Int, message: String) {
    try {
      val statusMessage = httpStatusMessage(statusCode)
      val body = message.toByteArray(Charsets.UTF_8)

      val output = client.getOutputStream()
      val response = """
        HTTP/1.1 $statusCode $statusMessage
        Content-Type: text/plain
        Content-Length: ${body.size}
        Access-Control-Allow-Origin: *

      """.trimIndent() + "\r\n"

      output.write(response.toByteArray(Charsets.UTF_8))
      output.write(body)
      output.flush()
    } catch (e: Exception) {
      // Ignore
    }
  }

  private fun httpStatusMessage(code: Int): String {
    return when (code) {
      200 -> "OK"
      400 -> "Bad Request"
      404 -> "Not Found"
      405 -> "Method Not Allowed"
      500 -> "Internal Server Error"
      502 -> "Bad Gateway"
      else -> "Unknown"
    }
  }

  companion object {
    val shared = CMCDProxy()
  }
}
