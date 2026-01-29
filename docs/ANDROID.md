# Android build (WIP)

This project now includes a minimal NativeActivity Android target that builds an APK and logs lifecycle events. It is a stub to validate the build pipeline; UI/rendering will be added later.

## Prerequisites

- Android SDK installed (Android Studio or command-line tools)
- ANDROID_HOME set to the SDK path
- JDK installed (JAVA_HOME or JDK_HOME set)
- Required SDK components installed:
  - Build tools (eg. 35.0.0)
  - NDK (eg. 27.0.12077973)
  - Android platform (eg. android-34)

## Build APK

```sh
zig build apk -Dandroid=true \
  -Dandroid-build-tools=35.0.0 \
  -Dandroid-ndk=27.0.12077973 \
  -Dandroid-api=34
```

The APK will be written to:

```
zig-out/bin/moltbot-client.apk
```

## Install + Run (manual)

```sh
adb install -r zig-out/bin/moltbot-client.apk
adb shell am start -S -W -n com.deanoc.moltbot/android.app.NativeActivity
```

Check logs:

```sh
adb logcat | rg MoltBot
```
