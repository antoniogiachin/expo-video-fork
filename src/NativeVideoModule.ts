import { requireNativeModule } from 'expo-modules-core';

import type { VideoPlayer } from './VideoPlayer.types';
import type { VideoThumbnail } from './VideoThumbnail';

type ExpoVideoModule = {
  VideoPlayer: typeof VideoPlayer;
  VideoThumbnail: typeof VideoThumbnail;

  isPictureInPictureSupported(): boolean;
  setVideoCacheSizeAsync(sizeBytes: number): Promise<void>;
  clearVideoCacheAsync(): Promise<void>;
  getCurrentVideoCacheSize(): number;

  // CMCD Proxy functions
  startCMCDProxy(): Promise<void>;
  stopCMCDProxy(): void;
  isCMCDProxyRunning(): boolean;
  getCMCDProxyPort(): number;
  setCMCDProxyStaticHeaders(headers: Record<string, string>): void;
};

export default requireNativeModule<ExpoVideoModule>('ExpoVideo');
