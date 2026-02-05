package expo.modules.video

import android.content.Context
import android.content.pm.ApplicationInfo
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import expo.modules.video.records.VideoSource
import expo.modules.video.utils.DynamicHeaderInterceptor
import expo.modules.video.utils.DynamicHeaderProvider
import okhttp3.OkHttpClient
import java.lang.ref.WeakReference

@OptIn(UnstableApi::class)
fun buildBaseDataSourceFactory(
  context: Context,
  videoSource: VideoSource,
  dynamicHeaderProvider: DynamicHeaderProvider? = null
): DataSource.Factory {
  return if (videoSource.uri?.scheme?.startsWith("http") == true) {
    buildOkHttpDataSourceFactory(context, videoSource, dynamicHeaderProvider)
  } else {
    DefaultDataSource.Factory(context)
  }
}

@OptIn(UnstableApi::class)
fun buildOkHttpDataSourceFactory(
  context: Context,
  videoSource: VideoSource,
  dynamicHeaderProvider: DynamicHeaderProvider? = null
): OkHttpDataSource.Factory {
  val clientBuilder = OkHttpClient.Builder()

  // Add dynamic header interceptor if enabled and provider is available
  if (videoSource.enableDynamicHeaders && dynamicHeaderProvider != null) {
    clientBuilder.addInterceptor(
      DynamicHeaderInterceptor(WeakReference(dynamicHeaderProvider))
    )
  }

  val client = clientBuilder.build()

  // If the application name has ANY non-ASCII characters, we need to strip them out. This is because using non-ASCII characters
  // in the User-Agent header can cause issues with getting the media to play.
  val applicationName = getApplicationName(context).filter { it.code in 0..127 }

  val defaultUserAgent = Util.getUserAgent(context, applicationName)

  return OkHttpDataSource.Factory(client).apply {
    val headers = videoSource.headers
    headers?.takeIf { it.isNotEmpty() }?.let {
      setDefaultRequestProperties(it)
    }
    val userAgent = headers?.get("User-Agent") ?: defaultUserAgent
    setUserAgent(userAgent)
  }
}

@OptIn(UnstableApi::class)
fun buildCacheDataSourceFactory(
  context: Context,
  videoSource: VideoSource,
  dynamicHeaderProvider: DynamicHeaderProvider? = null
): DataSource.Factory {
  return CacheDataSource.Factory().apply {
    setCache(VideoManager.cache.instance)
    setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    setUpstreamDataSourceFactory(buildBaseDataSourceFactory(context, videoSource, dynamicHeaderProvider))
  }
}

fun buildMediaSourceFactory(context: Context, dataSourceFactory: DataSource.Factory): MediaSource.Factory {
  return DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory)
}

@OptIn(UnstableApi::class)
fun buildExpoVideoMediaSource(
  context: Context,
  videoSource: VideoSource,
  dynamicHeaderProvider: DynamicHeaderProvider? = null
): MediaSource {
  val dataSourceFactory = if (videoSource.useCaching) {
    buildCacheDataSourceFactory(context, videoSource, dynamicHeaderProvider)
  } else {
    buildBaseDataSourceFactory(context, videoSource, dynamicHeaderProvider)
  }
  val mediaSourceFactory = buildMediaSourceFactory(context, dataSourceFactory)
  val mediaItem = videoSource.toMediaItem(context)
  return mediaSourceFactory.createMediaSource(mediaItem)
}

private fun getApplicationName(context: Context): String {
  val applicationInfo: ApplicationInfo = context.applicationInfo
  val stringId = applicationInfo.labelRes
  return if (stringId == 0) applicationInfo.nonLocalizedLabel.toString() else context.getString(stringId)
}
