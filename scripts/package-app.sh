#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EXECUTABLE_NAME="MeetingAgentApp"
APP_BUNDLE="$REPO_ROOT/dist/MeetingAgent.app"
ARCHIVE_PATH="$REPO_ROOT/dist/MeetingAgent.zip"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
INFO_PLIST="$REPO_ROOT/Sources/MeetingAgentApp/Resources/Info.plist"
RELEASE_EXECUTABLE="$REPO_ROOT/.build/release/$EXECUTABLE_NAME"
ENV_FILE="$REPO_ROOT/.env"
DEFAULT_CREDENTIALS="$RESOURCES_DIR/DefaultSpeechTranscriptionCredentials.json"
WHISPER_BIN_SOURCE="$REPO_ROOT/Resources/WhisperBin/whisper-cli"
WHISPER_BIN_DESTINATION="$RESOURCES_DIR/WhisperBin/whisper-cli"
WHISPER_LIB_SOURCE="$REPO_ROOT/Resources/WhisperLib"
WHISPER_LIB_DESTINATION="$RESOURCES_DIR/lib"
WHISPER_BACKENDS_SOURCE="$REPO_ROOT/Resources/WhisperLibexec"
WHISPER_BACKENDS_DESTINATION="$RESOURCES_DIR/libexec"
WHISPER_MODELS_SOURCE="$REPO_ROOT/Resources/WhisperModels"
WHISPER_MODELS_DESTINATION="$RESOURCES_DIR/WhisperModels"

if [ ! -f "$INFO_PLIST" ]; then
    echo "Missing app Info.plist at $INFO_PLIST" >&2
    exit 1
fi

cd "$REPO_ROOT"
swift build -c release --product MeetingAgentApp

rm -rf "$APP_BUNDLE"
rm -f "$ARCHIVE_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$RELEASE_EXECUTABLE" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

if [ -f "$WHISPER_BIN_SOURCE" ]; then
    mkdir -p "$(dirname "$WHISPER_BIN_DESTINATION")"
    cp "$WHISPER_BIN_SOURCE" "$WHISPER_BIN_DESTINATION"
    chmod 755 "$WHISPER_BIN_DESTINATION"
    echo "Embedded Whisper CLI from $WHISPER_BIN_SOURCE"
else
    echo "No Whisper CLI embedded; missing $WHISPER_BIN_SOURCE"
fi

if [ -d "$WHISPER_LIB_SOURCE" ]; then
    mkdir -p "$WHISPER_LIB_DESTINATION"
    copied_libraries=0
    for library_path in "$WHISPER_LIB_SOURCE"/*.dylib; do
        if [ -f "$library_path" ]; then
            cp "$library_path" "$WHISPER_LIB_DESTINATION"/
            chmod 755 "$WHISPER_LIB_DESTINATION/$(basename "$library_path")"
            copied_libraries=$((copied_libraries + 1))
        fi
    done
    if [ "$copied_libraries" -gt 0 ]; then
        echo "Embedded $copied_libraries Whisper libraries from $WHISPER_LIB_SOURCE"
    else
        echo "No Whisper libraries embedded; no dylibs found in $WHISPER_LIB_SOURCE"
    fi
else
    echo "No Whisper libraries embedded; missing $WHISPER_LIB_SOURCE"
fi

if [ -d "$WHISPER_BACKENDS_SOURCE" ]; then
    mkdir -p "$WHISPER_BACKENDS_DESTINATION"
    copied_backends=0
    for backend_path in "$WHISPER_BACKENDS_SOURCE"/*.so; do
        if [ -f "$backend_path" ]; then
            cp "$backend_path" "$WHISPER_BACKENDS_DESTINATION"/
            chmod 755 "$WHISPER_BACKENDS_DESTINATION/$(basename "$backend_path")"
            copied_backends=$((copied_backends + 1))
        fi
    done
    if [ "$copied_backends" -gt 0 ]; then
        echo "Embedded $copied_backends Whisper backend plugins from $WHISPER_BACKENDS_SOURCE"
    else
        echo "No Whisper backend plugins embedded; no shared objects found in $WHISPER_BACKENDS_SOURCE"
    fi
else
    echo "No Whisper backend plugins embedded; missing $WHISPER_BACKENDS_SOURCE"
fi

if [ -f "$WHISPER_BIN_DESTINATION" ] && [ -d "$WHISPER_LIB_DESTINATION" ] && command -v install_name_tool >/dev/null 2>&1; then
    install_name_tool \
        -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib \
        -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib \
        "$WHISPER_BIN_DESTINATION" 2>/dev/null || true
    for library_path in "$WHISPER_LIB_DESTINATION"/*.dylib; do
        if [ -f "$library_path" ]; then
            install_name_tool -id "@rpath/$(basename "$library_path")" "$library_path" 2>/dev/null || true
            install_name_tool \
                -change /opt/homebrew/opt/ggml/lib/libggml.0.dylib @rpath/libggml.0.dylib \
                -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib \
            "$library_path" 2>/dev/null || true
        fi
    done
    if [ -d "$WHISPER_BACKENDS_DESTINATION" ]; then
        for backend_path in "$WHISPER_BACKENDS_DESTINATION"/*.so; do
            if [ -f "$backend_path" ]; then
                install_name_tool \
                    -change /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib @rpath/libggml-base.0.dylib \
                    -change /opt/homebrew/opt/libomp/lib/libomp.dylib @rpath/libomp.dylib \
                    "$backend_path" 2>/dev/null || true
            fi
        done
    fi
fi

if [ -f "$WHISPER_LIB_DESTINATION/libggml.0.dylib" ] && command -v perl >/dev/null 2>&1; then
    perl -0pi -e 's#/opt/homebrew/Cellar/ggml/0\.10\.0/libexec#"/tmp/meeting-agent-no-ggml-libexec" . ("\0" x 6)#e' "$WHISPER_LIB_DESTINATION/libggml.0.dylib"
fi

if [ -d "$WHISPER_MODELS_SOURCE" ]; then
    mkdir -p "$WHISPER_MODELS_DESTINATION"
    copied_models=0
    for model_path in "$WHISPER_MODELS_SOURCE"/ggml-*.bin "$WHISPER_MODELS_SOURCE"/ggml-*.gguf; do
        if [ -f "$model_path" ]; then
            cp "$model_path" "$WHISPER_MODELS_DESTINATION"/
            copied_models=$((copied_models + 1))
        fi
    done
    if [ "$copied_models" -gt 0 ]; then
        echo "Embedded $copied_models Whisper models from $WHISPER_MODELS_SOURCE"
    else
        echo "No Whisper models embedded; no ggml model files found in $WHISPER_MODELS_SOURCE"
    fi
else
    echo "No Whisper models embedded; missing $WHISPER_MODELS_SOURCE"
fi

env_value() {
    key="$1"
    if [ ! -f "$ENV_FILE" ]; then
        return 0
    fi
    awk -F= -v key="$key" '
        $0 !~ /^[[:space:]]*#/ && index($0, "=") > 0 {
            name = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
            if (name != key) {
                next
            }
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "$ENV_FILE"
}

json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g'
}

DEEPGRAM_API_KEY=$(
    env_value MEETING_AGENT_DEEPGRAM_API_KEY
    env_value DEEPGRAM_API_KEY
    env_value deepgram_api_key
)
OPENROUTER_API_KEY=$(
    env_value MEETING_AGENT_OPENROUTER_API_KEY
    env_value OPENROUTER_API_KEY
    env_value openrouter_api_key
)
DEEPGRAM_API_KEY=$(printf "%s" "$DEEPGRAM_API_KEY" | awk 'NF { print; exit }')
OPENROUTER_API_KEY=$(printf "%s" "$OPENROUTER_API_KEY" | awk 'NF { print; exit }')

if [ -n "$DEEPGRAM_API_KEY" ] || [ -n "$OPENROUTER_API_KEY" ]; then
    {
        printf "{\n"
        separator=""
        if [ -n "$OPENROUTER_API_KEY" ]; then
            printf "  \"openRouterAPIKey\": \""
            printf "%s" "$OPENROUTER_API_KEY" | json_escape
            printf "\""
            separator=",\n"
        fi
        if [ -n "$DEEPGRAM_API_KEY" ]; then
            printf "%b" "$separator"
            printf "  \"deepgramAPIKey\": \""
            printf "%s" "$DEEPGRAM_API_KEY" | json_escape
            printf "\""
        fi
        printf "\n}\n"
    } > "$DEFAULT_CREDENTIALS"
    embedded=""
    if [ -n "$OPENROUTER_API_KEY" ]; then
        embedded="OpenRouter"
    fi
    if [ -n "$DEEPGRAM_API_KEY" ]; then
        if [ -n "$embedded" ]; then
            embedded="$embedded, Deepgram"
        else
            embedded="Deepgram"
        fi
    fi
    echo "Embedded default credentials for: $embedded"
else
    echo "No default credentials embedded; .env did not include supported API key names"
fi

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_BUNDLE"
fi

if command -v codesign >/dev/null 2>&1; then
    find "$RESOURCES_DIR" -type f \( -name "*.dylib" -o -name "*.so" -o -name "whisper-cli" \) -exec codesign --force --sign - {} \;
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"

echo "Packaged $APP_BUNDLE"
echo "Created distributable archive $ARCHIVE_PATH"
