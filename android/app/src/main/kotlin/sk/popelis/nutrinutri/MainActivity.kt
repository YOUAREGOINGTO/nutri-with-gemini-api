package sk.popelis.nutrinutri

import android.app.Activity
import android.content.Intent
import com.google.android.gms.oss.licenses.OssLicensesMenuActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

class MainActivity : FlutterActivity() {
    private val LICENSE_CHANNEL = "sk.popelis.nutrinutri/licenses"
    private val FILE_EXPORT_CHANNEL = "sk.popelis.nutrinutri/file_export"
    private val CREATE_DOCUMENT_REQUEST = 7342
    private var pendingExportResult: Result? = null
    private var pendingExportBytes: ByteArray? = null

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
            val bytes = call.argument<ByteArray>("bytes")
            if (fileName.isNullOrBlank() || bytes == null) {
                result.error("invalid_export", "Missing file name or bytes.", null)
                return@setMethodCallHandler
            }

            pendingExportResult = result
            pendingExportBytes = bytes

            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, fileName)
            }
            try {
                startActivityForResult(intent, CREATE_DOCUMENT_REQUEST)
            } catch (error: Exception) {
                pendingExportResult = null
                pendingExportBytes = null
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
            val bytes = pendingExportBytes
            pendingExportResult = null
            pendingExportBytes = null

            if (result == null) {
                super.onActivityResult(requestCode, resultCode, data)
                return
            }

            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result.success(null)
                return
            }

            val uri = data.data!!
            try {
                contentResolver.openOutputStream(uri, "wt")?.use { output ->
                    output.write(bytes ?: ByteArray(0))
                    output.flush()
                } ?: run {
                    result.error("export_failed", "Could not open the selected file for writing.", null)
                    return
                }
                result.success(uri.toString())
            } catch (error: Exception) {
                result.error("export_failed", error.message ?: "Could not write the selected file.", null)
            }
            return
        }

        super.onActivityResult(requestCode, resultCode, data)
    }
}
