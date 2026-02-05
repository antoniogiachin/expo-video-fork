package expo.modules.video.utils

import android.util.Log
import okhttp3.Interceptor
import okhttp3.Response
import java.lang.ref.WeakReference

/**
 * Interface for providing dynamic headers to the interceptor.
 * Implemented by VideoPlayer to provide CMCD headers.
 */
interface DynamicHeaderProvider {
  fun getDynamicHeaders(): Map<String, String>
}

/**
 * OkHttp Interceptor that injects dynamic headers into every HTTP request.
 * Used for CMCD (CTA-5004) header injection on video segment requests.
 *
 * The interceptor holds a weak reference to the header provider to avoid
 * memory leaks when the VideoPlayer is destroyed.
 */
class DynamicHeaderInterceptor(
  private val headerProviderRef: WeakReference<DynamicHeaderProvider>
) : Interceptor {

  companion object {
    private const val TAG = "EXPO_VIDEO"
  }

  override fun intercept(chain: Interceptor.Chain): Response {
    val originalRequest = chain.request()
    val provider = headerProviderRef.get()

    Log.d(TAG, "intercept called for: ${originalRequest.url}")
    Log.d(TAG, "provider is null: ${provider == null}")

    val headers = provider?.getDynamicHeaders() ?: emptyMap()
    Log.d(TAG, "headers count: ${headers.size}, headers: $headers")

    if (headers.isEmpty()) {
      Log.d(TAG, "headers empty, proceeding without modification")
      return chain.proceed(originalRequest)
    }

    val newRequest = originalRequest.newBuilder().apply {
      headers.forEach { (key, value) ->
        addHeader(key, value)
      }
    }.build()

    Log.d(TAG, "added ${headers.size} headers to request")
    return chain.proceed(newRequest)
  }
}
