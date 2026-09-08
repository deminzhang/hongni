package com.hongni.plugin

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * Godot Android plugin (v2) singleton "HongniPlugin". Exposes biometric
 * authentication, PBKDF2 PIN hashing, MediaStore scanning, the photo picker,
 * saving files into the device gallery (Pictures/Hongni), WorkManager-driven
 * periodic backup, video playback, and mDNS LAN discovery.
 *
 * GDScript calls methods by exact snake_case name; there is no camelCase
 * coercion, so every @UsedByGodot method below is named to match GDScript.
 */
class HongniPlugin(godot: Godot) : GodotPlugin(godot) {

    companion object {
        private const val REQ_PHOTO_PICKER = 4242
        private const val REQ_PERMISSIONS = 4243
        private const val PREFS_NAME = "hongni_backup"
        private const val KEY_PENDING = "backup_pending"
    }

    override fun getPluginName(): String = "HongniPlugin"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("biometric_result", String::class.java),
        SignalInfo("photo_picker_result", String::class.java),
        SignalInfo("lan_scan_result", String::class.java),
        SignalInfo("backup_pending"),
    )

    // --- Biometric ---

    @UsedByGodot
    fun has_biometric(): Boolean {
        val activity = getActivity() ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val bm = activity.getSystemService(Context.BIOMETRIC_SERVICE) as? BiometricManager
            ?: return false
        return bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
            BiometricManager.BIOMETRIC_SUCCESS
    }

    @UsedByGodot
    fun authenticate_biometric(reason: String) {
        val activity = getActivity()
        if (activity == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            emitSignal("biometric_result", "error")
            return
        }
        runOnUiThread {
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle("红泥")
                .setSubtitle(reason)
                .setNegativeButton("取消", activity.mainExecutor) { _, _ ->
                    emitSignal("biometric_result", "cancel")
                }
                .build()
            prompt.authenticate(CancellationSignal(), activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        result: BiometricPrompt.AuthenticationResult
                    ) {
                        emitSignal("biometric_result", "success")
                    }
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        emitSignal("biometric_result", "error")
                    }
                })
        }
    }

    // --- PIN hashing (PBKDF2-HMAC-SHA256, 100000 iterations) ---

    @UsedByGodot
    fun random_salt(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.toHex()
    }

    @UsedByGodot
    fun hash_pin(pin: String, saltHex: String): String {
        val salt = hexDecode(saltHex)
        val spec = PBEKeySpec(pin.toCharArray(), salt, 100000, 256)
        val key = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
            .generateSecret(spec).encoded
        return key.toHex()
    }

    @UsedByGodot
    fun verify_pin(pin: String, saltHex: String, expectedHex: String): Boolean {
        val actual = hash_pin(pin, saltHex)
        return MessageDigest.isEqual(
            actual.toByteArray(Charsets.UTF_8),
            expectedHex.toByteArray(Charsets.UTF_8),
        )
    }

    // --- MediaStore ---

    @UsedByGodot
    fun list_media(after_cursor: String, media: String): String {
        val activity = getActivity() ?: return "[]"
        if (!ensureMediaPermission(activity)) {
            return "[]"
        }
        val items = JSONArray()
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.SIZE,
        )
        val uris = when (media) {
            "video" -> listOf(MediaStore.Video.Media.EXTERNAL_CONTENT_URI)
            "image" -> listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI)
            else -> listOf(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            )
        }
        val afterId = after_cursor.toLongOrNull() ?: 0L
        val sort = "${MediaStore.MediaColumns.DATE_TAKEN} DESC"
        try {
            for (uri in uris) {
                val selection = if (afterId > 0) "${MediaStore.MediaColumns._ID} > ?" else null
                val selArgs = if (afterId > 0) arrayOf(afterId.toString()) else null
                activity.contentResolver.query(uri, projection, selection, selArgs, sort)?.use { c ->
                    val idIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                    val nameIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                    val mimeIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                    val takenIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
                    val sizeIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                    while (c.moveToNext() && items.length() < 1000) {
                        val id = c.getLong(idIdx)
                        val contentUri = uri.buildUpon().appendPath(id.toString()).build().toString()
                        val o = JSONObject()
                        o.put("id", id)
                        o.put("uri", contentUri)
                        o.put("display_name", c.getString(nameIdx) ?: "")
                        o.put("mime_type", c.getString(mimeIdx) ?: "")
                        o.put("taken_at", c.getLong(takenIdx) / 1000L)
                        o.put("size", c.getLong(sizeIdx))
                        items.put(o)
                    }
                }
            }
        } catch (e: SecurityException) {
            // Access revoked/between permission checks — return whatever was
            // gathered rather than crashing the Godot bridge.
        }
        return items.toString()
    }

    @UsedByGodot
    fun read_media_bytes(uriStr: String, destAbsPath: String): Boolean {
        val activity = getActivity() ?: return false
        return try {
            val uri = Uri.parse(uriStr)
            val input = activity.contentResolver.openInputStream(uri) ?: return false
            val ok = input.use { ins ->
                FileOutputStream(File(destAbsPath)).use { out ->
                    ins.copyTo(out)
                    true
                }
            }
            ok
        } catch (e: Exception) {
            false
        }
    }
    @UsedByGodot
    fun open_photo_picker() {
        val activity = getActivity() ?: return
        runOnUiThread {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Intent(MediaStore.ACTION_PICK_IMAGES)
            } else {
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "image/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
            }
            activity.startActivityForResult(intent, REQ_PHOTO_PICKER)
        }
    }

    @UsedByGodot
    fun save_to_gallery(srcAbsPath: String, displayName: String, mimeType: String): Boolean {
        val activity = getActivity() ?: return false
        val file = File(srcAbsPath)
        if (!file.exists() || !file.isFile) return false
        val mime = mimeType.ifBlank { "image/jpeg" }
        val name = displayName.ifBlank { file.name }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Scoped storage: MediaStore insert, no permission required.
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(
                        MediaStore.Images.Media.RELATIVE_PATH,
                        Environment.DIRECTORY_PICTURES + "/Hongni",
                    )
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val collection =
                    MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val uri = activity.contentResolver.insert(collection, values) ?: return false
                val wrote = try {
                    activity.contentResolver.openOutputStream(uri)?.use { out ->
                        file.inputStream().use { it.copyTo(out) }
                        true
                    } ?: false
                } catch (e: Exception) {
                    false
                }
                if (!wrote) {
                    activity.contentResolver.delete(uri, null, null)
                    return false
                }
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                activity.contentResolver.update(uri, values, null, null)
                true
            } else {
                // API 28 and below: public Pictures dir + media scan. WRITE
                // permission is runtime-granted; request it if still missing and
                // let the caller retry after the user responds.
                ensureWritePermission(activity)
                val dir =
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
                val sub = File(dir, "Hongni")
                if ((!sub.exists() && !sub.mkdirs()) || !sub.isDirectory) return false
                val outFile = File(sub, name)
                file.inputStream().use { i -> outFile.outputStream().use { o -> i.copyTo(o) } }
                activity.sendBroadcast(
                    Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE, Uri.fromFile(outFile)),
                )
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQ_PHOTO_PICKER) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            emitSignal("photo_picker_result", "[]")
            return
        }
        val uris = JSONArray()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                uris.put(clip.getItemAt(i).uri.toString())
            }
        } else {
            data.data?.let { uris.put(it.toString()) }
        }
        emitSignal("photo_picker_result", uris.toString())
    }

    // --- WorkManager periodic backup ---

    @UsedByGodot
    fun schedule_backup(interval_hours: Int) {
        val hours = interval_hours.coerceAtLeast(1)
        BackupScheduler.schedule(getActivity()!!, hours)
    }

    @UsedByGodot
    fun cancel_backup() {
        BackupScheduler.cancel(getActivity()!!)
    }

    /** Returns true and clears the pending-backup flag set by the Worker. */
    @UsedByGodot
    fun consume_backup_pending(): Boolean {
        val prefs = getActivity()?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            ?: return false
        if (!prefs.getBoolean(KEY_PENDING, false)) return false
        prefs.edit().putBoolean(KEY_PENDING, false).apply()
        return true
    }

    // --- Video playback ---

    @UsedByGodot
    fun play_video(uriOrPath: String) {
        val activity = getActivity() ?: return
        runOnUiThread {
            val uri = toPlayableVideoUri(activity, uriOrPath)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "video/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            try {
                activity.startActivity(intent)
            } catch (e: Exception) {
                // No handler for video/* — fall back to any viewer.
                val fallback = Intent(Intent.ACTION_VIEW, uri).apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                try {
                    activity.startActivity(fallback)
                } catch (e2: Exception) {
                    // ignored
                }
            }
        }
    }

    /**
     * A cloud video is downloaded into the app-internal cache and passed here as
     * an absolute path, but external players cannot read another app's file
     * paths (FileUriExposedException on API 24+). A bare absolute path is
     * exposed as a content:// URI through the FileProvider below. Real URIs
     * (content://, http(s)://, file://) are kept as-is.
     */
    private fun toPlayableVideoUri(activity: Activity, uriOrPath: String): Uri {
        val parsed = Uri.parse(uriOrPath)
        if (parsed.scheme != null) return parsed
        val file = File(uriOrPath)
        if (file.isFile) {
            return FileProvider.getUriForFile(
                activity,
                activity.packageName + ".hongni.files",
                file,
            )
        }
        return parsed
    }

    // --- mDNS LAN discovery (_hongni._tcp) ---

    @UsedByGodot
    fun scan_lan() {
        val activity = getActivity() ?: run {
            emitSignal("lan_scan_result", "[]")
            return
        }
        runOnUiThread { discoverServices(activity) }
    }

    private fun discoverServices(activity: Activity) {
        val nsd = activity.getSystemService(Context.NSD_SERVICE) as NsdManager
        val found = mutableListOf<String>()
        val latch = CountDownLatch(1)

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val host = serviceInfo.host?.hostAddress ?: return
                        found.add("http://$host:${serviceInfo.port}")
                    }
                })
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}
            override fun onDiscoveryStopped(serviceType: String) { latch.countDown() }
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { latch.countDown() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }

        nsd.discoverServices("_hongni._tcp", NsdManager.PROTOCOL_DNS_SD, discoveryListener)

        // Collect results for ~2.5s then stop discovery.
        Thread {
            try {
                latch.await(2500, TimeUnit.MILLISECONDS)
            } catch (e: InterruptedException) {
                // ignored
            }
            runOnUiThread {
                try { nsd.stopServiceDiscovery(discoveryListener) } catch (e: Exception) {}
                emitSignal("lan_scan_result", JSONArray(found.distinct()).toString())
            }
        }.start()
    }

    // --- helpers ---

    private fun ensureMediaPermission(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Full media access OR Android 14+ partial ("selected photos") access
            // both satisfy reading MediaStore for the system-album browse.
            val full = arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
            )
            val hasFull = full.all {
                activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
            }
            val hasPartial = activity.checkSelfPermission(
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            ) == PackageManager.PERMISSION_GRANTED
            if (hasFull || hasPartial) return true
            runOnUiThread {
                activity.requestPermissions(full, REQ_PERMISSIONS)
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                return true
            }
            runOnUiThread {
                activity.requestPermissions(
                    arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
                    REQ_PERMISSIONS,
                )
            }
        }
        // Best-effort: permissions are granted asynchronously; return true and
        // let the caller retry on next scan if still missing.
        return true
    }

    /** Fire-and-forget runtime request for WRITE_EXTERNAL_STORAGE (API 23-28). */
    private fun ensureWritePermission(activity: Activity) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Build.VERSION.SDK_INT > Build.VERSION_CODES.P
        ) {
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            runOnUiThread {
                activity.requestPermissions(
                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    REQ_PERMISSIONS,
                )
            }
        }
    }

    private fun hexDecode(s: String): ByteArray {
        val clean = s.filter { it != ' ' }
        val out = ByteArray(clean.length / 2)
        var i = 0
        while (i < out.size) {
            out[i] = clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            i++
        }
        return out
    }
}

private fun ByteArray.toHex(): String {
    val sb = StringBuilder(size * 2)
    for (b in this) {
        val v = b.toInt() and 0xFF
        if (v < 0x10) sb.append('0')
        sb.append(Integer.toHexString(v))
    }
    return sb.toString()
}
