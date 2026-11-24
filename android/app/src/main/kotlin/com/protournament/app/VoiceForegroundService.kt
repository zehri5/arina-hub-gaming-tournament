package com.protournament.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * BACKGROUND VOICE FIX (2026-10-30 user report: background me awaz
 * na aati hai na jati hai). Android suspends a backgrounded app's
 * Dart timers and blocks background mic access, so without a
 * foreground service the WebRTC session dies the moment the user
 * switches apps — even though the room page is still in the nav
 * stack and _room.leave() was never called. This service does NO
 * audio work itself; its existence as a foreground service keeps
 * this process (and its WebRTC mic + peer connections) alive while
 * the user is on voice. Started by Dart when voice joins, stopped
 * when voice leaves. The notification is mandatory for foreground
 * services and tells the user voice is still live; tapping it
 * returns to the app.
 */
class VoiceForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "pro_tournament_voice"
        const val NOTIFICATION_ID = 1
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Voice chat",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }
        val openIntent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification: Notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Pro Tournament voice chat")
                .setContentText("Voice chat chal rahi hai — wapas jane ke liye tap karein.")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pending)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("Pro Tournament voice chat")
                .setContentText("Voice chat chal rahi hai — wapas jane ke liye tap karein.")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentIntent(pending)
                .setOngoing(true)
                .build()
        }
        // ANDROID 14/15: startForeground MUST carry the microphone
        // type (declared in the manifest) or the system can throw
        // and kill the app on voice join. Never let this service
        // crash the app: on failure, stop quietly — voice itself
        // keeps working, only background persistence is lost.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (_: Exception) {
            stopSelf()
            return START_NOT_STICKY
        }
        // FIX 33 — STICKY NOTIFICATION (2026-11-24 user report:
        // the notification stayed in the shade after leaving the
        // voice room and could not be swiped away). This used to
        // return START_STICKY: if the process died while the
        // service was started (user swiped the app from recents
        // while on voice, or the system killed the backgrounded
        // process), Android RESTARTED the service in a fresh
        // process with no Flutter engine and no Dart alive — so
        // onStartCommand re-posted the ongoing notification and
        // NOTHING could ever stop it (no Dart to invoke 'stop',
        // and setOngoing(true) blocks the user from dismissing
        // it). START_NOT_STICKY: a dead service stays dead; the
        // app explicitly starts it on every voice join, so normal
        // operation — including background voice while the app is
        // alive — is unchanged.
        return START_NOT_STICKY
    }

    // FIX 33: the user swiped the app from recents — the task is
    // gone, so the voice session behind this service is gone too.
    // Stop with the task instead of lingering (and, pre-fix,
    // restarting) with an undismissable notification. Home-button
    // / app-switch backgrounding does NOT remove the task, so
    // background voice keeps working — this fires only when the
    // user explicitly kills the app.
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopForeground(true)
        super.onDestroy()
    }
}
