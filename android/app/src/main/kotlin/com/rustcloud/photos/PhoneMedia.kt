package com.rustcloud.photos

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Size
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The phone's photos and videos, channel `com.rustcloud.photos/media`:
 *
 * - `access()` / `requestAccess()`: `"full"`, `"partial"` (Android 14+: only the photos the user
 *   picked) or `"none"`. The request also asks for `ACCESS_MEDIA_LOCATION`, without which Android
 *   strips GPS from the files.
 * - `albums()`: the folders with photos or videos (MediaStore buckets), newest first:
 *   `[{id, name, path, count, cover}]`; `path` is `DCIM/Camera/` (Android 10+, else empty),
 *   `cover` the content URI of the newest item.
 * - `thumbnail(uri, size)`: a JPEG of the item, about `size` px; null if it can't be read.
 * - `items(buckets)`: the photos and videos in those albums, for the backup.
 * - `read(uri, offset, length)`: bytes of one, the original with its location.
 * - `network()`: `"unmetered"`, `"metered"` or `"none"`.
 * - `phoneName()`: the name the user gave the phone (Settings → About), else its model.
 * - `openSettings()`: the app's page in the system settings, for access denied for good.
 */
class PhoneMedia(private val context: Context, private val activity: Activity?) {
  private val io = Executors.newSingleThreadExecutor()
  private val main = Handler(Looper.getMainLooper())
  private var asking: MethodChannel.Result? = null

  fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "access" -> result.success(access())
      "requestAccess" -> requestAccess(result)
      "albums" -> background(result) { albums() }
      "thumbnail" -> {
        val uri = Uri.parse(call.argument<String>("uri")!!)
        val size = call.argument<Int>("size") ?: 256
        background(result) { thumbnail(uri, size) }
      }
      "phoneName" -> result.success(phoneName())
      "items" -> {
        val buckets = call.argument<List<String>>("buckets") ?: emptyList()
        background(result) { items(buckets) }
      }
      "read" -> {
        val uri = Uri.parse(call.argument<String>("uri")!!)
        val offset = (call.argument<Number>("offset") ?: 0).toLong()
        val length = (call.argument<Number>("length") ?: 0).toInt()
        background(result) { read(uri, offset, length) }
      }
      "network" -> result.success(network())
      "openSettings" -> {
        context.startActivity(
          Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  // ── Access ──────────────────────────────────────────────────────────

  private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

  private fun access(): String = when {
    Build.VERSION.SDK_INT >= 33 ->
      when {
        granted(Manifest.permission.READ_MEDIA_IMAGES) && granted(Manifest.permission.READ_MEDIA_VIDEO) -> "full"
        Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> "partial"
        else -> "none"
      }
    granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> "full"
    else -> "none"
  }

  private fun requestAccess(result: MethodChannel.Result) {
    val activity = activity ?: return result.success(access())
    asking?.success(access())
    asking = result
    val wanted = buildList {
      if (Build.VERSION.SDK_INT >= 33) {
        add(Manifest.permission.READ_MEDIA_IMAGES)
        add(Manifest.permission.READ_MEDIA_VIDEO)
        if (Build.VERSION.SDK_INT >= 34) add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
      } else {
        add(Manifest.permission.READ_EXTERNAL_STORAGE)
      }
      if (Build.VERSION.SDK_INT >= 29) add(Manifest.permission.ACCESS_MEDIA_LOCATION)
      // The backup's progress notification.
      if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
    }
    activity.requestPermissions(wanted.toTypedArray(), REQUEST_ACCESS)
  }

  /** From [MainActivity.onRequestPermissionsResult]. */
  fun onPermissions(requestCode: Int) {
    if (requestCode != REQUEST_ACCESS) return
    asking?.success(access())
    asking = null
  }

  // ── Albums ──────────────────────────────────────────────────────────

  private fun albums(): List<Map<String, Any>> {
    val files = MediaStore.Files.getContentUri("external")
    val hasPath = Build.VERSION.SDK_INT >= 29
    val projection = buildList {
      add(MediaStore.Files.FileColumns._ID)
      add(MediaStore.Files.FileColumns.MEDIA_TYPE)
      add(MediaStore.MediaColumns.BUCKET_ID)
      add(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
      if (hasPath) add(MediaStore.MediaColumns.RELATIVE_PATH)
    }.toTypedArray()
    val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (" +
      "${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"
    val order = "${MediaStore.MediaColumns.DATE_ADDED} DESC"
    val found = LinkedHashMap<String, MutableMap<String, Any>>()
    context.contentResolver.query(files, projection, selection, null, order)?.use { c ->
      val id = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
      val type = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
      val bucket = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
      val name = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
      val path = if (hasPath) c.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH) else -1
      while (c.moveToNext()) {
        val key = c.getString(bucket) ?: continue
        val album = found.getOrPut(key) {
          val base = if (c.getInt(type) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
          } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
          }
          mutableMapOf(
            "id" to key,
            "name" to (c.getString(name) ?: ""),
            "path" to (if (path >= 0) c.getString(path) ?: "" else ""),
            "count" to 0,
            "cover" to ContentUris.withAppendedId(base, c.getLong(id)).toString(),
          )
        }
        album["count"] = (album["count"] as Int) + 1
      }
    }
    return found.values.toList()
  }

  /**
   * The photos and videos of [buckets]: `[{id, bucket, name, size, modified, taken, mime, uri}]`;
   * `modified` in seconds (MediaStore's DATE_MODIFIED), `taken` in ms or 0. Items still being
   * written (IS_PENDING, Android 10+) are left for later.
   */
  private fun items(buckets: List<String>): List<Map<String, Any?>> {
    if (buckets.isEmpty()) return emptyList()
    val files = MediaStore.Files.getContentUri("external")
    val projection = arrayOf(
      MediaStore.Files.FileColumns._ID,
      MediaStore.Files.FileColumns.MEDIA_TYPE,
      MediaStore.MediaColumns.BUCKET_ID,
      MediaStore.MediaColumns.DISPLAY_NAME,
      MediaStore.MediaColumns.SIZE,
      MediaStore.MediaColumns.DATE_MODIFIED,
      MediaStore.MediaColumns.DATE_TAKEN,
      MediaStore.MediaColumns.MIME_TYPE,
    )
    val marks = buckets.joinToString(",") { "?" }
    var selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (" +
      "${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})" +
      " AND ${MediaStore.MediaColumns.BUCKET_ID} IN ($marks)"
    if (Build.VERSION.SDK_INT >= 29) selection += " AND ${MediaStore.MediaColumns.IS_PENDING} = 0"
    val out = ArrayList<Map<String, Any?>>()
    context.contentResolver.query(files, projection, selection, buckets.toTypedArray(), null)?.use { c ->
      val id = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
      val type = c.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
      val bucket = c.getColumnIndexOrThrow(MediaStore.MediaColumns.BUCKET_ID)
      val name = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
      val size = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
      val modified = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
      val taken = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
      val mime = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
      while (c.moveToNext()) {
        val video = c.getInt(type) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
        val base = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        val itemId = c.getLong(id)
        out.add(
          mapOf(
            "id" to itemId,
            "bucket" to c.getString(bucket),
            "name" to (c.getString(name) ?: "$itemId"),
            "size" to c.getLong(size),
            "modified" to c.getLong(modified),
            "taken" to (if (c.isNull(taken)) 0L else c.getLong(taken)),
            "mime" to (c.getString(mime) ?: if (video) "video/*" else "image/*"),
            "uri" to ContentUris.withAppendedId(base, itemId).toString(),
          ),
        )
      }
    }
    return out
  }

  /**
   * [length] bytes of the item from [offset] (fewer at its end). The original, with its location:
   * Android strips GPS from EXIF unless asked with setRequireOriginal (and ACCESS_MEDIA_LOCATION).
   */
  private fun read(uri: Uri, offset: Long, length: Int): ByteArray {
    val source = if (Build.VERSION.SDK_INT >= 29 && granted(Manifest.permission.ACCESS_MEDIA_LOCATION)) {
      MediaStore.setRequireOriginal(uri)
    } else {
      uri
    }
    val fd = context.contentResolver.openFileDescriptor(source, "r") ?: throw java.io.FileNotFoundException("$uri")
    fd.use {
      java.io.FileInputStream(it.fileDescriptor).use { input ->
        input.channel.position(offset)
        val buffer = ByteArray(length)
        var got = 0
        while (got < length) {
          val n = input.read(buffer, got, length - got)
          if (n < 0) break
          got += n
        }
        return if (got == length) buffer else buffer.copyOf(got)
      }
    }
  }

  /** `"unmetered"` (Wi-Fi and the like), `"metered"` (mobile data) or `"none"`. */
  private fun network(): String {
    val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
    if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return "none"
    return if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) "unmetered" else "metered"
  }

  private fun thumbnail(uri: Uri, size: Int): ByteArray? {
    val bitmap: Bitmap = try {
      if (Build.VERSION.SDK_INT >= 29) {
        context.contentResolver.loadThumbnail(uri, Size(size, size), null)
      } else {
        val id = ContentUris.parseId(uri)
        @Suppress("DEPRECATION")
        if (uri.toString().contains("/video/")) {
          MediaStore.Video.Thumbnails.getThumbnail(context.contentResolver, id, MediaStore.Video.Thumbnails.MINI_KIND, null)
        } else {
          MediaStore.Images.Thumbnails.getThumbnail(context.contentResolver, id, MediaStore.Images.Thumbnails.MINI_KIND, null)
        } ?: return null
      }
    } catch (e: Exception) {
      return null
    }
    val out = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
    return out.toByteArray()
  }

  private fun phoneName(): String {
    val named = try {
      Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
    } catch (e: Exception) {
      null
    }
    return named?.trim()?.takeIf { it.isNotEmpty() } ?: Build.MODEL ?: "Android"
  }

  private fun <T> background(result: MethodChannel.Result, work: () -> T) {
    io.execute {
      try {
        val value = work()
        main.post { result.success(value) }
      } catch (e: SecurityException) {
        main.post { result.error("NO_ACCESS", e.message, null) }
      } catch (e: Exception) {
        main.post { result.error("FAILED", e.toString(), null) }
      }
    }
  }

  companion object {
    const val CHANNEL = "com.rustcloud.photos/media"
    const val REQUEST_ACCESS = 7201
  }
}
