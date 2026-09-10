package com.hongni.plugin

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.SurfaceTexture
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.media.AudioAttributes
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.os.SystemClock
import android.provider.MediaStore
import android.util.Log
import android.view.Gravity
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.core.content.FileProvider
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Godot Android plugin (v2) singleton "HongniPlugin". Exposes biometric
 * authentication, PBKDF2 PIN hashing, MediaStore scanning, the photo picker,
 * saving files into the device gallery (Pictures/Hongni), WorkManager-driven
 * periodic backup, video playback (prepared paused — GDScript drives play/seek
 * and builds the preview-frame filmstrip), and mDNS LAN discovery.
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
        SignalInfo("inapp_video_closed"),
        SignalInfo("inapp_video_prepared"),
    )

    // In-app video playback (MediaPlayer + TextureView frame bridge). The
    // TextureView is a tiny 1x1 view attached to the activity so the decode
    // surface stays live while Godot keeps rendering; frames are read back via
    // getBitmap() and handed to GDScript as RGBA bytes.
    private var inAppPlayer: MediaPlayer? = null
    private var inAppTextureView: TextureView? = null
    private var inAppBitmap: Bitmap? = null
    private val inAppFrameLock = Any()
    // Decoded frame target size, set by start_inapp_video. grab_inapp_frame()
    // always scales the captured frame to this size so GDScript's
    // Image.create_from_data(W, H, …) always matches the byte length — some
    // devices return the surface buffer (video resolution) rather than the
    // requested getBitmap() size, which would otherwise break the transport and
    // freeze the in-app display.
    private var inAppFrameW = 0
    private var inAppFrameH = 0
    // SystemClock.uptimeMillis() of the last SurfaceTexture update. Used by
    // GDScript to detect a stalled decode (frozen picture) and hand off to the
    // OS player; 0 means no update has arrived yet.
    @Volatile private var inAppLastUpdateMs = 0L
    // Set by onPrepared; playback only starts when GDScript asks (no autoplay).
    @Volatile private var prepared = false
    // Set by onCompletion so GDScript can tell "ended" from "errored" (the
    // latter emits inapp_video_closed).
    @Volatile private var inAppCompleted = false
    // Preview-frame filmstrip (the seek bar): one RGBA image of `count` tiled
    // frames, built on a worker thread and collected by take_video_filmstrip().
    private val filmstripLock = Any()
    private var filmstripBytes: ByteArray? = null
    private var filmstripToken = 0
    private var filmstripRequestToken = 0
    // Background video-thumbnail extraction results, drained by GDScript.
    private val videoThumbQueue = ConcurrentLinkedQueue<Int>()
    private val videoThumbExecutor = Executors.newFixedThreadPool(2)

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
        // BUCKET_ID/BUCKET_DISPLAY_NAME group the device media into the system
        // gallery's own albums; WIDTH/HEIGHT (and DURATION for videos) let the
        // 详细 sheet show dimensions without decoding the file.
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
                val isVideo = uri == MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                val columns = mutableListOf(
                    MediaStore.MediaColumns._ID,
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.MIME_TYPE,
                    MediaStore.MediaColumns.DATE_TAKEN,
                    MediaStore.MediaColumns.SIZE,
                    MediaStore.MediaColumns.WIDTH,
                    MediaStore.MediaColumns.HEIGHT,
                    MediaStore.MediaColumns.BUCKET_ID,
                    MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
                )
                if (isVideo) columns.add(MediaStore.MediaColumns.DURATION)
                val projection = columns.toTypedArray()
                val selection = if (afterId > 0) "${MediaStore.MediaColumns._ID} > ?" else null
                val selArgs = if (afterId > 0) arrayOf(afterId.toString()) else null
                activity.contentResolver.query(uri, projection, selection, selArgs, sort)?.use { c ->
                    val idIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                    val nameIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
                    val mimeIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
                    val takenIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_TAKEN)
                    val sizeIdx = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                    val widthIdx = c.getColumnIndex(MediaStore.MediaColumns.WIDTH)
                    val heightIdx = c.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
                    val durationIdx = c.getColumnIndex(MediaStore.MediaColumns.DURATION)
                    val bucketIdIdx = c.getColumnIndex(MediaStore.MediaColumns.BUCKET_ID)
                    val bucketNameIdx = c.getColumnIndex(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
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
                        o.put("width", if (widthIdx >= 0) c.getInt(widthIdx) else 0)
                        o.put("height", if (heightIdx >= 0) c.getInt(heightIdx) else 0)
                        o.put("duration_ms", if (durationIdx >= 0) c.getLong(durationIdx) else 0L)
                        o.put("bucket_id", if (bucketIdIdx >= 0) c.getLong(bucketIdIdx) else 0L)
                        o.put("bucket_name", if (bucketNameIdx >= 0) c.getString(bucketNameIdx) ?: "" else "")
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

    /**
     * Decodes a MediaStore item (image or video) down to a center-cropped square
     * thumbnail and writes it as PNG to destAbsPath. Returns true on success.
     * Runs on the Godot call (main) thread, so GDScript should chunk large batches.
     */
    @UsedByGodot
    fun load_thumbnail(uriStr: String, destAbsPath: String, sizePx: Int): Boolean {
        val activity = getActivity() ?: return false
        return try {
            val uri = Uri.parse(uriStr)
            val size = if (sizePx <= 0) 256 else sizePx
            val bmp = decodeImageThumbnail(activity, uri, size)
                ?: decodeVideoThumbnail(activity, uri, size)
            if (bmp == null) {
                false
            } else {
                try {
                    FileOutputStream(File(destAbsPath)).use { out ->
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                    }
                    true
                } catch (e: Exception) {
                    false
                }
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Decodes a MediaStore image at up to maxPx on its longest edge, preserving
     * the aspect ratio, and writes it as JPEG. Unlike load_thumbnail this never
     * crops, so it can back the full-screen viewer for device photos.
     */
    @UsedByGodot
    fun load_media_preview(uriStr: String, destAbsPath: String, maxPx: Int): Boolean {
        val activity = getActivity() ?: return false
        return try {
            val uri = Uri.parse(uriStr)
            val limit = if (maxPx <= 0) 2048 else maxPx
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            activity.contentResolver.openInputStream(uri)?.use { s ->
                BitmapFactory.decodeStream(s, null, bounds)
            }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return false
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= limit) {
                sample *= 2
            }
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val decoded = activity.contentResolver.openInputStream(uri)?.use { s ->
                BitmapFactory.decodeStream(s, null, opts)
            } ?: return false
            val scaled = fitInside(decoded, limit)
            try {
                FileOutputStream(File(destAbsPath)).use { out ->
                    scaled.compress(Bitmap.CompressFormat.JPEG, 90, out)
                }
                true
            } catch (e: Exception) {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    /** Scales a bitmap down so its longest edge is at most maxPx (aspect kept). */
    private fun fitInside(src: Bitmap, maxPx: Int): Bitmap {
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0) return src
        val longest = max(w, h)
        if (longest <= maxPx) return src
        val scale = maxPx.toFloat() / longest
        return Bitmap.createScaledBitmap(
            src,
            max(1, (w * scale).roundToInt()),
            max(1, (h * scale).roundToInt()),
            true,
        )
    }

    /** Decodes an image item, downsampled, into a center-cropped square thumbnail. */
    private fun decodeImageThumbnail(context: Context, uri: Uri, size: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { s ->
            BitmapFactory.decodeStream(s, null, bounds)
        }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        val maxDim = max(bounds.outWidth, bounds.outHeight)
        while (maxDim / (sample * 2) >= size) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val bmp = context.contentResolver.openInputStream(uri)?.use { s ->
            BitmapFactory.decodeStream(s, null, opts)
        } ?: return null
        return centerCrop(bmp, size)
    }

    /** Grabs a representative frame for a video item, cropped to a square thumbnail. */
    private fun decodeVideoThumbnail(context: Context, uri: Uri, size: Int): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            // getScaledFrameAtTime requires API 27+; older devices fall back to the
            // raw frame and centerCrop handles the scaling.
            var frame: Bitmap? = null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                frame = retriever.getScaledFrameAtTime(
                    1_000_000,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    size,
                    size,
                )
            }
            if (frame == null) {
                frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
            frame?.let { centerCrop(it, size) }
        } catch (e: Exception) {
            null
        } finally {
            retriever.release()
        }
    }

    /** Center-crops a bitmap to a square and scales it to size×size. */
    private fun centerCrop(src: Bitmap, size: Int): Bitmap? {
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0) return null
        val side = min(w, h)
        val x = (w - side) / 2
        val y = (h - side) / 2
        val cropped = Bitmap.createBitmap(src, x, y, side, side)
        return if (side != size) Bitmap.createScaledBitmap(cropped, size, size, true) else cropped
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

    // --- In-app video playback (MediaPlayer decoded, frames read back) -------

    /**
     * Starts decoding a local video file. A 1x1 on-screen TextureView at the
     * top-left corner keeps the decode surface live (composited, so its
     * SurfaceTexture drains and the decoder never stalls) while Godot renders
     * the video frames via grab_inapp_frame(). The player is left **paused**
     * on its first frame; GDScript starts it with resume_inapp_video() after
     * the inapp_video_prepared signal. Returns true when the view was
     * scheduled (preparation is asynchronous).
     */
    @UsedByGodot
    fun start_inapp_video(path: String, frameWidth: Int, frameHeight: Int): Boolean {
        val activity = getActivity() ?: return false
        stop_inapp_video()
        runOnUiThread {
            try {
                val w = if (frameWidth <= 0) 640 else frameWidth.coerceIn(176, 1280)
                val h = if (frameHeight <= 0) 360 else frameHeight.coerceIn(144, 720)
                inAppFrameW = w
                inAppFrameH = h
                inAppLastUpdateMs = 0L
                prepared = false
                inAppCompleted = false
                val tv = TextureView(activity)
                tv.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                    override fun onSurfaceTextureAvailable(st: SurfaceTexture, w0: Int, h0: Int) {
                        try {
                            val mp = MediaPlayer()
                            mp.setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .build()
                            )
                            mp.setDataSource(path)
                            mp.setSurface(Surface(st))
                            mp.setOnPreparedListener {
                                prepared = true
                                emitSignal("inapp_video_prepared")
                            }
                            mp.setOnCompletionListener {
                                inAppCompleted = true
                            }
                            mp.setOnErrorListener { _, what, extra ->
                                Log.e("HongniPlugin", "in-app video error: what=$what extra=$extra path=$path")
                                emitSignal("inapp_video_closed")
                                true
                            }
                            mp.prepareAsync()
                            inAppPlayer = mp
                        } catch (e: Exception) {
                            emitSignal("inapp_video_closed")
                        }
                    }

                    override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w0: Int, h0: Int) {}

                    override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                        stop_inapp_video()
                        return true
                    }

                    override fun onSurfaceTextureUpdated(st: SurfaceTexture) {
                        inAppLastUpdateMs = SystemClock.uptimeMillis()
                        val bmp = tv.getBitmap(w, h)
                        if (bmp != null) {
                            synchronized(inAppFrameLock) {
                                inAppBitmap = bmp
                            }
                        }
                    }
                }
                // Must stay composited by the RenderThread so the SurfaceTexture
                // drains: if culled (INVISIBLE, off-screen, alpha 0) the decoder
                // fills the buffer pool and stalls after ~1 s. Keep it ON-SCREEN
                // as a 1x1 px corner view — still drawn (drains), while
                // getBitmap(w, h) reads the producer-set video-resolution frame,
                // so the tiny view size does not affect the captured pixels.
                val lp = FrameLayout.LayoutParams(1, 1)
                lp.gravity = Gravity.TOP or Gravity.START
                val host = activity.findViewById<ViewGroup>(android.R.id.content)
                if (host != null) {
                    host.addView(tv, lp)
                    inAppTextureView = tv
                } else {
                    emitSignal("inapp_video_closed")
                }
            } catch (e: Exception) {
                emitSignal("inapp_video_closed")
            }
        }
        return true
    }

    @UsedByGodot
    fun pause_inapp_video(): Boolean {
        val mp = inAppPlayer ?: return false
        return try {
            mp.pause()
            true
        } catch (e: Exception) {
            false
        }
    }

    @UsedByGodot
    fun resume_inapp_video(): Boolean {
        val mp = inAppPlayer ?: return false
        return try {
            mp.start()
            true
        } catch (e: Exception) {
            false
        }
    }

    @UsedByGodot
    fun is_inapp_video_playing(): Boolean {
        return try {
            inAppPlayer?.isPlaying == true
        } catch (e: Exception) {
            false
        }
    }

    /** True once prepareAsync() finished (the player sits paused on frame 1). */
    @UsedByGodot
    fun inapp_video_prepared(): Boolean = prepared

    /** True once the clip played to its end; cleared by seek_inapp_video(). */
    @UsedByGodot
    fun inapp_video_completed(): Boolean = inAppCompleted

    /** Current playback position in ms, 0 when nothing is prepared. */
    @UsedByGodot
    fun inapp_video_position_ms(): Long {
        return try {
            inAppPlayer?.currentPosition?.toLong() ?: 0L
        } catch (e: Exception) {
            0L
        }
    }

    /** Clip duration in ms, -1 when unknown/nothing prepared. */
    @UsedByGodot
    fun inapp_video_duration_ms(): Long {
        return try {
            val d = inAppPlayer?.duration ?: return -1L
            if (d > 0) d.toLong() else -1L
        } catch (e: Exception) {
            -1L
        }
    }

    /**
     * Seeks to `ms` (clamped to the clip). SEEK_CLOSEST decodes to the exact
     * requested frame — the viewer commits a seek on drag release, not per
     * motion event, so the extra decode cost stays off the drag path.
     */
    @UsedByGodot
    fun seek_inapp_video(ms: Long): Boolean {
        val mp = inAppPlayer ?: return false
        return try {
            val duration = mp.duration
            val target = if (duration > 0) ms.coerceIn(0L, duration.toLong()) else ms.coerceAtLeast(0L)
            inAppCompleted = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                mp.seekTo(target, MediaPlayer.SEEK_CLOSEST)
            } else {
                mp.seekTo(target.toInt())
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    @UsedByGodot
    fun stop_inapp_video(): Boolean {
        runOnUiThread {
            try {
                inAppPlayer?.stop()
            } catch (e: Exception) {
            }
            try {
                inAppPlayer?.release()
            } catch (e: Exception) {
            }
            inAppPlayer = null
            try {
                inAppTextureView?.let {
                    it.surfaceTextureListener = null
                    (it.parent as? ViewGroup)?.removeView(it)
                }
            } catch (e: Exception) {
            }
            inAppTextureView = null
            synchronized(inAppFrameLock) {
                inAppBitmap?.recycle()
                inAppBitmap = null
            }
            inAppLastUpdateMs = 0L
            prepared = false
            inAppCompleted = false
        }
        return true
    }

    /**
     * Builds the preview-frame seek bar for a local video: `count` frames evenly
     * spaced over the clip, centre-cropped to frameW x frameH and tiled left to
     * right into one RGBA image (width = count * frameW). Runs on a worker
     * thread — the result is published for take_video_filmstrip(token), which
     * only accepts the newest request (a stale build finishing late is dropped).
     */
    @UsedByGodot
    fun request_video_filmstrip(path: String, count: Int, frameW: Int, frameH: Int, token: Int): Boolean {
        val cells = count.coerceIn(1, 32)
        val w = frameW.coerceIn(16, 480)
        val h = frameH.coerceIn(9, 270)
        synchronized(filmstripLock) {
            filmstripBytes = null
            filmstripToken = 0
            filmstripRequestToken = token
        }
        videoThumbExecutor.execute {
            val bytes = buildFilmstrip(path, cells, w, h)
            synchronized(filmstripLock) {
                if (filmstripRequestToken == token) {
                    filmstripBytes = bytes
                    filmstripToken = token
                }
            }
        }
        return true
    }

    /** The filmstrip RGBA bytes for `token`, or empty (consumes the result). */
    @UsedByGodot
    fun take_video_filmstrip(token: Int): ByteArray {
        synchronized(filmstripLock) {
            if (filmstripToken != token) return ByteArray(0)
            val bytes = filmstripBytes ?: return ByteArray(0)
            filmstripBytes = null
            filmstripToken = 0
            return bytes
        }
    }

    private fun buildFilmstrip(path: String, count: Int, frameW: Int, frameH: Int): ByteArray {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
        } catch (e: Exception) {
            retriever.release()
            return ByteArray(0)
        }
        return try {
            val durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val strip = Bitmap.createBitmap(count * frameW, frameH, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(strip)
            val paint = Paint(Paint.FILTER_BITMAP_FLAG)
            for (i in 0 until count) {
                // Frame i covers its own slice of the timeline (i/count).
                val atMs = if (durationMs > 0) durationMs * i / count else 0L
                val frame = retriever.getFrameAtTime(
                    atMs * 1000L,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
                if (frame != null) {
                    canvas.drawBitmap(centerCrop(frame, frameW, frameH), (i * frameW).toFloat(), 0f, paint)
                }
            }
            bitmapToRgba(strip)
        } catch (e: Exception) {
            ByteArray(0)
        } finally {
            retriever.release()
        }
    }

    /** Scales `src` so it covers frameW x frameH, then takes the centre. */
    private fun centerCrop(src: Bitmap, w: Int, h: Int): Bitmap {
        if (src.width <= 0 || src.height <= 0) return src
        val scale = max(w.toFloat() / src.width, h.toFloat() / src.height)
        val sw = max(w, (src.width * scale).roundToInt())
        val sh = max(h, (src.height * scale).roundToInt())
        val scaled = if (sw == src.width && sh == src.height) src
        else Bitmap.createScaledBitmap(src, sw, sh, true)
        return Bitmap.createBitmap(scaled, (sw - w) / 2, (sh - h) / 2, w, h)
    }

    /** Returns the latest decoded frame as packed RGBA bytes, or empty. */
    @UsedByGodot
    fun grab_inapp_frame(): ByteArray {
        synchronized(inAppFrameLock) {
            var bmp = inAppBitmap ?: return ByteArray(0)
            val tw = inAppFrameW
            val th = inAppFrameH
            if (tw <= 0 || th <= 0) return ByteArray(0)
            // Some devices return the surface buffer (video resolution) rather
            // than the getBitmap(w, h) size; always normalise to the target size
            // so the byte length exactly matches GDScript's create_from_data(W,H).
            if (bmp.width != tw || bmp.height != th) {
                bmp = Bitmap.createScaledBitmap(bmp, tw, th, true)
            }
            return bitmapToRgba(bmp)
        }
    }

    /** Packed RGBA8 bytes (row-major) of a bitmap, as GDScript Image expects. */
    private fun bitmapToRgba(bmp: Bitmap): ByteArray {
        val w = bmp.width
        val h = bmp.height
        val pixels = IntArray(w * h)
        bmp.getPixels(pixels, 0, w, 0, 0, w, h)
        val out = ByteArray(w * h * 4)
        var i = 0
        for (argb in pixels) {
            out[i++] = ((argb shr 16) and 0xff).toByte()
            out[i++] = ((argb shr 8) and 0xff).toByte()
            out[i++] = (argb and 0xff).toByte()
            out[i++] = ((argb shr 24) and 0xff).toByte()
        }
        return out
    }

    /**
     * Milliseconds since the SurfaceTexture last produced a frame, or -1 when
     * none has arrived yet. GDScript watches this while playing: a large value
     * means the decode/render stalled (frozen picture) even though the player
     * may keep running, so it can hand off to the OS player.
     */
    @UsedByGodot
    fun inapp_frame_age_ms(): Long {
        val last = inAppLastUpdateMs
        if (last == 0L) return -1L
        return SystemClock.uptimeMillis() - last
    }

    /**
     * Requests a video thumbnail (frame extracted from a URL with optional
     * Bearer token, or a local path) written to destAbsPath. The work runs on a
     * background thread so the Godot main thread is never blocked; when it
     * finishes the asset id is pushed to a queue drained by
     * poll_video_thumb_finished() (positive = ok, negative = failed). Returns
     * true immediately (the request was scheduled).
     */
    @UsedByGodot
    fun extract_video_thumb(source: String, token: String, destAbsPath: String, sizePx: Int, assetId: Int): Boolean {
        videoThumbExecutor.execute {
            val ok = extractVideoThumbSync(source, token, destAbsPath, sizePx)
            videoThumbQueue.add(if (ok) assetId else -assetId)
        }
        return true
    }

    private fun extractVideoThumbSync(source: String, token: String, destAbsPath: String, sizePx: Int): Boolean {
        val retriever = MediaMetadataRetriever()
        return try {
            if (source.startsWith("http://") || source.startsWith("https://")) {
                val headers = HashMap<String, String>()
                if (token.isNotBlank()) headers["Authorization"] = "Bearer $token"
                retriever.setDataSource(source, headers)
            } else {
                retriever.setDataSource(source)
            }
            val size = if (sizePx <= 0) 256 else sizePx
            var frame: Bitmap? = null
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                frame = retriever.getScaledFrameAtTime(
                    1_000_000,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    size,
                    size,
                )
            }
            if (frame == null) {
                frame = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
            if (frame == null) return false
            val cropped = centerCrop(frame, size) ?: return false
            File(destAbsPath).parentFile?.mkdirs()
            FileOutputStream(File(destAbsPath)).use { out ->
                cropped.compress(Bitmap.CompressFormat.JPEG, 85, out)
            }
            true
        } catch (e: Exception) {
            false
        } finally {
            retriever.release()
        }
    }

    /** Drains and returns the asset ids whose video thumbnails just finished. */
    @UsedByGodot
    fun poll_video_thumb_finished(): IntArray {
        return videoThumbQueue.toIntArray().also { videoThumbQueue.clear() }
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
