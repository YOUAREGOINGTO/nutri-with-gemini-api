package sk.popelis.nutrinutri

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import com.google.android.gms.oss.licenses.OssLicensesMenuActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val LICENSE_CHANNEL = "sk.popelis.nutrinutri/licenses"
    private val FILE_EXPORT_CHANNEL = "sk.popelis.nutrinutri/file_export"
    private val CREATE_DOCUMENT_REQUEST = 7342
    private val EXPORT_PREFS = "nutrinutri_file_export"
    private val PENDING_EXPORT_SOURCE_PATH = "pending_export_source_path"
    private val PENDING_EXPORT_EXPECTED_BYTE_LENGTH = "pending_export_expected_byte_length"
    private var pendingExportResult: Result? = null
    private var pendingExportSourcePath: String? = null
    private var pendingExportExpectedByteLength: Long = -1L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LICENSE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "showLicenses" -> {
                    startActivity(Intent(this, OssLicensesMenuActivity::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_EXPORT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "saveFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            if (pendingExportResult != null) {
                result.error(
                    "export_in_progress",
                    "Another export is already in progress.",
                    null,
                )
                return@setMethodCallHandler
            }

            val fileName = call.argument<String>("fileName")
            val mimeType =
                call.argument<String>("mimeType") ?: "application/octet-stream"
            val sourcePath = call.argument<String>("sourcePath")
            val bytes = call.argument<ByteArray>("bytes")
            val expectedByteLength =
                call.argument<Number>("byteLength")?.toLong()?.takeIf { it > 0L } ?: -1L
            if (fileName.isNullOrBlank() || (sourcePath.isNullOrBlank() && bytes == null)) {
                result.error("invalid_export", "Missing file name or export data.", null)
                return@setMethodCallHandler
            }

            val exportSourcePath = try {
                prepareExportSource(sourcePath, bytes, expectedByteLength)
            } catch (error: Exception) {
                result.error(
                    "invalid_export",
                    error.message ?: "Could not prepare export data.",
                    null,
                )
                return@setMethodCallHandler
            }

            pendingExportResult = result
            pendingExportSourcePath = exportSourcePath
            pendingExportExpectedByteLength = expectedByteLength
            savePendingExport(exportSourcePath, expectedByteLength)

            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, fileName)
            }
            try {
                startActivityForResult(intent, CREATE_DOCUMENT_REQUEST)
            } catch (error: Exception) {
                pendingExportResult = null
                pendingExportSourcePath = null
                pendingExportExpectedByteLength = -1L
                clearPendingExportSourcePath(deleteFile = true, sourcePath = exportSourcePath)
                result.error(
                    "export_failed",
                    error.message ?: "Could not open the save dialog.",
                    null,
                )
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == CREATE_DOCUMENT_REQUEST) {
            val result = pendingExportResult
            val sourcePath = pendingExportSourcePath ?: savedPendingExportSourcePath()
            val expectedByteLength = pendingExportExpectedByteLength
                .takeIf { it > 0L }
                ?: savedPendingExportExpectedByteLength()
            pendingExportResult = null
            pendingExportSourcePath = null
            pendingExportExpectedByteLength = -1L

            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                clearPendingExportSourcePath(deleteFile = true, sourcePath = sourcePath)
                result?.success(null)
                return
            }

            val uri = data.data!!
            try {
                if (sourcePath.isNullOrBlank()) {
                    throw IllegalStateException("Export data was not available for writing.")
                }

                val sourceFile = File(sourcePath)
                if (!sourceFile.exists() || sourceFile.length() <= 0L) {
                    throw IllegalStateException("Export data was empty or unavailable.")
                }
                if (expectedByteLength > 0L && sourceFile.length() != expectedByteLength) {
                    throw IllegalStateException(
                        "Export data size changed before saving: ${sourceFile.length()} bytes, expected $expectedByteLength bytes."
                    )
                }

                var copiedBytes = 0L
                contentResolver.openOutputStream(uri, "wt")?.use { output ->
                    sourceFile.inputStream().use { input ->
                        copiedBytes = input.copyTo(output)
                    }
                    output.flush()
                } ?: run {
                    clearPendingExportSourcePath(deleteFile = true, sourcePath = sourcePath)
                    result?.error(
                        "export_failed",
                        "Could not open the selected file for writing.",
                        null,
                    )
                    return
                }

                if (copiedBytes <= 0L) {
                    throw IllegalStateException("Export wrote 0 bytes.")
                }
                if (expectedByteLength > 0L && copiedBytes != expectedByteLength) {
                    throw IllegalStateException(
                        "Export wrote $copiedBytes bytes, expected $expectedByteLength bytes."
                    )
                }

                verifySavedDocument(uri, expectedByteLength)

                clearPendingExportSourcePath(deleteFile = true, sourcePath = sourcePath)
                result?.success(uri.toString())
            } catch (error: Exception) {
                deleteOutputDocument(uri)
                clearPendingExportSourcePath(deleteFile = true, sourcePath = sourcePath)
                result?.error(
                    "export_failed",
                    error.message ?: "Could not write the selected file.",
                    null,
                )
            }
            return
        }

        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun prepareExportSource(
        sourcePath: String?,
        bytes: ByteArray?,
        expectedByteLength: Long,
    ): String {
        if (!sourcePath.isNullOrBlank()) {
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists() || sourceFile.length() <= 0L) {
                throw IllegalStateException("Export source file is empty or missing.")
            }
            if (expectedByteLength > 0L && sourceFile.length() != expectedByteLength) {
                throw IllegalStateException(
                    "Export source file has ${sourceFile.length()} bytes, expected $expectedByteLength bytes."
                )
            }
            return copyToNativeExportFile(sourceFile, expectedByteLength)
        }

        if (bytes == null || bytes.isEmpty()) {
            throw IllegalStateException("Export bytes are empty or missing.")
        }
        if (expectedByteLength > 0L && bytes.size.toLong() != expectedByteLength) {
            throw IllegalStateException(
                "Export bytes have ${bytes.size} bytes, expected $expectedByteLength bytes."
            )
        }

        val sourceFile = File.createTempFile("nutrinutri-export-", ".bin", cacheDir)
        sourceFile.writeBytes(bytes)
        if (sourceFile.length() <= 0L) {
            throw IllegalStateException("Temporary export file was empty.")
        }
        val writtenByteLength = sourceFile.length()
        if (expectedByteLength > 0L && writtenByteLength != expectedByteLength) {
            sourceFile.delete()
            throw IllegalStateException(
                "Temporary export file has $writtenByteLength bytes, expected $expectedByteLength bytes."
            )
        }
        return sourceFile.absolutePath
    }

    private fun copyToNativeExportFile(sourceFile: File, expectedByteLength: Long): String {
        val nativeSourceFile = File.createTempFile("nutrinutri-export-", ".bin", cacheDir)
        var copiedBytes = 0L
        sourceFile.inputStream().use { input ->
            FileOutputStream(nativeSourceFile).use { output ->
                copiedBytes = input.copyTo(output)
                output.flush()
            }
        }
        if (copiedBytes <= 0L) {
            nativeSourceFile.delete()
            throw IllegalStateException("Temporary export copy wrote 0 bytes.")
        }
        if (expectedByteLength > 0L && copiedBytes != expectedByteLength) {
            nativeSourceFile.delete()
            throw IllegalStateException(
                "Temporary export copy wrote $copiedBytes bytes, expected $expectedByteLength bytes."
            )
        }
        return nativeSourceFile.absolutePath
    }

    private fun verifySavedDocument(uri: Uri, expectedByteLength: Long) {
        if (expectedByteLength <= 0L) return

        val savedBytes = countSavedDocumentBytes(uri, expectedByteLength)
        if (savedBytes != expectedByteLength) {
            throw IllegalStateException(
                "Saved export has $savedBytes bytes, expected $expectedByteLength bytes."
            )
        }
    }

    private fun countSavedDocumentBytes(uri: Uri, stopAfterBytes: Long): Long {
        var totalBytes = 0L
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        contentResolver.openInputStream(uri)?.use { input ->
            while (true) {
                val readBytes = input.read(buffer)
                if (readBytes < 0) break
                totalBytes += readBytes.toLong()
                if (totalBytes > stopAfterBytes) break
            }
        } ?: throw IllegalStateException("Could not read back the saved export.")
        return totalBytes
    }

    private fun deleteOutputDocument(uri: Uri) {
        runCatching {
            DocumentsContract.deleteDocument(contentResolver, uri)
        }
    }

    private fun savePendingExport(sourcePath: String, expectedByteLength: Long) {
        getSharedPreferences(EXPORT_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_EXPORT_SOURCE_PATH, sourcePath)
            .putLong(PENDING_EXPORT_EXPECTED_BYTE_LENGTH, expectedByteLength)
            .apply()
    }

    private fun savedPendingExportSourcePath(): String? {
        return getSharedPreferences(EXPORT_PREFS, Context.MODE_PRIVATE)
            .getString(PENDING_EXPORT_SOURCE_PATH, null)
    }

    private fun savedPendingExportExpectedByteLength(): Long {
        return getSharedPreferences(EXPORT_PREFS, Context.MODE_PRIVATE)
            .getLong(PENDING_EXPORT_EXPECTED_BYTE_LENGTH, -1L)
    }

    private fun clearPendingExportSourcePath(deleteFile: Boolean, sourcePath: String?) {
        getSharedPreferences(EXPORT_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(PENDING_EXPORT_SOURCE_PATH)
            .remove(PENDING_EXPORT_EXPECTED_BYTE_LENGTH)
            .apply()
        if (deleteFile && !sourcePath.isNullOrBlank()) {
            runCatching { File(sourcePath).delete() }
        }
    }
}
