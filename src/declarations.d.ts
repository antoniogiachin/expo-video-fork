// Type declarations for modules without types
declare module 'react-native/Libraries/Image/resolveAssetSource' {
  export interface ResolvedAssetSource {
    uri: string;
    width: number;
    height: number;
    scale: number;
  }
  export default function resolveAssetSource(source: number): ResolvedAssetSource | null;
}

declare module '@react-native/assets-registry/registry' {
  export interface PackagerAsset {
    __packager_asset: boolean;
    fileSystemLocation: string;
    httpServerLocation: string;
    width?: number;
    height?: number;
    scales: number[];
    hash: string;
    name: string;
    type: string;
  }
  export function registerAsset(asset: PackagerAsset): number;
  export function getAssetByID(assetId: number): PackagerAsset;
}
