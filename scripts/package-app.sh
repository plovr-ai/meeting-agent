#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EXECUTABLE_NAME="MeetingAgentApp"
APP_BUNDLE="$REPO_ROOT/dist/MeetingAgent.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
INFO_PLIST="$REPO_ROOT/Sources/MeetingAgentApp/Resources/Info.plist"
RELEASE_EXECUTABLE="$REPO_ROOT/.build/release/$EXECUTABLE_NAME"
ENV_FILE="$REPO_ROOT/.env"
DEFAULT_CREDENTIALS="$RESOURCES_DIR/DefaultSpeechTranscriptionCredentials.json"

if [ ! -f "$INFO_PLIST" ]; then
    echo "Missing app Info.plist at $INFO_PLIST" >&2
    exit 1
fi

cd "$REPO_ROOT"
swift build -c release --product MeetingAgentApp

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$RELEASE_EXECUTABLE" "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

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

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "Packaged $APP_BUNDLE"
