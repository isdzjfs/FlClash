package com.follow.clash.plugins

import com.follow.clash.RunState
import com.follow.clash.Service
import com.follow.clash.State
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import com.follow.clash.invokeMethodOnMainThread
import com.follow.clash.models.SharedState
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    companion object {
        private const val DISCONNECT_REPORT_DELAY_MS = 3500L
        private const val SERVICE_START_TIMEOUT_MS = 20000L
        private const val SERVICE_SYNC_TIMEOUT_MS = 5000L
    }

    private lateinit var flutterMethodChannel: MethodChannel
    private val gson = Gson()
    private var pendingDisconnectJob: Job? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterMethodChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger, "${Components.PACKAGE_NAME}/service"
        )
        flutterMethodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        flutterMethodChannel.setMethodCallHandler(null)
        pendingDisconnectJob?.cancel()
        pendingDisconnectJob = null
        Service.onServiceConnected = null
        Service.onServiceDisconnected = null
        coroutineContext[Job]?.cancel()
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
            val data = call.arguments<String>()!!
            Service.invokeAction(data) { result.success(it) }
                .onFailure {
                    GlobalState.log("[ServicePlugin] handleInvokeAction() failed: ${it.message}")
                    result.success(null)
                }
        }
    }

    private fun handleShutdown(result: MethodChannel.Result) {
        pendingDisconnectJob?.cancel()
        pendingDisconnectJob = null
        Service.unbind()
        result.success(true)
    }

    private fun handleStart(result: MethodChannel.Result) {
        launch {
            State.handleStartService()
            val started = State.waitForStart(
                timeoutMillis = SERVICE_START_TIMEOUT_MS,
                syncTimeoutMillis = SERVICE_SYNC_TIMEOUT_MS
            )
            GlobalState.log(
                "[ServicePlugin] handleStart() completed, started=$started, runTime=${State.runTime}"
            )
            result.success(started)
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
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

    private fun onServiceConnected() {
        if (pendingDisconnectJob != null) {
            GlobalState.log("[ServicePlugin] onServiceConnected: cancel pending disconnect report")
        }
        pendingDisconnectJob?.cancel()
        pendingDisconnectJob = null
    }

    private fun onServiceDisconnected(message: String) {
        GlobalState.log("[ServicePlugin] onServiceDisconnected: $message, waiting for rebind")
        pendingDisconnectJob?.cancel()
        pendingDisconnectJob = launch {
            delay(DISCONNECT_REPORT_DELAY_MS)
            GlobalState.log(
                "[ServicePlugin] onServiceDisconnected: rebind timed out, reporting crash: $message"
            )
            State.runStateFlow.tryEmit(RunState.STOP)
            flutterMethodChannel.invokeMethodOnMainThread<Any>("crash", message)
            pendingDisconnectJob = null
        }
    }

    private fun handleSyncState(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments<String>()!!
        State.sharedState = gson.fromJson(data, SharedState::class.java)
        launch {
            State.syncState()
            result.success("")
        }
    }


    fun handleInit(result: MethodChannel.Result) {
        GlobalState.log("[ServicePlugin] handleInit() start")
        Service.bind()
        Service.onServiceConnected = ::onServiceConnected
        Service.onServiceDisconnected = ::onServiceDisconnected
        launch {
            var lastError: String? = null
            for (attempt in 1..3) {
                GlobalState.log("[ServicePlugin] handleInit() attempt $attempt")
                Service.setEventListener { handleSendEvent(it) }
                    .onSuccess {
                        GlobalState.log("[ServicePlugin] handleInit() SUCCESS on attempt $attempt")
                        result.success("")
                        return@launch
                    }.onFailure {
                        GlobalState.log("[ServicePlugin] handleInit() FAILED on attempt $attempt: ${it.message}")
                        lastError = it.message
                        if (attempt < 3) {
                            delay(2000)
                        }
                    }
            }
            GlobalState.log("[ServicePlugin] handleInit() all attempts failed, returning: $lastError")
            result.success(lastError)
        }
    }

    private fun handleGetRunTime(result: MethodChannel.Result) {
        launch {
            State.handleSyncState(timeoutMillis = SERVICE_SYNC_TIMEOUT_MS)
            result.success(State.runTime)
        }
    }
}
