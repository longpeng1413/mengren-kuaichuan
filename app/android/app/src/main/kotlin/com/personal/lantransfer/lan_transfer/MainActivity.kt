package com.personal.lantransfer.lan_transfer

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InterruptedIOException
import java.net.Inet4Address
import java.net.NetworkInterface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    companion object {
        private const val FILE_CHANNEL = "com.personal.lantransfer.lan_transfer/files"
        private const val DIRECTORY_REQUEST = 8231
        private const val MAX_DIAGNOSTIC_FILE_BYTES = 1024 * 1024L
        private const val DIAGNOSTIC_RETENTION_MS = 7L * 24 * 60 * 60 * 1000
        private val diagnosticLock = Any()
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private var fileChannel: MethodChannel? = null
    private val pendingSharedFiles = mutableListOf<String>()
    private val shareImportExecutor: ExecutorService = Executors.newSingleThreadExecutor { work ->
        Thread(work, "mengren-share-import")
    }
    @Volatile private var activityDestroyed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        nativeLog("activity_on_create action=${intent?.action ?: "none"}")
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        fileChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDirectory" -> pickDirectory(result)
                    "exportFile" -> exportFile(
                        sourcePath = call.argument<String>("sourcePath"),
                        fileName = call.argument<String>("fileName"),
                        mimeType = call.argument<String>("mimeType"),
                        treeUri = call.argument<String>("treeUri"),
                        locationLabel = call.argument<String>("locationLabel"),
                        result = result,
                    )
                    "openUri" -> openUri(call.argument<String>("uri"), result)
                    "takeSharedFiles" -> {
                        result.success(availableSharedFiles())
                    }
                    "diagnosticInfo" -> result.success(diagnosticInfo())
                    "networkInterfaces" -> result.success(networkInterfaces())
                    "exportDiagnostics" -> exportDiagnostics(result)
                    "clearDiagnostics" -> {
                        clearDiagnostics()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        handleIncomingFileIntent(intent)
        nativeLog("flutter_engine_configured")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        nativeLog("activity_new_intent action=${intent.action ?: "none"}")
        handleIncomingFileIntent(intent)
    }

    private fun handleIncomingFileIntent(incomingIntent: Intent?) {
        val action = incomingIntent?.action ?: return
        if (action != Intent.ACTION_SEND &&
            action != Intent.ACTION_SEND_MULTIPLE &&
            action != Intent.ACTION_VIEW) return
        val uris = linkedSetOf<Uri>()
        incomingIntent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let(uris::add)
            }
        }
        if (action == Intent.ACTION_VIEW) {
            incomingIntent.data?.let(uris::add)
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                incomingIntent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let(uris::add)
                incomingIntent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    ?.let(uris::addAll)
            } else {
                @Suppress("DEPRECATION")
                (incomingIntent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let(uris::add)
                @Suppress("DEPRECATION")
                incomingIntent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
            }
        }
        if (uris.isEmpty()) return
        nativeLog("incoming_file_intent action=$action count=${uris.size}")

        // Consume the launch intent immediately. Activity/engine recreation must
        // not import the same large file over and over again.
        incomingIntent.action = null
        incomingIntent.clipData = null
        incomingIntent.data = null
        incomingIntent.removeExtra(Intent.EXTRA_STREAM)

        shareImportExecutor.execute {
            nativeLog("share_import_started count=${uris.size}")
            val imported = mutableListOf<String>()
            val inbox = File(cacheDir, "shared-inbox").apply { mkdirs() }
            for (uri in uris) {
                if (Thread.currentThread().isInterrupted) break
                var partial: File? = null
                try {
                    val displayName = sharedDisplayName(uri)
                    val destination = uniqueFile(inbox, displayName)
                    partial = File(inbox, ".import-${UUID.randomUUID()}.part")
                    val input = contentResolver.openInputStream(uri) ?: continue
                    input.buffered(256 * 1024).use { source ->
                        partial.outputStream().buffered(256 * 1024).use { target ->
                            val buffer = ByteArray(256 * 1024)
                            while (true) {
                                if (Thread.currentThread().isInterrupted) {
                                    throw InterruptedIOException("共享文件导入已取消")
                                }
                                val count = source.read(buffer)
                                if (count < 0) break
                                target.write(buffer, 0, count)
                            }
                        }
                    }
                    if (!partial.renameTo(destination)) error("无法完成共享文件导入")
                    imported.add(destination.absolutePath)
                    nativeLog("share_import_file_complete bytes=${destination.length()}")
                    partial = null
                } catch (error: Exception) {
                    partial?.delete()
                    nativeLog("share_import_file_failed", error)
                }
            }
            if (imported.isNotEmpty()) {
                synchronized(pendingSharedFiles) { pendingSharedFiles.addAll(imported) }
                Handler(Looper.getMainLooper()).post {
                    if (!activityDestroyed) {
                        fileChannel?.invokeMethod("sharedFilesAvailable", imported.size)
                    }
                }
            }
            nativeLog("share_import_finished imported=${imported.size}")
        }
    }

    private fun diagnosticsDirectory(): File = File(filesDir, "diagnostics").apply { mkdirs() }

    private fun nativeLog(event: String, error: Throwable? = null) {
        try {
            synchronized(diagnosticLock) {
                val directory = diagnosticsDirectory()
                val now = System.currentTimeMillis()
                directory.listFiles()?.forEach { file ->
                    if (now - file.lastModified() > DIAGNOSTIC_RETENTION_MS) file.delete()
                }
                val current = File(directory, "android-diagnostic.log")
                if (current.exists() && current.length() >= MAX_DIAGNOSTIC_FILE_BYTES) {
                    val previous = File(directory, "android-diagnostic.previous.log")
                    previous.delete()
                    current.renameTo(previous)
                }
                val timestamp = SimpleDateFormat(
                    "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                    Locale.US,
                ).format(Date())
                val details = error?.let {
                    " error=${it.javaClass.simpleName}:${it.message ?: "unknown"} stack=${it.stackTraceToString()}"
                }.orEmpty().replace(Regex("[\\r\\n]+"), " | ").take(12000)
                current.appendText("$timestamp [android] $event$details\n")
            }
        } catch (_: Exception) {
            // Logging must never interfere with app startup or file transfer.
        }
    }

    private fun diagnosticInfo(): Map<String, Long> {
        val files = diagnosticsDirectory().listFiles()?.filter { it.isFile }.orEmpty()
        return mapOf(
            "bytes" to files.sumOf { it.length() },
            "fileCount" to files.size.toLong(),
        )
    }

    private fun networkInterfaces(): List<Map<String, Any?>> {
        return try {
            val result = mutableListOf<Map<String, Any?>>()
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces != null && interfaces.hasMoreElements()) {
                val network = interfaces.nextElement()
                if (!network.isUp || network.isLoopback) continue
                for (interfaceAddress in network.interfaceAddresses) {
                    val address = interfaceAddress.address
                    if (address !is Inet4Address || address.isLoopbackAddress) continue
                    result.add(
                        mapOf(
                            "name" to network.name,
                            "address" to address.hostAddress,
                            "prefixLength" to interfaceAddress.networkPrefixLength.toInt(),
                            "broadcast" to interfaceAddress.broadcast?.hostAddress,
                        ),
                    )
                }
            }
            nativeLog("network_interfaces count=${result.size}")
            result
        } catch (error: Exception) {
            nativeLog("network_interfaces_failed", error)
            emptyList()
        }
    }

    private fun clearDiagnostics() {
        synchronized(diagnosticLock) {
            diagnosticsDirectory().listFiles()?.forEach { it.delete() }
        }
    }

    private fun exportDiagnostics(result: MethodChannel.Result) {
        thread(name = "mengren-diagnostic-export") {
            var destinationUri: Uri? = null
            try {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    error("Android 10 以下版本暂不支持直接导出日志")
                }
                nativeLog("diagnostics_export_started")
                val fileName = "猛人快传-诊断日志-${System.currentTimeMillis()}.txt"
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                    put(MediaStore.Downloads.MIME_TYPE, "text/plain")
                    put(
                        MediaStore.Downloads.RELATIVE_PATH,
                        Environment.DIRECTORY_DOWNLOADS + "/猛人快传",
                    )
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                destinationUri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: error("无法创建诊断日志文件")
                val logs = synchronized(diagnosticLock) {
                    diagnosticsDirectory().listFiles()
                        ?.filter { it.isFile }
                        ?.sortedBy { it.name }
                        .orEmpty()
                }
                val output = contentResolver.openOutputStream(destinationUri, "w")
                    ?: error("无法写入诊断日志")
                output.bufferedWriter().use { writer ->
                    writer.appendLine("猛人快传诊断日志")
                    writer.appendLine("设备：${Build.MANUFACTURER} ${Build.MODEL}，Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
                    writer.appendLine("日志最多保留 7 天；不包含聊天文字和文件内容。")
                    for (log in logs) {
                        writer.appendLine()
                        writer.appendLine("===== ${log.name} =====")
                        log.bufferedReader().use { reader -> reader.copyTo(writer) }
                    }
                }
                contentResolver.update(
                    destinationUri,
                    ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                    null,
                    null,
                )
                Handler(Looper.getMainLooper()).post {
                    result.success(
                        mapOf(
                            "uri" to destinationUri.toString(),
                            "location" to "系统下载/猛人快传/$fileName",
                        ),
                    )
                }
            } catch (error: Exception) {
                destinationUri?.let { contentResolver.delete(it, null, null) }
                nativeLog("diagnostics_export_failed", error)
                Handler(Looper.getMainLooper()).post {
                    result.error("diagnostic_export_failed", error.message ?: "日志导出失败", null)
                }
            }
        }
    }

    private fun availableSharedFiles(): List<String> {
        val pending = synchronized(pendingSharedFiles) {
            pendingSharedFiles.toList().also { pendingSharedFiles.clear() }
        }
        val inboxFiles = File(cacheDir, "shared-inbox")
            .listFiles { file -> file.isFile && !file.name.startsWith(".import-") }
            ?.sortedBy { it.lastModified() }
            ?.map { it.absolutePath }
            .orEmpty()
        return (pending + inboxFiles).distinct()
    }

    private fun sharedDisplayName(uri: Uri): String {
        var value: String? = null
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) value = cursor.getString(index)
            }
        }
        val candidate = value ?: uri.lastPathSegment ?: "共享文件"
        return candidate.replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001f]"), "_").take(180)
    }

    private fun uniqueFile(directory: File, fileName: String): File {
        val safeName = fileName.ifBlank { "共享文件" }
        var candidate = File(directory, safeName)
        if (!candidate.exists()) return candidate
        val dot = safeName.lastIndexOf('.')
        val stem = if (dot > 0) safeName.substring(0, dot) else safeName
        val extension = if (dot > 0) safeName.substring(dot) else ""
        var index = 1
        while (candidate.exists()) {
            candidate = File(directory, "$stem ($index)$extension")
            index++
        }
        return candidate
    }

    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error("already_open", "文件夹选择器已经打开", null)
            return
        }
        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        startActivityForResult(intent, DIRECTORY_REQUEST)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != DIRECTORY_REQUEST) return
        val result = pendingDirectoryResult
        pendingDirectoryResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(null)
            return
        }
        val flags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            contentResolver.takePersistableUriPermission(uri, flags)
        } catch (_: SecurityException) {
            result?.error("permission_denied", "无法保存所选文件夹权限", null)
            return
        }
        val documentId = try {
            DocumentsContract.getTreeDocumentId(uri)
        } catch (_: Exception) {
            uri.lastPathSegment ?: "已选择文件夹"
        }
        val label = documentId.substringAfterLast(':').ifBlank { "已选择文件夹" }
        result?.success(mapOf("uri" to uri.toString(), "label" to label))
    }

    private fun exportFile(
        sourcePath: String?,
        fileName: String?,
        mimeType: String?,
        treeUri: String?,
        locationLabel: String?,
        result: MethodChannel.Result,
    ) {
        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("invalid_arguments", "文件参数无效", null)
            return
        }
        thread(name = "mengren-file-export") {
            var destinationUri: Uri? = null
            try {
                val source = File(sourcePath)
                if (!source.isFile) error("临时文件不存在")
                val resolvedMime = mimeType?.takeIf { it.isNotBlank() }
                    ?: "application/octet-stream"
                val location: String
                if (!treeUri.isNullOrBlank()) {
                    val tree = Uri.parse(treeUri)
                    val parentId = DocumentsContract.getTreeDocumentId(tree)
                    val parent = DocumentsContract.buildDocumentUriUsingTree(tree, parentId)
                    destinationUri = DocumentsContract.createDocument(
                        contentResolver,
                        parent,
                        resolvedMime,
                        fileName,
                    ) ?: error("无法在所选文件夹中创建文件")
                    location = "${locationLabel ?: "已选择文件夹"}/$fileName"
                } else {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                        error("Android 10 以下版本请先在设置中选择保存文件夹")
                    }
                    val values = ContentValues().apply {
                        put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                        put(MediaStore.Downloads.MIME_TYPE, resolvedMime)
                        put(
                            MediaStore.Downloads.RELATIVE_PATH,
                            Environment.DIRECTORY_DOWNLOADS + "/猛人快传",
                        )
                        put(MediaStore.Downloads.IS_PENDING, 1)
                    }
                    destinationUri = contentResolver.insert(
                        MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                        values,
                    ) ?: error("无法写入系统下载目录")
                    location = "系统下载/猛人快传/$fileName"
                }

                source.inputStream().buffered(1024 * 1024).use { input ->
                    val stream = contentResolver.openOutputStream(destinationUri!!, "w")
                        ?: error("无法打开目标文件")
                    stream.buffered(1024 * 1024).use { output -> input.copyTo(output, 1024 * 1024) }
                }
                if (treeUri.isNullOrBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val completed = ContentValues().apply {
                        put(MediaStore.Downloads.IS_PENDING, 0)
                    }
                    contentResolver.update(destinationUri!!, completed, null, null)
                }
                Handler(Looper.getMainLooper()).post {
                    result.success(
                        mapOf(
                            "uri" to destinationUri.toString(),
                            "location" to location,
                        ),
                    )
                }
            } catch (error: Exception) {
                destinationUri?.let {
                    try {
                        contentResolver.delete(it, null, null)
                    } catch (_: Exception) {
                    }
                }
                Handler(Looper.getMainLooper()).post {
                    result.error("export_failed", error.message ?: "保存文件失败", null)
                }
            }
        }
    }

    private fun openUri(uriValue: String?, result: MethodChannel.Result) {
        if (uriValue.isNullOrBlank()) {
            result.error("invalid_uri", "文件地址无效", null)
            return
        }
        try {
            val uri = Uri.parse(uriValue)
            val mimeType = contentResolver.getType(uri) ?: "*/*"
            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(viewIntent, "选择打开方式"))
            result.success(true)
        } catch (error: Exception) {
            result.error("open_failed", error.message ?: "没有可用的应用", null)
        }
    }

    override fun onStart() {
        super.onStart()
        nativeLog("activity_on_start")
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("$packageName:lan-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onStop() {
        nativeLog("activity_on_stop")
        multicastLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        multicastLock = null
        super.onStop()
    }

    override fun onDestroy() {
        nativeLog("activity_on_destroy")
        activityDestroyed = true
        fileChannel?.setMethodCallHandler(null)
        fileChannel = null
        shareImportExecutor.shutdownNow()
        super.onDestroy()
    }
}
