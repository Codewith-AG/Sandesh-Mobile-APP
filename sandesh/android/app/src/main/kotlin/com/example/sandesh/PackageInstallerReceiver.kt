package com.example.sandesh

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log

class PackageInstallerReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_INSTALL_COMPLETE = "com.example.sandesh.INSTALL_COMPLETE"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INSTALL_COMPLETE) return

        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)

        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirmIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }

                if (confirmIntent != null) {
                    confirmIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        context.startActivity(confirmIntent)
                    } catch (e: Exception) {
                        Log.e("PackageInstaller", "Failed to start confirm intent, showing notification", e)
                        showNotification(context, confirmIntent)
                    }
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                Log.i("PackageInstaller", "Install succeeded!")
            }
            else -> {
                Log.e("PackageInstaller", "Install failed! Status: $status Message: $message")
            }
        }
    }

    private fun showNotification(context: Context, confirmIntent: Intent) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "update_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "App Updates",
                NotificationManager.IMPORTANCE_HIGH
            )
            notificationManager.createNotificationChannel(channel)
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            confirmIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
        }

        val notification = builder
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Update Ready")
            .setContentText("Sandesh update is ready — Tap to finish installation")
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        notificationManager.notify(1001, notification)
    }
}
