package com.hongni.plugin

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * Periodic backup trigger. Sets a pending flag consumed by GDScript via
 * HongniPlugin.consume_backup_pending() the next time the app is foregrounded.
 */
class BackupWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    override fun doWork(): Result {
        applicationContext
            .getSharedPreferences("hongni_backup", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("backup_pending", true)
            .apply()
        return Result.success()
    }
}
