package com.rustcloud.photos

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext

/**
 * When the backup runs (WorkManager), channel `com.rustcloud.photos/backup` of the app:
 *
 * - `schedule({enabled, wifiOnly, charging})`: every 15 minutes and soon after a new photo or
 *   video (a content URI trigger), under those conditions; `enabled: false` stops it all.
 * - `syncNow()`: a run right away (needs only a network).
 *
 * A run is [BackupWorker]: a Flutter engine without a screen runs `backupMain` (lib/main.dart),
 * which does the work in Dart and says how it ended: `done`; `network` (lost: run again once
 * there is a network), `wifi` (videos wait for Wi-Fi), `later` (the server asked to wait).
 */
object Backup {
  const val CHANNEL = "com.rustcloud.photos/backup"
  private const val PREFS = "backup"
  private const val PERIODIC = "backup-periodic"
  private const val MEDIA = "backup-media"
  private const val NOW = "backup-now"
  private const val RETRY = "backup-retry"

  fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "schedule" -> {
        schedule(
          context,
          enabled = call.argument<Boolean>("enabled") ?: false,
          wifiOnly = call.argument<Boolean>("wifiOnly") ?: false,
          charging = call.argument<Boolean>("charging") ?: false,
        )
        result.success(null)
      }
      "syncNow" -> {
        syncNow(context)
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  fun schedule(context: Context, enabled: Boolean, wifiOnly: Boolean, charging: Boolean) {
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .putBoolean("enabled", enabled)
      .putBoolean("wifiOnly", wifiOnly)
      .putBoolean("charging", charging)
      .apply()
    val wm = WorkManager.getInstance(context)
    if (!enabled) {
      for (name in listOf(PERIODIC, MEDIA, NOW, RETRY)) wm.cancelUniqueWork(name)
      return
    }
    val periodic = PeriodicWorkRequestBuilder<BackupWorker>(15, TimeUnit.MINUTES)
      .setConstraints(constraints(context).build())
      .build()
    wm.enqueueUniquePeriodicWork(PERIODIC, ExistingPeriodicWorkPolicy.UPDATE, periodic)
    // New conditions apply to a waiting trigger too.
    wm.enqueueUniqueWork(MEDIA, ExistingWorkPolicy.REPLACE, mediaRequest(context))
  }

  private fun enabled(context: Context) =
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("enabled", false)

  private fun constraints(context: Context, unmetered: Boolean = false): Constraints.Builder {
    val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val wifi = unmetered || prefs.getBoolean("wifiOnly", false)
    return Constraints.Builder()
      .setRequiredNetworkType(if (wifi) NetworkType.UNMETERED else NetworkType.CONNECTED)
      .setRequiresCharging(prefs.getBoolean("charging", false))
  }

  /** A run soon after the phone gets a new photo or video. Fires once: armed again after each run. */
  fun watchMedia(context: Context) {
    if (enabled(context)) enqueueOnce(context, MEDIA, mediaRequest(context))
  }

  private fun mediaRequest(context: Context): OneTimeWorkRequest {
    val c = constraints(context)
      .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
      .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
      .setTriggerContentUpdateDelay(Duration.ofSeconds(10))
      .setTriggerContentMaxDelay(Duration.ofMinutes(2))
      .build()
    return OneTimeWorkRequestBuilder<BackupWorker>().setConstraints(c).build()
  }

  fun syncNow(context: Context) {
    val c = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
    val request = OneTimeWorkRequestBuilder<BackupWorker>()
      .setConstraints(c)
      .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
      .build()
    enqueueOnce(context, NOW, request)
  }

  /** Once the network is back (or Wi-Fi, for videos), after a short pause against flapping. */
  fun retryWhenConnected(context: Context, unmetered: Boolean, delay: Duration = Duration.ofSeconds(30)) {
    val request = OneTimeWorkRequestBuilder<BackupWorker>()
      .setConstraints(constraints(context, unmetered).build())
      .setInitialDelay(delay)
      .build()
    enqueueOnce(context, RETRY, request)
  }

  /**
   * Enqueues [request] under [name] unless one is already waiting there. A running one (maybe
   * the caller itself) gets this one after it, so nothing is cancelled and nothing piles up.
   */
  private fun enqueueOnce(context: Context, name: String, request: OneTimeWorkRequest) {
    val wm = WorkManager.getInstance(context)
    val waiting = try {
      wm.getWorkInfosForUniqueWork(name).get().any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.BLOCKED }
    } catch (e: Exception) {
      false
    }
    if (!waiting) wm.enqueueUniqueWork(name, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
  }
}

/** One backup run: Dart's `backupMain` in an engine of its own. */
class BackupWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
  private val main = Handler(Looper.getMainLooper())

  override suspend fun doWork(): Result {
    // Runs never overlap: two would upload the same files. A trigger that comes meanwhile
    // makes the running one go again when it ends.
    if (!running.compareAndSet(false, true)) {
      again.set(true)
      return Result.success()
    }
    try {
      try {
        setForeground(getForegroundInfo())
      } catch (e: Exception) {
        // Android 12+ may refuse from the background: the run still goes, for up to 10 minutes;
        // what is left continues next time.
      }
      when (withContext(Dispatchers.Main) { runDart() }) {
        "network" -> Backup.retryWhenConnected(applicationContext, unmetered = false)
        "wifi" -> Backup.retryWhenConnected(applicationContext, unmetered = true)
        "later" -> Backup.retryWhenConnected(applicationContext, unmetered = false, delay = Duration.ofMinutes(15))
      }
      return Result.success()
    } finally {
      running.set(false)
      Backup.watchMedia(applicationContext)
      if (again.getAndSet(false)) Backup.syncNow(applicationContext)
    }
  }

  private suspend fun runDart(): String = suspendCancellableCoroutine { cont ->
    val context = applicationContext
    val loader = FlutterInjector.instance().flutterLoader()
    loader.startInitialization(context)
    loader.ensureInitializationComplete(context, null)
    val engine = FlutterEngine(context)
    var destroyed = false
    fun destroy() {
      if (!destroyed) {
        destroyed = true
        engine.destroy()
      }
    }
    val messenger = engine.dartExecutor.binaryMessenger
    val services = NativeServices(context, null)
    MethodChannel(messenger, NativeServices.CHANNEL).setMethodCallHandler { call, result ->
      if (!services.handle(call, result)) result.notImplemented()
    }
    MethodChannel(messenger, PhoneMedia.CHANNEL).setMethodCallHandler(PhoneMedia(context, null)::handle)
    MethodChannel(messenger, Backup.CHANNEL).setMethodCallHandler { call, result -> Backup.handle(context, call, result) }
    MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
      when (call.method) {
        "progress" -> {
          val text = call.argument<String>("text") ?: ""
          val title = call.argument<String>("title") ?: ""
          try {
            setForegroundAsync(foregroundInfo(title, text))
          } catch (e: Exception) {
            // Not in the foreground (see doWork).
          }
          result.success(null)
        }
        "finish" -> {
          result.success(null)
          if (cont.isActive) cont.resume(call.arguments as? String ?: "failed")
          main.post { destroy() }
        }
        else -> result.notImplemented()
      }
    }
    cont.invokeOnCancellation { main.post { destroy() } }
    engine.dartExecutor.executeDartEntrypoint(
      DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backupMain"),
    )
  }

  override suspend fun getForegroundInfo(): ForegroundInfo =
    foregroundInfo(applicationContext.getString(R.string.backup_running), "")

  private fun foregroundInfo(title: String, text: String): ForegroundInfo {
    val context = applicationContext
    val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (nm.getNotificationChannel(NOTIFICATION_CHANNEL) == null) {
      nm.createNotificationChannel(
        NotificationChannel(
          NOTIFICATION_CHANNEL,
          context.getString(R.string.backup_channel),
          NotificationManager.IMPORTANCE_LOW,
        ),
      )
    }
    val notification = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL)
      .setSmallIcon(android.R.drawable.stat_sys_upload)
      .setContentTitle(title.ifEmpty { context.getString(R.string.backup_running) })
      .setContentText(text)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setSilent(true)
      .build()
    return if (Build.VERSION.SDK_INT >= 29) {
      ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    } else {
      ForegroundInfo(NOTIFICATION_ID, notification)
    }
  }

  companion object {
    const val CHANNEL = "com.rustcloud.photos/worker"
    private const val NOTIFICATION_CHANNEL = "backup"
    private const val NOTIFICATION_ID = 7301
    private val running = AtomicBoolean(false)
    private val again = AtomicBoolean(false)
  }
}
