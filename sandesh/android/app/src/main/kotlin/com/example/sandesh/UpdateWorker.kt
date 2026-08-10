package com.example.sandesh

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

class UpdateWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        const val KEY_DOWNLOAD_URL = "download_url"
        const val KEY_SHA256 = "sha256"
        const val KEY_VERSION_CODE = "version_code"
        const val KEY_APK_ASSET = "apk_asset"
    }

    override suspend fun doWork(): Result {
        val downloadUrl = inputData.getString(KEY_DOWNLOAD_URL) ?: return Result.failure()
        val expectedSha256 = inputData.getString(KEY_SHA256) ?: return Result.failure()
        val versionCode = inputData.getLong(KEY_VERSION_CODE, -1L)
        
        if (versionCode == -1L) return Result.failure()

        if (!downloadUrl.startsWith("https://")) {
            Log.e("UpdateWorker", "Only HTTPS is allowed for downloads")
            return Result.failure()
        }

        if (!Build.SUPPORTED_ABIS.contains("arm64-v8a")) {
            Log.e("UpdateWorker", "Only arm64-v8a is supported")
            return Result.failure()
        }

        val wifiOnly = inputData.getBoolean("wifiOnly", true)
        if (wifiOnly) {
            val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
            val network = connectivityManager.activeNetwork
            val capabilities = connectivityManager.getNetworkCapabilities(network)
            if (capabilities == null || !capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) || !capabilities.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) {
                Log.w("UpdateWorker", "Wi-Fi required but not connected or metered. Retrying later.")
                return Result.retry()
            }
        }

        Log.i("UpdateWorker", "Starting background update download for v$versionCode")

        val apkFile = File(context.cacheDir, "update_$versionCode.apk")
        
        try {
            // Delete existing partial/old downloads
            context.cacheDir.listFiles { _, name -> name.startsWith("update_") && name.endsWith(".apk") }?.forEach {
                if (it.name != apkFile.name) {
                    it.delete()
                }
            }
            if (apkFile.exists()) {
                apkFile.delete()
            }

            val url = URL(downloadUrl)
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.connectTimeout = 15000
            connection.readTimeout = 60000

            if (connection.responseCode != HttpURLConnection.HTTP_OK) {
                Log.e("UpdateWorker", "Failed to download, HTTP code: ${connection.responseCode}")
                return if (connection.responseCode in 500..599 || connection.responseCode == 429) {
                    Result.retry()
                } else {
                    Result.failure()
                }
            }

            connection.inputStream.use { input ->
                FileOutputStream(apkFile).use { output ->
                    input.copyTo(output)
                }
            }

            // Verify SHA-256
            val actualSha256 = calculateSha256(apkFile)
            if (actualSha256.lowercase() != expectedSha256.lowercase()) {
                Log.e("UpdateWorker", "SHA-256 mismatch. Expected: $expectedSha256, Actual: $actualSha256")
                apkFile.delete()
                return Result.failure()
            }

            // Additional validations: Package Name, Version Code, Signature
            val packageManager = context.packageManager
            val packageInfo = packageManager.getPackageArchiveInfo(apkFile.absolutePath, PackageManager.GET_SIGNING_CERTIFICATES)
            if (packageInfo == null) {
                Log.e("UpdateWorker", "Failed to parse APK package info")
                apkFile.delete()
                return Result.failure()
            }

            if (packageInfo.packageName != context.packageName) {
                Log.e("UpdateWorker", "Package name mismatch. Expected: ${context.packageName}, Actual: ${packageInfo.packageName}")
                apkFile.delete()
                return Result.failure()
            }

            val currentPackageInfo = packageManager.getPackageInfo(context.packageName, 0)
            val currentVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                currentPackageInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                currentPackageInfo.versionCode.toLong()
            }

            val apkVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                packageInfo.versionCode.toLong()
            }

            if (apkVersionCode <= currentVersionCode) {
                Log.e("UpdateWorker", "Downloaded APK version ($apkVersionCode) is not newer than current ($currentVersionCode)")
                apkFile.delete()
                return Result.failure() // Should not retry if version is older
            }

            val currentSignatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                currentPackageInfo.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                currentPackageInfo.signatures
            }
            
            val apkSignatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.signingInfo?.apkContentsSigners
            } else {
                @Suppress("DEPRECATION")
                packageInfo.signatures
            }

            if (currentSignatures.isNullOrEmpty() || apkSignatures.isNullOrEmpty()) {
                Log.e("UpdateWorker", "Failed to get signatures")
                apkFile.delete()
                return Result.failure()
            }

            val md = MessageDigest.getInstance("SHA-256")
            val currentSigHash = md.digest(currentSignatures[0].toByteArray()).joinToString("") { "%02x".format(it) }
            md.reset()
            val apkSigHash = md.digest(apkSignatures[0].toByteArray()).joinToString("") { "%02x".format(it) }

            if (currentSigHash != apkSigHash) {
                Log.e("UpdateWorker", "Signature mismatch. Expected: $currentSigHash, Actual: $apkSigHash")
                apkFile.delete()
                return Result.failure()
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
                Log.w("UpdateWorker", "Cannot auto-install, missing permission. Prompting user to open app.")
                showAppNotification(context, "Update Downloaded", "Tap to open Sandesh and install the update")
                return Result.success()
            }

            // Install APK
            installApk(apkFile)
            apkFile.delete()
            return Result.success()

        } catch (e: Exception) {
            Log.e("UpdateWorker", "Error downloading/installing update", e)
            apkFile.delete()
            return Result.retry()
        }
    }

    private fun calculateSha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { fis ->
            val buffer = ByteArray(8192)
            var bytesRead: Int
            while (fis.read(buffer).also { bytesRead = it } != -1) {
                digest.update(buffer, 0, bytesRead)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun installApk(file: File) {
        val packageInstaller = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }

        val sessionId = packageInstaller.createSession(params)
        val session = packageInstaller.openSession(sessionId)

        FileInputStream(file).use { inStream ->
            session.openWrite("sandesh_background_update", 0, file.length()).use { outStream ->
                inStream.copyTo(outStream)
                session.fsync(outStream)
            }
        }

        val intent = Intent(context, PackageInstallerReceiver::class.java).apply {
            action = PackageInstallerReceiver.ACTION_INSTALL_COMPLETE
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            sessionId,
            intent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        session.commit(pendingIntent.intentSender)
        session.close()
    }

    private fun showAppNotification(context: Context, title: String, message: String) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        val channelId = "update_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = android.app.NotificationChannel(
                channelId,
                "App Updates",
                android.app.NotificationManager.IMPORTANCE_HIGH
            )
            notificationManager.createNotificationChannel(channel)
        }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launchIntent,
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
            .setContentTitle(title)
            .setContentText(message)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        notificationManager.notify(1002, notification)
    }
}
