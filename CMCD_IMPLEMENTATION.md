# CMCD Dynamic Headers Implementation

Questo documento descrive l'implementazione del supporto CMCD (Common Media Client Data) con headers HTTP dinamici per expo-video.

## Overview

CMCD (CTA-5004) è uno standard per comunicare metriche client-side ai CDN tramite HTTP headers.

### API Unificata (React)

Da React l'utilizzo è semplice e identico su entrambe le piattaforme:

```typescript
import { useVideoPlayer, formatCmcdHeaders } from 'expo-video';

// 1. Crea player con enableDynamicHeaders
const player = useVideoPlayer({
  uri: videoUrl,
  enableDynamicHeaders: true,  // ← Attiva CMCD
});

// 2. Aggiorna headers dinamicamente
player.dynamicRequestHeaders = formatCmcdHeaders({
  bl: bufferLengthMs,
  sid: sessionId,
  cid: contentId,
  sf: 'h',  // HLS
  st: 'v',  // VOD
});
```

### Implementazione Nativa

Il layer nativo gestisce tutto automaticamente:

| Piattaforma | Implementazione |
|-------------|-----------------|
| **iOS** | Proxy HTTP locale (Network.framework) - avviato automaticamente |
| **Android** | OkHttp Interceptor |

```
┌───────────────────────────────────────────────────────────────┐
│                    React (API Unificata)                      │
│  enableDynamicHeaders: true + player.dynamicRequestHeaders    │
├───────────────────────────────────────────────────────────────┤
│         iOS                    │         Android              │
├────────────────────────────────┼──────────────────────────────┤
│  VideoPlayer rileva            │  VideoPlayer rileva          │
│  enableDynamicHeaders=true     │  enableDynamicHeaders=true   │
│           ↓                    │           ↓                  │
│  Avvia CMCDProxy auto          │  Attiva OkHttp Interceptor   │
│  Trasforma URL → proxy URL     │           ↓                  │
│           ↓                    │  Interceptor legge           │
│  Proxy legge                   │  dynamicRequestHeaders       │
│  dynamicRequestHeaders         │  e inietta headers           │
│  e inietta headers             │                              │
└────────────────────────────────┴──────────────────────────────┘
```

---

## Compatibilità

| Caratteristica | iOS | Android |
|---------------|-----|---------|
| **HLS** | ✅ | ✅ |
| **DASH** | ✅ | ✅ |
| **DRM (FairPlay/Nagra)** | ✅ | ✅ |
| **Token Auth (Akamai)** | ✅ | ✅ |
| **Live Streaming** | ✅ | ✅ |

---

## Approccio 1: CMCD Proxy (Consigliato)

### Architettura

```
┌─────────────┐     ┌──────────────────────┐     ┌─────────────┐
│   Player    │────▶│   localhost:PORT     │────▶│     CDN     │
│  (AVPlayer/ │     │   /proxy?url=...     │     │             │
│  ExoPlayer) │     │   + CMCD Headers     │     │             │
└─────────────┘     └──────────────────────┘     └─────────────┘
```

Il proxy:
1. Avvia un server HTTP locale su porta random
2. Intercetta tutte le richieste video
3. Aggiunge headers CMCD dinamici
4. Riscrive URL nei manifest HLS per usare il proxy
5. Inoltra al CDN originale

### Utilizzo

```typescript
import {
  useVideoPlayer,
  VideoView,
  CMCDProxy,
  formatCmcdHeaders,
  generateSessionId
} from 'expo-video';

// 1. Avvia il proxy
await CMCDProxy.start();
console.log('Proxy running on port:', CMCDProxy.getPort());

// 2. Crea URL proxy per il video
const originalUrl = 'https://cdn.example.com/video.m3u8';
const proxyUrl = CMCDProxy.createProxyUrl(originalUrl);

// 3. Usa il player con URL proxy
const player = useVideoPlayer({ uri: proxyUrl });

// 4. Genera session ID stabile
const sessionId = generateSessionId();

// 5. Aggiorna headers CMCD dinamicamente
player.addListener('timeUpdate', (event) => {
  const bufferLength = (player.bufferedPosition - player.currentTime) * 1000;

  player.dynamicRequestHeaders = formatCmcdHeaders({
    bl: Math.max(0, bufferLength), // buffer length in ms
    sid: sessionId,
    cid: 'content-123',
    sf: 'h', // HLS
    st: 'v', // VOD (o 'l' per live)
    v: 1,
  });
});

// 6. Ferma il proxy quando non serve più
CMCDProxy.stop();
```

### API Reference

#### CMCDProxy

```typescript
// Avvia il proxy
await CMCDProxy.start(): Promise<void>;

// Ferma il proxy
CMCDProxy.stop(): void;

// Stato del proxy
CMCDProxy.isRunning(): boolean;
CMCDProxy.getPort(): number;
CMCDProxy.getBaseUrl(): string | null;

// URL helpers
CMCDProxy.createProxyUrl(originalUrl: string): string | null;
CMCDProxy.extractOriginalUrl(proxyUrl: string): string | null;

// Headers statici (es. authorization)
CMCDProxy.setStaticHeaders(headers: Record<string, string>): void;
```

#### formatCmcdHeaders

```typescript
interface CmcdData {
  // CMCD-Request
  bl?: number;   // Buffer length (ms)
  mtp?: number;  // Measured throughput (kbps)
  dl?: number;   // Deadline (ms)

  // CMCD-Object
  br?: number;   // Encoded bitrate (kbps)
  d?: number;    // Object duration (ms)
  ot?: 'v' | 'a' | 'm' | 'i' | 'c' | 'tt' | 'k' | 'o';
  tb?: number;   // Top bitrate (kbps)

  // CMCD-Session
  sid?: string;  // Session ID
  cid?: string;  // Content ID
  sf?: 'd' | 'h' | 's' | 'o';  // Stream format
  st?: 'v' | 'l';              // Stream type
  v?: number;    // CMCD version

  // CMCD-Status
  bs?: boolean;  // Buffer starvation
  rtp?: number;  // Requested max throughput
  su?: boolean;  // Startup
}

formatCmcdHeaders(data: CmcdData): Record<string, string>;
```

### File Implementati (Proxy)

#### iOS

- `ios/Proxy/CMCDProxy.swift` - Server HTTP locale usando Network.framework (NWListener)
- `ios/Proxy/CMCDProxyManager.swift` - Singleton manager

**CMCDProxy.swift** implementa:
- Server TCP con `NWListener`
- Parsing richieste HTTP
- Proxy con `URLSession`
- HLS manifest URL rewriting
- Injection headers CMCD

#### Android

- `android/.../proxy/CMCDProxy.kt` - Server HTTP locale con ServerSocket + OkHttp
- `android/.../proxy/CMCDProxyManager.kt` - Singleton manager

**CMCDProxy.kt** implementa:
- Server TCP con `ServerSocket`
- Thread pool per connessioni concorrenti
- Proxy con `OkHttpClient`
- HLS manifest URL rewriting
- Injection headers CMCD

#### TypeScript

- `src/CMCDProxy.ts` - API TypeScript, helper `formatCmcdHeaders`, `generateSessionId`

#### VideoModule

Funzioni esposte:
- `startCMCDProxy()` - Avvia proxy
- `stopCMCDProxy()` - Ferma proxy
- `isCMCDProxyRunning()` - Stato
- `getCMCDProxyPort()` - Porta
- `getCMCDProxyBaseUrl()` - Base URL
- `createCMCDProxyUrl(url)` - Crea URL proxy
- `extractCMCDOriginalUrl(url)` - Estrae URL originale
- `setCMCDProxyStaticHeaders(headers)` - Headers statici

---

## Approccio 2: OkHttp Interceptor (Solo Android)

Questo approccio usa un OkHttp Interceptor per iniettare headers dinamici direttamente nelle richieste HTTP. Funziona solo su Android.

> **Nota**: Su iOS usa esclusivamente il Proxy approach. L'implementazione ResourceLoaderDelegate è stata rimossa per incompatibilità con DASH e DRM.

### Utilizzo (Android)

```typescript
const player = useVideoPlayer({
  uri: 'https://example.com/video.m3u8',
  enableDynamicHeaders: true, // Abilita OkHttp Interceptor (solo Android)
});

// Aggiorna headers dinamicamente
player.dynamicRequestHeaders = {
  'CMCD-Request': 'bl=2000',
  'CMCD-Session': 'sid="abc123"',
};
```

### Come Funziona (Android)

1. `VideoSource` con `enableDynamicHeaders: true` attiva l'interceptor
2. `DynamicHeaderInterceptor` intercetta ogni richiesta HTTP
3. Legge `dynamicRequestHeaders` dal `VideoPlayer` tramite `DynamicHeaderProvider`
4. Aggiunge gli headers alla richiesta
5. Inoltra al CDN originale

### File Implementati (OkHttp Interceptor)

#### TypeScript
- `src/VideoPlayer.types.ts` - `enableDynamicHeaders`, `dynamicRequestHeaders`

#### Android
- `android/.../utils/DynamicHeaderInterceptor.kt` - OkHttp Interceptor
- `android/.../utils/DataSourceUtils.kt` - Integrazione interceptor
- `android/.../records/VideoSource.kt` - Campo `enableDynamicHeaders`
- `android/.../player/VideoPlayer.kt` - Proprietà `dynamicRequestHeaders`

---

## Thread Safety

### Proxy
- **iOS**: `DispatchQueue` dedicata per il server, `connectionsLock` per array connessioni
- **Android**: `ExecutorService` con thread pool, `AtomicReference` per headers

### dynamicRequestHeaders
- **iOS**: `NSLock` per sincronizzazione lettura/scrittura
- **Android**: `AtomicReference<Map>` per accesso atomico

### Memory Management
- `WeakReference` usato ovunque per evitare memory leaks quando il player viene distrutto

---

## Esempio Completo con Proxy

```typescript
import { useEffect, useRef } from 'react';
import {
  useVideoPlayer,
  VideoView,
  CMCDProxy,
  formatCmcdHeaders,
  generateSessionId
} from 'expo-video';
import { useEventListener } from 'expo';

export function VideoPlayerWithCMCD({ videoUrl }: { videoUrl: string }) {
  const sessionId = useRef(generateSessionId());
  const proxyStarted = useRef(false);

  // Avvia proxy al mount
  useEffect(() => {
    const startProxy = async () => {
      if (!CMCDProxy.isRunning()) {
        await CMCDProxy.start();
        proxyStarted.current = true;
      }
    };
    startProxy();

    return () => {
      if (proxyStarted.current) {
        CMCDProxy.stop();
      }
    };
  }, []);

  // Crea URL proxy
  const proxyUrl = CMCDProxy.isRunning()
    ? CMCDProxy.createProxyUrl(videoUrl)
    : null;

  // Crea player
  const player = useVideoPlayer(
    proxyUrl ? { uri: proxyUrl } : null
  );

  // Aggiorna CMCD headers
  useEventListener(player, 'timeUpdate', (event) => {
    if (!player) return;

    const bufferMs = Math.max(0,
      (player.bufferedPosition - event.currentTime) * 1000
    );

    player.dynamicRequestHeaders = formatCmcdHeaders({
      bl: bufferMs,
      sid: sessionId.current,
      cid: videoUrl,
      sf: 'h',
      st: player.isLive ? 'l' : 'v',
      v: 1,
    });
  });

  if (!player) return null;

  return <VideoView player={player} style={{ flex: 1 }} />;
}
```

---

## Test e Verifica

### Con Charles Proxy

1. Avvia Charles Proxy
2. Configura proxy sul device/simulatore
3. Riproduci video con CMCD
4. Verifica headers nelle richieste:
   - `CMCD-Request: bl=...` (cambia tra richieste)
   - `CMCD-Session: sid=...,cid=...,sf=h,st=v`

### Checklist

- [ ] Proxy si avvia correttamente
- [ ] URL proxy generato correttamente
- [ ] Video riproduce tramite proxy
- [ ] Headers CMCD presenti nelle richieste manifest
- [ ] Headers CMCD presenti nelle richieste chunk
- [ ] `bl` (buffer length) cambia dinamicamente
- [ ] `sid` (session ID) rimane costante per sessione
- [ ] Manifest HLS riscritti correttamente (URL proxy)
- [ ] Live streaming funziona (manifest refresh)
- [ ] Nessun memory leak dopo stop/replace
- [ ] Proxy si ferma correttamente

---

## Changelog

### v3.0.15-cmcd.4
- **API Unificata**: `enableDynamicHeaders: true` funziona identico su iOS e Android
- **iOS**: Proxy avviato automaticamente dal layer nativo quando `enableDynamicHeaders=true`
- Non serve più gestire il proxy da React/TypeScript su iOS
- `VideoPlayer.swift` processa automaticamente la source e trasforma l'URL
- Documentazione aggiornata con nuova architettura

### v3.0.15-cmcd.3
- **BREAKING (iOS)**: Rimosso approccio ResourceLoaderDelegate per iOS
- iOS usa ora esclusivamente il Proxy approach
- Rimosso HLS URL rewriting da `ResourceLoaderDelegate.swift`
- Rimosso `dynamicHeadersProvider` e `dynamicHeaderProvider` da iOS
- Pulito `VideoAsset.swift`, `VideoPlayerItem.swift`, `VideoSourceLoader.swift`
- Android mantiene supporto OkHttp Interceptor con `enableDynamicHeaders`

### v3.0.15-cmcd.2
- **NEW**: Aggiunto approccio Proxy per supporto universale
- Proxy supporta HLS, DASH, DRM
- API `CMCDProxy` con start/stop/createProxyUrl
- Helper `formatCmcdHeaders` e `generateSessionId` esportati da expo-video
- Server HTTP nativo su iOS (Network.framework) e Android (ServerSocket)

### v3.0.15-cmcd.1
- Implementazione iniziale con ResourceLoaderDelegate (iOS) e OkHttp Interceptor (Android)
- Supporto HLS con URL rewriting (iOS)
- OkHttp Interceptor per Android
- Proprietà `dynamicRequestHeaders` su VideoPlayer
- Campo `enableDynamicHeaders` su VideoSource
