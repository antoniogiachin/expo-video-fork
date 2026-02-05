import Foundation
import Network
import ExpoModulesCore

/// A lightweight local HTTP proxy server for injecting CMCD headers into video requests.
/// This proxy intercepts requests, adds dynamic CMCD headers, and forwards them to the CDN.
///
/// Architecture:
/// ```
/// AVPlayer → localhost:PORT/proxy?url=ENCODED_URL → CMCDProxy → CDN
///                                                      ↓
///                                               + CMCD Headers
/// ```
@available(iOS 13.0, *)
final class CMCDProxy: @unchecked Sendable {

  // MARK: - Properties

  private var listener: NWListener?
  private var connections: [NWConnection] = []
  private let queue = DispatchQueue(label: "expo.video.cmcd.proxy", qos: .userInitiated)
  private let connectionsLock = NSLock()

  private(set) var port: UInt16 = 0
  private(set) var isRunning: Bool = false

  /// Closure to get current CMCD headers - called for each request
  var cmcdHeadersProvider: (() -> [String: String])?

  /// Static headers to add to all requests (e.g., authorization)
  var staticHeaders: [String: String] = [:]

  // MARK: - Lifecycle

  /// Starts the proxy server on a random available port
  func start() throws {
    guard !isRunning else { return }

    // Create TCP listener on random port
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true

    listener = try NWListener(using: parameters, on: .any)

    listener?.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if let port = self?.listener?.port?.rawValue {
          self?.port = port
          self?.isRunning = true
          log.info("[CMCDProxy] Started on port \(port)")
        }
      case .failed(let error):
        log.error("[CMCDProxy] Failed to start: \(error)")
        self?.isRunning = false
      case .cancelled:
        self?.isRunning = false
        log.info("[CMCDProxy] Stopped")
      default:
        break
      }
    }

    listener?.newConnectionHandler = { [weak self] connection in
      self?.handleConnection(connection)
    }

    listener?.start(queue: queue)
  }

  /// Stops the proxy server
  func stop() {
    listener?.cancel()
    listener = nil

    connectionsLock.lock()
    connections.forEach { $0.cancel() }
    connections.removeAll()
    connectionsLock.unlock()

    isRunning = false
    port = 0
  }

  // MARK: - Connection Handling

  private func handleConnection(_ connection: NWConnection) {
    connectionsLock.lock()
    connections.append(connection)
    connectionsLock.unlock()

    connection.stateUpdateHandler = { [weak self, weak connection] state in
      if case .cancelled = state, let conn = connection {
        self?.removeConnection(conn)
      }
    }

    connection.start(queue: queue)
    receiveRequest(from: connection)
  }

  private func removeConnection(_ connection: NWConnection) {
    connectionsLock.lock()
    connections.removeAll { $0 === connection }
    connectionsLock.unlock()
  }

  private func receiveRequest(from connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self = self, let data = data, !data.isEmpty else {
        connection.cancel()
        return
      }

      self.processRequest(data: data, connection: connection)
    }
  }

  // MARK: - Request Processing

  private func processRequest(data: Data, connection: NWConnection) {
    guard let requestString = String(data: data, encoding: .utf8) else {
      sendErrorResponse(to: connection, statusCode: 400, message: "Bad Request")
      return
    }

    // Parse HTTP request
    let lines = requestString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      sendErrorResponse(to: connection, statusCode: 400, message: "Bad Request")
      return
    }

    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else {
      sendErrorResponse(to: connection, statusCode: 400, message: "Bad Request")
      return
    }

    let method = parts[0]
    let path = parts[1]

    // Parse request headers
    var requestHeaders: [String: String] = [:]
    for line in lines.dropFirst() {
      if line.isEmpty { break }
      if let colonIndex = line.firstIndex(of: ":") {
        let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        requestHeaders[key] = value
      }
    }

    // Extract target URL from path
    // Expected format: /proxy?url=ENCODED_URL or /proxy/ENCODED_PATH
    guard let targetUrl = extractTargetUrl(from: path) else {
      sendErrorResponse(to: connection, statusCode: 400, message: "Missing target URL")
      return
    }

    // Proxy the request
    proxyRequest(
      method: method,
      targetUrl: targetUrl,
      originalHeaders: requestHeaders,
      connection: connection
    )
  }

  private func extractTargetUrl(from path: String) -> URL? {
    // Format: /proxy?url=ENCODED_URL
    guard let urlComponents = URLComponents(string: path),
          let queryItems = urlComponents.queryItems,
          let urlParam = queryItems.first(where: { $0.name == "url" })?.value,
          let decodedUrl = urlParam.removingPercentEncoding,
          let url = URL(string: decodedUrl) else {
      return nil
    }
    return url
  }

  private func proxyRequest(
    method: String,
    targetUrl: URL,
    originalHeaders: [String: String],
    connection: NWConnection
  ) {
    var request = URLRequest(url: targetUrl)
    request.httpMethod = method
    request.timeoutInterval = 30

    // Copy relevant headers from original request
    let headersToCopy = ["Range", "Accept", "Accept-Encoding", "Accept-Language"]
    for header in headersToCopy {
      if let value = originalHeaders[header] {
        request.setValue(value, forHTTPHeaderField: header)
      }
    }

    // Add static headers
    for (key, value) in staticHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }

    // Add dynamic CMCD headers
    if let cmcdHeaders = cmcdHeadersProvider?() {
      for (key, value) in cmcdHeaders {
        request.setValue(value, forHTTPHeaderField: key)
      }
      log.info("[CMCDProxy] Added CMCD headers to request: \(targetUrl.lastPathComponent)")
    }

    // Perform the request
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      if let error = error {
        log.error("[CMCDProxy] Request failed: \(error.localizedDescription)")
        self?.sendErrorResponse(to: connection, statusCode: 502, message: "Bad Gateway")
        return
      }

      guard let httpResponse = response as? HTTPURLResponse,
            let data = data else {
        self?.sendErrorResponse(to: connection, statusCode: 502, message: "Bad Gateway")
        return
      }

      self?.sendProxiedResponse(
        to: connection,
        statusCode: httpResponse.statusCode,
        headers: httpResponse.allHeaderFields as? [String: String] ?? [:],
        body: data,
        originalUrl: targetUrl
      )
    }
    task.resume()
  }

  // MARK: - Response Handling

  private func sendProxiedResponse(
    to connection: NWConnection,
    statusCode: Int,
    headers: [String: String],
    body: Data,
    originalUrl: URL
  ) {
    var responseHeaders = headers

    // Check if this is an HLS manifest that needs URL rewriting
    let contentType = headers["Content-Type"]?.lowercased() ?? ""
    var responseBody = body

    if contentType.contains("mpegurl") || contentType.contains("x-mpegurl") {
      // Rewrite manifest URLs to go through our proxy
      responseBody = rewriteManifest(data: body, baseUrl: originalUrl)
    }

    // Build HTTP response
    var response = "HTTP/1.1 \(statusCode) \(httpStatusMessage(statusCode))\r\n"

    // Add headers
    response += "Content-Length: \(responseBody.count)\r\n"
    response += "Connection: close\r\n"

    // Copy relevant response headers
    let headersToInclude = ["Content-Type", "Cache-Control", "Accept-Ranges", "Content-Range"]
    for header in headersToInclude {
      if let value = responseHeaders[header] {
        response += "\(header): \(value)\r\n"
      }
    }

    // Add CORS headers for flexibility
    response += "Access-Control-Allow-Origin: *\r\n"
    response += "\r\n"

    // Combine headers and body
    var fullResponse = Data(response.utf8)
    fullResponse.append(responseBody)

    connection.send(content: fullResponse, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func sendErrorResponse(to connection: NWConnection, statusCode: Int, message: String) {
    let body = message.data(using: .utf8) ?? Data()
    let response = """
      HTTP/1.1 \(statusCode) \(message)\r
      Content-Type: text/plain\r
      Content-Length: \(body.count)\r
      Connection: close\r
      \r
      \(message)
      """

    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func httpStatusMessage(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 206: return "Partial Content"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 304: return "Not Modified"
    case 400: return "Bad Request"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    default: return "Unknown"
    }
  }

  // MARK: - Manifest Rewriting

  /// Rewrites URLs in HLS manifest to route through the proxy
  private func rewriteManifest(data: Data, baseUrl: URL) -> Data {
    guard let manifest = String(data: data, encoding: .utf8) else {
      return data
    }

    let proxyBase = "http://127.0.0.1:\(port)/proxy?url="
    var rewrittenLines: [String] = []
    let lines = manifest.components(separatedBy: "\n")

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Empty lines - preserve
      if trimmed.isEmpty {
        rewrittenLines.append(line)
        continue
      }

      // Handle URI attributes in tags
      if trimmed.hasPrefix("#") && trimmed.contains("URI=\"") {
        let rewritten = rewriteUriAttributes(in: line, baseUrl: baseUrl, proxyBase: proxyBase)
        rewrittenLines.append(rewritten)
        continue
      }

      // Regular comment/tag lines - preserve
      if trimmed.hasPrefix("#") {
        rewrittenLines.append(line)
        continue
      }

      // URL line - rewrite to use proxy
      if let proxyUrl = createProxyUrl(for: trimmed, baseUrl: baseUrl, proxyBase: proxyBase) {
        rewrittenLines.append(proxyUrl)
      } else {
        rewrittenLines.append(line)
      }
    }

    return rewrittenLines.joined(separator: "\n").data(using: .utf8) ?? data
  }

  private func rewriteUriAttributes(in line: String, baseUrl: URL, proxyBase: String) -> String {
    var result = line
    let pattern = "URI=\"([^\"]+)\""

    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return line
    }

    let range = NSRange(line.startIndex..., in: line)
    let matches = regex.matches(in: line, options: [], range: range)

    for match in matches.reversed() {
      guard let uriRange = Range(match.range(at: 1), in: line) else { continue }
      let uriValue = String(line[uriRange])

      if let proxyUrl = createProxyUrl(for: uriValue, baseUrl: baseUrl, proxyBase: proxyBase) {
        let fullMatchRange = Range(match.range, in: result)!
        result.replaceSubrange(fullMatchRange, with: "URI=\"\(proxyUrl)\"")
      }
    }

    return result
  }

  private func createProxyUrl(for urlString: String, baseUrl: URL, proxyBase: String) -> String? {
    let trimmed = urlString.trimmingCharacters(in: .whitespaces)

    // Resolve to absolute URL
    let absoluteUrl: URL?
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      absoluteUrl = URL(string: trimmed)
    } else {
      absoluteUrl = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL
    }

    guard let url = absoluteUrl,
          let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
      return nil
    }

    return proxyBase + encoded
  }
}
