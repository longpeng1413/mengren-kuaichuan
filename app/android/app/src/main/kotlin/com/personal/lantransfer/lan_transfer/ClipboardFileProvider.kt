package com.personal.lantransfer.lan_transfer

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/**
 * Read-only access to files the user copied from a chat bubble (复制), so
 * WeChat and other apps can paste the picture/file from the clipboard.
 *
 * Not exported: another app can only open a URI the system granted it when
 * it read our clip (android:grantUriPermissions="true"). Only files under
 * this app's cache and files directories are served.
 *
 * URI: content://<package>.clipboardfiles/<cache|files>/<relative path>
 */
class ClipboardFileProvider : ContentProvider() {
    companion object {
        private const val CACHE_ROOT = "cache"
        private const val FILES_ROOT = "files"

        fun authority(context: Context) = "${context.packageName}.clipboardfiles"

        /** Null when [file] is outside the directories this provider serves. */
        fun uriFor(context: Context, file: File): Uri? {
            val canonical = file.canonicalFile
            for ((root, directory) in roots(context)) {
                val base = directory.canonicalFile
                if (!canonical.path.startsWith(base.path + File.separator)) continue
                val builder = Uri.Builder()
                    .scheme("content")
                    .authority(authority(context))
                    .appendPath(root)
                canonical.path.substring(base.path.length + 1)
                    .split(File.separatorChar)
                    .forEach { builder.appendPath(it) }
                return builder.build()
            }
            return null
        }

        private fun roots(context: Context) = listOf(
            CACHE_ROOT to context.cacheDir,
            FILES_ROOT to context.filesDir,
        )
    }

    override fun onCreate(): Boolean = true

    private fun fileFor(uri: Uri): File {
        val context = context ?: throw FileNotFoundException("no context")
        val segments = uri.pathSegments
        if (segments.size < 2) throw FileNotFoundException("invalid uri")
        val base = roots(context).firstOrNull { it.first == segments[0] }?.second?.canonicalFile
            ?: throw FileNotFoundException("invalid root")
        val file = File(base, segments.drop(1).joinToString(File.separator)).canonicalFile
        if (!file.path.startsWith(base.path + File.separator) || !file.isFile) {
            throw FileNotFoundException("file not available")
        }
        return file
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read only")
        return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String {
        val name = uri.lastPathSegment ?: return "application/octet-stream"
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val file = fileFor(uri)
        val columns = projection?.filter {
            it == OpenableColumns.DISPLAY_NAME || it == OpenableColumns.SIZE
        }?.toTypedArray() ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(columns, 1)
        cursor.addRow(
            columns.map { column ->
                if (column == OpenableColumns.DISPLAY_NAME) file.name else file.length()
            },
        )
        return cursor
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("read only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("read only")

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException("read only")
}
