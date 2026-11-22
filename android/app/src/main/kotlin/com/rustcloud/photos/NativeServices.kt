package com.rustcloud.photos

import android.accounts.Account
import android.accounts.AccountManager
import android.accounts.AuthenticatorException
import android.accounts.OperationCanceledException
import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.security.KeyStore
import java.security.cert.X509Certificate

/**
 * The part of channel `com.rustcloud.photos/native` that needs no screen, so the backup's
 * background engine (BackupWorker) has it too: `accounts`, `accountToken`, `deviceName`,
 * `userCertificates`. Without an activity, a token that needs the user (rc-client logged out,
 * consent) is answered with `{error: "login"}` instead of showing the client's screen.
 */
class NativeServices(private val context: Context, private val activity: Activity?) {
  /** False if [call] is not one of these. */
  fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
    when (call.method) {
      "accounts" -> result.success(AccountManager.get(context).getAccountsByType(ACCOUNT_TYPE).map { it.name })
      "accountToken" -> accountToken(call.argument<String>("name")!!, result)
      "deviceName" -> result.success(deviceName())
      "userCertificates" -> result.success(userCertificates())
      else -> return false
    }
    return true
  }

  private fun accountToken(name: String, result: MethodChannel.Result) {
    val account = Account(name, ACCOUNT_TYPE)
    val callback = android.accounts.AccountManagerCallback<android.os.Bundle> { future ->
      val reply: Map<String, Any?> = try {
        val b = future.result
        val token = b.getString(AccountManager.KEY_AUTHTOKEN)
        if (token == null) {
          mapOf("error" to "login", "message" to (b.getString(AccountManager.KEY_ERROR_MESSAGE) ?: ""))
        } else {
          mapOf(
            "token" to token,
            "server" to b.getString("server"),
            "expiresAt" to b.getLong("expiresAt", 0L),
          )
        }
      } catch (e: OperationCanceledException) {
        mapOf("error" to "cancelled", "message" to (e.message ?: ""))
      } catch (e: IOException) {
        mapOf("error" to "network", "message" to (e.message ?: ""))
      } catch (e: AuthenticatorException) {
        // The client answers ERROR_CODE_NETWORK_ERROR when it can't reach the server.
        val network = e.message?.contains("network", ignoreCase = true) == true
        mapOf("error" to if (network) "network" else "failed", "message" to (e.message ?: ""))
      } catch (e: Exception) {
        mapOf("error" to "failed", "message" to e.toString())
      }
      result.success(reply)
    }
    val manager = AccountManager.get(context)
    val main = Handler(Looper.getMainLooper())
    if (activity != null) {
      // With an activity, AccountManager itself shows the client's login or consent screen
      // (KEY_INTENT) and answers when the user is done.
      manager.getAuthToken(account, TOKEN_TYPE, null, activity, callback, main)
    } else {
      // In the background: no screen; a reply with KEY_INTENT has no token → "login".
      manager.getAuthToken(account, TOKEN_TYPE, null, false, callback, main)
    }
  }

  private fun deviceName(): String {
    val model = Build.MODEL ?: "Android"
    val maker = Build.MANUFACTURER ?: ""
    return if (maker.isNotEmpty() && !model.startsWith(maker, ignoreCase = true)) {
      "${maker.replaceFirstChar { it.uppercase() }} $model"
    } else {
      model
    }
  }

  /**
   * The CA certificates the user installed (DER). `AndroidCAStore` lists the system's and the
   * user's; the user's have aliases `user:…`. Dart trusts the system's by itself.
   */
  private fun userCertificates(): List<ByteArray> = try {
    val store = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
    store.aliases().toList()
      .filter { it.startsWith("user:") }
      .mapNotNull { (store.getCertificate(it) as? X509Certificate)?.encoded }
  } catch (e: Exception) {
    emptyList()
  }

  companion object {
    const val CHANNEL = "com.rustcloud.photos/native"
    const val ACCOUNT_TYPE = "com.rustcloud.account"
    const val TOKEN_TYPE = "api"
  }
}
