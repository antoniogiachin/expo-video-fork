// Copyright 2024-present 650 Industries. All rights reserved.

import Foundation
import Network

/// Local HTTP proxy server for injecting dynamic headers into video segment requests.
/// Uses Network.framework's NWListener for efficient TCP handling.
internal final class CMCDProxy {
  static let shared = CMCDProxy()

  private var listener: NWListener?
  private(set) var port: UInt16 = 0
  private let queue = DispatchQueue(label: "expo.video.cmcd.proxy", qos: .userInitiated)
  private let headersLock = NSLock()

  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var activeConnections: Set<NWConnection> = []
  private let connectionsLock = NSLock()

  /// Provider for dynamic headers - typically set by the VideoPlayer
  var dynamicHeadersProvider: (() -> [String: String])?

  /// Static headers that are always added to proxied requests
  private var _staticHeaders: [String: String] = [:]
  var staticHeaders: [String: String] {
    get {
      headersLock.lock()
      defer { headersLock.unlock() }
      return _staticHeaders
    }
    set {
      headersLock.lock()
      defer { headersLock.unlock() }
      _staticHeaders = newValue
    }
  }

  var isReady: Bool { port > 0 }

  private init() {}

  /// Starts the proxy server asynchronously.
  /// Returns when the proxy is ready to accept connections.
  func start() async throws {
    // If already running, return immediately
    if port > 0 { return }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      self.readyContinuation = continuation

      do {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters, on: .any)

        newListener.stateUpdateHandler = { [weak self] state in
          guard let self = self else { return }
          switch state {
          case .ready:
            if let listenerPort = newListener.port?.rawValue {
              self.port = listenerPort
              self.readyContinuation?.resume()
              self.readyContinuation = nil
            }
          case .failed(let error):
            self.readyContinuation?.resume(throwing: error)
            self.readyContinuation = nil
          case .cancelled:
            let cancelError = NSError(domain: "CMCDProxy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Proxy was cancelled"])
            self.readyContinuation?.resume(throwing: cancelError)
            self.readyContinuation = nil
          default:
            break
          }
        }

        newListener.newConnectionHandler = { [weak self] connection in
          self?.handleConnection(connection)
        }

        self.listener = newListener
        newListener.start(queue: self.queue)
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }

  /// Stops the proxy server and closes all active connections.
  func stop() {
    listener?.cancel()
    listener = nil
    port = 0

    connectionsLock.lock()
    let connections = activeConnections
    activeConnections.removeAll()
    connectionsLock.unlock()

    for connection in connections {
      connection.cancel()
    }
  }

  /// Creates a proxy URL for the given original URL.
  func createProxyUrl(for originalUrl: URL) -> URL? {
    guard port > 0 else { return nil }
    guard let encoded = originalUrl.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
      return nil
    }
    return URL(string: "http://127.0.0.1:\(port)/proxy?url=\(encoded)")
  }

  // MARK: - Connection Handling

  private func handleConnection(_ connection: NWConnection) {
    connectionsLock.lock()
    activeConnections.insert(connection)
    connectionsLock.unlock()

    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self = self, let connection = connection else { return }
      switch state {
      case .ready:
        self.receiveRequest(on: connection)
      case .failed, .cancelled:
        self.removeConnection(connection)
      default:
        break
      }
    }

    connection.start(queue: queue)
  }

  private func removeConnection(_ connection: NWConnection) {
    connectionsLock.lock()
    activeConnections.remove(connection)
    connectionsLock.unlock()
  }

  private func receiveRequest(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self = self else { return }

      if let error = error {
        print("[CMCDProxy] Receive error: \(error)")
        connection.cancel()
        return
      }

      guard let data = data, !data.isEmpty else {
        if isComplete {
          connection.cancel()
        }
        return
      }

      self.processRequest(data: data, connection: connection)
    }
  }

  private func processRequest(data: Data, connection: NWConnection) {
    guard let requestString = String(data: data, encoding: .utf8) else {
      sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request")
      return
    }

    // Parse HTTP request
    let lines = requestString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      sendErrorResponse(connection: connection, statusCode: 400, message: "Empty request")
      return
    }

    let requestParts = requestLine.components(separatedBy: " ")
    guard requestParts.count >= 2 else {
      sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid request line")
      return
    }

    let method = requestParts[0]
    let path = requestParts[1]

    // Only handle GET requests
    guard method == "GET" else {
      sendErrorResponse(connection: connection, statusCode: 405, message: "Method not allowed")
      return
    }

    // Extract original URL from /proxy?url=ENCODED_URL
    guard path.hasPrefix("/proxy?url="),
          let urlStart = path.range(of: "/proxy?url=")?.upperBound,
          let encodedUrl = String(path[urlStart...]).removingPercentEncoding,
          let originalUrl = URL(string: encodedUrl) else {
      sendErrorResponse(connection: connection, statusCode: 400, message: "Invalid proxy URL")
      return
    }

    // Fetch the original URL with injected headers
    fetchAndProxy(originalUrl: originalUrl, connection: connection)
  }

  private func fetchAndProxy(originalUrl: URL, connection: NWConnection) {
    var request = URLRequest(url: originalUrl)
    request.httpMethod = "GET"

    // Add static headers
    for (key, value) in staticHeaders {
      request.setValue(value, forHTTPHeaderField: key)
    }

    // Add dynamic headers from provider
    if let provider = dynamicHeadersProvider {
      let dynamicHeaders = provider()
      for (key, value) in dynamicHeaders {
        request.setValue(value, forHTTPHeaderField: key)
      }
    }

    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }

      if let error = error {
        self.sendErrorResponse(connection: connection, statusCode: 502, message: "Upstream error: \(error.localizedDescription)")
        return
      }

      guard let httpResponse = response as? HTTPURLResponse, let data = data else {
        self.sendErrorResponse(connection: connection, statusCode: 502, message: "Invalid upstream response")
        return
      }

      // Check if this is an HLS manifest that needs URL rewriting
      let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
      let isManifest = contentType.contains("mpegurl") ||
                       contentType.contains("x-mpegURL") ||
                       originalUrl.pathExtension.lowercased() == "m3u8"

      var responseData = data
      if isManifest {
        responseData = self.rewriteHLSManifest(data, baseUrl: originalUrl)
      }

      self.sendResponse(
        connection: connection,
        statusCode: httpResponse.statusCode,
        headers: httpResponse.allHeaderFields as? [String: String] ?? [:],
        data: responseData,
        isManifest: isManifest
      )
    }
    task.resume()
  }

  private func rewriteHLSManifest(_ data: Data, baseUrl: URL) -> Data {
    guard let content = String(data: data, encoding: .utf8) else {
      return data
    }

    var rewritten = ""
    let lines = content.components(separatedBy: "\n")

    for line in lines {
      var newLine = line

      // Rewrite URI attributes in tags like #EXT-X-KEY, #EXT-X-MAP, etc.
      if line.contains("URI=\"") {
        newLine = rewriteURIAttributes(in: line, baseUrl: baseUrl)
      }
      // Rewrite segment/playlist URLs (lines that don't start with #)
      else if !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
        if let segmentUrl = resolveUrl(line.trimmingCharacters(in: .whitespaces), relativeTo: baseUrl),
           let proxyUrl = createProxyUrl(for: segmentUrl) {
          newLine = proxyUrl.absoluteString
        }
      }

      rewritten += newLine + "\n"
    }

    return rewritten.data(using: .utf8) ?? data
  }

  private func rewriteURIAttributes(in line: String, baseUrl: URL) -> String {
    // Match URI="..." pattern
    let pattern = #"URI="([^"]*)""#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return line
    }

    var result = line
    let range = NSRange(line.startIndex..., in: line)

    // Find all URI attributes and rewrite them
    let matches = regex.matches(in: line, options: [], range: range)

    // Process matches in reverse order to preserve string indices
    for match in matches.reversed() {
      guard let uriRange = Range(match.range(at: 1), in: line) else { continue }
      let uri = String(line[uriRange])

      if let resolvedUrl = resolveUrl(uri, relativeTo: baseUrl),
         let proxyUrl = createProxyUrl(for: resolvedUrl) {
        let fullMatchRange = Range(match.range, in: result)!
        result.replaceSubrange(fullMatchRange, with: "URI=\"\(proxyUrl.absoluteString)\"")
      }
    }

    return result
  }

  private func resolveUrl(_ urlString: String, relativeTo baseUrl: URL) -> URL? {
    // If it's already an absolute URL
    if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
      return URL(string: urlString)
    }

    // Resolve relative URL
    return URL(string: urlString, relativeTo: baseUrl)?.absoluteURL
  }

  // MARK: - Response Sending

  private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String], data: Data, isManifest: Bool) {
    var responseHeaders = "HTTP/1.1 \(statusCode) \(httpStatusMessage(statusCode))\r\n"

    // Add CORS headers
    responseHeaders += "Access-Control-Allow-Origin: *\r\n"

    // Forward relevant headers
    for (key, value) in headers {
      let lowerKey = key.lowercased()
      // Skip headers that might cause issues
      if lowerKey == "content-encoding" || lowerKey == "transfer-encoding" || lowerKey == "content-length" {
        continue
      }
      responseHeaders += "\(key): \(value)\r\n"
    }

    // Set correct content length
    responseHeaders += "Content-Length: \(data.count)\r\n"
    responseHeaders += "\r\n"

    guard let headerData = responseHeaders.data(using: .utf8) else {
      connection.cancel()
      return
    }

    var fullResponse = headerData
    fullResponse.append(data)

    connection.send(content: fullResponse, completion: .contentProcessed { [weak self] error in
      if let error = error {
        print("[CMCDProxy] Send error: \(error)")
      }
      connection.cancel()
      self?.removeConnection(connection)
    })
  }

  private func sendErrorResponse(connection: NWConnection, statusCode: Int, message: String) {
    let body = message.data(using: .utf8) ?? Data()
    sendResponse(connection: connection, statusCode: statusCode, headers: ["Content-Type": "text/plain"], data: body, isManifest: false)
  }

  private func httpStatusMessage(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    default: return "Unknown"
    }
  }
}
