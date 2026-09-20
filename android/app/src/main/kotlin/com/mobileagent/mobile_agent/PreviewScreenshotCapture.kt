package com.mobileagent.mobile_agent_v1

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.Locale

/**
 * Renders a loopback page in a fresh, offscreen WebView and returns that
 * WebView's viewport as PNG bytes. It never captures the Activity window or a
 * WebView used by the visible app UI. Regular HTML/CSS and 2D canvas content
 * use the View drawing path; hardware-backed WebGL and video surfaces may not
 * be included in the bitmap.
 */
class PreviewScreenshotCapture(private val activity: Activity) {
    companion object {
        private const val DEFAULT_WIDTH = 1024
        private const val DEFAULT_HEIGHT = 768
        private const val MAX_VIEWPORT_DIMENSION = 2048
        private const val CAPTURE_TIMEOUT_MS = 15_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var activeRequest: CaptureRequest? = null
    private var disposed = false

    fun capture(call: MethodCall, result: MethodChannel.Result) {
        runOnMain {
            captureOnMain(call, result)
        }
    }

    fun dispose() {
        runOnMain {
            disposed = true
            activeRequest?.fail(
                code = "disposed",
                message = "Preview screenshot capture was disposed",
            )
        }
    }

    private fun captureOnMain(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("disposed", "Preview screenshot capture was disposed", null)
            return
        }
        if (activeRequest != null) {
            result.error("busy", "A preview screenshot capture is already running", null)
            return
        }

        val arguments = call.arguments as? Map<*, *>
        val url = arguments?.get("url") as? String
        if (url.isNullOrBlank() || !isAllowedLoopbackUrl(url)) {
            result.error(
                "invalid_url",
                "Preview capture requires an http URL on 127.0.0.1, localhost, or [::1]",
                null,
            )
            return
        }

        val width = readDimension(arguments, "width", DEFAULT_WIDTH)
        val height = readDimension(arguments, "height", DEFAULT_HEIGHT)
        if (width == null || height == null || !isValidDimension(width) || !isValidDimension(height)) {
            result.error(
                "invalid_viewport",
                "Preview capture width and height must be integers from 1 to $MAX_VIEWPORT_DIMENSION",
                null,
            )
            return
        }

        val request = CaptureRequest(url, width, height, result)
        activeRequest = request
        request.start()
    }

    private fun readDimension(arguments: Map<*, *>?, key: String, default: Int): Int? {
        if (arguments == null || !arguments.containsKey(key)) return default
        val value = arguments[key] ?: return null
        return when (value) {
            is Int -> value
            is Long -> if (value in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                value.toInt()
            } else {
                null
            }
            else -> null
        }
    }

    private fun isValidDimension(value: Int): Boolean {
        return value in 1..MAX_VIEWPORT_DIMENSION
    }

    private fun isAllowedLoopbackUrl(value: String): Boolean {
        val uri = try {
            Uri.parse(value)
        } catch (_: RuntimeException) {
            return false
        }
        if (!uri.isHierarchical || uri.scheme?.lowercase(Locale.ROOT) != "http") return false
        if (uri.userInfo != null) return false

        val host = uri.host?.lowercase(Locale.ROOT) ?: return false
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }

    private inner class CaptureRequest(
        private val url: String,
        private val width: Int,
        private val height: Int,
        private val result: MethodChannel.Result,
    ) {
        private var webView: WebView? = null
        private var webViewParent: ViewGroup? = null
        private var visualStateCallbackPosted = false
        private var completed = false

        private val timeout = Runnable {
            fail(
                code = "timeout",
                message = "Timed out waiting for the loopback page to load and render",
            )
        }

        fun start() {
            try {
                val view = WebView(activity)
                webView = view
                configure(view)
                attachBehindFlutter(view)
                mainHandler.postDelayed(timeout, CAPTURE_TIMEOUT_MS)
                view.loadUrl(url)
            } catch (error: Throwable) {
                fail(
                    code = "capture_start_failed",
                    message = error.message ?: "Could not start the preview WebView",
                )
            }
        }

        private fun configure(view: WebView) {
            val settings = view.settings
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.useWideViewPort = false
            settings.loadWithOverviewMode = false
            settings.setSupportZoom(false)
            settings.builtInZoomControls = false
            settings.displayZoomControls = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.allowFileAccessFromFileURLs = false
            settings.allowUniversalAccessFromFileURLs = false
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // The attached back-layer view is still offscreen from the user's
                // perspective; pre-raster keeps its visual state renderable.
                settings.setOffscreenPreRaster(true)
            }

            view.setBackgroundColor(Color.WHITE)
            view.isHorizontalScrollBarEnabled = false
            view.isVerticalScrollBarEnabled = false
            view.overScrollMode = View.OVER_SCROLL_NEVER
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest,
                ): Boolean {
                    if (!request.isForMainFrame) return false
                    if (isAllowedLoopbackUrl(request.url.toString())) return false
                    fail(
                        code = "navigation_blocked",
                        message = "Blocked navigation to a non-loopback URL",
                    )
                    return true
                }

                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                    super.onPageStarted(view, url, favicon)
                    if (completed) return
                    if (!isAllowedLoopbackUrl(url)) {
                        view.stopLoading()
                        fail(
                            code = "navigation_blocked",
                            message = "Blocked navigation to a non-loopback URL",
                        )
                    }
                }

                override fun onPageFinished(view: WebView, url: String) {
                    super.onPageFinished(view, url)
                    if (completed) return
                    if (!isAllowedLoopbackUrl(url)) {
                        fail(
                            code = "navigation_blocked",
                            message = "The preview finished on a non-loopback URL",
                        )
                        return
                    }
                    if (visualStateCallbackPosted) return
                    visualStateCallbackPosted = true

                    // onPageFinished is not a paint completion signal. This callback
                    // waits until the WebView's current visual state is drawn.
                    view.postVisualStateCallback(System.nanoTime(), object : WebView.VisualStateCallback() {
                        override fun onComplete(requestId: Long) {
                            if (activeRequest === this@CaptureRequest && !completed) {
                                captureViewport(view)
                            }
                        }
                    })
                }

                override fun onReceivedError(
                    view: WebView,
                    request: WebResourceRequest,
                    error: WebResourceError,
                ) {
                    super.onReceivedError(view, request, error)
                    if (request.isForMainFrame) {
                        fail(
                            code = "load_failed",
                            message = error.description?.toString()
                                ?: "The preview page could not be loaded",
                        )
                    }
                }

                override fun onReceivedHttpError(
                    view: WebView,
                    request: WebResourceRequest,
                    errorResponse: android.webkit.WebResourceResponse,
                ) {
                    super.onReceivedHttpError(view, request, errorResponse)
                    if (request.isForMainFrame && errorResponse.statusCode >= 400) {
                        fail(
                            code = "load_failed",
                            message = "The preview page returned HTTP ${errorResponse.statusCode}",
                        )
                    }
                }
            }
        }

        private fun attachBehindFlutter(view: WebView) {
            val content = activity.findViewById<ViewGroup>(android.R.id.content)
                ?: throw IllegalStateException("Activity content view is not ready")
            if (!content.isAttachedToWindow) {
                throw IllegalStateException("Activity content view is not attached")
            }

            // postVisualStateCallback is only reliable for an attached WebView.
            // Keep this fresh renderer behind Flutter's existing content so it
            // remains invisible to the user while still having a window token.
            content.addView(
                view,
                0,
                ViewGroup.LayoutParams(width, height),
            )
            webViewParent = content
            val widthSpec = View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY)
            val heightSpec = View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)
            view.measure(widthSpec, heightSpec)
            view.layout(0, 0, width, height)
        }

        private fun captureViewport(view: WebView) {
            if (completed) return
            if (view.width != width || view.height != height) {
                val widthSpec = View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY)
                val heightSpec = View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)
                view.measure(widthSpec, heightSpec)
                view.layout(0, 0, width, height)
            }

            val bitmap = try {
                Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            } catch (error: Throwable) {
                fail(
                    code = "capture_failed",
                    message = error.message ?: "Could not allocate the preview bitmap",
                )
                return
            }

            try {
                val canvas = Canvas(bitmap)
                canvas.drawColor(Color.WHITE)
                view.scrollTo(0, 0)
                view.draw(canvas)

                val output = ByteArrayOutputStream()
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                    fail("capture_failed", "Could not encode the preview as PNG")
                    return
                }
                complete(output.toByteArray())
            } catch (error: Throwable) {
                fail(
                    code = "capture_failed",
                    message = error.message ?: "Could not render the preview viewport",
                )
            } finally {
                bitmap.recycle()
            }
        }

        fun fail(code: String, message: String) {
            if (completed) return
            completed = true
            cleanup()
            result.error(code, message, null)
        }

        private fun complete(bytes: ByteArray) {
            if (completed) return
            completed = true
            cleanup()
            result.success(bytes)
        }

        private fun cleanup() {
            mainHandler.removeCallbacks(timeout)
            val view = webView
            webView = null
            if (view != null) {
                view.stopLoading()
                view.onPause()
                view.removeAllViews()
                val parent = webViewParent
                if (parent != null && view.parent === parent) {
                    parent.removeView(view)
                }
                view.destroy()
            }
            webViewParent = null
            if (activeRequest === this) activeRequest = null
        }
    }
}
