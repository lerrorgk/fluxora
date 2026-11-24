package io.fluxora.app.services

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.Toast
import io.fluxora.app.GlobalState
import io.fluxora.app.R
import io.fluxora.app.RunState
import io.fluxora.app.plugins.VpnPlugin
import io.flutter.plugin.common.MethodChannel

/// Receives the notification's action buttons.
///
/// `PendingIntent.getService` never reached `onStartCommand`, so the actions are
/// delivered as broadcasts (what ownbox does too). The Dart call goes through a
/// channel built from the cached engine rather than through the plugin
/// instance: the plugin lookup came back empty on device, which is why the taps
/// arrived here and then went nowhere.
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        val action = intent?.action ?: return
        Log.i(TAG, "received $action")

        // Stop reuses the quick-settings tile path: the tile toggles the service
        // from outside the UI and it works, so it is the one stop sequence that
        // is known to complete without a Flutter screen attached.
        if (action == FluxoraService.ACTION_STOP) {
            val stopped = runCatching {
                GlobalState.handleStop(skipDebounce = true)
                true
            }.getOrElse {
                Log.e(TAG, "stop via GlobalState failed: ${it.message}")
                false
            }
            Log.i(TAG, "stop -> GlobalState.handleStop handled=$stopped")

            // If the state machine thought it was already stopped, force it.
            if (!stopped || GlobalState.currentRunState == RunState.START) {
                runCatching { GlobalState.handleStop(skipDebounce = true) }
            }
            context?.let {
                it.stopService(Intent(it, FluxoraVpnService::class.java))
                it.stopService(Intent(it, FluxoraService::class.java))
            }
            return
        }

        if (action == FluxoraService.ACTION_RESET) {
            reset(context?.applicationContext)
            return
        }
        if (action == FluxoraService.ACTION_SPEED_TEST) {
            val engine = GlobalState.flutterEngine ?: return
            runCatching {
                MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                    .invokeMethod("notificationSpeedTest", null)
            }.onFailure { Log.e(TAG, "Speed test: invoke failed", it) }
        }
    }

    private fun reset(context: Context?) {
        fun failed(reason: String?) {
            Log.e(TAG, "Notification reset failed: $reason")
            context?.let { Toast.makeText(it, R.string.notification_reset_failed, Toast.LENGTH_SHORT).show() }
        }
        val engine = GlobalState.notificationEngine() ?: return failed("No running engine")
        val callback = object : MethodChannel.Result {
            override fun success(result: Any?) = VpnPlugin.flashActiveNotification()
            override fun error(code: String, message: String?, details: Any?) = failed(message ?: code)
            override fun notImplemented() = failed("No reset handler")
        }
        runCatching {
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("notificationReset", null, callback)
        }.onFailure { failed(it.message) }
    }

    companion object {
        private const val TAG = "NotificationAction"
        private const val CHANNEL = "vpn"
    }
}
