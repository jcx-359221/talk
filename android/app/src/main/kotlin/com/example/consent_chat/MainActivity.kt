package com.example.consent_chat

import android.provider.Settings
import android.os.Build
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "consent_chat/device_identity"
        ).setMethodCallHandler { call, result ->
            if (call.method == "androidId") {
                result.success(
                    Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
                )
            } else if (call.method == "networkTimeMillis") {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    result.error(
                        "network_time_unavailable",
                        "Android 13 or later is required for system network time.",
                        null
                    )
                } else {
                    try {
                        result.success(SystemClock.currentNetworkTimeClock().millis())
                    } catch (error: Exception) {
                        result.error(
                            "network_time_unavailable",
                            "Android system network time is unavailable.",
                            error.message
                        )
                    }
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
