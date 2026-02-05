import Foundation
import AVFoundation
import UIKit
import CoreServices
import ExpoModulesCore

/**
 * Class responsible for fulfilling data requests created  by the AVAsset. There are two types of requests:
 * - Initial request  - The response contains most of the information about the data source such as support for content ranges, total size etc.
 *   this information is cached for offline playback support.
 * - Data request - For each range request from the player the delegate will request and receive multiple chunks of data. We have to return a correct subrange
 *   of data and cache it. If a chunk of data is already available we will return it from cache.
 */
final class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDelegate, URLSessionDataDelegate, URLSessionTaskDelegate {
  private let url: URL
  private let saveFilePath: String
  private let fileExtension: String
  private let cachedResource: CachedResource
  private let urlRequestHeaders: [String: String]?
  internal var dynamicHeadersProvider: (() -> [String: String]?)?
  internal var onError: ((Error) -> Void)?

  private var cachableRequests: SynchronizedHashTable<CachableRequest> = SynchronizedHashTable()
  private var session: URLSession?

  /**
   * The default requestTimeoutInterval is 60, which is  too long (UI should respond relatively quickly to network errors)
   */
  private static let requestTimeoutInterval: Double = 5

  // When playing from an url without an extension appends an extension to the path based on the response from the server
  private var pathWithExtension: String {
    let ext = mimeTypeToExtension(mimeType: cachedResource.mediaInfo?.mimeType)
    if let ext, self.fileExtension.isEmpty {
      return self.saveFilePath + ".\(ext)"
    }
    return self.saveFilePath
  }

  init(
    url: URL,
    saveFilePath: String,
    fileExtension: String,
    urlRequestHeaders: [String: String]?,
    dynamicHeadersProvider: (() -> [String: String]?)? = nil
  ) {
    self.url = url
    self.saveFilePath = saveFilePath
    self.fileExtension = fileExtension
    self.urlRequestHeaders = urlRequestHeaders
    self.dynamicHeadersProvider = dynamicHeadersProvider
    cachedResource = CachedResource(dataFileUrl: saveFilePath, resourceUrl: url, dataPath: saveFilePath)
    super.init()
    self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
  }

  deinit {
    session?.invalidateAndCancel()
    session = nil
  }

  // MARK: - AVAssetResourceLoaderDelegate

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    processLoadingRequest(loadingRequest: loadingRequest)
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    cachableRequest(by: loadingRequest)?.dataTask.cancel()
  }

  // MARK: - URLSessionDelegate

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let currentRequest = dataTask.currentRequest,
      let response = dataTask.response as? HTTPURLResponse,
      let cachableRequest = cachableRequest(by: dataTask) else {
      return
    }

    let dataRequest = cachableRequest.dataRequest
    let requestedOffset = dataRequest.requestedOffset
    let currentOffset = dataRequest.currentOffset
    let length = dataRequest.requestedLength

    // If finding correct subdata failed, fallback to pure received data
    var subdata = data.subdata(request: currentRequest, response: response) ?? data

    // Rewrite URLs in HLS manifests to use our custom scheme
    if let mimeType = response.mimeType, isHlsManifest(mimeType: mimeType),
       let requestUrl = currentRequest.url {
      subdata = rewriteHlsManifest(data: subdata, baseUrl: requestUrl)
    }

    // Append modified or original data
    cachableRequest.onReceivedData(data: subdata)

    if dataRequest.requestsAllDataToEndOfResource {
      let currentDataResponseOffset = Int(currentOffset - requestedOffset)
      let currentDataResponseLength = cachableRequest.receivedData.count - currentDataResponseOffset
      let subdata = cachableRequest.receivedData.subdata(in: currentDataResponseOffset..<currentDataResponseOffset + currentDataResponseLength)
      dataRequest.respond(with: subdata)
    } else if currentOffset - requestedOffset <= cachableRequest.receivedData.count {
      let rangeStart = Int(currentOffset - requestedOffset)
      let rangeLength = min(cachableRequest.receivedData.count - rangeStart, length)
      let subdata = cachableRequest.receivedData.subdata(in: rangeStart..<rangeStart + rangeLength)
      dataRequest.respond(with: subdata)
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    // Log response for debugging
    if let httpResponse = response as? HTTPURLResponse {
      log.info("[ResourceLoaderDelegate] Response status: \(httpResponse.statusCode) for URL: \(dataTask.currentRequest?.url?.absoluteString ?? "unknown")")
      if httpResponse.statusCode >= 400 {
        log.error("[ResourceLoaderDelegate] Error response headers: \(httpResponse.allHeaderFields)")
      }
    }

    if let cachedDataRequest = cachableRequest(by: dataTask) {
      cachedDataRequest.response = response
      if cachedDataRequest.loadingRequest.contentInformationRequest != nil {
        fillInContentInformationRequest(forDataRequest: cachedDataRequest)
        cachedDataRequest.loadingRequest.response = response
        cachedDataRequest.loadingRequest.finishLoading()
        cachedDataRequest.dataTask.cancel()
        cachableRequests.remove(cachedDataRequest)
      }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let cachedDataRequest = cachableRequest(by: task) else {
      return
    }

    if let error = error {
      log.error("[ResourceLoaderDelegate] Task completed with error: \(error.localizedDescription)")
      if let urlError = error as? URLError {
        log.error("[ResourceLoaderDelegate] URLError code: \(urlError.code.rawValue)")
      }
    }

    // The data shouldn't be corrupted and can be cached
    if let error = error as? URLError, error.code == URLError.cancelled || error.code == URLError.networkConnectionLost {
      cachedDataRequest.saveData(to: cachedResource)
    } else if error == nil {
      cachedDataRequest.saveData(to: cachedResource)
    } else {
      cachedDataRequest.loadingRequest.finishLoading(with: error)
    }
    cachedDataRequest.loadingRequest.finishLoading(with: error)
    cachableRequests.remove(cachedDataRequest)
  }

  private func processLoadingRequest(loadingRequest: AVAssetResourceLoadingRequest) {
    let (remainingRequest, dataReceived) = attemptToRespondFromCache(forRequest: loadingRequest)

    // Cache fulfilled the entire request
    if dataReceived != nil && remainingRequest == nil {
      return
    }

    // Get the actual URL being requested (may be different for HLS segments)
    let requestUrl = getOriginalUrl(from: loadingRequest) ?? url
    var request = remainingRequest ?? createUrlRequest(for: requestUrl)

    // remainingRequest will have correct range header fields
    if remainingRequest == nil {
      addRangeHeaderFields(loadingRequest: loadingRequest, urlRequest: &request)
    }

    guard let session else {
      return
    }

    let dataTask = session.dataTask(with: request)

    // we can't do `if let loadingRequest = loadingRequest.dataRequest` as this would create new variable by copying
    if loadingRequest.dataRequest != nil {
      let cachableRequest = CachableRequest(loadingRequest: loadingRequest, dataTask: dataTask, dataRequest: loadingRequest.dataRequest!)
      // We need to add the data that was received from cache in order to keep byte offsets consistent
      if let dataReceived {
        cachableRequest.onReceivedData(data: dataReceived)
      }
      cachableRequests.add(cachableRequest)
    } else {
      log.warn("ResourceLoaderDelegate has received a loading request without a data request")
    }
    dataTask.resume()
  }

  private func fillInContentInformationRequest(forDataRequest request: CachableRequest?) {
    guard let response = request?.response as? HTTPURLResponse else {
      return
    }

    request?.loadingRequest.contentInformationRequest?.contentLength = response.expectedContentLength
    request?.loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = true

    // Always set content type for proper playback (including HLS manifests)
    if let mimeType = response.mimeType {
      let rawUti = UTType(mimeType: mimeType)?.identifier
      request?.loadingRequest.contentInformationRequest?.contentType = rawUti ?? response.mimeType
    }

    // Only cache video/audio segments, not manifests
    if let mimeType = response.mimeType, isCacheable(mimeType: mimeType) {
      cachedResource.onResponseReceived(response: response)
    }
    // Note: We don't throw error for non-cacheable types (like HLS manifests)
    // as they can still be played, just not cached
  }

  /// Attempts to load the request from cache, if just the beginning of the requested data  is available, returns a URL request to fetch the rest of the data
  private func attemptToRespondFromCache(forRequest loadingRequest: AVAssetResourceLoadingRequest) -> (request: URLRequest?, dataReceived: Data?) {
    guard let dataRequest = loadingRequest.dataRequest else {
      return (nil, nil)
    }

    let from = dataRequest.requestedOffset
    let to = from + Int64(dataRequest.requestedLength) - 1

    // Try to return the whole data from the cache
    if let cachedData = cachedResource.requestData(from: from, to: to) {
      if loadingRequest.contentInformationRequest != nil {
        cachedResource.fill(forLoadingRequest: loadingRequest)
      }
      loadingRequest.dataRequest?.respond(with: cachedData)
      loadingRequest.finishLoading()
      return (nil, cachedData)
    }

    // Try to return the beginning of the data, and create a request for the remainder
    if let partialData = cachedResource.requestBeginningOfData(from: from, to: to) {
      if loadingRequest.contentInformationRequest != nil {
        cachedResource.fill(forLoadingRequest: loadingRequest)
      }
      loadingRequest.dataRequest?.respond(with: partialData)

      let requestUrl = getOriginalUrl(from: loadingRequest) ?? url
      var request = createUrlRequest(for: requestUrl)
      if loadingRequest.contentInformationRequest == nil {
        if loadingRequest.dataRequest?.requestsAllDataToEndOfResource == true {
          let requestedOffset = dataRequest.requestedOffset
          request.setValue("bytes=\(Int(requestedOffset) + partialData.count)-", forHTTPHeaderField: "Range")
        } else if let dataRequest = loadingRequest.dataRequest {
          let requestedOffset = dataRequest.requestedOffset
          let requestedLength = dataRequest.requestedLength
          let from = Int(requestedOffset) + partialData.count
          let to = from + requestedLength - partialData.count - 1
          request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        }
      }
      return (request, partialData)
    }

    return (nil, nil)
  }

  // The loading resource might want only a part of the video
  // https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Range
  private func addRangeHeaderFields(loadingRequest: AVAssetResourceLoadingRequest, urlRequest: inout URLRequest) {
    guard let dataRequest = loadingRequest.dataRequest, loadingRequest.contentInformationRequest == nil else {
      return
    }

    if dataRequest.requestsAllDataToEndOfResource {
      let requestedOffset = dataRequest.requestedOffset
      urlRequest.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range")
      return
    }

    let requestedOffset = dataRequest.requestedOffset
    let requestedLength = Int64(dataRequest.requestedLength)
    urlRequest.setValue("bytes=\(requestedOffset)-\(requestedOffset + requestedLength - 1)", forHTTPHeaderField: "Range")
  }

  /// Determines if a MIME type should be cached.
  /// Only video/audio segments are cached, not manifests or other metadata.
  private func isCacheable(mimeType: String?) -> Bool {
    guard let mimeType = mimeType else { return false }
    // Only cache actual media segments (video/audio), not manifests
    return mimeType.starts(with: "video/") || mimeType.starts(with: "audio/")
  }

  /// Determines if a MIME type is an HLS manifest
  private func isHlsManifest(mimeType: String?) -> Bool {
    guard let mimeType = mimeType?.lowercased() else { return false }
    return mimeType.contains("mpegurl") ||
           mimeType.contains("x-mpegurl") ||
           mimeType == "application/vnd.apple.mpegurl"
  }

  /// Rewrites URLs in HLS manifest to use our custom scheme
  /// This ensures all segment/sub-manifest requests go through our delegate
  /// Works correctly for both VOD and Live streaming (manifest is re-fetched and rewritten each time)
  private func rewriteHlsManifest(data: Data, baseUrl: URL) -> Data {
    guard let manifestString = String(data: data, encoding: .utf8) else {
      return data
    }

    let customScheme = VideoCacheManager.expoVideoCacheScheme
    var rewrittenLines: [String] = []
    let lines = manifestString.components(separatedBy: "\n")

    for line in lines {
      let trimmedLine = line.trimmingCharacters(in: .whitespaces)

      // Empty lines - preserve as-is
      if trimmedLine.isEmpty {
        rewrittenLines.append(line)
        continue
      }

      // Handle URI attributes in tags like #EXT-X-KEY, #EXT-X-MAP, #EXT-X-MEDIA, etc.
      if trimmedLine.hasPrefix("#") && trimmedLine.contains("URI=\"") {
        let rewrittenLine = rewriteUriAttributes(in: line, baseUrl: baseUrl, customScheme: customScheme)
        rewrittenLines.append(rewrittenLine)
        continue
      }

      // Regular comment/tag lines - preserve as-is
      if trimmedLine.hasPrefix("#") {
        rewrittenLines.append(line)
        continue
      }

      // This is a URL line (segment or sub-manifest)
      if let rewrittenUrl = rewriteUrl(trimmedLine, baseUrl: baseUrl, customScheme: customScheme) {
        rewrittenLines.append(rewrittenUrl)
      } else {
        // If we can't rewrite, keep original (shouldn't happen but safe fallback)
        rewrittenLines.append(line)
      }
    }

    let result = rewrittenLines.joined(separator: "\n")
    log.info("[ResourceLoaderDelegate] Rewrote HLS manifest URLs to custom scheme (\(lines.count) lines)")
    return result.data(using: .utf8) ?? data
  }

  /// Rewrites all URI="..." attributes in a line
  private func rewriteUriAttributes(in line: String, baseUrl: URL, customScheme: String) -> String {
    var result = line
    let pattern = "URI=\"([^\"]+)\""

    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
      return line
    }

    let range = NSRange(line.startIndex..., in: line)
    let matches = regex.matches(in: line, options: [], range: range)

    // Process matches in reverse order to preserve indices
    for match in matches.reversed() {
      guard let uriRange = Range(match.range(at: 1), in: line) else { continue }
      let uriValue = String(line[uriRange])

      if let rewrittenUri = rewriteUrl(uriValue, baseUrl: baseUrl, customScheme: customScheme) {
        let fullMatchRange = Range(match.range, in: result)!
        result.replaceSubrange(fullMatchRange, with: "URI=\"\(rewrittenUri)\"")
      }
    }

    return result
  }

  /// Rewrites a single URL to use custom scheme
  private func rewriteUrl(_ urlString: String, baseUrl: URL, customScheme: String) -> String? {
    let trimmed = urlString.trimmingCharacters(in: .whitespaces)

    // Handle absolute URLs
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      guard let url = URL(string: trimmed),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
      }
      components.scheme = customScheme
      return components.url?.absoluteString
    }

    // Handle relative URLs
    guard let resolvedUrl = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL,
          var components = URLComponents(url: resolvedUrl, resolvingAgainstBaseURL: false) else {
      return nil
    }
    components.scheme = customScheme
    return components.url?.absoluteString
  }

  /// Extracts the original URL from a loading request by converting custom scheme back to original
  private func getOriginalUrl(from loadingRequest: AVAssetResourceLoadingRequest) -> URL? {
    guard let requestUrl = loadingRequest.request.url else {
      return nil
    }

    // Convert from custom scheme (expoVideoCache://) back to original scheme (https://)
    guard var components = URLComponents(url: requestUrl, resolvingAgainstBaseURL: false) else {
      return nil
    }

    // Replace custom scheme with https (or use original scheme if stored)
    if components.scheme == VideoCacheManager.expoVideoCacheScheme {
      components.scheme = "https"
    }

    return components.url
  }

  private func createUrlRequest(for requestUrl: URL) -> URLRequest {
    var request = URLRequest(url: requestUrl, cachePolicy: .useProtocolCachePolicy)
    request.timeoutInterval = Self.requestTimeoutInterval

    // Static headers from VideoSource
    self.urlRequestHeaders?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

    // Dynamic headers (CMCD) - fetched fresh on each request
    if let dynamicHeaders = dynamicHeadersProvider?() {
      dynamicHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    }

    log.info("[ResourceLoaderDelegate] Creating request for URL: \(requestUrl.absoluteString)")
    log.info("[ResourceLoaderDelegate] Static headers: \(String(describing: urlRequestHeaders))")
    log.info("[ResourceLoaderDelegate] Dynamic headers: \(String(describing: dynamicHeadersProvider?()))")

    return request
  }

  private func cachableRequest(by loadingRequest: AVAssetResourceLoadingRequest) -> CachableRequest? {
    return cachableRequests.allObjects.first(where: {
      $0.loadingRequest == loadingRequest
    })
  }

  private func cachableRequest(by task: URLSessionTask) -> CachableRequest? {
    return cachableRequests.allObjects.first(where: {
      $0.dataTask == task
    })
  }
}
