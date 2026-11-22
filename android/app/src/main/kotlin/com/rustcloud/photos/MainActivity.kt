package com.rustcloud.photos

import android.accounts.AccountManager
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The app's one activity, and the native side of channel `com.rustcloud.photos/native`:
 *
 * - `browserLogin(url)`: opens the server's login page in a Custom Tab; answers the URI the
 *   browser returned to (`com.rustcloud.photos:/callback?…`), or null if the user came back
 *   without finishing.
 * - `accounts()`: names of the RustCloud accounts this app may see (rc-client's phone account,
 *   see rc-client/README.md "Аккаунт телефона"). Apps signed with the client's key see them
 *   right away.
 * - `chooseAccount()`: the system's account picker, for when [accounts] is empty because the
 *   app is signed by another key; answers the chosen name or null.
 * - `accountToken(name)`: a 10-minute access token from rc-client:
 *   `{token, server, expiresAt}` or `{error: "network" | "login" | "cancelled" | "failed", message}`.
 * - `deviceName()`: the phone's model, shown in the server's list of sessions.
 * - `userCertificates()`: the CA certificates the user installed (DER), for Dart to trust.
 */
class MainActivity : FlutterActivity() {
  private var login: MethodChannel.Result? = null

  /** The tab was opened and the activity went to the background since. */
  private var loginLeft = false

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler(::handle)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PhoneMedia.CHANNEL).setMethodCallHandler(media::handle)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Backup.CHANNEL).setMethodCallHandler { call, result ->
      Backup.handle(applicationContext, call, result)
    }
  }

  /** The phone's photos (PhoneMedia.kt). */
  private val media by lazy { PhoneMedia(this, this) }

  /** Accounts, certificates (NativeServices.kt). */
  private val services by lazy { NativeServices(this, this) }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    media.onPermissions(requestCode)
  }

  private fun handle(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "browserLogin" -> browserLogin(call.argument<String>("url")!!, result)
      "chooseAccount" -> chooseAccount(result)
      else -> if (!services.handle(call, result)) result.notImplemented()
    }
  }

  // ── Browser login ───────────────────────────────────────────────────

  private fun browserLogin(url: String, result: MethodChannel.Result) {
    login?.success(null) // an older attempt the user abandoned
    login = result
    loginLeft = false
    try {
      CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(this, Uri.parse(url))
    } catch (e: Exception) {
      // No browser with Custom Tabs: any browser will do.
      try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
      } catch (e2: Exception) {
        login = null
        result.error("NO_BROWSER", e2.toString(), null)
      }
    }
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    val uri = intent.data
    if (uri != null && uri.scheme == CALLBACK_SCHEME) {
      login?.success(uri.toString())
      login = null
    }
  }

  override fun onPause() {
    super.onPause()
    if (login != null) loginLeft = true
  }

  override fun onResume() {
    super.onResume()
    // Back from the tab without the redirect (onNewIntent comes before onResume): the user
    // closed it. A short delay lets a late redirect still win.
    if (login != null && loginLeft) {
      Handler(Looper.getMainLooper()).postDelayed({
        if (login != null && loginLeft) {
          login?.success(null)
          login = null
        }
      }, 500)
    }
  }

  // ── rc-client's phone account ───────────────────────────────────────

  private var choosing: MethodChannel.Result? = null

  private fun chooseAccount(result: MethodChannel.Result) {
    choosing?.success(null)
    choosing = result
    @Suppress("DEPRECATION")
    val intent = AccountManager.newChooseAccountIntent(
      null, null, arrayOf(ACCOUNT_TYPE), null, null, null, null,
    )
    startActivityForResult(intent, CHOOSE_ACCOUNT)
  }

  @Deprecated("Deprecated in Java")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    @Suppress("DEPRECATION")
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode == CHOOSE_ACCOUNT) {
      choosing?.success(if (resultCode == RESULT_OK) data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME) else null)
      choosing = null
    }
  }

  companion object {
    const val CHANNEL = "com.rustcloud.photos/native"
    const val CALLBACK_SCHEME = "com.rustcloud.photos"
    const val ACCOUNT_TYPE = NativeServices.ACCOUNT_TYPE
    const val CHOOSE_ACCOUNT = 7101
  }
}
