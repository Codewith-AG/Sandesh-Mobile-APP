package com.example.sandesh

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkRequest
import androidx.work.BackoffPolicy
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.sandesh/updater"
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        PeriodicUpdateCheckWorker.schedule(this)
    }

    override fun onDestroy() {
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath != null) {
                        CoroutineScope(Dispatchers.IO).launch {
                            try {
                                installApk(apkPath)
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf("success" to true, "status" to "INSTALL_STARTED"))
                                }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.success(mapOf("success" to false, "status" to "ERROR: ${e.message}"))
                                }
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "apkPath is required", null)
                    }
                }
                "getInstalledSignatures" -> {
                    result.success(getInstalledSignatures())
                }
                "getApkSignatures" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath != null) {
                        result.success(getApkSignatures(apkPath))
                    } else {
                        result.error("INVALID_ARGUMENT", "apkPath is required", null)
                    }
                }
                "getApkPackageName" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath != null) {
                        result.success(getApkPackageName(apkPath))
                    } else {
                        result.error("INVALID_ARGUMENT", "apkPath is required", null)
                    }
                }
                "getApkVersionCode" -> {
                    val apkPath = call.argument<String>("apkPath")
                    if (apkPath != null) {
                        result.success(getApkVersionCode(apkPath))
                    } else {
                        result.error("INVALID_ARGUMENT", "apkPath is required", null)
                    }
                }
                "canRequestInstall" -> {
                    result.success(packageManager.canRequestPackageInstalls())
                }
                "openInstallPermissionSettings" -> {
                    val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                        data = android.net.Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                    result.success(true)
                }
                "getDeviceAbis" -> {
                    result.success(Build.SUPPORTED_ABIS.toList())
                }
                "isWifiConnected" -> {
                    result.success(isWifiConnected())
                }
                "scheduleBackgroundUpdate" -> {
                    val downloadUrl = call.argument<String>("downloadUrl")
                    val sha256 = call.argument<String>("sha256")
                    val versionCode = call.argument<Int>("versionCode")?.toLong()
                    val wifiOnly = call.argument<Boolean>("wifiOnly") ?: true

                    if (downloadUrl != null && sha256 != null && versionCode != null) {
                        scheduleBackgroundUpdate(downloadUrl, sha256, versionCode, wifiOnly)
                        result.success(true)
                    } else {
                        result.error("INVALID_ARGUMENT", "Missing arguments", null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun installApk(apkPath: String) {
        val file = File(apkPath)
        if (!file.exists() || file.length() == 0L) {
            throw java.io.IOException("APK file missing or empty at $apkPath")
        }

        // Use ACTION_VIEW + a FileProvider content URI so the system installer
        // can read the APK. PackageInstaller sessions with USER_ACTION_NOT_REQUIRED
        // fail silently on Android 12+ because BroadcastReceivers are blocked
        // from launching activities in the background (background-activity-launch
        // restrictions). Handing the URI directly to the system installer from
        // this foreground Activity avoids that restriction entirely.
        val apkUri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(apkUri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    private fun getInstalledSignatures(): String? {
        val packageInfo = packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        val signatures = packageInfo.signingInfo?.apkContentsSigners
        if (!signatures.isNullOrEmpty()) {
            val md = MessageDigest.getInstance("SHA-256")
            md.update(signatures[0].toByteArray())
            return md.digest().joinToString("") { "%02x".format(it) }
        }
        return null
    }

    private fun getApkSignatures(apkPath: String): String? {
        val packageInfo = packageManager.getPackageArchiveInfo(apkPath, PackageManager.GET_SIGNING_CERTIFICATES)
        packageInfo?.signingInfo?.apkContentsSigners?.let { signatures ->
            if (signatures.isNotEmpty()) {
                val md = MessageDigest.getInstance("SHA-256")
                md.update(signatures[0].toByteArray())
                return md.digest().joinToString("") { "%02x".format(it) }
            }
        }
        return null
    }

    private fun getApkPackageName(apkPath: String): String? {
        val packageInfo = packageManager.getPackageArchiveInfo(apkPath, 0)
        return packageInfo?.packageName
    }

    private fun getApkVersionCode(apkPath: String): Long? {
        val packageInfo = packageManager.getPackageArchiveInfo(apkPath, 0)
        return packageInfo?.longVersionCode
    }

    private fun isWifiConnected(): Boolean {
        val connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivityManager.activeNetwork ?: return false
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
               capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }

    private fun scheduleBackgroundUpdate(downloadUrl: String, sha256: String, versionCode: Long, wifiOnly: Boolean) {
        val workManager = WorkManager.getInstance(this)

        val constraintsBuilder = Constraints.Builder()
            .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)

        val workRequest = OneTimeWorkRequestBuilder<UpdateWorker>()
            .setConstraints(constraintsBuilder.build())
            .setInputData(
                workDataOf(
                    UpdateWorker.KEY_DOWNLOAD_URL to downloadUrl,
                    UpdateWorker.KEY_SHA256 to sha256,
                    UpdateWorker.KEY_VERSION_CODE to versionCode,
                    "wifiOnly" to wifiOnly
                )
            )
            .setBackoffCriteria(
                BackoffPolicy.EXPONENTIAL,
                WorkRequest.MIN_BACKOFF_MILLIS,
                TimeUnit.MILLISECONDS
            )
            // Run as expedited so the download starts promptly and, backed by the
            // worker's setForeground(), keeps running after the app is closed.
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag("version_$versionCode")
            .build()

        // Use a version-scoped unique name + KEEP policy:
        //   - KEEP: if a download for this version is already running/enqueued,
        //     it is NOT cancelled when the app relaunches (fixes the bug where
        //     every launch reset an in-progress background download).
        //   - Version-scoped name: a new version gets a fresh unique name so
        //     it always starts a new download regardless of the old one.
        workManager.enqueueUniqueWork(
            "sandesh_update_v$versionCode",
            ExistingWorkPolicy.KEEP,
            workRequest
        )
    }
}
