package com.follow.clash

import android.app.Activity
import android.os.Bundle
import com.follow.clash.common.GlobalState
import com.follow.clash.common.QuickAction
import com.follow.clash.common.action
import kotlinx.coroutines.launch

class TempActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent.action) {
            QuickAction.START.action -> {
                GlobalState.launch {
                    State.handleStartServiceAction()
                }
            }

            QuickAction.STOP.action -> {
                GlobalState.launch {
                    State.handleStopServiceAction()
                }
            }

            QuickAction.TOGGLE.action -> {
                GlobalState.launch {
                    State.handleToggleAction()
                }
            }
        }
        finish()
    }
}