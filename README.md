# stamen — personal Android music app

A Flutter Android app using the JioSaavn-compatible API pattern from your supplied Python bot.

## What is included
- Song search: `GET /search/songs?query=...&page=0&limit=25`
- Song details: `GET /songs/{song_id}`
- Streaming with `just_audio`
- Android media notification/background playback with `audio_service`
- Liked songs saved on-device
- Import audio files already on your device for offline listening
- Dark Spotify-inspired UI

## Important API and rights note
This project streams only audio URLs returned by the configured API. Use the service only where you have permission to access and stream the recordings. Offline library currently imports audio files that you own or are licensed to store. It does not rip or save copyrighted tracks from streaming URLs.

The API host in `lib/main.dart` is the same host found in your Python sample. It is a third-party service and may change, rate-limit requests, or stop working. Do not put private API credentials in a public repository.

## Build the Android project
This source bundle contains the Flutter application source and Android app manifest. To generate the remaining Flutter/Gradle platform scaffolding:

1. Install Flutter SDK and Android Studio.
2. Extract this folder.
3. Open a terminal in this folder and run:
   ```bash
   flutter create . --platforms=android
   flutter pub get
   flutter run
   ```
4. To build an APK:
   ```bash
   flutter build apk --release
   ```
   Output: `build/app/outputs/flutter-apk/app-release.apk`

If `flutter create .` asks about overwriting files, keep the supplied `lib/main.dart`, `pubspec.yaml`, and `android/app/src/main/AndroidManifest.xml`.

## API response assumptions
The implementation follows the structure in the supplied Python code:
- Search response: `{ "success": true, "data": { "results": [...] } }`
- Song detail response: `{ "success": true, "data": [ { "downloadUrl": [{ "url": "..." }] } ] }`

Artwork is read from `image[]` when present. If your API uses a different field, update `Song.fromSearch` and `MusicApi.resolveSong`.

## Current limitations
- Next/previous, shuffle and repeat controls are visual placeholders because the supplied Python API sample resolves one selected track at a time and does not define a playback queue.
- No account or cloud sync; favourites are stored locally on this device.
- The APK is not precompiled in this bundle. Build it with Flutter as above.
