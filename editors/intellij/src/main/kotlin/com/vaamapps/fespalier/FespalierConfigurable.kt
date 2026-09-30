package com.vaamapps.fespalier

import com.intellij.openapi.options.BoundSearchableConfigurable
import com.intellij.openapi.ui.DialogPanel
import com.intellij.ui.dsl.builder.COLUMNS_LARGE
import com.intellij.ui.dsl.builder.bindItem
import com.intellij.ui.dsl.builder.bindSelected
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.columns
import com.intellij.ui.dsl.builder.panel
import com.vaamapps.fespalier.core.RunnerSetting

class FespalierConfigurable : BoundSearchableConfigurable("fespalier", "com.vaamapps.fespalier.settings") {
    override fun createPanel(): DialogPanel {
        val s = FespalierSettings.getInstance().state
        return panel {
            row("Runner:") {
                comboBox(RunnerSetting.entries)
                    .bindItem({ s.runner }, { s.runner = it ?: RunnerSetting.AUTO })
                    .comment("Auto uses fsp when it is on PATH, otherwise dart run fespalier, which downloads the matching fsp.")
            }
            row("fsp executable:") {
                textField()
                    .bindText(s::fspPath)
                    .columns(COLUMNS_LARGE)
                    .comment("A name on PATH or a full path. Used when the runner is fsp, or auto and fsp is found.")
            }
            row {
                checkBox("Check when a file under the app folder is saved")
                    .bindSelected(s::checkOnSave)
                    .comment("The app folder is fespalier: app_dir: in pubspec.yaml (lib/app by default).")
            }
        }
    }

    override fun apply() {
        super.apply()
        // The new settings can change what runs, so forget results and whether fsp was found.
        FespalierService.invalidateEverywhere()
    }
}
