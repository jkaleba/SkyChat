package com.offlinegroupmessenger.offline_group_messenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class SkyChatBackgroundService : Service() {

    companion object {
        const val CHANNEL_BACKGROUND = "skychat_background"
        const val CHANNEL_MESSAGES = "skychat_messages"
        const val NOTIFICATION_ID_FOREGROUND = 1001
        const val ACTION_START = "com.skychat.action.START"
        const val ACTION_STOP = "com.skychat.action.STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_BODY = "body"

        private var nextMessageNotificationId = 2000

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return

            if (manager.getNotificationChannel(CHANNEL_BACKGROUND) == null) {
                val bgChannel = NotificationChannel(
                    CHANNEL_BACKGROUND,
                    "Background connection",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Keeps SkyChat connected to your offline group in the background"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(bgChannel)
            }

            if (manager.getNotificationChannel(CHANNEL_MESSAGES) == null) {
                val msgChannel = NotificationChannel(
                    CHANNEL_MESSAGES,
                    "Messages",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Notifications for received SkyChat messages"
                }
                manager.createNotificationChannel(msgChannel)
            }
        }

        fun showMessageNotification(context: Context, sender: String, text: String) {
            ensureChannels(context)
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_MESSAGES)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            val notification = builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(sender.ifBlank { "SkyChat" })
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .build()

            val id = nextMessageNotificationId++
            if (nextMessageNotificationId > 2999) nextMessageNotificationId = 2000
            manager.notify(id, notification)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannels(this)
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "SkyChat"
        val body = intent?.getStringExtra(EXTRA_BODY) ?: "Connected to offline group"

        val launchIntent = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_BACKGROUND)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID_FOREGROUND,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
            )
        } else {
            startForeground(NOTIFICATION_ID_FOREGROUND, notification)
        }

        return START_STICKY
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
