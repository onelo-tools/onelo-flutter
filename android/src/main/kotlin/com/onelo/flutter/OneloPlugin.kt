package com.onelo.flutter

import android.content.Context
import androidx.annotation.NonNull
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext

/**
 * Native Android bridge for the Onelo Flutter SDK's Play Integrity support.
 *
 * Dart (`lib/src/attest.dart`) owns the token lifecycle (caching, HTTP
 * exchange with `/api/sdk/auth/play-integrity`) — mirrors the iOS App Attest
 * split in `ios/Classes/OneloPlugin.swift`. This plugin exposes ONLY the two
 * primitives that must run in native Kotlin because they call Google's
 * `StandardIntegrityManager`:
 *
 *   • `prepareIntegrityToken(cloudProjectNumber)` → Boolean (caches the
 *     provider; Google rate-limits preparation to ~5/min, so it's reused)
 *   • `requestIntegrityToken(requestHash)`        → String (a fresh token)
 *
 * `getBundleId` is NOT implemented here (unlike iOS) — Dart already derives
 * the Android package name platform-agnostically via `package_info_plus`
 * (see `auth.dart`'s `_fetchBundleId`), so no native round-trip is needed.
 *
 * Registered on the SAME MethodChannel name (`onelo/attest`) as the iOS
 * plugin — see the comment there for why one shared name lets Dart call a
 * single channel and branch on which methods each platform actually exposes.
 */
class OneloPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    // Dispatchers.Main so `result.success`/`result.error` — which MUST run on
    // the platform thread per Flutter's MethodChannel.Result contract — happen
    // there automatically once a `withContext(Dispatchers.IO)` block returns;
    // only the actual Play Integrity network calls hop to IO. SupervisorJob so
    // one failed call doesn't cancel the scope for the next.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    @Volatile private var preparedFor: Long = 0L
    @Volatile private var tokenProvider: StandardIntegrityTokenProvider? = null

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "onelo/attest")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "prepareIntegrityToken" -> prepareIntegrityToken(call, result)
            "requestIntegrityToken" -> requestIntegrityToken(call, result)
            else -> result.notImplemented()
        }
    }

    /** See `com.onelo.reactnative.OneloAttestModule` (onelo-react-native) and
     *  `com.onelo.android.internal.OneloPlayIntegrity` (onelo-android) — same
     *  Standard API prepare/cache contract, ported here for Flutter. */
    private fun prepareIntegrityToken(call: MethodCall, result: Result) {
        val cloudProjectNumber = (call.argument<Any>("cloudProjectNumber") as? Number)?.toLong() ?: 0L
        if (cloudProjectNumber <= 0L) {
            result.error("integrity_not_configured", "cloudProjectNumber is missing or <= 0", null)
            return
        }
        tokenProvider?.let {
            if (preparedFor == cloudProjectNumber) { result.success(true); return }
        }
        scope.launch {
            try {
                val provider = withContext(Dispatchers.IO) {
                    val manager = IntegrityManagerFactory.createStandard(appContext)
                    manager.prepareIntegrityToken(
                        PrepareIntegrityTokenRequest.builder()
                            .setCloudProjectNumber(cloudProjectNumber)
                            .build()
                    ).await()
                }
                // Back on Dispatchers.Main (the scope's context) — safe to touch
                // shared state and call the platform-thread-bound Result here.
                tokenProvider = provider
                preparedFor = cloudProjectNumber
                result.success(true)
            } catch (e: Exception) {
                result.error("integrity_prepare_failed", e.message, null)
            }
        }
    }

    private fun requestIntegrityToken(call: MethodCall, result: Result) {
        val requestHash = call.argument<String>("requestHash")
        val provider = tokenProvider
        if (provider == null) {
            result.error("integrity_not_prepared", "prepareIntegrityToken must succeed first", null)
            return
        }
        if (requestHash.isNullOrEmpty()) {
            result.error("integrity_bad_argument", "requestHash is missing", null)
            return
        }
        scope.launch {
            try {
                val response = withContext(Dispatchers.IO) {
                    provider.request(
                        StandardIntegrityTokenRequest.builder()
                            .setRequestHash(requestHash)
                            .build()
                    ).await()
                }
                result.success(response.token())
            } catch (e: Exception) {
                result.error("integrity_request_failed", e.message, null)
            }
        }
    }
}
