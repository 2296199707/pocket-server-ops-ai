package com.mobileagent.mobile_agent_v1

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "mobile_agent/foreground"

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
