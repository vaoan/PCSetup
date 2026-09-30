#!/bin/bash
# =============================================================================
# golibrespot-heal.sh - self-healing watchdog for the Spotify -> Discord bridge
# =============================================================================
# Runs every 2 minutes from golibrespot-watchdog.timer. Detects the known
# failure modes of go-librespot and repairs only what is actually broken,
# escalating from "restart" to "upgrade the binary" when a restart provably
# cannot fix the problem.
#
# Failure modes handled (see spotify-discord/FAILURES.md for the full record):
#   SD-001  login5 auth failure -> every play returns HTTP 500. Caused by a bug
#           compiled into the binary, so a restart does NOT fix it; only an
#           upgrade does. This is why the escalation path exists.
#   SD-002  hashcash solver CPU spin - go-librespot burns a core while idle.
#           Same root cause as SD-001, but visible without anyone pressing play.
#   SD-003  dealer connection goes stale (pong losses) - a restart fixes it.
#   SD-004  API dead / not answering on 3678 - a restart fixes it.
#   SD-005  binary version rot - nothing ever upgraded go-librespot, so the box
#           silently decays as Spotify tightens auth. Handled proactively.
#
# SAFETY CONTRACT (why this is safe to run unattended every 2 minutes):
#   - It NEVER restarts anything while audio is actually playing.
#   - It only ever restarts go-librespot. It never touches the bot, and never
#     deletes or rewrites state.json (the Spotify login) - only backs it up.
#   - Every upgrade is verified, and rolls back to the previous binary if the
#     verification fails. A failed upgrade leaves a working box behind.
#   - Restarts and upgrades are rate limited, so it can never flap.
#
# Usage:
#   golibrespot-heal.sh              # heal (what the timer runs)
#   golibrespot-heal.sh --dry-run    # report what it WOULD do, change nothing
#   golibrespot-heal.sh --force-check-version   # ignore the weekly interval
# =============================================================================
set -uo pipefail

API="http://127.0.0.1:3678"
BIN="/usr/local/bin/go-librespot"
CONFIG_DIR="/root/.config/go-librespot"
STATE_DIR="/var/lib/golibrespot-heal"
WORK="$STATE_DIR/work"
UNIT="go-librespot"

# Instantaneous CPU above this, while playback is stopped, means the hashcash
# solver is spinning (SD-002). A genuinely idle Connect device sits near 0%.
CPU_SPIN_PCT=30
# How long after a tier-2 restart we still consider the symptom "the same
# incident". A recurrence inside this window proves restarting does not help.
TIER2_WINDOW=3600
# Rate limits.
MIN_SECONDS_BETWEEN_RESTARTS=300
MIN_SECONDS_BETWEEN_UPGRADES=86400
VERSION_CHECK_INTERVAL=604800   # 7 days

DRY_RUN=0
FORCE_VERSION_CHECK=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force-check-version) FORCE_VERSION_CHECK=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "$STATE_DIR" "$WORK"

# Serialize runs. An upgrade takes ~90s (download + restart + a verification
# poll), which is longer than the 2-minute timer's margin once a manual run is
# also in play - and overlapping runs were observed interleaving in testing,
# one reporting "already on the latest release" while another was mid-upgrade.
# Worse, a second run could restart the service inside the first run's
# verification window and make a good upgrade look like a failed one.
exec 9>"$STATE_DIR/heal.lock"
if ! flock -n 9; then
    echo "[golibrespot-heal] another run is already in progress; exiting"
    exit 0
fi

log() {
    # Goes to the journal (tag: golibrespot-heal) and to stdout when run by hand.
    local msg="$*"
    [ "$DRY_RUN" -eq 1 ] && msg="[dry-run] $msg"
    logger -t golibrespot-heal "$msg" 2>/dev/null || true
    echo "[golibrespot-heal] $msg"
}

now() { date +%s; }
stamp_read()  { cat "$STATE_DIR/$1" 2>/dev/null || echo 0; }
stamp_write() { [ "$DRY_RUN" -eq 1 ] || echo "$(now)" > "$STATE_DIR/$1"; }

# --- observation -------------------------------------------------------------

# HTTP status code from the control API, or 000 when it does not answer.
#
# NOTE: no `|| echo 000` fallback. curl still prints %{http_code} (as 000) when
# the connection fails AND exits non-zero, so the fallback appended a second
# 000 and the code became the string "000000" - which compares unequal to
# "200" so the behaviour was right, but every log line read "HTTP 000000" and
# any future `= "000"` test would have been quietly false.
api_code() {
    local code
    code=$(curl -s -o "$WORK/status.json" -m 5 -w '%{http_code}' "$API/status" 2>/dev/null)
    [ -n "$code" ] || code=000
    echo "$code"
}

# True while audio is actually playing - the guard that keeps this script from
# ever interrupting music.
playback_active() {
    grep -q '"stopped":false' "$WORK/status.json" 2>/dev/null &&
        ! grep -q '"paused":true' "$WORK/status.json" 2>/dev/null
}

glr_pid() { systemctl show -p MainPID --value "$UNIT" 2>/dev/null; }

# Instantaneous CPU% of the process. Deliberately NOT `ps -o pcpu`, which
# reports the average over the process lifetime - useless for spotting a spin
# that started recently, and misleading right after a restart.
cpu_pct() {
    local pid="$1" t1 t2 ticks
    [ -z "$pid" ] || [ "$pid" = "0" ] && { echo 0; return; }
    t1=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || { echo 0; return; }
    sleep 3
    t2=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || { echo 0; return; }
    ticks=$(getconf CLK_TCK 2>/dev/null || echo 100)
    awk -v a="$t1" -v b="$t2" -v k="$ticks" 'BEGIN { printf "%.0f", (b-a)*100/(k*3) }'
}

# Version currently running, read from the startup log line go-librespot emits
# ("running go-librespot 0.9.0"). The binary has no --version flag.
current_version() {
    local v
    v=$(journalctl -u "$UNIT" --no-pager 2>/dev/null |
        grep -o 'running go-librespot [0-9][0-9.]*' | tail -1 | awk '{print $3}')
    [ -n "$v" ] && { echo "$v"; return; }
    cat "$STATE_DIR/version" 2>/dev/null || echo "unknown"
}

latest_version() {
    curl -fsS -m 20 https://api.github.com/repos/devgianlu/go-librespot/releases/latest 2>/dev/null |
        grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 |
        sed 's/.*"v\{0,1\}\([0-9][0-9.]*\)".*/\1/'
}

# Journal window to search for errors. Anything logged BEFORE our last restart
# is history, not a live symptom - without this the script would re-read the
# old errors forever and escalate to an upgrade on the very next run.
error_since() {
    local lr since
    lr=$(stamp_read last_restart)
    since=$(( $(now) - 180 ))
    [ "$lr" -gt "$since" ] && since=$(( lr + 15 ))
    echo "$since"
}

journal_since() { journalctl -u "$UNIT" --since "@$1" --no-pager 2>/dev/null; }

# --- repair ------------------------------------------------------------------

restart_unit() {
    local reason="$1" last
    last=$(stamp_read last_restart)
    if [ $(( $(now) - last )) -lt "$MIN_SECONDS_BETWEEN_RESTARTS" ]; then
        log "WOULD restart ($reason) but a restart happened <${MIN_SECONDS_BETWEEN_RESTARTS}s ago; holding off"
        return 1
    fi
    log "restarting go-librespot: $reason"
    if [ "$DRY_RUN" -eq 0 ]; then
        systemctl restart "$UNIT"
        sleep 8
    fi
    stamp_write last_restart
    return 0
}

# Verify go-librespot is genuinely working - not merely running.
#   - unit active
#   - control API answering 200
#   - "authenticated Login5" in the log since the restart. This is the exact
#     capability SD-001 breaks, and checking it needs no audio playback.
#
# Polls rather than checking once after a fixed sleep. Measured on this box the
# marker lands 0.5s after start, but a single-shot check would call a merely
# SLOW login a FAILED one and roll back a perfectly good upgrade - an
# unattended false rollback nobody would notice for weeks.
verify_healthy() {
    local since="$1" timeout="${2:-45}" deadline code active=0 api=0
    deadline=$(( $(now) + timeout ))
    while :; do
        active=0; api=0
        [ "$(systemctl is-active "$UNIT" 2>/dev/null)" = "active" ] && active=1
        code=$(api_code)
        [ "$code" = "200" ] && api=1
        if [ "$active" -eq 1 ] && [ "$api" -eq 1 ] &&
           journal_since "$since" | grep -q 'authenticated Login5'; then
            return 0
        fi
        [ "$(now)" -ge "$deadline" ] && break
        sleep 3
    done
    [ "$active" -eq 1 ] || { log "verify: unit not active"; return 1; }
    [ "$api" -eq 1 ]    || { log "verify: /status returned $code"; return 1; }
    log "verify: no 'authenticated Login5' within ${timeout}s - the login5 path is still broken"
    return 1
}

# Replace the binary with the latest release, verify, and roll back if the
# verification fails. Backs up state.json (the Spotify login) first: losing it
# means redoing the interactive OAuth tunnel.
do_upgrade() {
    local reason="$1" latest current asset arch t0
    current=$(current_version)
    latest=$(latest_version)
    if [ -z "$latest" ]; then
        log "upgrade skipped ($reason): could not reach the GitHub release API"
        return 1
    fi
    if [ "$latest" = "$current" ]; then
        log "upgrade skipped ($reason): already on the latest release ($current)"
        stamp_write last_version_check
        return 1
    fi
    if [ $(( $(now) - $(stamp_read last_upgrade) )) -lt "$MIN_SECONDS_BETWEEN_UPGRADES" ]; then
        log "WOULD upgrade $current -> $latest ($reason) but an upgrade was attempted <24h ago; holding off"
        return 1
    fi

    arch="$(uname -m)"
    case "$arch" in
        x86_64)        asset="go-librespot_linux_x86_64.tar.gz" ;;
        aarch64|arm64) asset="go-librespot_linux_arm64.tar.gz" ;;
        *) log "upgrade aborted: unsupported architecture $arch"; return 1 ;;
    esac

    log "UPGRADING go-librespot $current -> $latest ($reason)"
    if [ "$DRY_RUN" -eq 1 ]; then return 0; fi
    stamp_write last_upgrade

    if ! curl -fsSL -m 180 \
        "https://github.com/devgianlu/go-librespot/releases/latest/download/$asset" \
        -o "$WORK/glr.tar.gz"; then
        log "upgrade aborted: download failed"
        return 1
    fi
    if ! tar -xzf "$WORK/glr.tar.gz" -C "$WORK" go-librespot 2>/dev/null; then
        log "upgrade aborted: archive did not contain a go-librespot binary"
        return 1
    fi
    # A truncated or HTML error-page download must never reach the install path.
    if [ ! -s "$WORK/go-librespot" ] || [ "$(stat -c %s "$WORK/go-librespot")" -lt 1000000 ]; then
        log "upgrade aborted: downloaded binary is implausibly small"
        return 1
    fi

    cp -a "$CONFIG_DIR/state.json" "$CONFIG_DIR/state.json.bak.$(date +%F)" 2>/dev/null || true
    cp -a "$BIN" "$BIN.prev.bak" || { log "upgrade aborted: could not back up the current binary"; return 1; }

    install -m 755 "$WORK/go-librespot" "$BIN"
    t0=$(now)
    systemctl restart "$UNIT"
    sleep 3
    stamp_write last_restart

    if verify_healthy "$t0"; then
        echo "$latest" > "$STATE_DIR/version"
        stamp_write last_version_check
        rm -f "$STATE_DIR/tier2_stamp"
        log "UPGRADE OK: now running $(current_version) and login5 authenticated"
        return 0
    fi

    log "UPGRADE FAILED verification - rolling back to $current"
    install -m 755 "$BIN.prev.bak" "$BIN"
    t0=$(now)
    systemctl restart "$UNIT"
    sleep 3
    stamp_write last_restart
    if verify_healthy "$t0"; then
        log "rollback OK: back on $current (a human should look at release $latest)"
    else
        log "ERROR: rollback did not verify either - go-librespot needs manual attention"
    fi
    return 1
}

# Tier 2: a restart is tried once; a recurrence inside TIER2_WINDOW proves the
# fault is in the binary, not the process, so we escalate to an upgrade.
escalate() {
    local reason="$1" t2
    t2=$(stamp_read tier2_stamp)
    if [ "$t2" -gt 0 ] && [ $(( $(now) - t2 )) -lt "$TIER2_WINDOW" ]; then
        log "$reason persisted after a restart - restarting cannot fix this"
        do_upgrade "$reason"
        return
    fi
    log "$reason detected - restarting once to see whether it recovers"
    if restart_unit "$reason"; then stamp_write tier2_stamp; fi
}

# --- main --------------------------------------------------------------------

log "check start (version=$(current_version)${DRY_RUN:+})"

CODE=$(api_code)

# Guard: never interrupt music. Everything below either restarts the service or
# swaps the binary, and none of it is worth cutting a song off for.
if [ "$CODE" = "200" ] && playback_active; then
    log "playback active - no action taken"
    exit 0
fi

SINCE=$(error_since)
LOGS=$(journal_since "$SINCE")

# SD-004: the control API is not answering at all.
if [ "$CODE" != "200" ]; then
    escalate "control API not answering (HTTP $CODE)"
    exit 0
fi

# SD-001: login5 / spclient token failures. Playback is impossible in this
# state, and no amount of restarting brings it back on an affected build.
if echo "$LOGS" | grep -qE 'failed authenticating with login5|failed renewing login5 access token|failed obtaining spclient access token'; then
    escalate "login5/spclient authentication failure"
    exit 0
fi

# SD-003: dealer connection gone stale. A restart genuinely fixes this one, so
# it stays a plain restart and never escalates to an upgrade.
DEALER=$(echo "$LOGS" | grep -c 'did not receive last pong from dealer')
if [ "${DEALER:-0}" -ge 3 ]; then
    restart_unit "dealer stale (${DEALER} pong losses)"
    exit 0
fi

# SD-002: the hashcash solver spinning. Detectable while completely idle, which
# is what makes it the early-warning signal for SD-001.
PID=$(glr_pid)
CPU=$(cpu_pct "$PID")
if [ "${CPU:-0}" -ge "$CPU_SPIN_PCT" ]; then
    escalate "CPU spin (${CPU}% while playback stopped)"
    exit 0
fi

# SD-005: proactive version check, so the box cannot rot again between failures.
LAST_CHECK=$(stamp_read last_version_check)
if [ "$FORCE_VERSION_CHECK" -eq 1 ] || [ $(( $(now) - LAST_CHECK )) -ge "$VERSION_CHECK_INTERVAL" ]; then
    CUR=$(current_version)
    LATEST=$(latest_version)
    if [ -n "$LATEST" ] && [ "$LATEST" != "$CUR" ]; then
        do_upgrade "new release available ($CUR -> $LATEST)"
    else
        [ -n "$LATEST" ] && log "version check: $CUR is current"
        stamp_write last_version_check
    fi
    exit 0
fi

log "healthy (cpu=${CPU}%, api=200)"
exit 0
