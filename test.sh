#!/usr/bin/env bash

set -Eeuo pipefail

SERVER="${INPUT_SOFTWARE}"
VERSION="${INPUT_VERSION}"
JAVA_VERSION="${INPUT_JAVA}"
PLUGINS="${INPUT_PLUGINS}"
COMMANDS="${INPUT_COMMANDS}"
TOCHECK="${INPUT_TOCHECK}"
CHECKSCRIPT="${INPUT_CHECKSCRIPT}"
TIMEOUT="${INPUT_TIMEOUT}"
COMMAND_DELAY="${INPUT_COMMAND_DELAY}"

SERVER_DIR="${RUNNER_TEMP}/server"

PLUGIN_DIR="${SERVER_DIR}/plugins"
SERVER_LOG="${SERVER_DIR}/server.log"

mkdir -p "${SERVER_DIR}"
mkdir -p "${PLUGIN_DIR}"

echo "========================================"
echo " Minecraft Server Plugin Test"
echo "========================================"
echo "Software:        ${SERVER}"
echo "Minecraft:       ${VERSION}"
echo "Java:             ${JAVA_VERSION}"
echo "Timeout:          ${TIMEOUT}s"
echo "Command delay:    ${COMMAND_DELAY}s"
echo "========================================"
echo

###############################################################################
# Utility functions
###############################################################################

error() {
    echo "::error::$*"
    exit 1
}

info() {
    echo "::notice::$*"
}

cleanup() {
    echo
    echo "Stopping Minecraft server..."

    if [[ -n "${SERVER_PID:-}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true

        for _ in {1..10}; do
            if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
                break
            fi

            sleep 1
        done

        if kill -0 "${SERVER_PID}" 2>/dev/null; then
            kill -9 "${SERVER_PID}" 2>/dev/null || true
        fi
    fi

    if [[ -f "${SERVER_LOG}" ]]; then
        cp "${SERVER_LOG}" "${GITHUB_WORKSPACE}/server.log" 2>/dev/null || true
    fi
}

trap cleanup EXIT

###############################################################################
# Validate inputs
###############################################################################

case "${SERVER}" in
    paper|folia|bukkit)
        ;;
    *)
        error "Unsupported server software '${SERVER}'.

Supported:
  paper
  folia
  bukkit"
        ;;
esac

case "${JAVA_VERSION}" in
    8|11|17|21|25)
        ;;
    *)
        error "Unsupported Java version '${JAVA_VERSION}'.

Supported:
  8
  11
  17
  21
  25"
        ;;
esac

if ! [[ "${TIMEOUT}" =~ ^[0-9]+$ ]]; then
    error "timeout must be an integer."
fi

if ! [[ "${COMMAND_DELAY}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    error "command-delay must be a number."
fi

###############################################################################
# Locate Java
###############################################################################

echo "Selecting Java ${JAVA_VERSION}..."

find_java() {
    local version="$1"

    local candidates=(
        "/opt/hostedtoolcache/Java/Temurin/${version}."*/x64/bin/java
        "/opt/hostedtoolcache/Java_Temurin-Hotspot_jdk/${version}."*/x64/bin/java
        "/usr/lib/jvm/temurin-${version}-jdk-amd64/bin/java"
        "/usr/lib/jvm/temurin-${version}-jdk/bin/java"
    )

    local candidate

    for candidate in "${candidates[@]}"; do
        if [[ -x "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    candidate="$(
        find /opt/hostedtoolcache /usr/lib/jvm \
            -type f \
            -path "*/bin/java" \
            2>/dev/null \
        | while read -r java; do
            if "${java}" -version 2>&1 \
                | grep -qE "\"${version}([.]|$)"; then
                echo "${java}"
                break
            fi
        done
    )"

    if [[ -n "${candidate}" ]]; then
        echo "${candidate}"
        return 0
    fi

    return 1
}

JAVA_BIN="$(find_java "${JAVA_VERSION}")" || {
    error "Could not locate Java ${JAVA_VERSION} after installation."
}

echo
echo "Java executable:"
echo "  ${JAVA_BIN}"
echo

"${JAVA_BIN}" -version 2>&1

###############################################################################
# Required tools
###############################################################################

for command in curl jq python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        error "Required command '${command}' is not installed."
    fi
done

###############################################################################
# Download server
###############################################################################

download_paper() {
    echo
    echo "Finding latest stable Paper build for Minecraft ${VERSION}..."

    local builds_url
    builds_url="https://fill.papermc.io/v3/projects/paper/versions/${VERSION}/builds"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        -H "User-Agent: MinecraftServerPluginTest/1.0 (GitHub Actions)" \
        "${builds_url}" \
        -o /tmp/paper-builds.json

    local url

    url="$(
        jq -r '
            first(
                .[]
                | select(.channel == "STABLE")
                | .downloads["server:default"].url
            ) // empty
        ' /tmp/paper-builds.json
    )"

    if [[ -z "${url}" ]]; then
        echo
        echo "Paper API response:"
        cat /tmp/paper-builds.json

        error "Could not find a stable Paper build for Minecraft ${VERSION}."
    fi

    echo
    echo "Downloading Paper:"
    echo "${url}"
    echo

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        -H "User-Agent: MinecraftServerPluginTest/1.0 (GitHub Actions)" \
        "${url}" \
        -o "${SERVER_DIR}/server.jar"
}

download_folia() {
    echo
    echo "Finding latest stable Folia build for Minecraft ${VERSION}..."

    local builds_url
    builds_url="https://fill.papermc.io/v3/projects/folia/versions/${VERSION}/builds"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        -H "User-Agent: MinecraftServerPluginTest/1.0 (GitHub Actions)" \
        "${builds_url}" \
        -o /tmp/folia-builds.json

    local url

    url="$(
        jq -r '
            first(
                .[]
                | select(.channel == "STABLE")
                | .downloads["server:default"].url
            ) // empty
        ' /tmp/folia-builds.json
    )"

    if [[ -z "${url}" ]]; then
        echo
        echo "Folia API response:"
        cat /tmp/folia-builds.json

        error "Could not find a stable Folia build for Minecraft ${VERSION}."
    fi

    echo
    echo "Downloading Folia:"
    echo "${url}"
    echo

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        -H "User-Agent: MinecraftServerPluginTest/1.0 (GitHub Actions)" \
        "${url}" \
        -o "${SERVER_DIR}/server.jar"
}

download_bukkit() {
    echo
    echo "Building CraftBukkit ${VERSION} using Spigot BuildTools..."
    echo

    mkdir -p "${SERVER_DIR}/buildtools"
    cd "${SERVER_DIR}/buildtools"

    local buildtools_url
    buildtools_url="https://hub.spigotmc.org/jenkins/job/BuildTools/lastSuccessfulBuild/artifact/target/BuildTools.jar"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        "${buildtools_url}" \
        -o BuildTools.jar

    echo "Running BuildTools..."

    # Keep BuildTools completely silent during a successful build.
    # Output is captured so it can be displayed if the build fails.
    local buildtools_log
    buildtools_log="${SERVER_DIR}/buildtools.log"

    if ! "${JAVA_BIN}" \
        -Xms512M \
        -Xmx2G \
        -jar BuildTools.jar \
        --rev "${VERSION}" \
        > "${buildtools_log}" \
        2>&1; then

        echo
        echo "========================================"
        echo " BuildTools failed"
        echo "========================================"
        echo

        cat "${buildtools_log}"

        error "BuildTools failed while building CraftBukkit ${VERSION}."
    fi

    local spigot_jar
    spigot_jar="./spigot-${VERSION}.jar"

    if [[ ! -f "${spigot_jar}" ]]; then
        echo
        echo "BuildTools directory:"
        find . -maxdepth 2 -type f | sort

        error "BuildTools did not produce ${spigot_jar}."
    fi

    cp "${spigot_jar}" "${SERVER_DIR}/spigot-${VERSION}.jar"

    echo "CraftBukkit/Spigot build completed successfully."
}

case "${SERVER}" in
    paper)
        download_paper
        ;;

    folia)
        download_folia
        ;;

    bukkit)
        download_bukkit
        ;;
esac

###############################################################################
# Select server JAR
###############################################################################

if [[ "${SERVER}" == "bukkit" ]]; then
    SERVER_JAR="${SERVER_DIR}/spigot-${VERSION}.jar"
else
    SERVER_JAR="${SERVER_DIR}/server.jar"
fi

echo
echo "Server JAR:"
ls -lh "${SERVER_JAR}"

###############################################################################
# Install plugins
###############################################################################

echo
echo "Installing plugins..."
echo

mapfile -t PLUGIN_PATTERNS < <(
    printf '%s\n' "${PLUGINS}" \
    | sed '/^[[:space:]]*$/d'
)

if [[ "${#PLUGIN_PATTERNS[@]}" -eq 0 ]]; then
    error "No plugins were specified."
fi

PLUGIN_COUNT=0

for pattern in "${PLUGIN_PATTERNS[@]}"; do
    pattern="$(echo "${pattern}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    [[ -z "${pattern}" ]] && continue

    echo "Pattern: ${pattern}"

    pushd "${GITHUB_WORKSPACE}" >/dev/null

    shopt -s nullglob
    matches=( ${pattern} )
    shopt -u nullglob

    popd >/dev/null

    if [[ "${#matches[@]}" -eq 0 ]]; then
        error "Plugin pattern matched no files: ${pattern}"
    fi

    for plugin in "${matches[@]}"; do
        if [[ ! -f "${GITHUB_WORKSPACE}/${plugin}" ]]; then
            error "Plugin is not a regular file: ${plugin}"
        fi

        if [[ "${plugin,,}" != *.jar ]]; then
            echo "WARNING: ${plugin} does not have a .jar extension."
        fi

        destination="${PLUGIN_DIR}/$(basename "${plugin}")"

        echo "  Installing: ${plugin}"
        echo "       -> ${destination}"

        cp -f "${GITHUB_WORKSPACE}/${plugin}" "${destination}"

        PLUGIN_COUNT=$((PLUGIN_COUNT + 1))
    done
done

if [[ "${PLUGIN_COUNT}" -eq 0 ]]; then
    error "No plugin files were installed."
fi

echo
echo "Installed ${PLUGIN_COUNT} plugin JAR(s)."

###############################################################################
# EULA
###############################################################################

echo "eula=true" > "${SERVER_DIR}/eula.txt"

###############################################################################
# Start server
###############################################################################

echo
echo "========================================"
echo " Starting ${SERVER}"
echo "========================================"
echo

cd "${SERVER_DIR}"

rm -f "${SERVER_LOG}"

CONSOLE_PIPE="${SERVER_DIR}/console.pipe"

rm -f "${CONSOLE_PIPE}"
mkfifo "${CONSOLE_PIPE}"

exec 3<>"${CONSOLE_PIPE}"

"${JAVA_BIN}" \
    -Xms1G \
    -Xmx2G \
    -jar "${SERVER_JAR}" \
    < "${CONSOLE_PIPE}" \
    > "${SERVER_LOG}" \
    2>&1 &

SERVER_PID=$!

echo "Server PID: ${SERVER_PID}"

###############################################################################
# Wait for startup
###############################################################################

echo
echo "Waiting for server startup..."
echo

SERVER_STARTED=0

for ((elapsed=0; elapsed<TIMEOUT; elapsed++)); do

    if grep -Eq 'Done \([0-9.]+s\)!|For help, type "help"|Done \(' \
        "${SERVER_LOG}" 2>/dev/null; then

        SERVER_STARTED=1

        echo
        echo "Server started successfully."
        echo

        break
    fi

    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo
        echo "========================================"
        echo " Server stopped unexpectedly"
        echo "========================================"
        echo

        cat "${SERVER_LOG}"

        exit 1
    fi

    sleep 1
done

if [[ "${SERVER_STARTED}" -eq 0 ]]; then
    echo
    echo "========================================"
    echo " Server startup timed out"
    echo "========================================"
    echo

    cat "${SERVER_LOG}"

    exit 1
fi

###############################################################################
# Execute commands
###############################################################################

if [[ -n "${COMMANDS}" ]]; then
    echo
    echo "========================================"
    echo " Executing server commands"
    echo "========================================"
    echo

    mapfile -t SERVER_COMMANDS < <(
        printf '%s\n' "${COMMANDS}" \
        | sed '/^[[:space:]]*$/d'
    )

    for command in "${SERVER_COMMANDS[@]}"; do
        command="$(echo "${command}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        if [[ "${command}" =~ ^\".*\"$ ]]; then
            command="${command:1:${#command}-2}"
        fi

        echo ">>> ${command}"

        printf '%s\n' "${command}" > "${CONSOLE_PIPE}"

        sleep "${COMMAND_DELAY}"
    done

    echo
    echo "All commands executed."
fi

###############################################################################
# Give the server time to flush logs
###############################################################################

sleep 2

###############################################################################
# Run external check script
###############################################################################

if [[ -n "${CHECKSCRIPT}" ]]; then
    echo
    echo "========================================"
    echo " Running checkscript"
    echo "========================================"
    echo
    echo "Command:"
    echo "${CHECKSCRIPT}"
    echo

    set +e

    # shellcheck disable=SC2086
    ${CHECKSCRIPT} < "${SERVER_LOG}"

    CHECK_EXIT=$?

    set -e

    if [[ "${CHECK_EXIT}" -eq 0 ]]; then
        echo
        echo "Checkscript passed."
    elif [[ "${CHECK_EXIT}" -eq 1 ]]; then
        echo
        echo "Checkscript reported failure."

        echo
        echo "Server log:"
        echo "----------------------------------------"
        cat "${SERVER_LOG}"
        echo "----------------------------------------"

        exit 1
    else
        echo
        echo "Checkscript exited with unexpected exit code ${CHECK_EXIT}."

        echo
        echo "Server log:"
        echo "----------------------------------------"
        cat "${SERVER_LOG}"
        echo "----------------------------------------"

        exit "${CHECK_EXIT}"
    fi
fi

###############################################################################
# Pattern checking
###############################################################################

if [[ -n "${TOCHECK}" ]]; then
    echo
    echo "========================================"
    echo " Checking server log"
    echo "========================================"
    echo

    mapfile -t PATTERNS < <(
        printf '%s\n' "${TOCHECK}" \
        | sed '/^[[:space:]]*$/d'
    )

    PATTERN_FAILURE=0
    PATTERN_INDEX=0

    for pattern in "${PATTERNS[@]}"; do
        pattern="$(echo "${pattern}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        if [[ "${pattern}" =~ ^\".*\"$ ]]; then
            pattern="${pattern:1:${#pattern}-2}"
        fi

        PATTERN_INDEX=$((PATTERN_INDEX + 1))

        echo
        echo "Pattern ${PATTERN_INDEX}:"
        echo "  ${pattern}"

        if python3 - "${SERVER_LOG}" "${pattern}" <<'PY'
import re
import sys

filename = sys.argv[1]
pattern = sys.argv[2]

regex = ''.join(
    '.*' if character == '*' else re.escape(character)
    for character in pattern
)

compiled = re.compile(regex, re.IGNORECASE)

with open(filename, "r", encoding="utf-8", errors="replace") as file:
    for line in file:
        if compiled.search(line):
            print(line.rstrip())
            sys.exit(0)

sys.exit(1)
PY
        then
            echo "  PASS"
        else
            echo "  FAIL"
            PATTERN_FAILURE=1
        fi
    done

    if [[ "${PATTERN_FAILURE}" -ne 0 ]]; then
        echo
        echo "========================================"
        echo " Plugin test FAILED"
        echo "========================================"
        echo

        echo "Server log:"
        echo "----------------------------------------"
        cat "${SERVER_LOG}"
        echo "----------------------------------------"

        exit 1
    fi

    echo
    echo "All log patterns matched."
fi

###############################################################################
# Success
###############################################################################

echo
echo "========================================"
echo " Plugin test PASSED"
echo "========================================"
echo

echo "Software: ${SERVER}"
echo "Minecraft: ${VERSION}"
echo "Java: ${JAVA_VERSION}"
echo "Plugins: ${PLUGIN_COUNT}"

exit 0
