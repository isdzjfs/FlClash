package com.follow.clash

import android.net.VpnService
import com.follow.clash.common.GlobalState
import com.follow.clash.models.SharedState
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.TilePlugin
import com.follow.clash.service.models.NotificationParams
import com.google.gson.Gson
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class RunState {
    START, PENDING, STOP
}

private const val DEFAULT_SYNC_STATE_TIMEOUT_MS = 5000L
private const val SERVICE_START_WAIT_TIMEOUT_MS = 20000L
private const val SERVICE_START_WAIT_INTERVAL_MS = 300L


object State {

    val runLock = Mutex()

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

    suspend fun handleSyncState(timeoutMillis: Long = DEFAULT_SYNC_STATE_TIMEOUT_MS) {
        runLock.withLock {
            try {
                Service.bind()
                runTime = Service.getRunTime(timeoutMillis)
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

    suspend fun waitForStart(
        timeoutMillis: Long = SERVICE_START_WAIT_TIMEOUT_MS,
        syncTimeoutMillis: Long = DEFAULT_SYNC_STATE_TIMEOUT_MS
    ): Boolean {
        if (runTime != 0L) {
            return true
        }
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            handleSyncState(timeoutMillis = syncTimeoutMillis)
            if (runTime != 0L) {
                return true
            }
            delay(SERVICE_START_WAIT_INTERVAL_MS)
        }
        handleSyncState(timeoutMillis = syncTimeoutMillis)
        return runTime != 0L
    }

    suspend fun handleStartServiceAction() {
        runLock.withLock {
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
        runLock.withLock {
            if (runStateFlow.value != RunState.START) {
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
                if (runStateFlow.value != RunState.STOP) {
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
//        GlobalState.application.showToast(sharedState.startTip)
        val initParams = mutableMapOf<String, Any>()
        initParams["home-dir"] = GlobalState.application.filesDir.path
        initParams["version"] = android.os.Build.VERSION.SDK_INT
        val initParamsString = Gson().toJson(initParams)
        val setupParamsString = Gson().toJson(sharedState.setupParams)
        Service.quickSetup(
            initParamsString,
            setupParamsString,
            onStarted = {
            },
            onResult = {
                if (it.isNotEmpty()) {
                    GlobalState.application.showToast(it)
                }
                startService()
            },
        )
    }

    private fun startService() {
        GlobalState.launch {
            runLock.withLock {
                if (runStateFlow.value != RunState.STOP) {
                    return@launch
                }
                try {
                    runStateFlow.tryEmit(RunState.PENDING)
                    val options = sharedState.vpnOptions ?: return@launch
                    appPlugin?.let {
                        it.prepare(options.enable) {
                            val nextRunTime = Service.startService(options, runTime)
                            if (nextRunTime == 0L) {
                                runTime = 0L
                                GlobalState.log("State.startService failed: runtime unavailable")
                                runStateFlow.tryEmit(RunState.STOP)
                                return@prepare
                            }
                            runTime = nextRunTime
                            runStateFlow.tryEmit(RunState.START)
                        }
                    } ?: run {
                        val intent = VpnService.prepare(GlobalState.application)
                        if (intent != null) {
                            return@launch
                        }
                        val nextRunTime = Service.startService(options, runTime)
                        if (nextRunTime == 0L) {
                            runTime = 0L
                            GlobalState.log("State.startService failed: runtime unavailable")
                            return@launch
                        }
                        runTime = nextRunTime
                        runStateFlow.tryEmit(RunState.START)
                    }
                } finally {
                    if (runStateFlow.value == RunState.PENDING) {
                        runStateFlow.tryEmit(RunState.STOP)
                    }
                }
            }
        }
    }

    fun handleStopService() {
        GlobalState.launch {
            runLock.withLock {
                if (runStateFlow.value != RunState.START) {
                    return@launch
                }
                try {
                    runStateFlow.tryEmit(RunState.PENDING)
                    runTime = Service.stopService()
                    runStateFlow.tryEmit(RunState.STOP)
                } finally {
                    if (runStateFlow.value == RunState.PENDING) {
                        runStateFlow.tryEmit(RunState.START)
                    }
                }
            }
        }
    }
}



