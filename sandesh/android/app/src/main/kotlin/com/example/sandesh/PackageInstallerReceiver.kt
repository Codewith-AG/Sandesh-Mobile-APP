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
                // Surface the failure to the user instead of failing silently, with a
                // human-readable reason and a tap target to reopen Sandesh and retry.
                showFailureNotification(context, reasonFor(status, message))
            }
        }
    }

    private fun reasonFor(status: Int, message: String?): String = when (status) {
        PackageInstaller.STATUS_FAILURE_ABORTED -> "Installation was cancelled."
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "Installation was blocked by the device."
        PackageInstaller.STATUS_FAILURE_CONFLICT ->
            "Update conflicts with the installed app (signature mismatch). Reinstall Sandesh from the same source."
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "This update is not compatible with your device."
        PackageInstaller.STATUS_FAILURE_INVALID -> "The downloaded update file is invalid or corrupted."
        PackageInstaller.STATUS_FAILURE_STORAGE -> "Not enough storage to install the update."
        else -> message ?: "The update could not be installed. Please try again."
    }

    private fun showFailureNotification(context: Context, reason: String) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "update_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notificationManager.createNotificationChannel(
                NotificationChannel(channelId, "App Updates", NotificationManager.IMPORTANCE_HIGH)
            )
        }
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pendingIntent = PendingIntent.getActivity(
            context, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            android.app.Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("Update failed")
            .setContentText(reason)
            .setStyle(android.app.Notification.BigTextStyle().bigText(reason))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()
        notificationManager.notify(1004, notification)
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
