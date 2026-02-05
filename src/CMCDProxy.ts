import NativeVideoModule from './NativeVideoModule';

/**
 * CMCD (Common Media Client Data) data structure for generating headers.
 * Based on CTA-5004 specification.
 */
export type CmcdData = {
  /**
   * Session ID - A unique string identifying the current playback session.
   */
  sid?: string;

  /**
   * Content ID - A unique string identifying the current content.
   */
  cid?: string;

  /**
   * Encoded bitrate - The encoded bitrate of the audio/video object being requested (kbps).
   */
  br?: number;

  /**
   * Object duration - The playback duration of the object being requested (milliseconds).
   */
  d?: number;

  /**
   * Object type - The type of object being requested:
   * - 'm' = manifest
   * - 'a' = audio only
   * - 'v' = video only
   * - 'av' = muxed audio/video
   * - 'i' = init segment
   * - 'c' = caption/subtitle
   * - 'k' = encryption key
   * - 'o' = other
   */
  ot?: 'm' | 'a' | 'v' | 'av' | 'i' | 'c' | 'k' | 'o';

  /**
   * Top bitrate - The highest bitrate rendition available (kbps).
   */
  tb?: number;

  /**
   * Buffer length - The buffer length in milliseconds.
   */
  bl?: number;

  /**
   * Deadline - The time remaining until rebuffer (milliseconds).
   */
  dl?: number;

  /**
   * Measured throughput - The throughput between client and server (kbps).
   */
  mtp?: number;

  /**
   * Next object request - Relative path of the next object to be requested.
   */
  nor?: string;

  /**
   * Next range request - Byte range of the next object.
   */
  nrr?: string;

  /**
   * Startup - true if the object is needed urgently due to startup/seek/recovery.
   */
  su?: boolean;

  /**
   * Buffer starvation - true if a rebuffering event occurred.
   */
  bs?: boolean;

  /**
   * Playback rate - 1 = real-time, 2 = double speed, 0 = not playing.
   */
  pr?: number;

  /**
   * Stream format - The streaming format:
   * - 'd' = DASH
   * - 'h' = HLS
   * - 's' = Smooth Streaming
   * - 'o' = other
   */
  sf?: 'd' | 'h' | 's' | 'o';

  /**
   * Stream type - 'v' = VOD, 'l' = live.
   */
  st?: 'v' | 'l';

  /**
   * Version - CMCD version (default is 1).
   */
  v?: number;

  /**
   * Requested maximum throughput - The requested maximum throughput (kbps).
   */
  rtp?: number;
};

/**
 * Formats CMCD data into HTTP headers according to CTA-5004 specification.
 * Returns headers in the four standard CMCD header format:
 * - CMCD-Object: Object-related keys (br, d, ot, tb)
 * - CMCD-Request: Request-related keys (bl, dl, mtp, nor, nrr, su)
 * - CMCD-Session: Session-related keys (cid, pr, sf, sid, st, v)
 * - CMCD-Status: Status-related keys (bs, rtp)
 *
 * @param data The CMCD data to format
 * @returns Record of header name to header value
 */
export function formatCmcdHeaders(data: CmcdData): Record<string, string> {
  const headers: Record<string, string> = {};

  const formatValue = (key: string, value: unknown): string => {
    if (typeof value === 'boolean') {
      return value ? key : '';
    }
    if (typeof value === 'string') {
      // Strings need to be quoted, except for tokens (ot, sf, st)
      if (['ot', 'sf', 'st'].includes(key)) {
        return `${key}=${value}`;
      }
      return `${key}="${value}"`;
    }
    if (typeof value === 'number') {
      // Integers don't need decimal points
      if (Number.isInteger(value)) {
        return `${key}=${value}`;
      }
      return `${key}=${value.toFixed(0)}`;
    }
    return '';
  };

  // CMCD-Object: br, d, ot, tb
  const objectParts: string[] = [];
  if (data.br !== undefined) objectParts.push(formatValue('br', data.br));
  if (data.d !== undefined) objectParts.push(formatValue('d', data.d));
  if (data.ot !== undefined) objectParts.push(formatValue('ot', data.ot));
  if (data.tb !== undefined) objectParts.push(formatValue('tb', data.tb));
  if (objectParts.length > 0) {
    headers['CMCD-Object'] = objectParts.filter(Boolean).join(',');
  }

  // CMCD-Request: bl, dl, mtp, nor, nrr, su
  const requestParts: string[] = [];
  if (data.bl !== undefined) requestParts.push(formatValue('bl', data.bl));
  if (data.dl !== undefined) requestParts.push(formatValue('dl', data.dl));
  if (data.mtp !== undefined) requestParts.push(formatValue('mtp', data.mtp));
  if (data.nor !== undefined) requestParts.push(formatValue('nor', data.nor));
  if (data.nrr !== undefined) requestParts.push(formatValue('nrr', data.nrr));
  if (data.su !== undefined) requestParts.push(formatValue('su', data.su));
  if (requestParts.length > 0) {
    headers['CMCD-Request'] = requestParts.filter(Boolean).join(',');
  }

  // CMCD-Session: cid, pr, sf, sid, st, v
  const sessionParts: string[] = [];
  if (data.cid !== undefined) sessionParts.push(formatValue('cid', data.cid));
  if (data.pr !== undefined) sessionParts.push(formatValue('pr', data.pr));
  if (data.sf !== undefined) sessionParts.push(formatValue('sf', data.sf));
  if (data.sid !== undefined) sessionParts.push(formatValue('sid', data.sid));
  if (data.st !== undefined) sessionParts.push(formatValue('st', data.st));
  if (data.v !== undefined) sessionParts.push(formatValue('v', data.v));
  if (sessionParts.length > 0) {
    headers['CMCD-Session'] = sessionParts.filter(Boolean).join(',');
  }

  // CMCD-Status: bs, rtp
  const statusParts: string[] = [];
  if (data.bs !== undefined) statusParts.push(formatValue('bs', data.bs));
  if (data.rtp !== undefined) statusParts.push(formatValue('rtp', data.rtp));
  if (statusParts.length > 0) {
    headers['CMCD-Status'] = statusParts.filter(Boolean).join(',');
  }

  return headers;
}

/**
 * Generates a random session ID suitable for CMCD.
 * Returns a UUID v4 format string.
 *
 * @returns A unique session identifier string
 */
export function generateSessionId(): string {
  // Generate UUID v4
  const hex = '0123456789abcdef';
  let uuid = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      uuid += '-';
    } else if (i === 14) {
      uuid += '4'; // Version 4
    } else if (i === 19) {
      uuid += hex[(Math.random() * 4) | 8]; // Variant bits
    } else {
      uuid += hex[(Math.random() * 16) | 0];
    }
  }
  return uuid;
}

/**
 * API for controlling the local HTTP proxy used for dynamic header injection.
 * The proxy intercepts video segment requests and adds custom headers.
 */
export const CMCDProxy = {
  /**
   * Starts the local HTTP proxy server.
   * This method is async and resolves when the proxy is ready to accept connections.
   *
   * @returns Promise that resolves when the proxy is running
   * @platform android
   * @platform ios
   */
  async start(): Promise<void> {
    return NativeVideoModule.startCMCDProxy();
  },

  /**
   * Stops the local HTTP proxy server.
   *
   * @platform android
   * @platform ios
   */
  stop(): void {
    NativeVideoModule.stopCMCDProxy();
  },

  /**
   * Checks if the proxy server is currently running.
   *
   * @returns true if the proxy is running and accepting connections
   * @platform android
   * @platform ios
   */
  isRunning(): boolean {
    return NativeVideoModule.isCMCDProxyRunning();
  },

  /**
   * Gets the port number the proxy is listening on.
   *
   * @returns The port number, or 0 if the proxy is not running
   * @platform android
   * @platform ios
   */
  getPort(): number {
    return NativeVideoModule.getCMCDProxyPort();
  },

  /**
   * Gets the base URL for the proxy server.
   *
   * @returns The base URL (e.g., "http://127.0.0.1:8080") or null if not running
   * @platform android
   * @platform ios
   */
  getBaseUrl(): string | null {
    const port = NativeVideoModule.getCMCDProxyPort();
    if (port === 0) return null;
    return `http://127.0.0.1:${port}`;
  },

  /**
   * Creates a proxy URL for the given original URL.
   * The proxy URL will route through the local proxy server.
   *
   * @param originalUrl The original video URL to proxy
   * @returns The proxy URL, or null if the proxy is not running
   * @platform android
   * @platform ios
   */
  createProxyUrl(originalUrl: string): string | null {
    const port = NativeVideoModule.getCMCDProxyPort();
    if (port === 0) return null;
    const encoded = encodeURIComponent(originalUrl);
    return `http://127.0.0.1:${port}/proxy?url=${encoded}`;
  },

  /**
   * Sets static headers that will be added to all proxied requests.
   * These headers are in addition to any dynamic headers set on the VideoPlayer.
   *
   * @param headers Record of header names to values
   * @platform android
   * @platform ios
   */
  setStaticHeaders(headers: Record<string, string>): void {
    NativeVideoModule.setCMCDProxyStaticHeaders(headers);
  },
};
