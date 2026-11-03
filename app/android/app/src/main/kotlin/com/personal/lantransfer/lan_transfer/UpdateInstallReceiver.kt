package com.personal.lantransfer.lan_transfer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives PackageInstaller session results. Declared with
 * android:exported="false", so only the PendingIntent created by this app can
 * reach it; other apps cannot inject a confirmation intent.
 */
class UpdateInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        MainActivity.onUpdateInstallStatus(context, intent)
    }
}
