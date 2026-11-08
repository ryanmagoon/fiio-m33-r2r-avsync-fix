#!/bin/bash
# Builds probe/tsprobe.apk with plain Android SDK build-tools (no Gradle).
# Usage: tools/build_probe.sh [build-tools-version] [platform-api]
set -euo pipefail
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
BT=$SDK/build-tools/${1:-31.0.0}; AJ=$SDK/platforms/android-${2:-30}/android.jar
cd "$(dirname "$0")/../probe"
rm -rf build && mkdir -p build/classes build/out
javac --release 8 -cp "$AJ" -d build/classes src/com/test/tsprobe/MainActivity.java
"$BT/d8" --release --lib "$AJ" --min-api 26 --output build/out build/classes/com/test/tsprobe/*.class
"$BT/aapt2" link -o build/out/base.apk -I "$AJ" --manifest AndroidManifest.xml
(cd build/out && zip -q base.apk classes.dex)
[ -f build/debug.keystore ] || keytool -genkeypair -keystore build/debug.keystore -storepass android -keypass android \
  -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
"$BT/apksigner" sign --ks build/debug.keystore --ks-pass pass:android --key-pass pass:android --out tsprobe.apk build/out/base.apk
echo "built probe/tsprobe.apk"
