package com.example.sandesh

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.work.*
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

class PeriodicUpdateCheckWorker(
    private val context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        Log.i("PeriodicUpdateCheck", "Checking for updates")
        try {
            val url = URL("https://github.com/Codewith-AG/Sandesh-Releases/releases/latest/download/update.json")
            val connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.connectTimeout = 15000
            connection.readTimeout = 15000

            // Handle redirect if needed (though curl needs -L, HttpURLConnection usually follows redirects automatically for same protocol, but GitHub redirects from https to https so it should work, but to be safe we handle it)
            var finalConnection = connection
            var redirectCount = 0
            while (finalConnection.responseCode in 300..399) {
                if (redirectCount++ > 5) return Result.failure()
                val redirectUrl = finalConnection.getHeaderField("Location") ?: return Result.failure()
                finalConnection = URL(redirectUrl).openConnection() as HttpURLConnection
            }

            if (finalConnection.responseCode != 200) {
                if (finalConnection.responseCode == 404) return Result.success() // No release yet
                return Result.retry()
            }

            val response = BufferedReader(InputStreamReader(finalConnection.inputStream)).use { it.readText() }
            val json = JSONObject(response)
            
            val remoteVersionCode = json.getLong("versionCode")
            val apkAsset = json.getString("apkAsset")
            val downloadUrl = "https://github.com/Codewith-AG/Sandesh-Releases/releases/latest/download/$apkAsset"
            val sha256 = json.getString("sha256")
            
            val packageManager = context.packageManager
            val currentPackageInfo = packageManager.getPackageInfo(context.packageName, 0)
            val currentVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                currentPackageInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                currentPackageInfo.versionCode.toLong()
            }

            // Respect the user's toggles. Flutter's shared_preferences plugin
            // stores values on Android in "FlutterSharedPreferences" with a
            // "flutter." key prefix. Defaults mirror the Dart side (both true).
            val flutterPrefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val autoUpdateEnabled = flutterPrefs.getBoolean("flutter.update_auto_update", true)
            val wifiOnly = flutterPrefs.getBoolean("flutter.update_wifi_only", true)

            if (remoteVersionCode > currentVersionCode && autoUpdateEnabled) {
                Log.i("PeriodicUpdateCheck", "New version $remoteVersionCode found (autoUpdate=$autoUpdateEnabled, wifiOnly=$wifiOnly)! Enqueueing UpdateWorker.")
                
                val workManager = WorkManager.getInstance(context)

                // Wi-Fi-only ON  -> UNMETERED: WorkManager holds the job until an
                //                  unmetered Wi-Fi network is available, i.e.
                //                  "no Wi-Fi -> wait -> download when Wi-Fi returns".
                // Wi-Fi-only OFF -> CONNECTED: download over any network.
                val constraintsBuilder = Constraints.Builder()
                    .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
                
                val workRequest = OneTimeWorkRequestBuilder<UpdateWorker>()
                    .setConstraints(constraintsBuilder.build())
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, WorkRequest.MIN_BACKOFF_MILLIS, TimeUnit.MILLISECONDS)
                    // Expedited + the worker's setForeground() lets the download
                    // run to completion even while the app is fully closed.
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .setInputData(
                        workDataOf(
                            UpdateWorker.KEY_DOWNLOAD_URL to downloadUrl,
                            UpdateWorker.KEY_SHA256 to sha256,
                            UpdateWorker.KEY_VERSION_CODE to remoteVersionCode,
                            "wifiOnly" to wifiOnly
                        )
                    )
                    .addTag("version_$remoteVersionCode")
                    .build()

                // REPLACE ensures newer version supersedes any existing enqueued download.
                workManager.enqueueUniqueWork(
                    "sandesh_update",
                    ExistingWorkPolicy.REPLACE,
                    workRequest
                )
            }
            return Result.success()

        } catch (e: Exception) {
            Log.e("PeriodicUpdateCheck", "Error checking for update", e)
            return Result.retry()
        }
    }
    
    companion object {
        fun schedule(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()
                
            val request = PeriodicWorkRequestBuilder<PeriodicUpdateCheckWorker>(6, TimeUnit.HOURS)
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, WorkRequest.MIN_BACKOFF_MILLIS, TimeUnit.MILLISECONDS)
                .build()
                
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                "sandesh_periodic_update_check",
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }
    }
}
