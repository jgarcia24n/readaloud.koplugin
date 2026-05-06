#!/usr/bin/env bash
# Build media_player_helper.dex from MediaPlayerHelper.java
# Requires Android SDK build-tools (d8 or dx) and an android.jar for compilation.
#
# Usage:
#   cd readaloud.koplugin/android
#   ANDROID_HOME=/path/to/sdk ./build-dex.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
ANDROID_API="${ANDROID_API:-21}"
ANDROID_JAR="${ANDROID_HOME}/platforms/android-${ANDROID_API}/android.jar"

if [ ! -f "$ANDROID_JAR" ]; then
    echo "ERROR: android.jar not found at $ANDROID_JAR"
    echo "Set ANDROID_HOME or ANDROID_API, or edit ANDROID_JAR in this script."
    exit 1
fi

echo "Compiling MediaPlayerHelper.java (API $ANDROID_API)..."
mkdir -p classes
javac -classpath "$ANDROID_JAR" --release 8 -d classes MediaPlayerHelper.java

echo "Converting to DEX..."
if command -v d8 &>/dev/null; then
    d8 --release --min-api "$ANDROID_API" --output . \
        classes/org/koreader/plugin/readaloud/MediaPlayerHelper.class
elif command -v dx &>/dev/null; then
    dx --dex --output=classes.dex classes/
else
    echo "ERROR: neither d8 nor dx found."
    echo "Add Android SDK build-tools to PATH: export PATH=\$ANDROID_HOME/build-tools/<version>:\$PATH"
    exit 1
fi

mv classes.dex media_player_helper.dex
rm -rf classes

echo "Done: $(pwd)/media_player_helper.dex"
