#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
out=${HOME}/Library/Caches/insight-notch/android-widget-build
java="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}/bin"
mkdir -p "$out/classes" "$out/dex"
jar=$(find "$sdk/platforms" -name android.jar -print -quit)
tools=$(find "$sdk/build-tools" -name aapt2 -print -quit)
tools=$(dirname "$tools")
chmod +x "$tools/aapt2" "$tools/zipalign" "$tools/apksigner" "$tools/d8"
"$tools/aapt2" compile --dir "$root/res" -o "$out/resources.zip"
"$tools/aapt2" link -o "$out/base.apk" --manifest "$root/AndroidManifest.xml" -I "$jar" --java "$out/generated" "$out/resources.zip"
"$java/javac" -source 8 -target 8 -bootclasspath "$jar" -d "$out/classes" $(find "$root/src" "$out/generated" -name '*.java')
"$java/jar" cf "$out/classes.jar" -C "$out/classes" .
JAVA_HOME="${java%/bin}" "$tools/d8" --min-api 26 --lib "$jar" --output "$out/dex" "$out/classes.jar"
cp "$out/base.apk" "$out/unsigned.apk"
(cd "$out/dex" && /usr/bin/zip -q "$out/unsigned.apk" classes.dex)
"$tools/zipalign" -f 4 "$out/unsigned.apk" "$out/aligned.apk"
key="${HOME}/.local/share/pedro-notch/batteries-signing.jks"
mkdir -p "$(dirname "$key")"
if [[ ! -f "$key" ]]; then
 "$java/keytool" -genkeypair -keystore "$key" -storepass android -keypass android -alias insight-local -dname 'CN=Insight Batteries Local' -keyalg RSA -keysize 2048 -validity 10000
 chmod 600 "$key"
fi
JAVA_HOME="${java%/bin}" "$tools/apksigner" sign --ks "$key" --ks-pass pass:android --out "$out/InsightBatteries.apk" "$out/aligned.apk"
JAVA_HOME="${java%/bin}" "$tools/apksigner" verify "$out/InsightBatteries.apk"
echo "$out/InsightBatteries.apk"
