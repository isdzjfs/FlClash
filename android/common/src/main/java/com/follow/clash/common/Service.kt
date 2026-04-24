package com.follow.clash.common

import android.content.Intent
import android.os.IBinder
import kotlinx.coroutines.CoroutineScope
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
    private val onServiceConnected: (() -> Unit)? = null,
    private val onServiceDisconnected: ((String) -> Unit)? = null,
    private val interfaceCreator: (IBinder) -> T,
) : CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {

    private val _bindingState = AtomicBoolean(false)

    private var _serviceState = MutableStateFlow<Pair<T?, String>?>(null)

    val serviceState: StateFlow<Pair<T?, String>?> = _serviceState
    private var job: Job? = null

    private fun handleBind(data: Pair<IBinder?, String>) {
        val binder = data.first
        if (binder != null) {
            _serviceState.value = Pair(interfaceCreator(binder), data.second)
            onServiceConnected?.invoke()
        } else {
            // onServiceDisconnected: the remote process crashed or was killed.
            // Android will automatically try to rebind, so do NOT unbind here.
            // Just reset the state so useService will block until reconnected.
            GlobalState.log("[ServiceDelegate] onServiceDisconnected: ${data.second}, waiting for rebind...")
            _serviceState.value = null
            onServiceDisconnected?.invoke(data.second)
        }
    }

    fun bind() {
        if (_bindingState.compareAndSet(false, true)) {
            job?.cancel()
            job = null
            _serviceState.value = null
            job = launch {
                runCatching {
                    GlobalState.application.bindServiceFlow<IBinder>(intent)
                        .collect { handleBind(it) }
                }
            }
        }
    }

    suspend inline fun <R> useService(
        timeoutMillis: Long = 15000, crossinline block: suspend (T) -> R
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

    fun unbind() {
        if (_bindingState.compareAndSet(true, false)) {
            job?.cancel()
            job = null
            _serviceState.value = null
        }
    }
}
