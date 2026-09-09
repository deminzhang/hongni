package com.hongni.plugin

import android.content.Context
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * Thin wrapper around WorkManager for periodic backup scheduling. WorkManager
 * is a compileOnly dependency of this plugin and is provided at runtime by the
 * host Godot Android build (see addons/hongni_plugin/export_plugin.gd).
 */
object BackupScheduler {

    private const val UNIQUE_WORK = "hongni_backup_periodic"

    fun schedule(context: Context, intervalHours: Int) {
        val request = PeriodicWorkRequestBuilder<BackupWorker>(
            intervalHours.toLong(), TimeUnit.HOURS,
        ).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            UNIQUE_WORK,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(UNIQUE_WORK)
    }
}
