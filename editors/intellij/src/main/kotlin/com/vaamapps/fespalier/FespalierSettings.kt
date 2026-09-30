package com.vaamapps.fespalier

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.vaamapps.fespalier.core.RunnerSetting

/** Settings | Tools | fespalier. Same three settings as the VS Code extension. */
@Service(Service.Level.APP)
@State(name = "FespalierSettings", storages = [Storage("fespalier.xml")])
class FespalierSettings : PersistentStateComponent<FespalierSettings.State> {
    class State {
        var runner: RunnerSetting = RunnerSetting.AUTO
        var fspPath: String = "fsp"
        var checkOnSave: Boolean = true
    }

    private var state = State()

    override fun getState(): State = state

    override fun loadState(state: State) {
        this.state = state
    }

    companion object {
        fun getInstance(): FespalierSettings = ApplicationManager.getApplication().getService(FespalierSettings::class.java)
    }
}
