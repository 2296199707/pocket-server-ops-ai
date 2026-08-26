package com.mobileagent.mobile_agent_v1

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "mobile_agent/foreground"
    private val storageChannelName = "mobile_agent/storage"
    private val storageRequestCode = 2007
    private val legacyStorageRequestCode = 2008
    private var storageResult: MethodChannel.Result? = null

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
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun startTaskService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
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
}
