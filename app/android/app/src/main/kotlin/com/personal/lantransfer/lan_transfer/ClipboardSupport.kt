package com.personal.lantransfer.lan_transfer

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Chat helpers that need Android APIs:
 * - pasting pictures/files from the clipboard into the chat input,
 * - copying a file saved through 系统下载 (content URI only) so it can be
 *   forwarded,
 * - small thumbnails of received pictures for the chat.
 *
 * Copies go into the Dart-managed `outgoing_cache` directory passed in by
 * the caller; unfinished copies end in `.part` and are removed by its
 * startup cleanup. Thumbnails are returned as bytes and never written to
 * disk.
 */
class ClipboardSupport(
    private val context: Context,
    private val log: (String, Throwable?) -> Unit,
) {
    private val copyExecutor: ExecutorService = Executors.newSingleThreadExecutor { work ->
        Thread(work, "mengren-clipboard-copy")
    }
    private val thumbnailExecutor: ExecutorService = Executors.newFixedThreadPool(2) { work ->
        Thread(work, "mengren-thumbnail")
    }
    private val mainHandler = Handler(Looper.getMainLooper())

    private val clipboard: ClipboardManager
        get() = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    /** Only reads the description, so Android shows no "pasted" notice. */
    fun peek(): Map<String, Boolean> {
        val description = clipboard.primaryClipDescription
            ?: return mapOf("files" to false, "image" to false, "text" to false)
        var text = false
        var image = false
        var files = false
        for (index in 0 until description.mimeTypeCount) {
            val type = description.getMimeType(index) ?: continue
            when {
                type == ClipDescription.MIMETYPE_TEXT_INTENT -> Unit
                type == ClipDescription.MIMETYPE_TEXT_URILIST -> files = true
                type.startsWith("text/") -> text = true
                type.startsWith("image/") -> image = true
                else -> files = true
            }
        }
        return mapOf("files" to files, "image" to image, "text" to text)
    }

    fun readClipboardFiles(directory: String?, result: MethodChannel.Result) {
        if (directory.isNullOrBlank()) {
            result.error("invalid_arguments", "缓存目录无效", null)
            return
        }
        // Read on the main thread: the URI read permission comes with the clip.
        val clip = clipboard.primaryClip
        val uris = mutableListOf<Uri>()
        if (clip != null) {
            for (index in 0 until clip.itemCount) {
                val uri = clip.getItemAt(index).uri ?: continue
                if (uri.scheme == "content") uris.add(uri)
            }
        }
        if (uris.isEmpty()) {
            result.success(emptyList<String>())
            return
        }
        copyExecutor.execute {
            val copied = mutableListOf<String>()
            for (uri in uris) {
                try {
                    copied.add(copyToDirectory(uri, File(directory)).absolutePath)
                } catch (error: Exception) {
                    log("clipboard_copy_failed", error)
                }
            }
            log("clipboard_files_copied count=${copied.size}/${uris.size}", null)
            mainHandler.post { result.success(copied) }
        }
    }

    fun copyUriToCache(uriValue: String?, directory: String?, result: MethodChannel.Result) {
        if (uriValue.isNullOrBlank() || directory.isNullOrBlank()) {
            result.error("invalid_arguments", "文件地址无效", null)
            return
        }
        copyExecutor.execute {
            try {
                val file = copyToDirectory(Uri.parse(uriValue), File(directory))
                mainHandler.post { result.success(file.absolutePath) }
            } catch (error: Exception) {
                log("forward_copy_failed", error)
                mainHandler.post {
                    result.error("copy_failed", error.message ?: "无法读取这个文件", null)
                }
            }
        }
    }

    fun loadThumbnail(uriValue: String?, size: Int, result: MethodChannel.Result) {
        if (uriValue.isNullOrBlank()) {
            result.success(null)
            return
        }
        thumbnailExecutor.execute {
            val bytes = try {
                decodeThumbnail(Uri.parse(uriValue), size.coerceIn(64, 1024))?.let { bitmap ->
                    ByteArrayOutputStream().use { output ->
                        val format = if (bitmap.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
                        bitmap.compress(format, 85, output)
                        bitmap.recycle()
                        output.toByteArray()
                    }
                }
            } catch (error: Exception) {
                // Deleted or moved by the user: the chat shows the file card.
                null
            } catch (error: OutOfMemoryError) {
                log("thumbnail_out_of_memory", error)
                null
            }
            mainHandler.post { result.success(bytes) }
        }
    }

    fun shutdown() {
        copyExecutor.shutdownNow()
        thumbnailExecutor.shutdownNow()
    }

    private fun copyToDirectory(uri: Uri, directory: File): File {
        directory.mkdirs()
        val destination = uniqueFile(directory, displayName(uri))
        val partial = File(directory, ".copy-${UUID.randomUUID()}.part")
        try {
            val input = context.contentResolver.openInputStream(uri) ?: error("无法读取这个文件")
            input.buffered(256 * 1024).use { source ->
                partial.outputStream().buffered(256 * 1024).use { target ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        if (Thread.currentThread().isInterrupted) error("复制已取消")
                        val count = source.read(buffer)
                        if (count < 0) break
                        target.write(buffer, 0, count)
                    }
                }
            }
            if (!partial.renameTo(destination)) error("无法保存复制的文件")
            return destination
        } finally {
            if (partial.exists()) partial.delete()
        }
    }

    private fun displayName(uri: Uri): String {
        var value: String? = null
        try {
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0) value = cursor.getString(index)
                    }
                }
        } catch (_: Exception) {
        }
        var name = (value ?: uri.lastPathSegment ?: "粘贴的文件")
            .substringAfterLast('/')
            .replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_")
            .take(180)
            .ifBlank { "粘贴的文件" }
        if (!name.contains('.')) {
            val extension = context.contentResolver.getType(uri)
                ?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            if (!extension.isNullOrBlank()) name = "$name.$extension"
        }
        return name
    }

    private fun uniqueFile(directory: File, fileName: String): File {
        var candidate = File(directory, fileName)
        if (!candidate.exists()) return candidate
        val dot = fileName.lastIndexOf('.')
        val stem = if (dot > 0) fileName.substring(0, dot) else fileName
        val extension = if (dot > 0) fileName.substring(dot) else ""
        var index = 1
        while (candidate.exists()) {
            candidate = File(directory, "$stem ($index)$extension")
            index++
        }
        return candidate
    }

    private fun decodeThumbnail(uri: Uri, size: Int): Bitmap? {
        val resolver = context.contentResolver
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // ImageDecoder also applies the EXIF orientation.
            val source = ImageDecoder.createSource(resolver, uri)
            return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val width = info.size.width
                val height = info.size.height
                val scale = maxOf(width, height).toFloat() / size
                if (scale > 1f) {
                    decoder.setTargetSize(
                        maxOf(1, (width / scale).toInt()),
                        maxOf(1, (height / scale).toInt()),
                    )
                }
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= size) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val bitmap = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: return null
        val orientation = try {
            resolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            } ?: ExifInterface.ORIENTATION_NORMAL
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val degrees = when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (degrees == 0f) return bitmap
        val rotated = Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height,
            Matrix().apply { postRotate(degrees) }, true,
        )
        if (rotated !== bitmap) bitmap.recycle()
        return rotated
    }
}
