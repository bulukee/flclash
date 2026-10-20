package com.follow.clash.common

import android.content.Intent
import android.os.IBinder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.util.concurrent.atomic.AtomicBoolean

class ServiceDelegate<T>(
    private val intent: Intent,
    private val onServiceDisconnected: ((String) -> Unit)? = null,
    private val interfaceCreator: (IBinder) -> T,
) : CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {

    private val _bindingState = AtomicBoolean(false)

    private var _serviceState = MutableStateFlow<Pair<T?, String>?>(null)

    val serviceState: StateFlow<Pair<T?, String>?> = _serviceState
    private var job: Job? = null
    private var generation = 0L

    private fun handleBind(bindingGeneration: Long, data: Pair<IBinder?, String>) {
        val disconnected = synchronized(this) {
            if (bindingGeneration != generation || !_bindingState.get()) return
            val binder = data.first
            if (binder != null) {
                _serviceState.value = Pair(interfaceCreator(binder), data.second)
                false
            } else {
                _serviceState.value = Pair(null, data.second)
                _bindingState.set(false)
                job?.cancel()
                job = null
                true
            }
        }
        if (disconnected) onServiceDisconnected?.invoke(data.second)
    }

    @Synchronized
    fun bind() {
        if (_bindingState.compareAndSet(false, true)) {
            job?.cancel()
            job = null
            _serviceState.value = null
            val bindingGeneration = ++generation
            job = launch(start = CoroutineStart.LAZY) {
                try {
                    GlobalState.application.bindServiceFlow<IBinder>(intent)
                        .collect { handleBind(bindingGeneration, it) }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    handleBind(bindingGeneration, Pair(null, error.message ?: "Service binding failed"))
                }
            }
            job?.start()
        }
    }

    suspend inline fun <R> useService(
        timeoutMillis: Long = 5000, crossinline block: suspend (T) -> R
    ): Result<R> {
        return runCatching {
            withTimeout(timeoutMillis) {
                val state = serviceState.filterNotNull().first()
                state.first?.let {
                    withContext(Dispatchers.Default) {
                        block(it)
                    }
                } ?: throw Exception(state.second)
            }
        }
    }

    @Synchronized
    fun unbind() {
        generation++
        _bindingState.set(false)
        job?.cancel()
        job = null
        _serviceState.value = null
    }
}
