package com.offlinegroupmessenger.offline_group_messenger

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.skychat/background"
        private const val REQ_POST_NOTIFICATIONS = 4101
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        SkyChatBackgroundService.ensureChannels(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                            result.success(true)
                        } else if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            result.success(true)
                        } else {
                            pendingPermissionResult?.success(false)
                            pendingPermissionResult = result
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_POST_NOTIFICATIONS
                            )
                        }
                    }

                    "startBackgroundService" -> {
                        val title = call.argument<String>("title") ?: "SkyChat"
                        val body = call.argument<String>("body") ?: "Connected to offline group"
                        val intent = Intent(this, SkyChatBackgroundService::class.java).apply {
                            action = SkyChatBackgroundService.ACTION_START
                            putExtra(SkyChatBackgroundService.EXTRA_TITLE, title)
                            putExtra(SkyChatBackgroundService.EXTRA_BODY, body)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }

                    "stopBackgroundService" -> {
                        val intent = Intent(this, SkyChatBackgroundService::class.java).apply {
                            action = SkyChatBackgroundService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }

                    "showMessageNotification" -> {
                        val sender = call.argument<String>("sender") ?: "SkyChat"
                        val text = call.argument<String>("text") ?: ""
                        if (text.isNotEmpty()) {
                            SkyChatBackgroundService.showMessageNotification(this, sender, text)
                        }
                        result.success(null)
                    }

                    "moveToBackground" -> {
                        moveTaskToBack(true)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_POST_NOTIFICATIONS) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }
}
