#!/bin/bash
# Splunk Status Monitor
# Watchdog: detect Splunk down correctly, then start or restart as needed.
# Designed for Splunk Enterprise 9.x / 10.x.
# Auto-detects the Splunk OS user. Prefers that account over deprecated root.

# Do not use set -e: health checks and CLI calls are expected to fail.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
LOG_FILE="${LOG_FILE:-/var/log/Splunk_Status.log}"
CHECK_INTERVAL_SEC="${CHECK_INTERVAL_SEC:-30}"
CONFIRM_DOWN_WAIT_SEC="${CONFIRM_DOWN_WAIT_SEC:-180}"
STARTUP_WAIT_SEC="${STARTUP_WAIT_SEC:-180}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-10}"
CURL_CONNECT_TIMEOUT_SEC="${CURL_CONNECT_TIMEOUT_SEC:-5}"
CURL_MAX_TIME_SEC="${CURL_MAX_TIME_SEC:-15}"
WEB_URL="${WEB_URL:-https://127.0.0.1}"
MGMT_URL="${MGMT_URL:-https://127.0.0.1:8089}"
# If process + management port are healthy, a web-only failure is logged
# but does not restart Splunk (restarting a live indexer is destructive).
REQUIRE_WEB_FOR_DOWN="${REQUIRE_WEB_FOR_DOWN:-no}"

# Preferred install paths. Override with SPLUNK_HOME if needed.
CANDIDATE_HOMES=(
    "${SPLUNK_HOME:-}"
    "/splunk/opt/splunk"
    "/opt/splunk"
)

CURRENT_USER="$(id -un 2>/dev/null || whoami)"
CURRENT_UID="$(id -u 2>/dev/null || true)"
if ! printf '%s' "$CURRENT_UID" | grep -qE '^[0-9]+$'; then
    CURRENT_UID="65534"
fi

SPLUNK_HOME=""
SPLUNK_BIN=""
PROCESS_ID="BOOT"
SPLUNK_SERVICE_USER=""
SPLUNK_SERVICE_UID=""
SPLUNK_SERVICE_USER_SOURCE=""
EFFECTIVE_WEB_URL="$WEB_URL"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
positive_int_or() {
    local value="$1"
    local fallback="$2"
    if printf '%s' "$value" | grep -qE '^[1-9][0-9]*$'; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

CHECK_INTERVAL_SEC="$(positive_int_or "$CHECK_INTERVAL_SEC" 30)"
CONFIRM_DOWN_WAIT_SEC="$(positive_int_or "$CONFIRM_DOWN_WAIT_SEC" 180)"
STARTUP_WAIT_SEC="$(positive_int_or "$STARTUP_WAIT_SEC" 180)"
POLL_INTERVAL_SEC="$(positive_int_or "$POLL_INTERVAL_SEC" 10)"
CURL_CONNECT_TIMEOUT_SEC="$(positive_int_or "$CURL_CONNECT_TIMEOUT_SEC" 5)"
CURL_MAX_TIME_SEC="$(positive_int_or "$CURL_MAX_TIME_SEC" 15)"

sanitize_log_text() {
    printf '%s' "$1" | tr '\n\r' '  ' | sed 's/"/'"'"'/g' | cut -c1-4000
}

init_log_file() {
    local candidates=(
        "$LOG_FILE"
        "/var/log/Splunk_Status.log"
    )
    if [ -n "$SPLUNK_HOME" ]; then
        candidates+=("$SPLUNK_HOME/var/log/Splunk_Status.log")
    fi
    candidates+=("/tmp/Splunk_Status.log")

    local path
    for path in "${candidates[@]}"; do
        [ -z "$path" ] && continue
        if ( umask 022; mkdir -p "$(dirname "$path")" 2>/dev/null; touch "$path" 2>/dev/null ); then
            LOG_FILE="$path"
            return 0
        fi
    done
    LOG_FILE="/dev/stderr"
    return 1
}

log_message() {
    local message process_id line
    message="$(sanitize_log_text "$1")"
    process_id="${2:-$PROCESS_ID}"
    line="timestamp=\"$(date '+%Y-%m-%d %H:%M:%S %Z')\" process_id=\"$process_id\" user=\"$CURRENT_USER\" uid=\"$CURRENT_UID\" message=\"$message\""
    if ! echo "$line" >> "$LOG_FILE" 2>/dev/null; then
        echo "$line" >&2
    fi
}

ok_fail() {
    if [ "$1" -eq 0 ]; then
        printf '%s' "ok"
    else
        printf '%s' "fail"
    fi
}

# ---------------------------------------------------------------------------
# Splunk home / CLI
# ---------------------------------------------------------------------------
detect_splunk_home() {
    local home
    for home in "${CANDIDATE_HOMES[@]}"; do
        [ -z "$home" ] && continue
        if [ -x "$home/bin/splunk" ]; then
            SPLUNK_HOME="$home"
            SPLUNK_BIN="$home/bin/splunk"
            return 0
        fi
    done
    return 1
}

splunk_version_string() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 "$SPLUNK_BIN" version 2>/dev/null | head -n 1
    else
        "$SPLUNK_BIN" version 2>/dev/null | head -n 1
    fi
}

is_root_account() {
    local u="$1"
    [ -n "$u" ] || return 1
    [ "$u" = "root" ] || [ "$u" = "0" ]
}

resolve_username() {
    local v="$1" name
    [ -n "$v" ] || return 1
    if printf '%s' "$v" | grep -qE '^[0-9]+$'; then
        name="$(getent passwd "$v" 2>/dev/null | cut -d: -f1)"
    else
        getent passwd "$v" >/dev/null 2>&1 || return 1
        name="$v"
    fi
    [ -n "$name" ] || return 1
    printf '%s' "$name"
}

set_service_user() {
    local name uid
    name="$(resolve_username "$1")" || return 1
    uid="$(getent passwd "$name" 2>/dev/null | cut -d: -f3)"
    [ -n "$uid" ] || return 1
    SPLUNK_SERVICE_USER="$name"
    SPLUNK_SERVICE_UID="$uid"
    SPLUNK_SERVICE_USER_SOURCE="$2"
    return 0
}

as_user_run() {
    local user="$1"
    shift
    if [ "$CURRENT_USER" = "$user" ] || [ "$CURRENT_UID" = "$(getent passwd "$user" 2>/dev/null | cut -d: -f3)" ]; then
        "$@"
        return $?
    fi
    if [ "$CURRENT_UID" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$user" -- "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo -H -n -u "$user" -- "$@"
        return $?
    fi
    return 1
}

can_write_or_create_dir() {
    local user="$1"
    local dir="$2"
    local parent
    if [ -d "$dir" ]; then
        as_user_run "$user" test -w "$dir" 2>/dev/null
        return $?
    fi
    parent="$(dirname "$dir")"
    while [ -n "$parent" ] && [ "$parent" != "/" ] && [ "$parent" != "." ]; do
        if [ -d "$parent" ]; then
            as_user_run "$user" test -w "$parent" 2>/dev/null
            return $?
        fi
        parent="$(dirname "$parent")"
    done
    return 1
}

user_can_operate_splunk() {
    local user="$1"
    is_root_account "$user" && return 0

    if ! as_user_run "$user" test -r "$SPLUNK_HOME/etc" 2>/dev/null; then
        return 1
    fi
    if [ -e "$SPLUNK_HOME/etc/users/users.ini" ] && ! as_user_run "$user" test -r "$SPLUNK_HOME/etc/users/users.ini" 2>/dev/null; then
        return 1
    fi
    can_write_or_create_dir "$user" "$SPLUNK_HOME/var/log/splunk" || return 1
    can_write_or_create_dir "$user" "$SPLUNK_HOME/var/run/splunk" || return 1
    return 0
}

accept_service_user() {
    local raw="$1"
    local src="$2"
    local require_access="${3:-yes}"
    local name
    name="$(resolve_username "$raw")" || return 1
    if [ "$require_access" = "yes" ] && ! user_can_operate_splunk "$name"; then
        log_message "Ignoring candidate service user=$name source=$src: cannot read $SPLUNK_HOME/etc or write $SPLUNK_HOME/var (start would fail with Permission denied)." "$PROCESS_ID"
        return 1
    fi
    set_service_user "$name" "$src"
}

read_runtime_owner() {
    local p owner
    for p in \
        "$SPLUNK_HOME/var/run/splunk" \
        "$SPLUNK_HOME/var/log/splunk" \
        "$SPLUNK_HOME/etc" \
        "$SPLUNK_HOME/bin/splunk"
    do
        [ -e "$p" ] || continue
        owner="$(stat -c '%U' "$p" 2>/dev/null)"
        [ -n "$owner" ] || continue
        printf '%s' "$owner"
        return 0
    done
    return 1
}

service_user_is_root() {
    is_root_account "$SPLUNK_SERVICE_USER" || [ "$SPLUNK_SERVICE_UID" = "0" ]
}

running_as_service_user() {
    [ -n "$SPLUNK_SERVICE_USER" ] || return 1
    [ "$CURRENT_USER" = "$SPLUNK_SERVICE_USER" ] || [ "$CURRENT_UID" = "$SPLUNK_SERVICE_UID" ]
}

read_launch_conf_os_user() {
    local f="$SPLUNK_HOME/etc/splunk-launch.conf"
    local val
    [ -f "$f" ] || return 1
    val="$(awk -F= '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*SPLUNK_OS_USER[[:space:]]*=/ {
            val=$2
            sub(/[;#].*$/, "", val)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            print val
        }
    ' "$f" | tail -n 1)"
    [ -n "$val" ] || return 1
    printf '%s' "$val"
}

read_systemd_splunk_user() {
    local unit val
    command -v systemctl >/dev/null 2>&1 || return 1
    for unit in Splunkd.service splunk.service splunkd.service; do
        val="$(systemctl show -p User --value "$unit" 2>/dev/null | tr -d '\r')"
        # Splunk 8+ units often have no User= (systemd default root) even when
        # SPLUNK_OS_USER is a non-root account. Only trust a non-root value.
        if [ -n "$val" ] && ! is_root_account "$val"; then
            printf '%s' "$val"
            return 0
        fi
    done
    return 1
}

pid_file_path() {
    echo "$SPLUNK_HOME/var/run/splunk/splunkd.pid"
}

read_pid_file() {
    local f pid
    f="$(pid_file_path)"
    [ -f "$f" ] || return 1
    pid="$(awk '{ gsub(/[^0-9]/, "", $1); if ($1 != "") { print $1; exit } }' "$f" 2>/dev/null)"
    printf '%s' "$pid" | grep -qE '^[1-9][0-9]*$' || return 1
    printf '%s' "$pid"
}

pid_is_splunkd() {
    local pid="$1" comm cmdline
    printf '%s' "$pid" | grep -qE '^[1-9][0-9]*$' || return 1
    [ -d "/proc/$pid" ] || return 1
    comm="$(tr '\0' ' ' < "/proc/$pid/comm" 2>/dev/null)"
    printf '%s' "$comm" | grep -qiE '^splunkd' && return 0
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    printf '%s' "$cmdline" | grep -qiE '(^|[[:space:]/])splunkd([[:space:]]|$)' && return 0
    return 1
}

read_running_splunkd_user() {
    local pid user
    pid="$(read_pid_file)" || return 1
    pid_is_splunkd "$pid" || return 1
    user="$(ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}')"
    [ -n "$user" ] || return 1
    printf '%s' "$user"
}

read_home_owner() {
    stat -c '%U' "$SPLUNK_HOME" 2>/dev/null
}

detect_splunk_service_user() {
    local raw
    SPLUNK_SERVICE_USER=""
    SPLUNK_SERVICE_UID=""
    SPLUNK_SERVICE_USER_SOURCE=""

    # Do not trust top-level $SPLUNK_HOME owner. On this fleet the tree is often
    # owned by a login user (ict) while var/log, var/run, and etc are still root.

    if [ -n "${SPLUNK_OS_USER:-}" ] && accept_service_user "$SPLUNK_OS_USER" "env:SPLUNK_OS_USER" "yes"; then
        return 0
    fi

    raw="$(read_launch_conf_os_user 2>/dev/null)"
    if [ -n "$raw" ] && accept_service_user "$raw" "splunk-launch.conf" "yes"; then
        return 0
    fi

    raw="$(read_running_splunkd_user 2>/dev/null)"
    if [ -n "$raw" ] && accept_service_user "$raw" "running-splunkd" "no"; then
        return 0
    fi

    raw="$(read_systemd_splunk_user 2>/dev/null)"
    if [ -n "$raw" ] && accept_service_user "$raw" "systemd" "yes"; then
        return 0
    fi

    raw="$(read_runtime_owner 2>/dev/null)"
    if [ -n "$raw" ] && accept_service_user "$raw" "runtime-dir-owner" "yes"; then
        return 0
    fi

    raw="$(read_home_owner 2>/dev/null)"
    if [ -n "$raw" ] && accept_service_user "$raw" "splunk-home-owner" "yes"; then
        return 0
    fi

    if accept_service_user "$CURRENT_USER" "monitor-process" "yes"; then
        return 0
    fi

    if [ "$CURRENT_UID" -eq 0 ]; then
        set_service_user "root" "fallback-root"
        return 0
    fi

    SPLUNK_SERVICE_USER="$CURRENT_USER"
    SPLUNK_SERVICE_UID="$CURRENT_UID"
    SPLUNK_SERVICE_USER_SOURCE="monitor-process-unresolved"
    return 0
}

splunk_version_requires_run_as_root_flag() {
    local ver major minor
    ver="$(splunk_version_string)"
    major="$(printf '%s' "$ver" | sed -n 's/.*[Ss]plunk \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1/p')"
    minor="$(printf '%s' "$ver" | sed -n 's/.*[Ss]plunk \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\2/p')"
    # If version cannot be parsed, do not assume the flag is required.
    [ -n "$major" ] || return 1
    if [ "$major" -gt 10 ]; then
        return 0
    fi
    if [ "$major" -eq 10 ] && [ "${minor:-0}" -ge 2 ]; then
        return 0
    fi
    return 1
}

needs_run_as_root_flag() {
    service_user_is_root || return 1
    [ "$CURRENT_UID" -eq 0 ] || return 1
    splunk_version_requires_run_as_root_flag
}

cli_rejected_flags() {
    printf '%s' "$1" | grep -qiE 'invalid argument|unknown option|unrecognized|not a valid option|unexpected argument'
}

output_is_permission_denied() {
    printf '%s' "$1" | grep -qiE 'permission denied|cannot create|unreadable'
}

run_splunk_cli() {
    local action="$1"
    local used_root="no"
    local out rc
    local -a cmd=("$SPLUNK_BIN" "$action")
    local -a wrapper=()

    [ -n "$SPLUNK_SERVICE_USER" ] || detect_splunk_service_user

    case "$action" in
        start|restart)
            cmd+=(--accept-license --answer-yes --no-prompt)
            ;;
        stop)
            cmd+=(--no-prompt)
            ;;
        status)
            ;;
        *)
            echo "Unsupported splunk action: $action"
            return 2
            ;;
    esac

    if running_as_service_user; then
        wrapper=()
    elif service_user_is_root; then
        if [ "$CURRENT_UID" -ne 0 ]; then
            log_message "Cannot run splunk $action: Splunk is configured as root but monitor user is $CURRENT_USER." "$PROCESS_ID"
            echo "Cannot run splunk $action as root from user $CURRENT_USER"
            return 1
        fi
    else
        if [ "$CURRENT_UID" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
            wrapper=(runuser -u "$SPLUNK_SERVICE_USER" --)
        elif command -v sudo >/dev/null 2>&1; then
            wrapper=(sudo -H -n -u "$SPLUNK_SERVICE_USER" --)
        elif [ "$CURRENT_UID" -eq 0 ]; then
            wrapper=(su -s /bin/bash)
        else
            log_message "Cannot switch from $CURRENT_USER to Splunk user $SPLUNK_SERVICE_USER (need runuser/sudo)." "$PROCESS_ID"
            echo "Cannot switch to Splunk user $SPLUNK_SERVICE_USER from $CURRENT_USER"
            return 1
        fi
    fi

    if [ "$action" != "status" ] && [ ${#wrapper[@]} -eq 0 ] && needs_run_as_root_flag; then
        cmd+=(--run-as-root)
        used_root="yes"
    fi

    if [ "${wrapper[0]:-}" = "su" ]; then
        log_message "Running as $SPLUNK_SERVICE_USER (source=$SPLUNK_SERVICE_USER_SOURCE): su -c ${cmd[*]}" "$PROCESS_ID"
        out="$(su -s /bin/bash -c "$(printf '%q ' "${cmd[@]}")" "$SPLUNK_SERVICE_USER" 2>&1)"
        rc=$?
    elif [ ${#wrapper[@]} -gt 0 ]; then
        log_message "Running as $SPLUNK_SERVICE_USER (source=$SPLUNK_SERVICE_USER_SOURCE): ${wrapper[*]} ${cmd[*]}" "$PROCESS_ID"
        out="$("${wrapper[@]}" "${cmd[@]}" 2>&1)"
        rc=$?
    else
        log_message "Running as $CURRENT_USER (service_user=$SPLUNK_SERVICE_USER source=$SPLUNK_SERVICE_USER_SOURCE): ${cmd[*]}" "$PROCESS_ID"
        out="$("${cmd[@]}" 2>&1)"
        rc=$?
    fi
    printf '%s\n' "$out"

    if [ $rc -eq 0 ]; then
        return 0
    fi

    if [ "$used_root" = "yes" ] && cli_rejected_flags "$out"; then
        log_message "CLI rejected flags (exit=$rc). Retrying without --run-as-root. output=$(sanitize_log_text "$out")" "$PROCESS_ID"
        unset "cmd[$((${#cmd[@]} - 1))]"
        log_message "Running: ${cmd[*]}" "$PROCESS_ID"
        out="$("${cmd[@]}" 2>&1)"
        rc=$?
        printf '%s\n' "$out"
    elif [ ${#wrapper[@]} -gt 0 ] && [ "$CURRENT_UID" -eq 0 ] && output_is_permission_denied "$out"; then
        log_message "Start/stop as $SPLUNK_SERVICE_USER failed with Permission denied. Splunk files are not writable by that user. Retrying as root --run-as-root." "$PROCESS_ID"
        set_service_user "root" "fallback-root-permission-denied"
        wrapper=()
        cmd=("$SPLUNK_BIN" "$action")
        case "$action" in
            start|restart) cmd+=(--accept-license --answer-yes --no-prompt) ;;
            stop) cmd+=(--no-prompt) ;;
        esac
        if [ "$action" != "status" ] && splunk_version_requires_run_as_root_flag; then
            cmd+=(--run-as-root)
            used_root="yes"
        fi
        log_message "Running as root (source=$SPLUNK_SERVICE_USER_SOURCE): ${cmd[*]}" "$PROCESS_ID"
        out="$("${cmd[@]}" 2>&1)"
        rc=$?
        printf '%s\n' "$out"
    elif [ ${#wrapper[@]} -gt 0 ] && printf '%s' "$out" | grep -qiE 'sudo: a password is required|sudo: no tty|authentication failure'; then
        log_message "User switch failed. Grant NOPASSWD sudo to $CURRENT_USER for user $SPLUNK_SERVICE_USER, or run the monitor as $SPLUNK_SERVICE_USER / root. output=$(sanitize_log_text "$out")" "$PROCESS_ID"
    fi

    return $rc
}

# ---------------------------------------------------------------------------
# Process / HTTP probes
# ---------------------------------------------------------------------------
get_splunk_status_output() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 "$SPLUNK_BIN" status 2>&1
    else
        "$SPLUNK_BIN" status 2>&1
    fi
}

splunkd_is_running() {
    local status_out="${1-}"
    local pid
    if [ -z "$status_out" ]; then
        status_out="$(get_splunk_status_output)"
    fi
    # "splunkd is not running" does not contain "splunkd is running".
    if printf '%s' "$status_out" | grep -qiE 'splunkd is running'; then
        return 0
    fi
    pid="$(read_pid_file)" || return 1
    pid_is_splunkd "$pid"
}

http_probe() {
    local url="$1"
    local err_file hdr_file
    HTTP_CODE="000"
    CURL_RC=0
    SERVER_HEADER=""
    CURL_ERR=""
    HEADERS_SNIPPET=""

    err_file="$(mktemp 2>/dev/null || echo "/tmp/splunk_curl_err_$$.$RANDOM")"
    hdr_file="$(mktemp 2>/dev/null || echo "/tmp/splunk_curl_hdr_$$.$RANDOM")"

    HTTP_CODE="$(
        curl -k -sS --http1.1 -4 \
            --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
            --max-time "$CURL_MAX_TIME_SEC" \
            -o /dev/null -D "$hdr_file" -w "%{http_code}" \
            "$url" 2>"$err_file"
    )"
    CURL_RC=$?
    HTTP_CODE="$(printf '%s' "$HTTP_CODE" | tr -cd '0-9')"
    if ! printf '%s' "$HTTP_CODE" | grep -qE '^[0-9]{3}$'; then
        HTTP_CODE="000"
    fi
    CURL_ERR="$(tr '\n' ' ' < "$err_file" 2>/dev/null)"
    SERVER_HEADER="$(grep -i '^server:' "$hdr_file" 2>/dev/null | head -n 1 | tr -d '\r')"
    HEADERS_SNIPPET="$(tr '\n\r' '  ' < "$hdr_file" 2>/dev/null | cut -c1-500)"
    rm -f "$err_file" "$hdr_file"
}

http_code_means_listening() {
    local code="$1"
    case "$code" in
        2??|3??|401|403|404|409)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

server_looks_like_splunk() {
    printf '%s' "$1" | grep -qiE 'splunkd|splunk'
}

port_is_healthy() {
    local url="$1"
    local require_server="${2:-yes}"
    http_probe "$url"

    if [ "$CURL_RC" -ne 0 ] || [ "$HTTP_CODE" = "000" ]; then
        return 1
    fi
    if ! http_code_means_listening "$HTTP_CODE"; then
        return 1
    fi
    if [ "$require_server" = "yes" ] && [ -n "$SERVER_HEADER" ] && ! server_looks_like_splunk "$SERVER_HEADER"; then
        return 1
    fi
    return 0
}

web_is_healthy() {
    local url last_fail_code="000" last_fail_rc=0
    local -a urls=("$WEB_URL")

    if [ "$WEB_URL" != "https://127.0.0.1:8000" ]; then
        urls+=("https://127.0.0.1:8000")
    fi

    for url in "${urls[@]}"; do
        if port_is_healthy "$url" "no"; then
            EFFECTIVE_WEB_URL="$url"
            return 0
        fi
        last_fail_code="$HTTP_CODE"
        last_fail_rc="$CURL_RC"
    done
    HTTP_CODE="$last_fail_code"
    CURL_RC="$last_fail_rc"
    return 1
}

describe_curl_rc() {
    case "$1" in
        0) echo "ok" ;;
        6) echo "couldn't resolve host" ;;
        7) echo "connection refused / failed to connect" ;;
        28) echo "timeout" ;;
        35) echo "SSL/TLS handshake failed" ;;
        52) echo "empty reply from server" ;;
        56) echo "receive failure" ;;
        124) echo "timeout(1) wrapper" ;;
        *) echo "curl-exit-$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Combined health check
# ---------------------------------------------------------------------------
check_service() {
    local mode="${1:-verbose}"
    local status_out pid pid_alive
    local web_ok=1 mgmt_ok=1 proc_ok=1
    local fail_reasons=()

    status_out="$(get_splunk_status_output)"
    pid="$(read_pid_file 2>/dev/null || true)"
    if pid_is_splunkd "$pid"; then
        pid_alive="yes"
    else
        pid_alive="no"
    fi

    if splunkd_is_running "$status_out"; then
        proc_ok=0
    fi

    if web_is_healthy; then
        web_ok=0
        if [ "$mode" = "verbose" ] && ! server_looks_like_splunk "$SERVER_HEADER"; then
            log_message "Web port is responding but Server header is not Splunkd. url=$EFFECTIVE_WEB_URL http_code=$HTTP_CODE server=\"$(sanitize_log_text "$SERVER_HEADER")\"" "$PROCESS_ID"
        fi
    else
        fail_reasons+=("web")
        if [ "$mode" = "verbose" ]; then
            log_message "WEB CHECK FAILED tried=$WEB_URL,https://127.0.0.1:8000 last_url_http=$HTTP_CODE curl_rc=$CURL_RC curl_meaning=\"$(describe_curl_rc "$CURL_RC")\" server=\"$(sanitize_log_text "$SERVER_HEADER")\" error=\"$(sanitize_log_text "$CURL_ERR")\" headers=\"$(sanitize_log_text "$HEADERS_SNIPPET")\"" "$PROCESS_ID"
        fi
    fi
    LAST_WEB_HTTP="$HTTP_CODE"

    if port_is_healthy "$MGMT_URL" "yes"; then
        mgmt_ok=0
    else
        fail_reasons+=("mgmt")
        if [ "$mode" = "verbose" ]; then
            log_message "MGMT CHECK FAILED url=$MGMT_URL curl_rc=$CURL_RC curl_meaning=\"$(describe_curl_rc "$CURL_RC")\" http_code=$HTTP_CODE server=\"$(sanitize_log_text "$SERVER_HEADER")\" error=\"$(sanitize_log_text "$CURL_ERR")\" headers=\"$(sanitize_log_text "$HEADERS_SNIPPET")\"" "$PROCESS_ID"
        fi
    fi
    LAST_MGMT_HTTP="$HTTP_CODE"

    if [ $proc_ok -ne 0 ]; then
        fail_reasons+=("splunkd_process")
        if [ "$mode" = "verbose" ]; then
            log_message "PROCESS CHECK FAILED pid_file=$(pid_file_path) pid=\"$pid\" pid_is_splunkd=$pid_alive status=\"$(sanitize_log_text "$status_out")\"" "$PROCESS_ID"
        fi
    elif [ "$mode" = "verbose" ] && { [ $web_ok -ne 0 ] || [ $mgmt_ok -ne 0 ]; }; then
        log_message "PROCESS CHECK OK (ports are not healthy). pid=\"$pid\" pid_is_splunkd=$pid_alive status=\"$(sanitize_log_text "$status_out")\"" "$PROCESS_ID"
    fi

    if [ $proc_ok -eq 0 ] && [ $mgmt_ok -eq 0 ]; then
        if [ $web_ok -ne 0 ]; then
            if [ "$REQUIRE_WEB_FOR_DOWN" = "yes" ]; then
                if [ "$mode" = "verbose" ]; then
                    log_message "Service is DOWN because web check is required. web=$(ok_fail $web_ok) mgmt=$(ok_fail $mgmt_ok) proc=$(ok_fail $proc_ok)" "$PROCESS_ID"
                fi
                return 1
            fi
            if [ "$mode" = "verbose" ]; then
                log_message "Service is UP (splunkd + mgmt). Web UI is down; not restarting because core is healthy. Set REQUIRE_WEB_FOR_DOWN=yes to treat web-only failure as down." "$PROCESS_ID"
            fi
        fi
        return 0
    fi

    if [ "$mode" = "verbose" ]; then
        log_message "Service is DOWN. failed_checks=${fail_reasons[*]} web=$(ok_fail $web_ok) mgmt=$(ok_fail $mgmt_ok) proc=$(ok_fail $proc_ok) web_http=$LAST_WEB_HTTP mgmt_http=$LAST_MGMT_HTTP" "$PROCESS_ID"
    fi
    return 1
}

wait_until_healthy() {
    local timeout_sec="${1:-$STARTUP_WAIT_SEC}"
    local elapsed=0
    log_message "Waiting up to ${timeout_sec}s for Splunk to become healthy (poll every ${POLL_INTERVAL_SEC}s)." "$PROCESS_ID"
    while [ "$elapsed" -lt "$timeout_sec" ]; do
        if check_service quiet; then
            log_message "Service is UP after ${elapsed}s." "$PROCESS_ID"
            return 0
        fi
        sleep "$POLL_INTERVAL_SEC"
        elapsed=$((elapsed + POLL_INTERVAL_SEC))
    done
    if check_service verbose; then
        log_message "Service is UP after ${elapsed}s." "$PROCESS_ID"
        return 0
    fi
    log_message "Service is still DOWN after waiting ${timeout_sec}s." "$PROCESS_ID"
    return 1
}

wait_for_splunkd_stop() {
    local max_sec="${1:-30}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_sec" ]; do
        if ! splunkd_is_running; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------
log_cli_result() {
    local action="$1"
    local rc="$2"
    local out="$3"
    log_message "splunk $action finished exit=$rc output=$(sanitize_log_text "$out")" "$PROCESS_ID"
    if printf '%s' "$out" | grep -qiE 'already running'; then
        log_message "NOTE: splunk $action reported already running. A start cannot recover a hung process; restart/stop is required." "$PROCESS_ID"
    fi
    if printf '%s' "$out" | grep -qiE 'run as root|not configured to run as root|must not be run as root'; then
        log_message "NOTE: Splunk refused root. Detected service user=$SPLUNK_SERVICE_USER source=$SPLUNK_SERVICE_USER_SOURCE. Prefer that account instead of --run-as-root." "$PROCESS_ID"
    fi
    if printf '%s' "$out" | grep -qiE 'please add --accept-license|license not accepted'; then
        log_message "NOTE: License was not accepted. --accept-license should be passed on start." "$PROCESS_ID"
    fi
    if printf '%s' "$out" | grep -qiE 'permission denied|cannot create'; then
        log_message "NOTE: Permission denied means the chosen OS user cannot write Splunk dirs. Monitor will retry as root with --run-as-root when possible." "$PROCESS_ID"
    fi
}

do_start() {
    local out rc
    out="$(run_splunk_cli start)"
    rc=$?
    log_cli_result "start" "$rc" "$out"
    return $rc
}

do_restart() {
    local out rc
    out="$(run_splunk_cli restart)"
    rc=$?
    log_cli_result "restart" "$rc" "$out"
    return $rc
}

do_stop() {
    local out rc
    out="$(run_splunk_cli stop)"
    rc=$?
    log_cli_result "stop" "$rc" "$out"
    return $rc
}

recover_splunk() {
    local attempt="$1"
    local running=1

    detect_splunk_service_user
    log_message "Recovery using service user=$SPLUNK_SERVICE_USER uid=$SPLUNK_SERVICE_UID source=$SPLUNK_SERVICE_USER_SOURCE monitor_user=$CURRENT_USER" "$PROCESS_ID"

    if splunkd_is_running; then
        running=0
    fi

    case "$attempt" in
        1)
            if [ $running -eq 0 ]; then
                log_message "Recovery attempt 1: splunkd IS running but health checks failed. Calling restart instead of start." "$PROCESS_ID"
                do_restart
            else
                log_message "Recovery attempt 1: splunkd is not running. Calling start." "$PROCESS_ID"
                do_start
            fi
            ;;
        2)
            log_message "Recovery attempt 2: stop, wait for process exit, then start." "$PROCESS_ID"
            do_stop
            if ! wait_for_splunkd_stop 30; then
                log_message "splunkd still present after stop; continuing with start anyway." "$PROCESS_ID"
            fi
            do_start
            ;;
        3)
            log_message "Recovery attempt 3: final restart." "$PROCESS_ID"
            do_restart
            ;;
        *)
            log_message "Unknown recovery attempt: $attempt" "$PROCESS_ID"
            return 1
            ;;
    esac
}

acquire_lock() {
    local lock
    if ! command -v flock >/dev/null 2>&1; then
        log_message "WARNING: flock not found; duplicate monitors will not be blocked." "STARTUP"
        return 0
    fi
    for lock in /var/run/splunk_status_monitor.lock /tmp/splunk_status_monitor.lock; do
        if exec 9>"$lock" 2>/dev/null; then
            if flock -n 9 2>/dev/null; then
                log_message "Lock acquired: $lock" "STARTUP"
                return 0
            fi
            # File opened but already locked: another instance. Do NOT try the
            # next path, or two monitors would run with two different lock files.
            log_message "Another monitor instance already holds $lock. Exiting." "STARTUP"
            exit 0
        fi
    done
    log_message "WARNING: could not create a lock file. Continuing without exclusive lock." "STARTUP"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required." >&2
    exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
    echo "WARNING: flock not found; duplicate monitors will not be blocked." >&2
fi

if ! detect_splunk_home; then
    init_log_file
    log_message "FATAL: splunk binary not found. Checked: ${CANDIDATE_HOMES[*]}" "STARTUP"
    exit 1
fi

init_log_file
acquire_lock
PROCESS_ID="STARTUP"
detect_splunk_service_user

log_message "Splunk monitor started. splunk_home=$SPLUNK_HOME bin=$SPLUNK_BIN version=\"$(sanitize_log_text "$(splunk_version_string)")\" log_file=$LOG_FILE web_url=$WEB_URL mgmt_url=$MGMT_URL service_user=$SPLUNK_SERVICE_USER service_uid=$SPLUNK_SERVICE_UID service_user_source=$SPLUNK_SERVICE_USER_SOURCE monitor_user=$CURRENT_USER run_as_root_flag=$(needs_run_as_root_flag && echo yes || echo no) require_web_for_down=$REQUIRE_WEB_FOR_DOWN" "STARTUP"

while true; do
    PROCESS_ID="$(openssl rand -hex 3 2>/dev/null | tr 'a-f' 'A-F')"
    [ -n "$PROCESS_ID" ] || PROCESS_ID="$(printf '%04X%02X' $$ "${RANDOM:-1}")"

    if check_service quiet; then
        sleep "$CHECK_INTERVAL_SEC"
        continue
    fi

    check_service verbose

    log_message "Service looks down. Waiting ${CONFIRM_DOWN_WAIT_SEC}s before treating it as a real outage (avoids bounce on slow startup)." "$PROCESS_ID"
    sleep "$CONFIRM_DOWN_WAIT_SEC"

    if check_service verbose; then
        log_message "Service recovered by itself before any start/restart." "$PROCESS_ID"
        sleep "$CHECK_INTERVAL_SEC"
        continue
    fi

    recover_splunk 1
    if wait_until_healthy "$STARTUP_WAIT_SEC"; then
        log_message "Service is up after recovery attempt 1." "$PROCESS_ID"
        sleep "$CHECK_INTERVAL_SEC"
        continue
    fi

    recover_splunk 2
    if wait_until_healthy "$STARTUP_WAIT_SEC"; then
        log_message "Service is up after recovery attempt 2 (stop+start)." "$PROCESS_ID"
        sleep "$CHECK_INTERVAL_SEC"
        continue
    fi

    recover_splunk 3
    if wait_until_healthy "$STARTUP_WAIT_SEC"; then
        log_message "Service is up after recovery attempt 3 (restart)." "$PROCESS_ID"
    else
        log_message "Service is still down after all recovery attempts. Next loop in ${CHECK_INTERVAL_SEC}s. Also check $SPLUNK_HOME/var/log/splunk/splunkd.log" "$PROCESS_ID"
    fi

    sleep "$CHECK_INTERVAL_SEC"
done
