package com.mobileagent.mobile_agent_v1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

class AgentForegroundService : Service() {
    companion object {
        const val EXTRA_TASK_ID = "taskId"
        const val ACTION_START_TASK = "mobile_agent.action.START_TASK"
        const val ACTION_STOP_TASK = "mobile_agent.action.STOP_TASK"
        private const val channelId = "agent_tasks"
        private const val notificationId = 1001
    }

    private val taskIds = linkedSetOf<String>()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(notificationId, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val taskId = intent?.getStringExtra(EXTRA_TASK_ID)
        if (intent?.action == ACTION_STOP_TASK) {
            removeTask(taskId)
        } else if (taskId != null) {
            taskIds.add(taskId)
        }
        if (taskIds.isEmpty()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        getSystemService(NotificationManager::class.java).notify(notificationId, buildNotification())
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
    }

    private fun removeTask(taskId: String?) {
        if (taskId != null) taskIds.remove(taskId)
        if (taskIds.isEmpty()) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
        } else {
            getSystemService(NotificationManager::class.java)
                .notify(notificationId, buildNotification())
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            channelId,
            "Agent tasks",
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val text = when (taskIds.size) {
            0 -> "Agent 任务启动中"
            1 -> "任务运行中：${taskIds.first()}"
            else -> "${taskIds.size} 个 Agent 任务运行中"
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
                .setContentTitle("PocketServerOps AI")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true)
                .build()
        } else {
            Notification.Builder(this)
                .setContentTitle("PocketServerOps AI")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true)
                .build()
        }
    }
}
