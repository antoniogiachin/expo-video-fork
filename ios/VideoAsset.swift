import Foundation
import AVFoundation
import CryptoKit
import MobileCoreServices
import ExpoModulesCore

internal class VideoAsset: AVURLAsset, @unchecked Sendable {
  internal let videoSource: VideoSource
  private var resourceLoaderDelegate: ResourceLoaderDelegate?
  private let initialScheme: String?
  private let saveFilePath: String?
  private var customFileExtension: String?
  private let useCaching: Bool
  private let usesDynamicHeaders: Bool

  var cachingError: Error?

  internal var urlRequestHeaders: [String: String]?

  // Weak reference to VideoPlayer for dynamic headers (CMCD)
  internal weak var dynamicHeaderProvider: VideoPlayer? {
    didSet {
      // Update the closure reference when provider changes
      updateDynamicHeadersProvider()
    }
  }

  // Store closure for dynamic headers
  private var dynamicHeadersClosure: (() -> [String: String]?)?

  private func updateDynamicHeadersProvider() {
    // This is called when dynamicHeaderProvider is set
    // The closure in ResourceLoaderDelegate will capture this reference
  }

  init(url: URL, videoSource: VideoSource) {
    self.videoSource = videoSource
    self.usesDynamicHeaders = videoSource.enableDynamicHeaders
    let cachedMimeType = MediaInfo(forResourceUrl: url)?.mimeType
    let cachedExtension = mimeTypeToExtension(mimeType: cachedMimeType) ?? ""
    let fileExtension = url.pathExtension.isEmpty ? cachedExtension : url.pathExtension
    self.saveFilePath = Self.pathForUrl(url: url, fileExtension: fileExtension)
    self.urlRequestHeaders = videoSource.headers
    self.initialScheme = URLComponents(url: url, resolvingAgainstBaseURL: false)?.scheme

    // Creates an URL that will delegate it's requests to ResourceLoaderDelegate
    let urlWithCustomScheme = url.withScheme(VideoCacheManager.expoVideoCacheScheme)

    let assetOptions: [String: Any]? = if let headers = videoSource.headers {
      ["AVURLAssetHTTPHeaderFieldsKey": headers]
    } else {
      nil
    }

    let canCache = Self.canCache(videoSource: videoSource)

    if saveFilePath == nil && videoSource.useCaching {
      log.warn("Failed to create a cache file path for the provided source with uri: \(videoSource.uri?.absoluteString ?? "null")")
    }

    if !canCache && videoSource.useCaching {
      log.warn("Provided source with uri: \(videoSource.uri?.absoluteString ?? "null") cannot be cached. Caching will be disabled")
    }

    if urlWithCustomScheme == nil && videoSource.useCaching {
      log.warn("CachingPlayerItem error: Urls without a scheme are not supported, the resource won't be cached")
    }

    // Use ResourceLoaderDelegate when caching OR when dynamic headers are enabled
    let shouldUseResourceLoader = videoSource.useCaching || videoSource.enableDynamicHeaders

    guard let saveFilePath, let urlWithCustomScheme, shouldUseResourceLoader else {
      // Initialize with no caching and no dynamic headers
      useCaching = false
      super.init(url: url, options: assetOptions)
      return
    }

    // Enable ResourceLoaderDelegate (for caching and/or dynamic headers)
    useCaching = videoSource.useCaching

    // Create closure that captures self weakly for dynamic headers
    let dynamicHeadersProvider: (() -> [String: String]?)? = videoSource.enableDynamicHeaders ? { [weak self] in
      return self?.dynamicHeaderProvider?.dynamicRequestHeaders
    } : nil

    resourceLoaderDelegate = ResourceLoaderDelegate(
      url: url,
      saveFilePath: saveFilePath,
      fileExtension: fileExtension,
      urlRequestHeaders: urlRequestHeaders,
      dynamicHeadersProvider: dynamicHeadersProvider
    )
    super.init(url: urlWithCustomScheme, options: assetOptions)

    resourceLoaderDelegate?.onError = { [weak self] error in
      self?.cachingError = error
    }
    self.resourceLoader.setDelegate(resourceLoaderDelegate, queue: VideoCacheManager.shared.cacheQueue)

    if useCaching {
      self.createCacheDirectoryIfNeeded()
      VideoCacheManager.shared.ensureCacheIntegrity(forSavePath: saveFilePath)
    }
  }

  deinit {
    guard useCaching else {
      return
    }
    if let saveFilePath, let cachedFileUrl = URL(string: saveFilePath) {
      VideoCacheManager.shared.unregisterOpenFile(at: cachedFileUrl)
    }
    VideoCacheManager.shared.ensureCacheSize()
  }

  static func pathForUrl(url: URL, fileExtension: String) -> String? {
    let hashedData = SHA256.hash(data: Data(url.absoluteString.utf8))
    let hashString = hashedData.compactMap { String(format: "%02x", $0) }.joined()
    let parsedExtension = fileExtension.starts(with: ".") || fileExtension.isEmpty ? fileExtension : ("." + fileExtension)
    let hashFilename = hashString + parsedExtension

    guard var cachesDirectory = try? FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    else {
      log.warn("CachingPlayerItem error: Can't access default cache directory")
      return nil
    }

    cachesDirectory.appendPathComponent(VideoCacheManager.expoVideoCacheScheme, isDirectory: true)
    cachesDirectory.appendPathComponent(hashFilename)

    return cachesDirectory.path
  }

  static func canCache(videoSource: VideoSource) -> Bool {
    guard videoSource.uri?.scheme?.starts(with: "http") == true else {
      return false
    }
    return videoSource.drm == nil
  }

  private func createCacheDirectoryIfNeeded() {
    guard var cachesDirectory = try? FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true)
    else {
      return
    }

    cachesDirectory.appendPathComponent(VideoCacheManager.expoVideoCacheScheme, isDirectory: true)
    try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
  }
}
