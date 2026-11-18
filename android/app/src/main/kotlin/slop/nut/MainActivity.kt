package slop.nut

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var media: MediaPlugin? = null
    private var folderResult: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // video / sound through Android's own codecs (see MediaPlugin).
        media = MediaPlugin(flutterEngine.dartExecutor.binaryMessenger)
        // an export folder picked once (kept across restarts) and files
        // written straight into it - no save window each time.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mcore/folders").setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> {
                    folderResult?.success(null)
                    folderResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                    )
                    startActivityForResult(intent, PICK_FOLDER)
                }
                "writeFile" -> {
                    val tree = Uri.parse(call.argument<String>("tree")!!)
                    val name = call.argument<String>("name")!!
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    val src = File(call.argument<String>("src")!!)
                    worker.execute {
                        try {
                            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
                            val doc = DocumentsContract.createDocument(contentResolver, parent, mime, name)
                                ?: throw IllegalStateException("The folder refused the file.")
                            contentResolver.openOutputStream(doc)!!.use { out -> src.inputStream().use { it.copyTo(out) } }
                            main.post { result.success(doc.toString()) }
                        } catch (e: Exception) {
                            main.post { result.error("write", e.message ?: e.toString(), null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FOLDER) return
        val r = folderResult ?: return
        folderResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            r.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {
        }
        // a readable name: the folder's last part ("primary:Movies/Clips" -> "Movies/Clips").
        val id = DocumentsContract.getTreeDocumentId(uri)
        r.success(mapOf("uri" to uri.toString(), "name" to id.substringAfter(':', id)))
    }

    companion object {
        private const val PICK_FOLDER = 4711
    }
}
