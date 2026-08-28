package com.mobileagent.mobile_agent_v1

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "mobile_agent/foreground"
    private val storageChannelName = "mobile_agent/storage"
    private val fileChannelName = "mobile_agent/file"
    private val updateChannelName = "mobile_agent/update"
    private val storageRequestCode = 2007
    private val legacyStorageRequestCode = 2008
    private val notificationRequestCode = 2009
    private val installRequestCode = 2010
    private var storageResult: MethodChannel.Result? = null
    private var notificationResult: MethodChannel.Result? = null
    private var installResult: MethodChannel.Result? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return FlutterEngineCache.getInstance()
            .get(MobileAgentApplication.ENGINE_ID)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_START_TASK)
                            .putExtra(AgentForegroundService.EXTRA_TASK_ID, call.argument<String>("taskId"))
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_ENABLED,
                                call.argument<Boolean>("overlayEnabled") ?: false,
                            )
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_SCALE,
                                call.argument<Double>("overlayScale") ?: 1.0,
                            )
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_LENGTH_SCALE,
                                call.argument<Double>("overlayLengthScale") ?: 1.0,
                            )
                            .putExtra(
                                AgentForegroundService.EXTRA_TASK_TITLE,
                                call.argument<String>("title"),
                            )
                        startTaskService(intent)
                        result.success(null)
                    }
                    "stop" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_STOP_TASK)
                            .putExtra(AgentForegroundService.EXTRA_TASK_ID, call.argument<String>("taskId"))
                        sendTaskServiceCommand(intent)
                        result.success(null)
                    }
                    "finish" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_FINISH_TASK)
                            .putExtra(AgentForegroundService.EXTRA_TASK_ID, call.argument<String>("taskId"))
                            .putExtra(
                                AgentForegroundService.EXTRA_TASK_STATUS,
                                call.argument<String>("status"),
                            )
                        sendTaskServiceCommand(intent)
                        result.success(null)
                    }
                    "consumeOverlayTask" -> {
                        val taskId = intent?.getStringExtra(
                            AgentForegroundService.EXTRA_OPEN_TASK_ID,
                        )
                        intent?.removeExtra(AgentForegroundService.EXTRA_OPEN_TASK_ID)
                        result.success(taskId)
                    }
                    "updateProgress" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_UPDATE_PROGRESS)
                            .putExtra(AgentForegroundService.EXTRA_TASK_ID, call.argument<String>("taskId"))
                            .putExtra(
                                AgentForegroundService.EXTRA_PROGRESS_LABEL,
                                call.argument<String>("label"),
                            )
                        sendTaskServiceCommand(intent)
                        result.success(null)
                    }
                    "setOverlayEnabled" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_SET_OVERLAY)
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_ENABLED,
                                call.argument<Boolean>("enabled") ?: false,
                            )
                        sendTaskServiceCommand(intent)
                        result.success(null)
                    }
                    "setOverlayScale" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_SET_OVERLAY_SCALE)
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_SCALE,
                                call.argument<Double>("scale") ?: 1.0,
                            )
                        sendTaskServiceCommand(intent)
                        result.success(null)
                    }
                    "setOverlayLengthScale" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_SET_OVERLAY_LENGTH_SCALE)
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_LENGTH_SCALE,
                                call.argument<Double>("scale") ?: 1.0,
                            )
                        sendTaskServiceCommand(intent)
                        result.success(null)
                    }
                    "setOverlayApproval" -> {
                        val intent = Intent(this, AgentForegroundService::class.java)
                            .setAction(AgentForegroundService.ACTION_SET_OVERLAY_APPROVAL)
                            .putExtra(
                                AgentForegroundService.EXTRA_TASK_ID,
                                call.argument<String>("taskId"),
                            )
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_APPROVAL_LABEL,
                                call.argument<String>("label"),
                            )
                            .putExtra(
                                AgentForegroundService.EXTRA_OVERLAY_APPROVAL_READ_ONLY,
                                call.argument<Boolean>("allowReadOnly") ?: false,
                            )
                        sendTaskServiceCommand(intent)
                        result.success(null)
                    }
                    "canDrawOverlays" -> result.success(canDrawOverlays())
                    "requestOverlayPermission" -> requestOverlayPermission(result)
                    "canPostNotifications" -> result.success(canPostNotifications())
                    "requestNotificationPermission" ->
                        requestNotificationPermission(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasExternalStorageAccess" -> result.success(hasExternalStorageAccess())
                    "requestExternalStorageAccess" -> requestExternalStorageAccess(result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openFile" -> openFile(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(call.argument<String>("path"), result)
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "requestInstallPermission" -> requestInstallPermission(result)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    private fun hasExternalStorageAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun canPostNotifications(): Boolean {
        return Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (canPostNotifications()) {
            result.success(true)
            return
        }
        notificationResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationRequestCode,
        )
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()
    }

    private fun requestInstallPermission(result: MethodChannel.Result) {
        if (canInstallPackages()) {
            result.success(true)
            return
        }
        installResult = result
        try {
            startActivityForResult(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
                installRequestCode,
            )
        } catch (error: Exception) {
            installResult = null
            result.error(
                "install_permission_unavailable",
                error.message ?: "无法打开安装权限设置",
                null,
            )
        }
    }

    private fun requestExternalStorageAccess(result: MethodChannel.Result) {
        if (hasExternalStorageAccess()) {
            result.success(true)
            return
        }
        storageResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val intent = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            startActivityForResult(intent, storageRequestCode)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            requestPermissions(
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                legacyStorageRequestCode,
            )
        } else {
            storageResult?.success(true)
            storageResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == storageRequestCode) {
            storageResult?.success(hasExternalStorageAccess())
            storageResult = null
            return
        }
        if (requestCode == installRequestCode) {
            installResult?.success(canInstallPackages())
            installResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == legacyStorageRequestCode) {
            storageResult?.success(hasExternalStorageAccess())
            storageResult = null
            return
        }
        if (requestCode == notificationRequestCode) {
            notificationResult?.success(canPostNotifications())
            notificationResult = null
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun startTaskService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationRequestCode,
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun sendTaskServiceCommand(intent: Intent) {
        // The service is already foreground while a task is active. Reusing
        // its command channel avoids a second foreground-service start when
        // the Dart isolate finishes after the Activity is backgrounded.
        startService(intent)
    }

    private fun canDrawOverlays(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(this)
    }

    private fun requestOverlayPermission(result: MethodChannel.Result) {
        if (canDrawOverlays()) {
            result.success(true)
            return
        }
        try {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName"),
                ),
            )
            result.success(false)
        } catch (error: Exception) {
            result.error(
                "overlay_permission_unavailable",
                error.message ?: "无法打开悬浮窗权限设置",
                null,
            )
        }
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_apk", "APK 路径为空", null)
            return
        }
        val file = File(path)
        if (!file.isFile) {
            result.error("invalid_apk", "APK 文件不存在", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ),
            )
            result.error(
                "install_permission_required",
                "请允许本应用安装未知应用",
                null,
            )
            return
        }

        try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error(
                "install_failed",
                error.message ?: "无法启动系统安装器",
                null,
            )
        }
    }

    private fun openFile(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_file", "文件路径为空", null)
            return
        }
        val file = File(path)
        if (!file.isFile) {
            result.error("invalid_file", "文件不存在", null)
            return
        }
        try {
            val shareFile = File(
                cacheDir,
                "mobile-agent-open-${System.currentTimeMillis()}-${file.name}",
            )
            file.copyTo(shareFile, overwrite = true)
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                shareFile,
            )
            val mimeType = MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(shareFile.extension.lowercase()) ?: "*/*"
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "使用其他应用打开"))
            result.success(null)
        } catch (error: Exception) {
            result.error(
                "open_file_failed",
                error.message ?: "没有可打开此文件的应用",
                null,
            )
        }
    }
}
