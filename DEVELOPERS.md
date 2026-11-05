# MCore for developers

## Layout

| Path | What it is |
| --- | --- |
| `packages/movement_core/` | The engine, pure Dart (no Flutter): project model and JSON, keyframes and easing, effects, contours, masks, physics, text layout (its own OpenType reader), lines, import / export (SVG, GIF, JPEG, ZIP, the AI text format). Usable from any renderer. |
| `lib/app_state.dart` | The app's state: the open project, selection, undo, playback, preferences. |
| `lib/render/` | Draws a frame with Flutter's canvas (`canvas_renderer.dart`). |
| `lib/ui/` | The screens and panels, one folder per tab. |
| `lib/io/` | Files: projects, autosave, backups, fonts, media stores, export. |
| `lib/services/` | Video and sound through Android's own codecs (`native_media.dart` talks to `android/.../MediaPlugin.kt`). |
| `test/`, `packages/movement_core/test/` | Widget tests and engine tests. |
| `docs/` | Notes for users. |

The engine knows nothing about Flutter; the app hands it the frame size
(`stageSize`) and asks it for geometry. Everything a frame shows is a pure
function of the project and the frame number, except physics, which is baked
frame by frame and cached (`physics/contour_physics.dart`).

## Checks

Run them before a pull request:

```sh
flutter analyze && flutter test
cd packages/movement_core && dart analyze && dart test
```

## Builds and releases

`.github/workflows/build.yml` runs the checks and builds the APK (64-bit
ARM) on every push to `main`. A tag `v*` (for example `v0.1.0`) publishes
that APK as a release.

Release builds are signed with one fixed key, so an update installs over
the app already on a phone. The key is never in the repository. CI takes it
from these repository secrets:

| Secret | Value |
| --- | --- |
| `MCORE_KEYSTORE_BASE64` | the keystore file, base64 (`base64 -w0 key.jks`) |
| `MCORE_KEYSTORE_PASSWORD` | its password |
| `MCORE_KEY_ALIAS` | the key's alias |
| `MCORE_KEY_PASSWORD` | the key's password (if different) |

Locally the same environment variables work, with `MCORE_KEYSTORE` set to
the keystore's path; without them a release build is signed with the debug
key (fine for trying it, but it won't install over a signed build).

## Version

The version is in `pubspec.yaml` (`0.1.0+1`: name + build number). CI uses
its run number as the build number.
