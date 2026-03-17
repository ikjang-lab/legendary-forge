package com.ikjang.legendary_forge

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "com.ikjang.legendary_forge/forge"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAccessibilityEnabled" -> {
                        result.success(isAccessibilityServiceEnabled())
                    }
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(null)
                    }
                    "isOverlayPermissionGranted" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "requestOverlayPermission" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.success(null)
                    }
                    "saveTargetLevel" -> {
                        val level = call.argument<Int>("level") ?: 10
                        getSharedPreferences(
                            KakaoForgeAccessibilityService.PREF_NAME,
                            Context.MODE_PRIVATE
                        ).edit().putInt(
                            KakaoForgeAccessibilityService.PREF_TARGET_LEVEL,
                            level
                        ).apply()
                        result.success(null)
                    }
                    "getTargetLevel" -> {
                        val level = getSharedPreferences(
                            KakaoForgeAccessibilityService.PREF_NAME,
                            Context.MODE_PRIVATE
                        ).getInt(KakaoForgeAccessibilityService.PREF_TARGET_LEVEL, 10)
                        result.success(level)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val am = getSystemService(ACCESSIBILITY_SERVICE) as AccessibilityManager
        val enabledServices = am.getEnabledAccessibilityServiceList(
            AccessibilityServiceInfo.FEEDBACK_ALL_MASK
        )
        return enabledServices.any {
            it.resolveInfo.serviceInfo.packageName == packageName &&
                    it.resolveInfo.serviceInfo.name.contains("KakaoForge")
        }
    }
}
