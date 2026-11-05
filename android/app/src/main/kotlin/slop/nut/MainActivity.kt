package slop.nut

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var media: MediaPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // video / sound through Android's own codecs (see MediaPlugin).
        media = MediaPlugin(flutterEngine.dartExecutor.binaryMessenger)
    }
}
