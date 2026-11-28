import 'dart:convert';
import 'dart:io';

/// App-wide settings that belong to the app, not to any project
/// (`<documents>/app_settings.json`). Unreadable or missing = defaults.
class AppSettings {
  final File file;
  AppSettings(this.file);

  /// The app's settings, once main() has loaded them (null in tests).
  static AppSettings? instance;

  Map<String, dynamic> _data = {};

  Future<void> load() async {
    try {
      if (await file.exists()) _data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      _data = {};
    }
  }

  bool get perfHud => _data['perfHud'] == true;

  /// The app's own editing preferences (AppState.appUiState).
  Map<String, dynamic> get ui => _data['ui'] is Map ? Map<String, dynamic>.from(_data['ui'] as Map) : const {};

  Future<void> setUi(Map<String, dynamic> ui) async {
    _data['ui'] = ui;
    try {
      await file.writeAsString(jsonEncode(_data));
    } catch (_) {}
  }

  /// A new project asked for the tool guides: the next editor shows them.
  Future<void> setTourWanted() => setUi({...ui, 'guideBottomSeen': false, 'guideTopSeen': false, 'guideActionSeen': false});

  Future<void> setPerfHud(bool on) async {
    _data['perfHud'] = on;
    try {
      await file.writeAsString(jsonEncode(_data));
    } catch (_) {}
  }

  /// A folder outside the app the projects are kept in too (null: none).
  String? get projectsFolder {
    final v = _data['projectsFolder'];
    return v is String && v.isNotEmpty ? v : null;
  }

  String? get projectsFolderName => _data['projectsFolderName'] as String?;

  /// When the projects were last written there (ms; 0: never).
  int get projectsFolderSaved => (_data['projectsFolderSaved'] as num?)?.toInt() ?? 0;

  /// The last try at writing them there failed: why (null: it went well).
  String? get projectsFolderError {
    final v = _data['projectsFolderError'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Previous versions kept per project (each time it is left after
  /// editing), and new versions kept in a branch started from an old one.
  int get versionsKept => ((_data['versionsKept'] as num?)?.toInt() ?? 10).clamp(1, 100);
  int get branchVersionsKept => ((_data['branchVersionsKept'] as num?)?.toInt() ?? 5).clamp(1, 50);

  /// Home screen: projects by 'modified' (default) or 'created' date.
  String get projectSort => _data['projectSort'] == 'created' ? 'created' : 'modified';

  /// 'en' (default) or 'ru'.
  String get language => _data['language'] == 'ru' ? 'ru' : 'en';

  Future<void> setValue(String key, Object value) async {
    _data[key] = value;
    try {
      await file.writeAsString(jsonEncode(_data));
    } catch (_) {}
  }
}
