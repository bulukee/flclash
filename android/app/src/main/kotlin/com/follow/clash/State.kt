package com.follow.clash

import android.net.VpnService
import com.follow.clash.common.GlobalState
import com.follow.clash.models.SharedState
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.TilePlugin
import com.follow.clash.service.models.NotificationParams
import com.google.gson.Gson
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class RunState {
    START, PENDING, STOP
}


object State {

    val runLock = Mutex()

    @Volatile
    var shouldBeRunning: Boolean = false

    @Volatile
    private var hasExplicitRunIntent: Boolean = false

    @Volatile
    private var isStartingService: Boolean = false

    var runTime: Long = 0

    var sharedState: SharedState = SharedState()

    val runStateFlow: MutableStateFlow<RunState> = MutableStateFlow(RunState.STOP)

    var flutterEngine: FlutterEngine? = null

    val appPlugin: AppPlugin?
        get() = flutterEngine?.plugin<AppPlugin>()

    val tilePlugin: TilePlugin?
        get() = flutterEngine?.plugin<TilePlugin>()

    suspend fun handleToggleAction() {
        var action: (suspend () -> Unit)?
        runLock.withLock {
            action = when (runStateFlow.value) {
                RunState.PENDING -> null
                RunState.START -> ::handleStopServiceAction
                RunState.STOP -> ::handleStartServiceAction
            }
        }
        action?.invoke()
    }

    suspend fun handleSyncState() {
        runLock.withLock {
            try {
                Service.bind()
                runTime = Service.getRunTime()
                if (!hasExplicitRunIntent) {
                    shouldBeRunning = runTime != 0L
                }
                val runState = when (runTime == 0L) {
                    true -> RunState.STOP
                    false -> RunState.START
                }
                runStateFlow.tryEmit(runState)
            } catch (_: Exception) {
                runStateFlow.tryEmit(RunState.STOP)
            }
        }
    }

    fun handleServiceDisconnected(): Boolean {
        val wasRunning = shouldBeRunning && runStateFlow.value != RunState.STOP
        runStateFlow.tryEmit(RunState.STOP)
        return wasRunning
    }

    suspend fun recoverService(): Boolean {
        return runLock.withLock {
            if (!shouldBeRunning) return@withLock false
            try {
                setupAndStart()
                shouldBeRunning
            } catch (_: Exception) {
                runStateFlow.tryEmit(RunState.STOP)
                false
            }
        }
    }

    suspend fun handleStartServiceAction() {
        runLock.withLock {
            shouldBeRunning = true
            hasExplicitRunIntent = true
            if (runStateFlow.value != RunState.STOP) {
                return
            }
            tilePlugin?.handleStart()
            if (flutterEngine != null) {
                return
            }
            startServiceWithPref()
        }

    }

    suspend fun handleStopServiceAction() {
        shouldBeRunning = false
        hasExplicitRunIntent = true
        if (isStartingService) return
        runLock.withLock {
            if (runStateFlow.value != RunState.START &&
                runStateFlow.value != RunState.PENDING
            ) {
                return
            }
            tilePlugin?.handleStop()
            if (flutterEngine != null) {
                return
            }
            GlobalState.application.showToast(sharedState.stopTip)
            handleStopService()
        }
    }

    fun handleStartService() {
        shouldBeRunning = true
        hasExplicitRunIntent = true
        val appPlugin = flutterEngine?.plugin<AppPlugin>()
        if (appPlugin != null) {
            appPlugin.requestNotificationsPermission {
                startService()
            }
            return
        }
        startService()
    }

    private fun startServiceWithPref() {
        GlobalState.launch {
            runLock.withLock {
                if (!shouldBeRunning || runStateFlow.value != RunState.STOP) {
                    return@launch
                }
                sharedState = GlobalState.application.sharedState
                setupAndStart()
            }
        }
    }

    suspend fun syncState() {
        GlobalState.setCrashlytics(sharedState.crashlytics)
        Service.updateNotificationParams(
            NotificationParams(
                title = sharedState.currentProfileName,
                stopText = sharedState.stopText,
                onlyStatisticsProxy = sharedState.onlyStatisticsProxy
            )
        )
        Service.setCrashlytics(sharedState.crashlytics)
    }

    private suspend fun setupAndStart() {
        Service.bind()
        syncState()
        GlobalState.application.showToast(sharedState.startTip)
        val initParams = mutableMapOf<String, Any>()
        initParams["home-dir"] = GlobalState.application.filesDir.path
        initParams["version"] = android.os.Build.VERSION.SDK_INT
        val initParamsString = Gson().toJson(initParams)
        val setupParamsString = Gson().toJson(sharedState.setupParams)
        val result = Service.quickSetup(
            initParamsString,
            setupParamsString,
            onStarted = {
                startService()
            },
            onResult = {
                if (it.isNotEmpty()) {
                    GlobalState.application.showToast(it)
                }
            },
        )
        result.getOrElse { throw it }
    }

    private fun startService() {
        GlobalState.launch {
            runLock.withLock {
                if (!shouldBeRunning || runStateFlow.value != RunState.STOP) {
                    return@launch
                }
                if (isStartingService) return@launch
                isStartingService = true
                try {
                    runStateFlow.tryEmit(RunState.PENDING)
                    val options = sharedState.vpnOptions ?: return@launch
                    appPlugin?.let {
                        it.prepare(options.enable) {
                            if (!shouldBeRunning) return@prepare
                            val startedAt = Service.startService(options, runTime)
                            if (shouldBeRunning) {
                                runTime = startedAt
                                runStateFlow.tryEmit(RunState.START)
                            } else {
                                runTime = Service.stopService()
                                runStateFlow.tryEmit(RunState.STOP)
                            }
                        }
                    } ?: run {
                        val intent = VpnService.prepare(GlobalState.application)
                        if (intent != null) {
                            return@launch
                        }
                        if (!shouldBeRunning) return@launch
                        val startedAt = Service.startService(options, runTime)
                        if (shouldBeRunning) {
                            runTime = startedAt
                            runStateFlow.tryEmit(RunState.START)
                        } else {
                            runTime = Service.stopService()
                            runStateFlow.tryEmit(RunState.STOP)
                        }
                    }
                } finally {
                    isStartingService = false
                    if (runStateFlow.value == RunState.PENDING) {
                        runStateFlow.tryEmit(RunState.STOP)
                    }
                }
            }
        }
    }

    fun handleStopService() {
        shouldBeRunning = false
        hasExplicitRunIntent = true
        if (isStartingService) return
        GlobalState.launch {
            runLock.withLock {
                if (runStateFlow.value != RunState.START &&
                    runStateFlow.value != RunState.PENDING
                ) {
                    return@launch
                }
                try {
                    runStateFlow.tryEmit(RunState.PENDING)
                    runTime = Service.stopService()
                    runStateFlow.tryEmit(RunState.STOP)
                } finally {
                    if (runStateFlow.value == RunState.PENDING) {
                        runStateFlow.tryEmit(
                            if (shouldBeRunning) RunState.START else RunState.STOP
                        )
                    }
                }
            }
        }
    }
}



