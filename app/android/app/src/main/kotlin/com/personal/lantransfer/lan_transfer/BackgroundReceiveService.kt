package com.personal.lantransfer.lan_transfer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Optional "keep receiving in the background" mode. A foreground service with
 * a persistent notification keeps the process (and the Flutter engine owned by
 * the activity) from being frozen, and holds the locks discovery needs while
 * the screen is off. Swiping the app away from recents still stops receiving.
 */
class BackgroundReceiveService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannels(this)
        val notification = buildNotification(
            this,
            CHANNEL_SERVICE,
            "猛人快传正在后台接收",
            "可以接收局域网和公网发来的文件和消息；在设置里关闭“后台持续接收”即可停止",
            ongoing = true,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                SERVICE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(SERVICE_NOTIFICATION_ID, notification)
        }
        acquireLocks()
        isRunning = true
        // Not sticky: a service restarted without the activity would show the
        // notification while no Flutter engine is listening.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "$packageName:background-receive",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (wifiLock == null) {
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "$packageName:background-receive",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (multicastLock == null) {
            multicastLock = wifi.createMulticastLock("$packageName:background-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    companion object {
        private const val CHANNEL_SERVICE = "background_receive"
        private const val CHANNEL_INCOMING = "incoming_items"
        private const val SERVICE_NOTIFICATION_ID = 7001
        private var nextIncomingId = 7100

        @Volatile
        var isRunning = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, BackgroundReceiveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BackgroundReceiveService::class.java))
        }

        /** Shown when a file or message arrives while the app is not visible. */
        fun notifyIncoming(context: Context, title: String, text: String) {
            ensureChannels(context)
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val notification = buildNotification(
                context,
                CHANNEL_INCOMING,
                title,
                text,
                ongoing = false,
            )
            nextIncomingId = if (nextIncomingId >= 7199) 7100 else nextIncomingId + 1
            manager.notify(nextIncomingId, notification)
        }

        private fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_SERVICE) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_SERVICE,
                        "后台持续接收",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply { description = "开启“后台持续接收”时常驻的提示" },
                )
            }
            if (manager.getNotificationChannel(CHANNEL_INCOMING) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_INCOMING,
                        "收到的文件和消息",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ).apply { description = "后台收到文件或消息时提醒" },
                )
            }
        }

        private fun buildNotification(
            context: Context,
            channel: String,
            title: String,
            text: String,
            ongoing: Boolean,
        ): Notification {
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, channel)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return builder
                .setSmallIcon(R.drawable.ic_stat_receive)
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setContentIntent(open)
                .setOngoing(ongoing)
                .setAutoCancel(!ongoing)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .build()
        }
    }
}
