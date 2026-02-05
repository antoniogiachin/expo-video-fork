# CMCD Dynamic Headers Implementation

Questo documento descrive l'implementazione del supporto CMCD (Common Media Client Data) con headers HTTP dinamici per expo-video.

## Overview

CMCD (CTA-5004) è uno standard per comunicare metriche client-side ai CDN tramite HTTP headers. Questa implementazione permette di aggiornare gli headers dinamicamente per ogni richiesta di chunk video, senza ricaricare la source.

## Architettura

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│   JavaScript    │     │    Native Bridge     │     │  Network Layer  │
│                 │     │                      │     │                 │
│ player.dynamic  │────▶│ dynamicRequestHeaders│────▶│ OkHttp/URLSess  │
│ RequestHeaders  │     │ (lettura per-request)│     │ (ogni chunk)    │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
```

### Flusso dei dati

1. **JavaScript** aggiorna `player.dynamicRequestHeaders` (es. su ogni `timeUpdate`)
2. **Native layer** legge questi headers ad ogni richiesta HTTP
3. **Headers** vengono iniettati in manifest e chunk requests

## Nuove API

### VideoSource

```typescript
const source: VideoSource = {
  uri: 'https://example.com/video.m3u8',
  headers: { 'x-cdn-provider': 'akamai' }, // headers statici
  enableDynamicHeaders: true, // NUOVO: abilita CMCD
};
```

### VideoPlayer

```typescript
// Aggiornare headers dinamicamente
player.dynamicRequestHeaders = {
  'CMCD-Request': 'bl=2000',
  'CMCD-Session': 'sid="abc123",sf=h,st=v',
};
```

## Modifiche ai File

### TypeScript

#### `src/VideoPlayer.types.ts`

**Aggiunte:**

```typescript
// In VideoPlayer class
dynamicRequestHeaders: Record<string, string>;

// In VideoSource type
enableDynamicHeaders?: boolean;
```

---

### Android

#### `android/src/main/java/expo/modules/video/utils/DynamicHeaderInterceptor.kt` (NUOVO)

OkHttp Interceptor che inietta headers dinamici in ogni richiesta HTTP.

```kotlin
interface DynamicHeaderProvider {
  fun getDynamicHeaders(): Map<String, String>
}

class DynamicHeaderInterceptor(
  private val headerProviderRef: WeakReference<DynamicHeaderProvider>
) : Interceptor {
  override fun intercept(chain: Interceptor.Chain): Response {
    val headers = headerProviderRef.get()?.getDynamicHeaders() ?: emptyMap()
    // ... inject headers
  }
}
```

#### `android/src/main/java/expo/modules/video/utils/DataSourceUtils.kt`

**Modifiche:**

- `buildBaseDataSourceFactory()` - aggiunto parametro `dynamicHeaderProvider`
- `buildOkHttpDataSourceFactory()` - aggiunge interceptor quando `enableDynamicHeaders=true`
- `buildCacheDataSourceFactory()` - passa provider attraverso la chain
- `buildExpoVideoMediaSource()` - passa provider attraverso la chain

#### `android/src/main/java/expo/modules/video/records/VideoSource.kt`

**Aggiunte:**

```kotlin
@Field var enableDynamicHeaders: Boolean = false

fun toMediaSource(context: Context, dynamicHeaderProvider: DynamicHeaderProvider? = null)
```

#### `android/src/main/java/expo/modules/video/player/VideoPlayer.kt`

**Aggiunte:**

```kotlin
class VideoPlayer(...) : ..., DynamicHeaderProvider {

  // Thread-safe storage
  private val _dynamicRequestHeaders = AtomicReference<Map<String, String>>(emptyMap())

  var dynamicRequestHeaders: Map<String, String>
    get() = _dynamicRequestHeaders.get()
    set(value) = _dynamicRequestHeaders.set(value)

  // DynamicHeaderProvider implementation
  override fun getDynamicHeaders(): Map<String, String> = dynamicRequestHeaders
}
```

**Modifiche:**

- `prepare()` - passa `this` come DynamicHeaderProvider a `toMediaSource()`

#### `android/src/main/java/expo/modules/video/VideoModule.kt`

**Aggiunte:**

```kotlin
Property("dynamicRequestHeaders")
  .get { ref: VideoPlayer -> ref.dynamicRequestHeaders }
  .set { ref: VideoPlayer, headers: Map<String, String>? ->
    ref.dynamicRequestHeaders = headers ?: emptyMap()
  }
```

---

### iOS

#### `ios/Records/VideoSource.swift`

**Aggiunte:**

```swift
@Field
var enableDynamicHeaders: Bool = false
```

#### `ios/Cache/ResourceLoaderDelegate.swift`

**Aggiunte:**

```swift
private let dynamicHeadersProvider: (() -> [String: String]?)?

init(..., dynamicHeadersProvider: (() -> [String: String]?)? = nil)
```

**Modifiche:**

- `createUrlRequest()` - inietta headers dinamici da `dynamicHeadersProvider()`

```swift
private func createUrlRequest() -> URLRequest {
  var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)

  // Static headers
  self.urlRequestHeaders?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

  // Dynamic headers (CMCD)
  if let dynamicHeaders = dynamicHeadersProvider?() {
    dynamicHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
  }

  return request
}
```

#### `ios/VideoAsset.swift`

**Aggiunte:**

```swift
private let usesDynamicHeaders: Bool
internal weak var dynamicHeaderProvider: VideoPlayer?
```

**Modifiche:**

- `init()` - usa ResourceLoaderDelegate quando `enableDynamicHeaders=true` (anche senza caching)
- Passa closure per headers dinamici a ResourceLoaderDelegate

#### `ios/VideoPlayer.swift`

**Aggiunte:**

```swift
// Thread-safe storage
private let dynamicHeadersLock = NSLock()
private var _dynamicRequestHeaders: [String: String] = [:]

var dynamicRequestHeaders: [String: String] {
  get {
    dynamicHeadersLock.lock()
    defer { dynamicHeadersLock.unlock() }
    return _dynamicRequestHeaders
  }
  set {
    dynamicHeadersLock.lock()
    defer { dynamicHeadersLock.unlock() }
    _dynamicRequestHeaders = newValue
  }
}
```

**Modifiche:**

- `replaceCurrentItem(sync)` - passa `self` a VideoPlayerItem
- `replaceCurrentItem(async)` - passa `self` a videoSourceLoader.load()

#### `ios/VideoPlayerItem.swift`

**Modifiche:**

- `init(videoSource:videoPlayer:)` - accetta VideoPlayer, lo passa a VideoAsset
- `init(videoSource:urlOverride:videoPlayer:)` - stesso

#### `ios/VideoSourceLoader.swift`

**Modifiche:**

- `load(videoSource:videoPlayer:)` - accetta e passa VideoPlayer
- `loadImpl(videoSource:videoPlayer:)` - passa a VideoPlayerItem

#### `ios/VideoModule.swift`

**Aggiunte:**

```swift
Property("dynamicRequestHeaders") { player -> [String: String] in
  return player.dynamicRequestHeaders
}
.set { player, headers in
  player.dynamicRequestHeaders = headers
}
```

---

## Thread Safety

### Android
- `AtomicReference<Map<String, String>>` per accesso thread-safe
- `WeakReference` nel DynamicHeaderInterceptor per evitare memory leaks

### iOS
- `NSLock` per sincronizzare accesso alla property
- `weak var` per riferimento a VideoPlayer in VideoAsset

---

## Limitazioni Note

1. **iOS senza cache**: Quando `enableDynamicHeaders=true`, viene forzato l'uso di `ResourceLoaderDelegate` anche senza caching. Questo è necessario perché `AVURLAssetHTTPHeaderFieldsKey` non supporta headers dinamici.

2. **HLS Only (iOS)**: Su iOS, gli headers dinamici funzionano solo con contenuti HLS quando viene usato il ResourceLoaderDelegate.

3. **Performance**: Gli headers vengono letti ad ogni richiesta chunk. L'uso di `AtomicReference`/`NSLock` minimizza l'overhead.

---

## Esempio di Utilizzo

```typescript
import { useVideoPlayer, VideoView } from 'expo-video';
import { formatCmcdHeaders, generateSessionId } from 'app/utils/cmcd';

const sessionId = generateSessionId();

const player = useVideoPlayer({
  uri: 'https://example.com/video.m3u8',
  enableDynamicHeaders: true,
});

// Aggiornare CMCD headers su ogni timeUpdate
player.addListener('timeUpdate', (event) => {
  const bufferLength = (player.bufferedPosition - player.currentTime) * 1000;

  player.dynamicRequestHeaders = formatCmcdHeaders({
    bl: Math.max(0, bufferLength), // buffer length in ms
    sid: sessionId,
    cid: 'content-123',
    sf: 'h', // HLS
    st: 'v', // VOD
    v: 1,
  });
});
```

---

## Test

### Con Charles Proxy

1. Avviare Charles Proxy
2. Configurare proxy sul device/simulatore
3. Riprodurre video con `enableDynamicHeaders: true`
4. Verificare nelle richieste chunk:
   - `CMCD-Request: bl=...` (cambia tra richieste)
   - `CMCD-Session: sid=...,cid=...,sf=h,st=v,v=1`

### Verifiche

- [ ] Headers presenti nelle richieste manifest
- [ ] Headers presenti nelle richieste chunk
- [ ] `bl` (buffer length) cambia dinamicamente
- [ ] `sid` (session ID) rimane costante per sessione
- [ ] Nessun memory leak dopo stop/replace source
