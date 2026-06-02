package sk.popelis.nutrinutri

import android.app.Activity
import android.content.Context
import android.content.Intent
import com.google.android.gms.oss.licenses.OssLicensesMenuActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

class MainActivity : FlutterActivity() {
    private val LICENSE_CHANNEL = "sk.popelis.nutrinutri/licenses"
    private val FILE_EXPORT_CHANNEL = "sk.popelis.nutrinutri/file_export"
    private val CREATE_DOCUMENT_REQUEST = 7342
    private val EXPORT_PREFS = "nutrinutri_file_export"
    private val PENDING_EXPORT_SOURCE_PATH = "pending_export_source_path"
    private var pendingExportResult: Result? = null
    private var pendingExportSourcePath: String? = null

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
            if (fileName.isNullOrBlank() || (sourcePath.isNullOrBlank() && bytes == null)) {
                result.error("invalid_export", "Missing file name or export data.", null)
                return@setMethodCallHandler
            }

            val exportSourcePath = try {
                prepareExportSource(sourcePath, bytes)
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
            savePendingExportSourcePath(exportSourcePath)

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
            pendingExportResult = null
            pendingExportSourcePath = null

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

                clearPendingExportSourcePath(deleteFile = true, sourcePath = sourcePath)
                result?.success(uri.toString())
            } catch (error: Exception) {
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

    private fun prepareExportSource(sourcePath: String?, bytes: ByteArray?): String {
        if (!sourcePath.isNullOrBlank()) {
            val sourceFile = File(sourcePath)
            if (!sourceFile.exists() || sourceFile.length() <= 0L) {
                throw IllegalStateException("Export source file is empty or missing.")
            }
            return sourceFile.absolutePath
        }

        if (bytes == null || bytes.isEmpty()) {
            throw IllegalStateException("Export bytes are empty or missing.")
        }

        val sourceFile = File.createTempFile("nutrinutri-export-", ".bin", cacheDir)
        sourceFile.writeBytes(bytes)
        if (sourceFile.length() <= 0L) {
            throw IllegalStateException("Temporary export file was empty.")
        }
        return sourceFile.absolutePath
    }

    private fun savePendingExportSourcePath(sourcePath: String) {
        getSharedPreferences(EXPORT_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_EXPORT_SOURCE_PATH, sourcePath)
            .apply()
    }

    private fun savedPendingExportSourcePath(): String? {
        return getSharedPreferences(EXPORT_PREFS, Context.MODE_PRIVATE)
            .getString(PENDING_EXPORT_SOURCE_PATH, null)
    }

    private fun clearPendingExportSourcePath(deleteFile: Boolean, sourcePath: String?) {
        getSharedPreferences(EXPORT_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(PENDING_EXPORT_SOURCE_PATH)
            .apply()
        if (deleteFile && !sourcePath.isNullOrBlank()) {
            runCatching { File(sourcePath).delete() }
        }
    }
}
