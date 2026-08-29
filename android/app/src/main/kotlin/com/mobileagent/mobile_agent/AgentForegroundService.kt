package com.mobileagent.mobile_agent_v1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

import kotlin.math.abs

class AgentForegroundService : Service() {
    companion object {
        const val EXTRA_TASK_ID = "taskId"
        const val EXTRA_TASK_TITLE = "taskTitle"
        const val EXTRA_OVERLAY_ENABLED = "overlayEnabled"
        const val EXTRA_OVERLAY_SCALE = "overlayScale"
        const val EXTRA_OVERLAY_LENGTH_SCALE = "overlayLengthScale"
        const val EXTRA_PROGRESS_LABEL = "progressLabel"
        const val ACTION_START_TASK = "mobile_agent.action.START_TASK"
        const val ACTION_STOP_TASK = "mobile_agent.action.STOP_TASK"
        const val ACTION_FINISH_TASK = "mobile_agent.action.FINISH_TASK"
        const val ACTION_UPDATE_PROGRESS = "mobile_agent.action.UPDATE_PROGRESS"
        const val ACTION_SET_OVERLAY = "mobile_agent.action.SET_OVERLAY"
        const val ACTION_SET_OVERLAY_SCALE = "mobile_agent.action.SET_OVERLAY_SCALE"
        const val ACTION_SET_OVERLAY_LENGTH_SCALE = "mobile_agent.action.SET_OVERLAY_LENGTH_SCALE"
        const val ACTION_SET_OVERLAY_APPROVAL = "mobile_agent.action.SET_OVERLAY_APPROVAL"
        const val EXTRA_OVERLAY_APPROVAL_LABEL = "overlayApprovalLabel"
        const val EXTRA_OVERLAY_APPROVAL_READ_ONLY = "overlayApprovalReadOnly"
        const val EXTRA_TASK_STATUS = "taskStatus"
        const val EXTRA_OPEN_TASK_ID = "openTaskId"
        private const val overlayEventsChannel = "mobile_agent/foreground_events"
        private const val channelId = "agent_tasks"
        private const val notificationId = 1001
        private const val overlayPermissionRequestCode = 1002
        private const val preferencesName = "agent_background"
        private const val overlayVisiblePixels = 20
        private const val overlayHorizontalMargin = 8
        private const val overlayBaseWidth = 244
    }

    private val taskIds = linkedSetOf<String>()
    private val taskLabels = linkedMapOf<String, String>()
    private val taskTitles = linkedMapOf<String, String>()
    private val taskStartedAt = linkedMapOf<String, Long>()
    private val taskFinishedAt = linkedMapOf<String, Long>()
    private val taskStatuses = linkedMapOf<String, String>()
    private data class PendingApproval(
        val label: String,
        val allowReadOnly: Boolean,
    )

    private val pendingApprovals = linkedMapOf<String, PendingApproval>()
    private val preferences by lazy {
        getSharedPreferences(preferencesName, MODE_PRIVATE)
    }
    private val windowManager by lazy {
        getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }
    private val notificationManager by lazy {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }
    private val overlayHandler = Handler(Looper.getMainLooper())
    private var overlayRefreshScheduled = false
    private val overlayRefreshRunnable = object : Runnable {
        override fun run() {
            overlayRefreshScheduled = false
            if (overlayView != null && hasRunningTask()) {
                refreshOverlayText()
                scheduleOverlayRefresh()
            }
        }
    }
    private val wakeLock by lazy {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:agent",
        ).apply { setReferenceCounted(false) }
    }
    private var overlayEnabled = false
    private var overlayScale = 1.0f
    private var overlayLengthScale = 1.0f
    private var overlayView: LinearLayout? = null
    private var overlayTitleView: TextView? = null
    private var overlayActionView: TextView? = null
    private var overlayApprovalView: LinearLayout? = null
    private var overlayApprovalLabelView: TextView? = null
    private var overlayApprovalReadButton: TextView? = null
    private var overlayParams: WindowManager.LayoutParams? = null
    private var approvalRestoreX: Int? = null
    private var approvalRestoreY: Int? = null
    private var approvalRestoreHidden = false
    private var approvalLayoutActive = false
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
        overlayScale = preferences.getFloat("overlay_scale", 1.0f).coerceIn(0.2f, 1.4f)
        overlayLengthScale = preferences.getFloat("overlay_length_scale", 1.0f)
            .coerceIn(0.2f, 1.4f)
        createNotificationChannel()
        startForeground(notificationId, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val taskId = intent?.getStringExtra(EXTRA_TASK_ID)
        when (intent?.action) {
            ACTION_STOP_TASK -> removeTask(taskId)
            ACTION_FINISH_TASK -> finishTask(
                taskId,
                intent.getStringExtra(EXTRA_TASK_STATUS),
            )
            ACTION_UPDATE_PROGRESS -> {
                if (taskId != null &&
                    taskIds.contains(taskId) &&
                    !isTerminalStatus(taskStatuses[taskId])) {
                    taskLabels[taskId] =
                        intent.getStringExtra(EXTRA_PROGRESS_LABEL)?.trim()
                            ?.takeIf { it.isNotEmpty() }
                            ?: "处理中"
                    lastTaskId = taskId
                }
            }
            ACTION_SET_OVERLAY_APPROVAL -> {
                if (taskId != null) {
                    val label = intent.getStringExtra(EXTRA_OVERLAY_APPROVAL_LABEL)
                        ?.trim()
                        ?.takeIf { it.isNotEmpty() }
                    if (label == null) {
                        pendingApprovals.remove(taskId)
                    } else {
                        if (pendingApprovals.isEmpty() && overlayParams != null) {
                            val params = overlayParams!!
                            approvalRestoreX = params.x
                            approvalRestoreY = params.y
                            approvalRestoreHidden = isHalfHidden()
                        }
                        pendingApprovals[taskId] = PendingApproval(
                            label = label.take(220),
                            allowReadOnly = intent.getBooleanExtra(
                                EXTRA_OVERLAY_APPROVAL_READ_ONLY,
                                false,
                            ),
                        )
                        lastTaskId = taskId
                    }
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
                if (!overlayEnabled) {
                    for (finishedTaskId in taskIds.toList()) {
                        if (isTerminalStatus(taskStatuses[finishedTaskId])) {
                            removeTask(finishedTaskId)
                        }
                    }
                }
            }
            ACTION_SET_OVERLAY_SCALE -> {
                overlayScale = intent.getDoubleExtra(
                    EXTRA_OVERLAY_SCALE,
                    overlayScale.toDouble(),
                ).toFloat().coerceIn(0.2f, 1.4f)
                preferences.edit().putFloat("overlay_scale", overlayScale).apply()
                if (overlayView != null) {
                    val params = overlayParams
                    if (params != null) {
                        preferences.edit()
                            .putInt("overlay_x", params.x)
                            .putInt("overlay_y", params.y)
                            .putBoolean("overlay_edge_hidden", isHalfHidden())
                            .apply()
                    }
                    removeOverlay()
                }
            }
            ACTION_SET_OVERLAY_LENGTH_SCALE -> {
                overlayLengthScale = intent.getDoubleExtra(
                    EXTRA_OVERLAY_LENGTH_SCALE,
                    overlayLengthScale.toDouble(),
                ).toFloat().coerceIn(0.2f, 1.4f)
                preferences.edit()
                    .putFloat("overlay_length_scale", overlayLengthScale)
                    .apply()
                if (overlayView != null) {
                    val params = overlayParams
                    if (params != null) {
                        preferences.edit()
                            .putInt("overlay_x", params.x)
                            .putInt("overlay_y", params.y)
                            .putBoolean("overlay_edge_hidden", isHalfHidden())
                            .apply()
                    }
                    removeOverlay()
                }
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
                if (intent.hasExtra(EXTRA_OVERLAY_SCALE)) {
                    overlayScale = intent.getDoubleExtra(
                        EXTRA_OVERLAY_SCALE,
                        overlayScale.toDouble(),
                    ).toFloat().coerceIn(0.2f, 1.4f)
                    preferences.edit().putFloat("overlay_scale", overlayScale).apply()
                }
                if (intent.hasExtra(EXTRA_OVERLAY_LENGTH_SCALE)) {
                    overlayLengthScale = intent.getDoubleExtra(
                        EXTRA_OVERLAY_LENGTH_SCALE,
                        overlayLengthScale.toDouble(),
                    ).toFloat().coerceIn(0.2f, 1.4f)
                    preferences.edit()
                        .putFloat("overlay_length_scale", overlayLengthScale)
                        .apply()
                }
                if (taskId != null) {
                    taskIds.add(taskId)
                    taskLabels.putIfAbsent(taskId, "启动中")
                    taskStatuses[taskId] = "running"
                    taskFinishedAt.remove(taskId)
                    taskTitles[taskId] = taskTitle(intent, taskId)
                    taskStartedAt.putIfAbsent(taskId, System.currentTimeMillis())
                    lastTaskId = taskId
                }
            }
            else -> if (taskId != null) {
                taskIds.add(taskId)
                taskLabels.putIfAbsent(taskId, "启动中")
                taskStatuses.putIfAbsent(taskId, "running")
                taskTitles[taskId] = taskTitle(intent, taskId)
                taskStartedAt.putIfAbsent(taskId, System.currentTimeMillis())
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
        if (hasRunningTask()) acquireWakeLock() else releaseWakeLock()
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
            taskTitles.remove(taskId)
            taskStartedAt.remove(taskId)
            taskFinishedAt.remove(taskId)
            taskStatuses.remove(taskId)
            pendingApprovals.remove(taskId)
            if (lastTaskId == taskId) lastTaskId = taskIds.lastOrNull()
        }
        if (taskIds.isEmpty()) {
            removeOverlay()
            releaseWakeLock()
            stopForegroundService()
            stopSelf()
        } else {
            if (hasRunningTask()) acquireWakeLock() else releaseWakeLock()
            showOrUpdateOverlay()
            notificationManager.notify(notificationId, buildNotification())
        }
    }

    private fun finishTask(taskId: String?, requestedStatus: String?) {
        if (taskId == null || !taskIds.contains(taskId)) return
        if (!overlayEnabled || !canDrawOverlays()) {
            removeTask(taskId)
            return
        }
        val status = normalizeTaskStatus(requestedStatus)
        taskStatuses[taskId] = status
        taskLabels[taskId] = terminalTaskLabel(status)
        taskFinishedAt[taskId] = System.currentTimeMillis()
        pendingApprovals.remove(taskId)
        lastTaskId = taskId
        if (hasRunningTask()) acquireWakeLock() else releaseWakeLock()
        showOrUpdateOverlay()
        notificationManager.notify(notificationId, buildNotification())
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
        val approval = activeApprovalLabel()
        val taskText = when (taskIds.size) {
            0 -> "Agent 启动中"
            1 -> label
            else -> "${taskIds.size} 个任务 · $label"
        }
        val text = when {
            approval != null -> "需要授权 · $approval"
            overlayEnabled && !canDrawOverlays() -> "需要悬浮窗权限 · $taskText"
            else -> taskText
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
            .setProgress(0, 0, hasRunningTask())
        if (approval != null) {
            builder.addAction(
                Notification.Action.Builder(
                    null,
                    "查看并授权",
                    openAppPendingIntent(),
                ).build(),
            )
        }
        if (overlayEnabled && !canDrawOverlays()) {
            builder.addAction(
                Notification.Action.Builder(
                    null,
                    "去系统设置",
                    overlayPermissionPendingIntent(),
                ).build(),
            )
        }
        return builder.build()
    }

    private fun overlayPermissionPendingIntent(): PendingIntent {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName"),
        )
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        return PendingIntent.getActivity(this, overlayPermissionRequestCode, intent, flags)
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
        val taskId = activeTaskId()
        val shouldClose = taskId != null && isTerminalStatus(taskStatuses[taskId])
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                if (shouldClose) putExtra(EXTRA_OPEN_TASK_ID, taskId)
            },
        )
        if (shouldClose && taskId != null) {
            sendOverlayTaskOpened(taskId)
            removeTask(taskId)
        }
    }

    private fun activeLabel(): String {
        val taskId = activeTaskId()
        return taskLabels[taskId] ?: "处理中"
    }

    private fun activeTaskId(): String? {
        return lastTaskId?.takeIf { taskIds.contains(it) } ?: taskIds.lastOrNull()
    }

    private fun activeStatus(): String {
        return taskStatuses[activeTaskId()] ?: "running"
    }

    private fun hasRunningTask(): Boolean {
        return taskIds.any { !isTerminalStatus(taskStatuses[it]) }
    }

    private fun isTerminalStatus(status: String?): Boolean {
        return status == "completed" ||
            status == "failed" ||
            status == "cancelled" ||
            status == "canceled" ||
            status == "unknown"
    }

    private fun normalizeTaskStatus(status: String?): String {
        return when (status?.trim()?.lowercase()) {
            "completed" -> "completed"
            "failed" -> "failed"
            "cancelled", "canceled" -> "cancelled"
            "unknown" -> "unknown"
            else -> "unknown"
        }
    }

    private fun terminalTaskLabel(status: String): String {
        return when (status) {
            "completed" -> "已完成"
            "failed" -> "执行失败"
            "cancelled" -> "已停止"
            else -> "状态未知"
        }
    }

    private fun activeApprovalLabel(): String? {
        return activeApproval()?.label
    }

    private fun activeApproval(): PendingApproval? {
        val activeTask = lastTaskId
        if (activeTask != null) {
            pendingApprovals[activeTask]?.let { return it }
        }
        return pendingApprovals.values.lastOrNull()
    }

    private fun resolveOverlayApproval(decision: String) {
        val taskId = lastApprovalTaskId() ?: return
        sendOverlayApprovalDecision(taskId, decision)
    }

    private fun lastApprovalTaskId(): String? {
        val activeTask = lastTaskId
        if (activeTask != null && pendingApprovals.containsKey(activeTask)) {
            return activeTask
        }
        return pendingApprovals.keys.lastOrNull()
    }

    private fun sendOverlayApprovalDecision(taskId: String, decision: String) {
        val engine = FlutterEngineCache.getInstance()
            .get(MobileAgentApplication.ENGINE_ID) ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, overlayEventsChannel)
            .invokeMethod(
                "overlayApprovalDecision",
                mapOf("taskId" to taskId, "decision" to decision),
            )
    }

    private fun activeTitle(): String {
        val taskId = activeTaskId()
        return taskTitles[taskId]?.takeIf { it.isNotBlank() } ?: "后台任务"
    }

    private fun activeRuntime(): String {
        val taskId = activeTaskId()
        val started = taskStartedAt[taskId] ?: System.currentTimeMillis()
        val ended = taskFinishedAt[taskId] ?: System.currentTimeMillis()
        val seconds = ((ended - started) / 1000L)
            .coerceAtLeast(0L)
        val hours = seconds / 3600L
        val minutes = (seconds % 3600L) / 60L
        val remaining = seconds % 60L
        return if (hours > 0) {
            "%02d:%02d:%02d".format(hours, minutes, remaining)
        } else {
            "%02d:%02d".format(minutes, remaining)
        }
    }

    private fun sendOverlayTaskOpened(taskId: String) {
        val engine = FlutterEngineCache.getInstance()
            .get(MobileAgentApplication.ENGINE_ID) ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, overlayEventsChannel)
            .invokeMethod(
                "overlayTaskOpened",
                mapOf("taskId" to taskId),
            )
    }

    private fun taskTitle(intent: Intent, taskId: String): String {
        return intent.getStringExtra(EXTRA_TASK_TITLE)?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: taskTitles[taskId]
            ?: "后台任务"
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
            refreshOverlayText()
            scheduleOverlayRefresh()
            return
        }
        val titleView = TextView(this).apply {
            setTextColor(Color.argb(245, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledSp(12f))
            setTypeface(Typeface.DEFAULT, Typeface.BOLD)
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        val actionView = TextView(this).apply {
            setTextColor(Color.argb(232, 214, 226, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledSp(11f))
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        val approvalLabelView = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledSp(12f))
            maxLines = 5
            ellipsize = TextUtils.TruncateAt.END
            setPadding(scaledDp(10), scaledDp(8), scaledDp(10), scaledDp(4))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }
        val approvalReadButton = approvalButton("仅读取", "read").apply {
            visibility = if (activeApproval()?.allowReadOnly == true) {
                View.VISIBLE
            } else {
                View.GONE
            }
        }
        val approvalView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = if (activeApproval() == null) View.GONE else View.VISIBLE
            background = GradientDrawable().apply {
                setColor(Color.argb(92, 255, 255, 255))
                cornerRadius = scaledDp(12).toFloat()
            }
            addView(approvalLabelView, approvalLabelView.layoutParams)
            addView(
                LinearLayout(this@AgentForegroundService).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.END
                    setPadding(
                        scaledDp(8),
                        scaledDp(2),
                        scaledDp(8),
                        scaledDp(8),
                    )
                    addView(approvalButton("拒绝", "deny"))
                    addView(approvalReadButton)
                    addView(approvalButton("允许", "allow"))
                },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                topMargin = scaledDp(6)
            }
        }
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
            setPadding(scaledDp(12), scaledDp(8), scaledDp(12), scaledDp(9))
            background = GradientDrawable().apply {
                colors = intArrayOf(
                    Color.argb(198, 57, 67, 88),
                    Color.argb(158, 28, 35, 51),
                )
                orientation = GradientDrawable.Orientation.TL_BR
                cornerRadius = scaledDp(18).toFloat()
                setStroke(dp(1), Color.argb(150, 232, 240, 255))
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                elevation = dp(8).toFloat()
            }
            setOnTouchListener { _, event -> handleOverlayTouch(event) }
            addView(
                titleView,
                titleView.layoutParams,
            )
            addView(
                actionView,
                (actionView.layoutParams as LinearLayout.LayoutParams).apply {
                    topMargin = scaledDp(2)
                },
            )
            addView(approvalView, approvalView.layoutParams)
        }
        val params = WindowManager.LayoutParams(
            overlayWindowWidth(),
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
            overlayTitleView = titleView
            overlayActionView = actionView
            overlayApprovalView = approvalView
            overlayApprovalLabelView = approvalLabelView
            overlayApprovalReadButton = approvalReadButton
            overlayParams = params
            refreshOverlayText()
            scheduleOverlayRefresh()
        } catch (_: SecurityException) {
            removeOverlay()
        } catch (_: IllegalStateException) {
            removeOverlay()
        }
    }

    private fun refreshOverlayText() {
        overlayTitleView?.text = "${activeTitle()}  ·  运行 ${activeRuntime()}"
        val approval = activeApproval()
        val status = activeStatus()
        overlayActionView?.text = if (approval != null) {
            "需要人工授权"
        } else if (isTerminalStatus(status)) {
            "● ${terminalTaskLabel(status)}"
        } else {
            activeLabel()
        }
        overlayActionView?.setTextColor(
            when {
                approval != null -> Color.argb(232, 255, 224, 150)
                status == "completed" -> Color.argb(245, 105, 225, 156)
                status == "failed" || status == "unknown" ->
                    Color.argb(245, 255, 120, 120)
                status == "cancelled" || status == "canceled" ->
                    Color.argb(245, 255, 196, 110)
                else -> Color.argb(232, 214, 226, 255)
            },
        )
        overlayApprovalView?.visibility =
            if (approval == null) View.GONE else View.VISIBLE
        overlayApprovalLabelView?.text = approval?.label.orEmpty()
        overlayApprovalReadButton?.visibility =
            if (approval?.allowReadOnly == true) View.VISIBLE else View.GONE
        updateOverlayApprovalLayout()
    }

    private fun approvalButton(label: String, decision: String): TextView {
        return TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, scaledSp(11f))
            gravity = Gravity.CENTER
            isClickable = true
            minWidth = scaledDp(54)
            setPadding(scaledDp(10), scaledDp(6), scaledDp(10), scaledDp(6))
            background = GradientDrawable().apply {
                setColor(
                    when (decision) {
                        "allow" -> Color.argb(215, 31, 113, 92)
                        "deny" -> Color.argb(185, 125, 52, 57)
                        else -> Color.argb(185, 56, 83, 126)
                    },
                )
                cornerRadius = scaledDp(9).toFloat()
            }
            text = label
            setOnClickListener { resolveOverlayApproval(decision) }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                marginStart = scaledDp(5)
            }
        }
    }

    private fun updateOverlayApprovalLayout() {
        val view = overlayView ?: return
        val params = overlayParams ?: return
        val hasApproval = activeApproval() != null
        val targetWidth = overlayWindowWidth()
        if (params.width != targetWidth) params.width = targetWidth
        if (hasApproval) {
            val screenWidth = resources.displayMetrics.widthPixels
            if (!approvalLayoutActive) {
                params.x = ((screenWidth - targetWidth) / 2).coerceAtLeast(dp(8))
                approvalLayoutActive = true
            }
            params.y = boundedY(params.y, view.height)
        } else {
            val restoreX = approvalRestoreX
            val restoreY = approvalRestoreY
            if (restoreX != null && restoreY != null) {
                params.x = restoreX
                params.y = restoreY
                if (approvalRestoreHidden) {
                    params.x = if (restoreX < resources.displayMetrics.widthPixels / 2) {
                        -targetWidth + dp(overlayVisiblePixels)
                    } else {
                        resources.displayMetrics.widthPixels - dp(overlayVisiblePixels)
                    }
                } else {
                    val maximumX = (resources.displayMetrics.widthPixels - targetWidth - dp(8))
                        .coerceAtLeast(dp(8))
                    params.x = params.x.coerceIn(dp(8), maximumX)
                }
                params.y = boundedY(params.y, view.height)
            }
            approvalRestoreX = null
            approvalRestoreY = null
            approvalRestoreHidden = false
            approvalLayoutActive = false
        }
        updateOverlayLayout(params)
    }

    private fun scheduleOverlayRefresh() {
        if (overlayRefreshScheduled || overlayView == null) return
        overlayRefreshScheduled = true
        overlayHandler.postDelayed(overlayRefreshRunnable, 1000L)
    }

    private fun removeOverlay() {
        overlayRefreshScheduled = false
        overlayHandler.removeCallbacks(overlayRefreshRunnable)
        val view = overlayView ?: return
        try {
            windowManager.removeView(view)
        } catch (_: IllegalArgumentException) {
            // The system may have removed the window already.
        }
        overlayView = null
        overlayTitleView = null
        overlayActionView = null
        overlayApprovalView = null
        overlayApprovalLabelView = null
        overlayApprovalReadButton = null
        overlayParams = null
        approvalRestoreX = null
        approvalRestoreY = null
        approvalRestoreHidden = false
        approvalLayoutActive = false
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
                    if (isTerminalStatus(taskStatuses[activeTaskId()])) {
                        openApp()
                    } else if (isHalfHidden()) {
                        revealOverlay()
                    } else {
                        openApp()
                    }
                } else if (isTouchingScreenEdge()) {
                    snapToEdge()
                } else {
                    keepOverlayVisible()
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                if (isTouchingScreenEdge()) snapToEdge() else keepOverlayVisible()
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
            .putBoolean("overlay_edge_hidden", true)
            .apply()
        updateOverlayLayout(params)
    }

    private fun keepOverlayVisible() {
        val view = overlayView ?: return
        val params = overlayParams ?: return
        val screenWidth = resources.displayMetrics.widthPixels
        val width = view.width.takeIf { it > 0 } ?: dp(120)
        val maximumX = (screenWidth - width - dp(8)).coerceAtLeast(dp(8))
        params.x = params.x.coerceIn(dp(8), maximumX)
        params.y = boundedY(params.y, view.height)
        preferences.edit()
            .putInt("overlay_x", params.x)
            .putInt("overlay_y", params.y)
            .putBoolean("overlay_edge_hidden", false)
            .apply()
        updateOverlayLayout(params)
    }

    private fun isTouchingScreenEdge(): Boolean {
        val view = overlayView ?: return false
        val params = overlayParams ?: return false
        val screenWidth = resources.displayMetrics.widthPixels
        return params.x <= 0 || params.x + view.width >= screenWidth
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
            .putBoolean("overlay_edge_hidden", false)
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
        val screenWidth = resources.displayMetrics.widthPixels
        val width = overlayWidth()
        if (!preferences.contains("overlay_x")) {
            return (screenWidth - width - scaledDp(overlayHorizontalMargin))
                .coerceAtLeast(scaledDp(overlayHorizontalMargin))
        }
        val savedX = preferences.getInt("overlay_x", 0)
        val edgeHidden = if (preferences.contains("overlay_edge_hidden")) {
            preferences.getBoolean("overlay_edge_hidden", false)
        } else {
            savedX < 0 || savedX >= screenWidth - dp(overlayVisiblePixels)
        }
        if (edgeHidden) {
            return if (savedX < screenWidth / 2) {
                -width + dp(overlayVisiblePixels)
            } else {
                screenWidth - dp(overlayVisiblePixels)
            }
        }
        val maximumX = (screenWidth - width - scaledDp(overlayHorizontalMargin))
            .coerceAtLeast(scaledDp(overlayHorizontalMargin))
        return savedX.coerceIn(scaledDp(overlayHorizontalMargin), maximumX)
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

    private fun scaledDp(value: Int): Int {
        return (value * overlayScale * resources.displayMetrics.density)
            .toInt()
            .coerceAtLeast(1)
    }

    private fun scaledSp(value: Float): Float = value * overlayScale

    private fun overlayWidth(): Int {
        return (scaledDp(overlayBaseWidth) * overlayLengthScale)
            .toInt()
            .coerceAtLeast(1)
    }

    private fun overlayWindowWidth(): Int {
        val screenWidth = resources.displayMetrics.widthPixels
        val available = (screenWidth - dp(24)).coerceAtLeast(dp(160))
        val normal = overlayWidth().coerceAtMost(available)
        if (activeApproval() == null) return normal
        val expanded = (screenWidth * 0.82f).toInt().coerceAtMost(dp(420))
        return expanded.coerceAtLeast(normal).coerceAtMost(available)
    }
}
