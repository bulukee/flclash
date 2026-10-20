package com.follow.clash.plugins

import com.follow.clash.Service
import com.follow.clash.State
import com.follow.clash.common.Components
import com.follow.clash.invokeMethodOnMainThread
import com.follow.clash.models.SharedState
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.concurrent.atomic.AtomicBoolean

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    private lateinit var flutterMethodChannel: MethodChannel
    @Volatile
    private var recoveryJob: Job? = null

    @Volatile
    private var recoverRunningService = false

    @Volatile
    private var intentionallyShutdown = false

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterMethodChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger, "${Components.PACKAGE_NAME}/service"
        )
        flutterMethodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        intentionallyShutdown = true
        Service.onServiceDisconnected = null
        recoveryJob?.cancel()
        flutterMethodChannel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = when (call.method) {
        "init" -> {
            handleInit(result)
        }

        "shutdown" -> {
            handleShutdown(result)
        }

        "invokeAction" -> {
            handleInvokeAction(call, result)
        }

        "getRunTime" -> {
            handleGetRunTime(result)
        }

        "syncState" -> {
            handleSyncState(call, result)
        }

        "start" -> {
            handleStart(result)
        }

        "stop" -> {
            handleStop(result)
        }

        else -> {
            result.notImplemented()
        }
    }

    private fun handleInvokeAction(call: MethodCall, result: MethodChannel.Result) {
        launch {
            val data = call.arguments<String>()
            if (data == null) {
                result.error("INVALID_ACTION", "Core action is missing", null)
                return@launch
            }
            val completed = AtomicBoolean(false)
            Service.invokeAction(data) {
                if (completed.compareAndSet(false, true)) {
                    result.success(it)
                }
            }.onFailure {
                if (completed.compareAndSet(false, true)) {
                    result.error("CORE_UNAVAILABLE", "Core service request failed", null)
                }
            }
        }
    }

    private fun handleShutdown(result: MethodChannel.Result) {
        intentionallyShutdown = true
        recoveryJob?.cancel()
        Service.unbind()
        result.success(true)
    }

    private fun handleStart(result: MethodChannel.Result) {
        recoveryJob?.cancel()
        recoverRunningService = false
        intentionallyShutdown = false
        State.handleStartService()
        result.success(true)
    }

    private fun handleStop(result: MethodChannel.Result) {
        recoveryJob?.cancel()
        recoverRunningService = false
        State.handleStopService()
        result.success(true)
    }

    val semaphore = Semaphore(10)

    fun handleSendEvent(value: String?) {
        launch(Dispatchers.Main) {
            semaphore.withPermit {
                flutterMethodChannel.invokeMethod("event", value)
            }
        }
    }

    private fun onServiceDisconnected(message: String) {
        if (intentionallyShutdown) return
        recoverRunningService = State.handleServiceDisconnected() || recoverRunningService
        flutterMethodChannel.invokeMethodOnMainThread<Any>("crash", message)
        if (!intentionallyShutdown) {
            scheduleRecovery()
        }
    }

    @Synchronized
    private fun scheduleRecovery() {
        if (recoveryJob?.isActive == true) return
        recoveryJob = launch(start = CoroutineStart.LAZY) {
            repeat(6) { attempt ->
                delay(if (attempt == 0) 300L else minOf(8_000L, 500L * (1L shl attempt)))
                Service.bind()
                val listenerResult = Service.setEventListener { handleSendEvent(it) }
                coroutineContext.ensureActive()
                if (listenerResult.isSuccess) {
                    if (recoverRunningService) {
                        if (!State.shouldBeRunning) {
                            recoverRunningService = false
                        }
                    }
                    if (recoverRunningService) {
                        if (!State.recoverService()) {
                            if (!State.shouldBeRunning) {
                                flutterMethodChannel.invokeMethodOnMainThread<Any>("recovered", null)
                                return@launch
                            }
                            return@repeat
                        }
                        if (!State.shouldBeRunning) {
                            flutterMethodChannel.invokeMethodOnMainThread<Any>("recovered", null)
                            return@launch
                        }
                    }
                    flutterMethodChannel.invokeMethodOnMainThread<Any>("recovered", null)
                    return@launch
                }
            }
            flutterMethodChannel.invokeMethodOnMainThread<Any>("recoveryFailed", null)
        }
        recoveryJob?.start()
    }

    private fun handleSyncState(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments<String>()!!
        State.sharedState = Gson().fromJson(data, SharedState::class.java)
        launch {
            State.syncState()
            result.success("")
        }
    }


    fun handleInit(result: MethodChannel.Result) {
        recoveryJob?.cancel()
        recoverRunningService = false
        intentionallyShutdown = false
        Service.onServiceDisconnected = ::onServiceDisconnected
        Service.bind()
        launch {
            Service.setEventListener {
                handleSendEvent(it)
            }.onSuccess {
                result.success("")
            }.onFailure {
                result.success(it.message)
            }

        }
    }

    private fun handleGetRunTime(result: MethodChannel.Result) {
        launch {
            State.handleSyncState()
            result.success(State.runTime)
        }
    }
}
