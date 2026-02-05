import { NativeModulesProxy, requireNativeModule } from 'expo-modules-core';

// Import the native module
const VideoModule = requireNativeModule('ExpoVideo');

/**
 * CMCD (Common Media Client Data) Proxy Manager
 *
 * Provides a local HTTP proxy server that intercepts video requests and injects
 * CMCD headers for CDN analytics. This approach works with all video formats
 * (HLS, DASH) and DRM content.
 *
 * Architecture:
 * ```
 * Player → localhost:PORT/proxy?url=ENCODED_URL → CMCDProxy → CDN
 *                                                      ↓
 *                                               + CMCD Headers
 * ```
 *
 * @example
 * ```typescript
 * import { CMCDProxy } from 'expo-video';
 *
 * // Start the proxy
 * await CMCDProxy.start();
 *
 * // Get proxy URL for your video
 * const proxyUrl = CMCDProxy.createProxyUrl('https://cdn.example.com/video.m3u8');
 *
 * // Use proxy URL with player
 * const player = useVideoPlayer({ uri: proxyUrl });
 *
 * // Update CMCD headers dynamically
 * player.dynamicRequestHeaders = {
 *   'CMCD-Request': 'bl=2000',
 *   'CMCD-Session': 'sid="abc123"',
 * };
 *
 * // Stop proxy when done
 * CMCDProxy.stop();
 * ```
 */
export const CMCDProxy = {
  /**
   * Starts the CMCD proxy server on a random available port.
   * The proxy will intercept video requests and add CMCD headers.
   *
   * @returns Promise that resolves when the proxy is started
   * @throws Error if the proxy fails to start
   *
   * @example
   * ```typescript
   * try {
   *   await CMCDProxy.start();
   *   console.log('Proxy started on port', CMCDProxy.getPort());
   * } catch (error) {
   *   console.error('Failed to start proxy:', error);
   * }
   * ```
   */
  async start(): Promise<void> {
    return VideoModule.startCMCDProxy();
  },

  /**
   * Stops the CMCD proxy server.
   *
   * @example
   * ```typescript
   * CMCDProxy.stop();
   * ```
   */
  stop(): void {
    VideoModule.stopCMCDProxy();
  },

  /**
   * Returns whether the proxy is currently running.
   *
   * @returns `true` if the proxy is running, `false` otherwise
   */
  isRunning(): boolean {
    return VideoModule.isCMCDProxyRunning();
  },

  /**
   * Returns the port the proxy is running on.
   *
   * @returns Port number, or 0 if not running
   */
  getPort(): number {
    return VideoModule.getCMCDProxyPort();
  },

  /**
   * Returns the base URL of the proxy (e.g., "http://127.0.0.1:8080").
   *
   * @returns Base URL string, or null if not running
   */
  getBaseUrl(): string | null {
    return VideoModule.getCMCDProxyBaseUrl();
  },

  /**
   * Creates a proxy URL for the given video URL.
   * The returned URL routes through the local proxy which adds CMCD headers.
   *
   * @param originalUrl - The original video URL (HLS, DASH, etc.)
   * @returns Proxy URL that routes through the CMCD proxy, or null if proxy not running
   *
   * @example
   * ```typescript
   * const originalUrl = 'https://cdn.example.com/video.m3u8';
   * const proxyUrl = CMCDProxy.createProxyUrl(originalUrl);
   * // Returns: "http://127.0.0.1:8080/proxy?url=https%3A%2F%2Fcdn.example.com%2Fvideo.m3u8"
   * ```
   */
  createProxyUrl(originalUrl: string): string | null {
    return VideoModule.createCMCDProxyUrl(originalUrl);
  },

  /**
   * Extracts the original URL from a proxy URL.
   *
   * @param proxyUrl - The proxy URL
   * @returns Original URL, or null if not a valid proxy URL
   */
  extractOriginalUrl(proxyUrl: string): string | null {
    return VideoModule.extractCMCDOriginalUrl(proxyUrl);
  },

  /**
   * Sets static headers to add to all proxied requests.
   * Use this for headers that don't change (e.g., authorization tokens).
   *
   * @param headers - Dictionary of static headers
   *
   * @example
   * ```typescript
   * CMCDProxy.setStaticHeaders({
   *   'Authorization': 'Bearer token123',
   *   'X-Custom-Header': 'value',
   * });
   * ```
   */
  setStaticHeaders(headers: Record<string, string>): void {
    VideoModule.setCMCDProxyStaticHeaders(headers);
  },
};

/**
 * CMCD Data structure according to CTA-5004 specification.
 * Use with `formatCmcdHeaders` helper to create properly formatted headers.
 */
export interface CmcdData {
  // CMCD-Request keys
  /** Buffer length in milliseconds */
  bl?: number;
  /** Measured throughput in kbps */
  mtp?: number;
  /** Deadline in milliseconds */
  dl?: number;
  /** Next object request URL */
  nor?: string;
  /** Next range request */
  nrr?: string;

  // CMCD-Object keys
  /** Encoded bitrate in kbps */
  br?: number;
  /** Object duration in milliseconds */
  d?: number;
  /** Object type */
  ot?: 'v' | 'a' | 'm' | 'i' | 'c' | 'tt' | 'k' | 'o';
  /** Top bitrate in kbps */
  tb?: number;

  // CMCD-Session keys
  /** Content ID */
  cid?: string;
  /** Playback rate (1 = normal) */
  pr?: number;
  /** Session ID */
  sid?: string;
  /** Streaming format: d=DASH, h=HLS, s=Smooth, o=other */
  sf?: 'd' | 'h' | 's' | 'o';
  /** Stream type: v=VOD, l=Live */
  st?: 'v' | 'l';
  /** CMCD version */
  v?: number;

  // CMCD-Status keys
  /** Buffer starvation */
  bs?: boolean;
  /** Requested maximum throughput in kbps */
  rtp?: number;
  /** Startup */
  su?: boolean;
}

/**
 * Formats CMCD data into HTTP headers according to CTA-5004 specification.
 *
 * @param data - CMCD data object
 * @returns Object with CMCD-Request, CMCD-Object, CMCD-Session, CMCD-Status headers
 *
 * @example
 * ```typescript
 * const headers = formatCmcdHeaders({
 *   bl: 2500,
 *   sid: 'abc123',
 *   cid: 'content-456',
 *   sf: 'h',
 *   st: 'v',
 * });
 * // Result:
 * // {
 * //   'CMCD-Request': 'bl=2500',
 * //   'CMCD-Session': 'cid="content-456",sf=h,sid="abc123",st=v'
 * // }
 * ```
 */
export function formatCmcdHeaders(data: CmcdData): Record<string, string> {
  const headers: Record<string, string> = {};

  // CMCD-Request: bl, mtp, dl, nor, nrr
  const requestParts: string[] = [];
  if (data.bl !== undefined) requestParts.push(`bl=${Math.round(data.bl)}`);
  if (data.mtp !== undefined) requestParts.push(`mtp=${Math.round(data.mtp)}`);
  if (data.dl !== undefined) requestParts.push(`dl=${Math.round(data.dl)}`);
  if (data.nor !== undefined) requestParts.push(`nor="${encodeURIComponent(data.nor)}"`);
  if (data.nrr !== undefined) requestParts.push(`nrr="${data.nrr}"`);
  if (requestParts.length > 0) {
    headers['CMCD-Request'] = requestParts.join(',');
  }

  // CMCD-Object: br, d, ot, tb
  const objectParts: string[] = [];
  if (data.br !== undefined) objectParts.push(`br=${Math.round(data.br)}`);
  if (data.d !== undefined) objectParts.push(`d=${Math.round(data.d)}`);
  if (data.ot !== undefined) objectParts.push(`ot=${data.ot}`);
  if (data.tb !== undefined) objectParts.push(`tb=${Math.round(data.tb)}`);
  if (objectParts.length > 0) {
    headers['CMCD-Object'] = objectParts.join(',');
  }

  // CMCD-Session: cid, pr, sf, sid, st, v
  const sessionParts: string[] = [];
  if (data.cid !== undefined) sessionParts.push(`cid="${data.cid}"`);
  if (data.pr !== undefined && data.pr !== 1) sessionParts.push(`pr=${data.pr}`);
  if (data.sf !== undefined) sessionParts.push(`sf=${data.sf}`);
  if (data.sid !== undefined) sessionParts.push(`sid="${data.sid}"`);
  if (data.st !== undefined) sessionParts.push(`st=${data.st}`);
  if (data.v !== undefined) sessionParts.push(`v=${data.v}`);
  if (sessionParts.length > 0) {
    headers['CMCD-Session'] = sessionParts.join(',');
  }

  // CMCD-Status: bs, rtp, su
  const statusParts: string[] = [];
  if (data.bs === true) statusParts.push('bs');
  if (data.rtp !== undefined) statusParts.push(`rtp=${Math.round(data.rtp)}`);
  if (data.su === true) statusParts.push('su');
  if (statusParts.length > 0) {
    headers['CMCD-Status'] = statusParts.join(',');
  }

  return headers;
}

/**
 * Generates a random session ID for CMCD tracking.
 *
 * @returns A UUID-like session ID string
 */
export function generateSessionId(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export default CMCDProxy;
