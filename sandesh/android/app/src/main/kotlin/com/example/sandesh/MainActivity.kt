package com.example.sandesh

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
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
        val packageInstaller = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }

        val sessionId = packageInstaller.createSession(params)
        val session = packageInstaller.openSession(sessionId)

        val file = File(apkPath)
        val inStream = FileInputStream(file)
        val outStream = session.openWrite("sandesh_update", 0, file.length())

        val buffer = ByteArray(65536)
        var bytesRead: Int
        while (inStream.read(buffer).also { bytesRead = it } != -1) {
            outStream.write(buffer, 0, bytesRead)
        }
        
        session.fsync(outStream)
        outStream.close()
        inStream.close()

        val intent = Intent(this, PackageInstallerReceiver::class.java).apply {
            action = PackageInstallerReceiver.ACTION_INSTALL_COMPLETE
        }
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            sessionId,
            intent,
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        session.commit(pendingIntent.intentSender)
        session.close()
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

        // Use KEEP policy: if a work with the same unique name is already running/enqueued,
        // it won't be replaced — preventing duplicate downloads.
        // Tag encodes version so newer version triggers REPLACE via the version tag check below.
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
            .addTag("version_$versionCode")
            .build()

        // REPLACE ensures a newer versionCode always supersedes an older enqueued download.
        workManager.enqueueUniqueWork(
            "sandesh_update",
            ExistingWorkPolicy.REPLACE,
            workRequest
        )
    }
}
