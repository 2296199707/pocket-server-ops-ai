package com.mobileagent.mobile_agent_v1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.TextView

import kotlin.math.abs

class AgentForegroundService : Service() {
    companion object {
        const val EXTRA_TASK_ID = "taskId"
        const val EXTRA_OVERLAY_ENABLED = "overlayEnabled"
        const val EXTRA_PROGRESS_LABEL = "progressLabel"
        const val ACTION_START_TASK = "mobile_agent.action.START_TASK"
        const val ACTION_STOP_TASK = "mobile_agent.action.STOP_TASK"
        const val ACTION_UPDATE_PROGRESS = "mobile_agent.action.UPDATE_PROGRESS"
        const val ACTION_SET_OVERLAY = "mobile_agent.action.SET_OVERLAY"
        private const val channelId = "agent_tasks"
        private const val notificationId = 1001
        private const val preferencesName = "agent_background"
        private const val overlayVisiblePixels = 20
    }

    private val taskIds = linkedSetOf<String>()
    private val taskLabels = linkedMapOf<String, String>()
    private val preferences by lazy {
        getSharedPreferences(preferencesName, MODE_PRIVATE)
    }
    private val windowManager by lazy {
        getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }
    private val notificationManager by lazy {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }
    private val wakeLock by lazy {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:agent",
        ).apply { setReferenceCounted(false) }
    }
    private var overlayEnabled = false
    private var overlayView: TextView? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var lastTaskId: String? = null
    private var touchStartX = 0f
    private var touchStartY = 0f
    private var touchInitialX = 0
    private var touchInitialY = 0
    private var touchMoved = false
    private var touchStartedAt = 0L

    override fun onCreate() {
        super.onCreate()
        overlayEnabled = preferences.getBoolean("overlay_enabled", false)
        createNotificationChannel()
        startForeground(notificationId, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val taskId = intent?.getStringExtra(EXTRA_TASK_ID)
        when (intent?.action) {
            ACTION_STOP_TASK -> removeTask(taskId)
            ACTION_UPDATE_PROGRESS -> {
                if (taskId != null && taskIds.contains(taskId)) {
                    taskLabels[taskId] =
                        intent.getStringExtra(EXTRA_PROGRESS_LABEL)?.trim()
                            ?.takeIf { it.isNotEmpty() }
                            ?: "处理中"
                    lastTaskId = taskId
                }
            }
            ACTION_SET_OVERLAY -> {
                overlayEnabled = intent.getBooleanExtra(
                    EXTRA_OVERLAY_ENABLED,
                    overlayEnabled,
                )
                preferences.edit()
                    .putBoolean("overlay_enabled", overlayEnabled)
                    .apply()
            }
            ACTION_START_TASK -> {
                if (intent.hasExtra(EXTRA_OVERLAY_ENABLED)) {
                    overlayEnabled = intent.getBooleanExtra(
                        EXTRA_OVERLAY_ENABLED,
                        overlayEnabled,
                    )
                    preferences.edit()
                        .putBoolean("overlay_enabled", overlayEnabled)
                        .apply()
                }
                if (taskId != null) {
                    taskIds.add(taskId)
                    taskLabels.putIfAbsent(taskId, "启动中")
                    lastTaskId = taskId
                }
            }
            else -> if (taskId != null) {
                taskIds.add(taskId)
                taskLabels.putIfAbsent(taskId, "启动中")
                lastTaskId = taskId
            }
        }
        if (taskIds.isEmpty()) {
            removeOverlay()
            releaseWakeLock()
            stopForegroundService()
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        acquireWakeLock()
        showOrUpdateOverlay()
        notificationManager.notify(notificationId, buildNotification())
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        removeOverlay()
        releaseWakeLock()
        super.onDestroy()
    }

    private fun removeTask(taskId: String?) {
        if (taskId != null) {
            taskIds.remove(taskId)
            taskLabels.remove(taskId)
            if (lastTaskId == taskId) lastTaskId = taskIds.lastOrNull()
        }
        if (taskIds.isEmpty()) {
            removeOverlay()
            releaseWakeLock()
            stopForegroundService()
            stopSelf()
        } else {
            acquireWakeLock()
            showOrUpdateOverlay()
            notificationManager.notify(notificationId, buildNotification())
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
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val label = activeLabel()
        val text = when (taskIds.size) {
            0 -> "Agent 启动中"
            1 -> label
            else -> "${taskIds.size} 个任务 · $label"
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setContentTitle("PocketServerOps AI")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppPendingIntent())
            .setProgress(0, 0, true)
        return builder.build()
    }

    private fun openAppPendingIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return PendingIntent.getActivity(this, notificationId, intent, flags)
    }

    private fun openApp() {
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
        )
    }

    private fun activeLabel(): String {
        val taskId = lastTaskId ?: taskIds.lastOrNull()
        return taskLabels[taskId] ?: "处理中"
    }

    private fun acquireWakeLock() {
        if (!wakeLock.isHeld) wakeLock.acquire()
    }

    private fun releaseWakeLock() {
        if (wakeLock.isHeld) wakeLock.release()
    }

    private fun stopForegroundService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun canDrawOverlays(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(this)
    }

    private fun showOrUpdateOverlay() {
        if (!overlayEnabled || !canDrawOverlays()) {
            removeOverlay()
            return
        }
        val existing = overlayView
        if (existing != null) {
            existing.text = activeLabel()
            return
        }
        val view = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = GradientDrawable().apply {
                setColor(Color.argb(222, 30, 30, 34))
                cornerRadius = dp(18).toFloat()
                setStroke(dp(1), Color.argb(110, 255, 255, 255))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                elevation = dp(5).toFloat()
            }
            text = activeLabel()
            setOnTouchListener { _, event -> handleOverlayTouch(event) }
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = initialOverlayX()
            y = initialOverlayY()
        }
        try {
            windowManager.addView(view, params)
            overlayView = view
            overlayParams = params
            view.post {
                if (!preferences.contains("overlay_x")) snapToEdge()
            }
        } catch (_: SecurityException) {
            removeOverlay()
        } catch (_: IllegalStateException) {
            removeOverlay()
        }
    }

    private fun removeOverlay() {
        val view = overlayView ?: return
        try {
            windowManager.removeView(view)
        } catch (_: IllegalArgumentException) {
            // The system may have removed the window already.
        }
        overlayView = null
        overlayParams = null
    }

    private fun handleOverlayTouch(event: MotionEvent): Boolean {
        val params = overlayParams ?: return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                touchStartX = event.rawX
                touchStartY = event.rawY
                touchInitialX = params.x
                touchInitialY = params.y
                touchMoved = false
                touchStartedAt = System.currentTimeMillis()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - touchStartX
                val dy = event.rawY - touchStartY
                if (abs(dx) > dp(4) || abs(dy) > dp(4)) touchMoved = true
                params.x = touchInitialX + dx.toInt()
                params.y = touchInitialY + dy.toInt()
                updateOverlayLayout(params)
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (!touchMoved &&
                    System.currentTimeMillis() - touchStartedAt < 500
                ) {
                    if (isHalfHidden()) revealOverlay() else openApp()
                } else {
                    snapToEdge()
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                snapToEdge()
                return true
            }
        }
        return true
    }

    private fun updateOverlayLayout(params: WindowManager.LayoutParams) {
        val view = overlayView ?: return
        try {
            windowManager.updateViewLayout(view, params)
        } catch (_: IllegalArgumentException) {
            removeOverlay()
        }
    }

    private fun snapToEdge() {
        val view = overlayView ?: return
        val params = overlayParams ?: return
        val width = view.width.takeIf { it > 0 } ?: dp(120)
        val left = params.x + width / 2 < resources.displayMetrics.widthPixels / 2
        val visible = dp(overlayVisiblePixels)
        params.x = if (left) -width + visible
        else resources.displayMetrics.widthPixels - visible
        params.y = boundedY(params.y, view.height)
        preferences.edit()
            .putInt("overlay_x", params.x)
            .putInt("overlay_y", params.y)
            .apply()
        updateOverlayLayout(params)
    }

    private fun revealOverlay() {
        val view = overlayView ?: return
        val params = overlayParams ?: return
        val width = view.width.takeIf { it > 0 } ?: dp(120)
        val screenWidth = resources.displayMetrics.widthPixels
        params.x = if (params.x < screenWidth / 2) dp(8)
        else screenWidth - width - dp(8)
        params.y = boundedY(params.y, view.height)
        preferences.edit()
            .putInt("overlay_x", params.x)
            .putInt("overlay_y", params.y)
            .apply()
        updateOverlayLayout(params)
    }

    private fun isHalfHidden(): Boolean {
        val view = overlayView ?: return false
        val params = overlayParams ?: return false
        val screenWidth = resources.displayMetrics.widthPixels
        return params.x < 0 || params.x + view.width > screenWidth - dp(overlayVisiblePixels)
    }

    private fun boundedY(value: Int, viewHeight: Int): Int {
        val screenHeight = resources.displayMetrics.heightPixels
        val minimum = dp(24)
        val maximum = (screenHeight - viewHeight - dp(24)).coerceAtLeast(minimum)
        return value.coerceIn(minimum, maximum)
    }

    private fun initialOverlayX(): Int {
        return if (preferences.contains("overlay_x")) {
            preferences.getInt("overlay_x", 0)
        } else {
            resources.displayMetrics.widthPixels - dp(overlayVisiblePixels)
        }
    }

    private fun initialOverlayY(): Int {
        return preferences.getInt("overlay_y", dp(120))
    }

    @Suppress("DEPRECATION")
    private fun overlayType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            WindowManager.LayoutParams.TYPE_PHONE
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }
}
