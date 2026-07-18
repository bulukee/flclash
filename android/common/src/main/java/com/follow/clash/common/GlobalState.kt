package com.follow.clash.common


import android.app.Application
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers

object GlobalState : CoroutineScope by CoroutineScope(Dispatchers.Default) {

    const val NOTIFICATION_CHANNEL = "FlClash"

    const val NOTIFICATION_ID = 1

    val packageName: String
        get() = application.packageName

    val RECEIVE_BROADCASTS_PERMISSIONS: String
        get() = "${packageName}.permission.RECEIVE_BROADCASTS"


    private var _application: Application? = null

    val application: Application
        get() = _application!!


    fun log(text: String) {
        Log.d("[FlClash]", text)
    }

    fun init(application: Application) {
        _application = application
    }

    fun setCrashlytics(enable: Boolean) {
        // Crash reporting is intentionally disabled in the branded build.
        // Keep this compatibility method because the Flutter bridge may still
        // call it when restoring settings from older installations.
        if (enable) log("crash reporting is unavailable in this build")
    }
}
