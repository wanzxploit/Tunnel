#!/usr/bin/env bash

# =========================================================
# Tunnel
# Cloudflared + localhost.run + Pinggy + Serveo launcher
# Created by Wanz Xploit
# =========================================================

set -u

APP_NAME="Tunnel"
AUTHOR="Wanz Xploit"
VERSION="5.6"

# --- Palette ---------------------------------------------------------------
# A single cohesive system: a network-teal primary, a soft-blue highlight, and
# muted neutrals. Kept narrow (256-color) so it renders reliably on any modern
# terminal, including Termux.
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

C_INK='\033[38;5;255m'      # body text        soft white
C_MUTED='\033[38;5;244m'     # secondary        grey
C_DIM='\033[38;5;240m'       # faint            darker grey
C_ACCENT='\033[38;5;49m'     # primary          network teal
C_ACCENT2='\033[38;5;75m'    # highlight        soft blue
C_OK='\033[38;5;48m'         # success          green
C_WARN='\033[38;5;214m'      # warning          amber
C_ERR='\033[38;5;203m'       # error            coral

# --- Terminal sizing -------------------------------------------------------
# Detect live terminal width but clamp it so the frame never wraps on tiny
# terminals nor stretches awkwardly on very wide ones.
TERM_MIN=42
TERM_MAX=80
detect_width() {
    local cols=64
    if [[ -n "${COLUMNS:-}" ]] && [[ "$COLUMNS" =~ ^[0-9]+$ ]] && (( COLUMNS >= TERM_MIN )); then
        cols="$COLUMNS"
    elif command -v tput >/dev/null 2>&1; then
        local t
        t="$(tput cols 2>/dev/null || echo 64)"
        [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" -ge 4 ]] && cols="$t"
    fi
    if (( cols > TERM_MAX )); then cols="$TERM_MAX"; fi
    if (( cols < TERM_MIN )); then cols="$TERM_MIN"; fi
    TERM_WIDTH="$cols"
}

TUNNEL_PID=""
LOG_FILE=""
TERM_WIDTH=64
RECONNECT_COUNT=0

cleanup() {
    printf "\n"

    if [[ -n "${TUNNEL_PID:-}" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        echo -e "${C_WARN}  Stopping tunnel...${RESET}"
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi

    if [[ -n "${LOG_FILE:-}" && -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
    fi

    echo -e "${C_OK}  Tunnel stopped.${RESET}\n"
    exit 0
}

trap cleanup INT TERM EXIT

clear_screen() {
    clear 2>/dev/null || printf '\033c'
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detects a native Termux install (not proot-distro). Termux uses pkg /
# its own package manager and its own repo layout, so installers must
# branch on this instead of assuming Debian-style apt.
is_termux() {
    [[ -n "${TERMUX_VERSION:-}" ]] || [[ -x "/data/data/com.termux/files/usr/bin/pkg" ]]
}

# Runs a privileged command. Uses sudo when it exists; otherwise runs the
# command directly. This matters because proot-distro environments (Termux,
# "Code On The Go", etc.) log you in as root by default and frequently do
# NOT ship sudo at all - any script that hardcodes `sudo ...` silently dies
# on "sudo: command not found" the moment it hits the first privileged step.
run_priv() {
    if command_exists sudo; then
        sudo "$@"
    else
        "$@"
    fi
}

# Package-manager-aware installer helpers so the same script works on
# native Termux (pkg), proot-distro / Debian / Ubuntu (apt), and other
# apt-based Linux distros.
pm_update() {
    if is_termux; then
        run_priv pkg update -y
    else
        run_priv apt update
    fi
}

pm_install() {
    if is_termux; then
        run_priv pkg install -y "$@"
    else
        run_priv apt install -y "$@"
    fi
}

# =========================================================
# UI primitives
# =========================================================

hline() {
    local char="${1:-─}"
    printf "${C_MUTED}"
    printf "%0.s${char}" $(seq 1 "$TERM_WIDTH")
    printf "${RESET}\n"
}

box_top() {
    printf "${C_ACCENT}╭${C_MUTED}"
    printf "%0.s─" $(seq 1 "$((TERM_WIDTH - 2))")
    printf "${C_ACCENT}╮${RESET}\n"
}

box_bottom() {
    printf "${C_ACCENT}╰${C_MUTED}"
    printf "%0.s─" $(seq 1 "$((TERM_WIDTH - 2))")
    printf "${C_ACCENT}╯${RESET}\n"
}

# Draws a left rail and pads the line to fill the frame width exactly.
box_line() {
    local text="$1"
    local visible_len
    visible_len=$(printf "%s" "$text" | sed -e 's/\x1b\[[0-9;]*m//g' | wc -c)
    # printf "%s" emits no trailing newline, so wc -c is the exact width.
    local pad=$((TERM_WIDTH - 4 - visible_len))
    (( pad < 0 )) && pad=0
    printf "${C_MUTED}│${RESET} %b" "$text"
    printf "%0.s " $(seq 1 "$pad")
    printf " ${C_MUTED}│${RESET}\n"
}

box_blank() {
    box_line ""
}

box_title() {
    local text="$1"
    local visible_len
    visible_len=$(printf "%s" "$text" | sed -e 's/\x1b\[[0-9;]*m//g' | wc -c)
    local pad=$((TERM_WIDTH - visible_len))
    (( pad < 0 )) && pad=0
    local left=$(( pad / 2 ))
    local right=$(( pad - left ))
    printf "${C_ACCENT}"
    printf "%0.s━" $(seq 1 "$left")
    printf "${RESET}%b" "$text"
    printf "${C_ACCENT}"
    printf "%0.s━" $(seq 1 "$right")
    printf "${RESET}\n"
}

status_line() {
    local kind="$1"
    local label="$2"
    local tag color

    case "$kind" in
        ok)   tag=" OK "; color="$C_OK"   ;;
        warn) tag=" WARN "; color="$C_WARN" ;;
        err)  tag=" FAIL "; color="$C_ERR"  ;;
        *)    tag=" INFO "; color="$C_ACCENT" ;;
    esac

    echo -e " ${color}${BOLD}${tag}${RESET}  ${C_INK}${label}${RESET}"
}

chip() {
    # inline provider tag rendered with accent brackets
    local text="$1"
    printf "${C_MUTED}[${RESET}${C_ACCENT2}${BOLD}%s${RESET}${C_MUTED}]${RESET}" "$text"
}

banner() {
    clear_screen

    # Compact, width-independent header. No giant ASCII art, so it renders
    # cleanly on every terminal width.
    local sub="${VERSION}  •  ${AUTHOR}"
    local sublen=${#sub}
    local dtype="$(( (TERM_WIDTH - sublen) / 2 ))"
    (( dtype < 0 )) && dtype=0

    echo
    echo -e "  ${C_ACCENT}${BOLD}────  ╱╲  ────${RESET}"
    echo
    printf "${C_MUTED}"
    printf "%0.s " $(seq 1 "$dtype")
    printf "${RESET}${C_MUTED}%s${RESET}\n" "$sub"
    echo
    hline "${C_ACCENT}─"
    echo
}

spinner_wait() {
    local i="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    echo "${frames[$(( i % ${#frames[@]} ))]}"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

check_local_port() {
    local port="$1"
    if command_exists timeout; then
        timeout 2 bash -c "echo >/dev/tcp/127.0.0.1/$port" >/dev/null 2>&1
        return $?
    fi
    return 2
}

# =========================================================
# Dependency checks / installers
# =========================================================

install_cloudflared() {
    echo
    status_line info "Installing cloudflared..."
    hline

    if is_termux; then
        # Native Termux ships cloudflared in its own repo - no Debian repo hacking needed.
        pm_update
        pm_install cloudflared
    else
        # proot / Debian / Ubuntu: add Cloudflare's official apt repo.
        pm_update
        pm_install curl gpg
        run_priv mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | run_priv tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
            | run_priv tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
        pm_update
        pm_install cloudflared
    fi

    hline
    if command_exists cloudflared; then
        status_line ok "cloudflared installed successfully."
        return 0
    else
        status_line err "cloudflared installation failed."
        return 1
    fi
}

install_ssh() {
    echo
    status_line info "Installing openssh-client..."
    hline
    pm_update && pm_install openssh-client
    hline
    if command_exists ssh; then
        status_line ok "openssh-client installed successfully."
        return 0
    else
        status_line err "openssh-client installation failed."
        return 1
    fi
}

install_curl() {
    echo
    status_line info "Installing curl..."
    hline
    pm_update && pm_install curl
    hline
    if command_exists curl; then
        status_line ok "curl installed successfully."
        return 0
    else
        status_line err "curl installation failed."
        return 1
    fi
}

ensure_dependency() {
    local bin="$1"
    local label="$2"
    local installer="$3"

    command_exists "$bin" && return 0

    echo
    status_line warn "${label} is not installed. Installing automatically..."
    "$installer"
    return $?
}

preflight_check() {
    banner

    box_top
    box_title "$(echo -e " ${C_ACCENT2}${BOLD}DEPENDENCY CHECK${RESET} ")"

    local missing=()
    for pair in "cloudflared:cloudflared" "openssh-client:ssh" "curl:curl"; do
        label="${pair%%:*}"
        bin="${pair##*:}"
        local filled
        printf -v filled "%-16s" "$label"
        if command_exists "$bin"; then
            box_line "$(echo -e "${C_OK}●${RESET} ${filled} ${C_MUTED}installed${RESET}")"
        else
            box_line "$(echo -e "${C_ERR}●${RESET} ${filled} ${C_MUTED}missing${RESET}")"
            missing+=("$bin")
        fi
    done

    box_bottom
    echo

    if is_termux; then
        echo -e "  ${C_MUTED}Termux detected - installer will use pkg.${RESET}"
    elif command_exists sudo; then
        echo -e "  ${C_MUTED}sudo detected - installer will use it.${RESET}"
    else
        echo -e "  ${C_MUTED}sudo not found - installer runs directly (assumes root/proot).${RESET}"
    fi

    if (( ${#missing[@]} > 0 )); then
        echo
        local label="dependencies"
        [[ "${#missing[@]}" -eq 1 ]] && label="dependency"
        echo -e "  ${C_WARN}${#missing[@]} missing ${label}.${RESET}"
        read -r -p "$(echo -e "  ${C_ACCENT}?${RESET} Install all now ${C_MUTED}[Y/n]${RESET}: ")" answer
        case "$answer" in
            n|N|no) ;;
            *)
                for bin in "${missing[@]}"; do
                    case "$bin" in
                        cloudflared) ensure_dependency "cloudflared" "cloudflared" "install_cloudflared" ;;
                        ssh)         ensure_dependency "ssh" "openssh-client" "install_ssh" ;;
                        curl)        ensure_dependency "curl" "curl" "install_curl" ;;
                    esac
                done
                ;;
        esac
        echo
    else
        echo -e "  ${C_OK}✓ All dependencies installed.${RESET}"
    fi

    echo
    read -r -p "$(echo -e "  ${C_ACCENT}Press Enter to return...${RESET}")"
}

show_menu() {
    banner

    box_top
    box_title "$(echo -e " ${C_ACCENT2}${BOLD}SELECT PROVIDER${RESET} ")"
    box_blank
    box_line "$(echo -e " ${BOLD}${C_ACCENT2}1${RESET}  ${C_INK}Cloudflared${RESET}   ${C_MUTED}trycloudflare.com${RESET}")"
    box_line "$(echo -e " ${BOLD}${C_ACCENT2}2${RESET}  ${C_INK}localhost.run${RESET}  ${C_MUTED}SSH reverse tunnel${RESET}")"
    box_line "$(echo -e " ${BOLD}${C_ACCENT2}3${RESET}  ${C_INK}Pinggy${RESET}        ${C_WARN}⚠ interstitial${RESET}")"
    box_line "$(echo -e " ${BOLD}${C_ACCENT2}4${RESET}  ${C_INK}Serveo${RESET}        ${C_WARN}⚠ interstitial${RESET}")"
    box_blank
    box_line "$(echo -e " ${BOLD}${C_ACCENT2}5${RESET}  ${C_INK}Check dependencies${RESET}")"
    box_line "$(echo -e " ${BOLD}${C_ERR}0${RESET}  ${C_INK}Exit${RESET}")"
    box_bottom
    echo
}

ask_port() {
    local port
    while true; do
        read -r -p "$(echo -e "  ${C_ACCENT}?${RESET} Local port to expose: ")" port
        if validate_port "$port"; then
            PORT="$port"
            break
        fi
        status_line err "Invalid port. Use a value between 1-65535."
    done
}

verify_local_server() {
    echo
    status_line info "Checking localhost:${PORT}..."

    check_local_port "$PORT"
    local status=$?

    if [[ "$status" -eq 0 ]]; then
        status_line ok "Local server detected."
        return 0
    fi

    if [[ "$status" -eq 2 ]]; then
        status_line warn "Could not auto-verify the port."
        return 0
    fi

    status_line warn "No server detected on port ${PORT}."
    read -r -p "$(echo -e "  ${C_ACCENT}?${RESET} Continue anyway ${C_MUTED}[y/N]${RESET}: ")" answer

    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) status_line err "Cancelled."; exit 1 ;;
    esac
}

# Launches an SSH-based tunnel in the background.
launch_ssh_tunnel() {
    ssh "$@" >"$LOG_FILE" 2>&1 &
    TUNNEL_PID=$!
}

# Generic log-based URL watcher (used by cloudflared / localhost.run / pinggy / serveo)
# If an anchor pattern is given, only lines matching it are searched for the
# URL - this matters for services like localhost.run whose startup banner
# advertises unrelated links (e.g. an admin panel) before the real tunnel
# line, which a plain "first match wins" regex would grab by mistake.
wait_for_url() {
    local regex="$1"
    local timeout_seconds="${2:-30}"
    local anchor="${3:-}"
    local elapsed=0
    local url=""
    local i=0

    while (( elapsed < timeout_seconds )); do
        if [[ -f "$LOG_FILE" ]]; then
            if [[ -n "$anchor" ]]; then
                url="$(grep -E "$anchor" "$LOG_FILE" 2>/dev/null | grep -Eo "$regex" | head -n 1 || true)"
            else
                url="$(grep -Eo "$regex" "$LOG_FILE" 2>/dev/null | head -n 1 || true)"
            fi
            if [[ -n "$url" ]]; then
                PUBLIC_URL="$url"
                printf "\r\033[K"
                return 0
            fi
        fi

        if [[ -n "${TUNNEL_PID:-}" ]] && ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            printf "\r\033[K"
            return 1
        fi

        local frame
        frame=$(spinner_wait "$i")
        printf "\r  ${C_ACCENT}%s${RESET}  ${C_MUTED}Waiting for public URL... %ss${RESET}" "$frame" "$elapsed"

        sleep 1
        ((elapsed++))
        ((i++))
    done

    printf "\r\033[K"
    return 1
}

show_result() {
    # A public link that cannot fit inside the frame would wrap on narrow
    # terminals. Detect that and print it as a full-width featured line below
    # the box so it stays visible and copy-paste friendly at any terminal size.
    local url_len
    url_len=$(printf "%s" "$PUBLIC_URL" | wc -c)
    local inner=$((TERM_WIDTH - 4 - 9))     # room inside frame for "Public  " + value

    printf "\n"
    box_top
    box_title "$(echo -e " ${C_OK}${BOLD}● TUNNEL ACTIVE${RESET} ")"
    box_blank
    box_line "$(echo -e " ${C_MUTED}Provider ${RESET} $(chip "$SERVER_NAME")")"
    box_line "$(echo -e " ${C_MUTED}Local    ${RESET} ${C_INK}127.0.0.1:${PORT}${RESET}")"
    if (( url_len <= inner )); then
        box_line "$(echo -e " ${C_MUTED}Public   ${RESET} ${BOLD}${C_ACCENT2}${PUBLIC_URL}${RESET}")"
    else
        box_blank
        box_line "$(echo -e " ${C_MUTED}Public   ${RESET} ${C_MUTED}(link di bawah)${RESET}")"
    fi
    if (( RECONNECT_COUNT > 0 )); then
        box_blank
        box_line "$(echo -e " ${C_WARN}↻  Auto-reconnect #${RECONNECT_COUNT}${RESET}${C_MUTED}  new link below${RESET}")"
    fi
    box_bottom

    # Featured link line - spans the full terminal width, highlighted so it is
    # easy to spot and select.
    if (( url_len > inner )); then
        echo
        echo -e "  ${C_MUTED}┌─ ${C_INK}Public URL${C_MUTED} ─${RESET}"
        echo -e "  ${C_ACCENT}${BOLD}${PUBLIC_URL}${RESET}"
        echo -e "  ${C_MUTED}└${RESET}"
    fi

    echo
    echo -e "  ${C_DIM}Auto-reconnect is active - a fresh link shows automatically on drop.${RESET}"
    echo -e "  ${C_MUTED}Press Ctrl+C to stop the tunnel.${RESET}"
    echo
}

# Waits for the running tunnel process to die. When it exits (by itself or
# because the remote host dropped it), restarts the provider so a fresh
# public URL is obtained. Ctrl+C is handled by the EXIT trap in cleanup().
run_forever() {
    local name="$1"
    local retries=0

    while true; do
        RECONNECT_COUNT="$retries"

        case "$name" in
            cloudflared)   start_cloudflared ;;
            localhost.run) start_localhost_run ;;
            pinggy)        start_pinggy ;;
            serveo)        start_serveo ;;
        esac

        # start_* returns only after the tunnel process has exited.
        # 0 = tunnel ran then dropped -> reconnect. 1 = fatal startup error.
        if (( $? != 0 )); then
            exit 1
        fi

        retries=$((retries + 1))
        status_line warn "Tunnel lost. Reconnecting (attempt #${retries})..."

        if [[ -n "${TUNNEL_PID:-}" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
            kill "$TUNNEL_PID" 2>/dev/null || true
            wait "$TUNNEL_PID" 2>/dev/null || true
        fi
        rm -f "$LOG_FILE"
        sleep 3
    done
}

show_failure_log() {
    echo
    status_line err "Failed to obtain a public URL."

    if [[ -f "$LOG_FILE" ]]; then
        echo
        echo -e "  ${C_MUTED}Last log output:${RESET}"
        hline
        tail -n 15 "$LOG_FILE" 2>/dev/null || true
        hline
    fi
}

# =========================================================
# Providers
# =========================================================

start_cloudflared() {
    SERVER_NAME="Cloudflared"

    if ! ensure_dependency "cloudflared" "cloudflared" "install_cloudflared"; then
        exit 1
    fi

    local max_attempts=3
    local attempt=1

    while (( attempt <= max_attempts )); do
        LOG_FILE="$(mktemp)"

        printf "\r\033[K  ${C_ACCENT}${BOLD} INFO ${RESET}  ${C_INK}Cloudflare quick tunnel (attempt %d/%d)...${RESET}" "$attempt" "$max_attempts"

        cloudflared tunnel --url "http://127.0.0.1:${PORT}" >"$LOG_FILE" 2>&1 &
        TUNNEL_PID=$!

        if wait_for_url 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' 25; then
            printf "\n"
            show_result
            wait "$TUNNEL_PID"
            return 0
        fi

        # trycloudflare.com's free quick-tunnel endpoint has a known,
        # longstanding issue where it occasionally rate-limits or hiccups
        # and cloudflared fails to parse the response, producing exactly
        # this error. It is transient on Cloudflare's side, not a config
        # problem - retrying after a short pause usually clears it.
        if grep -q "failed to unmarshal quick Tunnel\|error code: 1101" "$LOG_FILE" 2>/dev/null; then
            rm -f "$LOG_FILE"
            if (( attempt < max_attempts )); then
                sleep 4
            fi
            ((attempt++))
            continue
        fi

        printf "\n"
        show_failure_log
        exit 1
    done

    printf "\n"
    status_line err "Cloudflare's quick-tunnel service is still rate-limited after ${max_attempts} tries."
    echo -e "  ${C_MUTED}Known Cloudflare-side limitation, not a script bug.${RESET}"
    echo -e "  ${C_MUTED}Try again later, or use localhost.run / Pinggy instead.${RESET}"
    exit 1
}

start_localhost_run() {
    SERVER_NAME="localhost.run"

    if ! ensure_dependency "ssh" "openssh-client" "install_ssh"; then
        exit 1
    fi

    LOG_FILE="$(mktemp)"
    status_line info "Starting localhost.run tunnel..."

    launch_ssh_tunnel \
        -o "ServerAliveInterval=30" \
        -o "ServerAliveCountMax=3" \
        -o "ExitOnForwardFailure=yes" \
        -o "StrictHostKeyChecking=accept-new" \
        -R "80:127.0.0.1:${PORT}" \
        nokey@localhost.run

    if wait_for_url \
        'https?://[A-Za-z0-9._-]+\.(lhr\.life|localhost\.run|lhr\.domains)' \
        40 \
        'tunneled with tls termination'; then
        show_result
        wait "$TUNNEL_PID"
        return 0
    else
        show_failure_log
        return 1
    fi
}

start_pinggy() {
    SERVER_NAME="Pinggy"

    if ! ensure_dependency "ssh" "openssh-client" "install_ssh"; then
        exit 1
    fi

    LOG_FILE="$(mktemp)"
    status_line info "Starting Pinggy tunnel..."
    echo -e "  ${C_MUTED}Free tier: 60 minute session, no signup required.${RESET}"

    launch_ssh_tunnel \
        -p 443 \
        -o "ServerAliveInterval=30" \
        -o "ServerAliveCountMax=3" \
        -o "StrictHostKeyChecking=accept-new" \
        -R "0:localhost:${PORT}" \
        free@a.pinggy.io

    if wait_for_url 'https?://[A-Za-z0-9._-]+\.(pinggy\.link|pinggy-free\.link|free\.pinggy\.net)' 40; then
        show_result
        wait "$TUNNEL_PID"
        return 0
    else
        show_failure_log
        return 1
    fi
}

start_serveo() {
    SERVER_NAME="Serveo"

    if ! ensure_dependency "ssh" "openssh-client" "install_ssh"; then
        exit 1
    fi

    LOG_FILE="$(mktemp)"
    status_line info "Starting Serveo tunnel..."
    status_line warn "Serveo is community-run and occasionally goes down - try another provider if this fails."

    # Try port 22 first, fallback to port 443 if blocked
    launch_ssh_tunnel \
        -o "ServerAliveInterval=30" \
        -o "ServerAliveCountMax=3" \
        -o "StrictHostKeyChecking=accept-new" \
        -o "ConnectTimeout=10" \
        -R "80:127.0.0.1:${PORT}" \
        serveo.net

    if wait_for_url 'https?://[A-Za-z0-9.-]+\.(serveo\.net|serveousercontent\.com)' 30; then
        show_result
        wait "$TUNNEL_PID"
        return 0
    else
        # Kill failed attempt and try port 443
        if [[ -n "${TUNNEL_PID:-}" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
            kill "$TUNNEL_PID" 2>/dev/null || true
            wait "$TUNNEL_PID" 2>/dev/null || true
        fi
        rm -f "$LOG_FILE"

        status_line info "Retrying on port 443..."
        LOG_FILE="$(mktemp)"

        launch_ssh_tunnel \
            -p 443 \
            -o "ServerAliveInterval=30" \
            -o "ServerAliveCountMax=3" \
            -o "StrictHostKeyChecking=accept-new" \
            -R "80:127.0.0.1:${PORT}" \
            serveo.net

        if wait_for_url 'https?://[A-Za-z0-9.-]+\.(serveo\.net|serveousercontent\.com)' 30; then
            show_result
            wait "$TUNNEL_PID"
            return 0
        else
            show_failure_log
            return 1
        fi
    fi
}

main() {
    detect_width

    while true; do
        show_menu
        read -r -p "$(echo -e "  ${C_ACCENT}?${RESET} ${C_INK}Choice:${RESET} ")" choice

        case "$choice" in
            1) SELECTED_SERVER="cloudflared"; break ;;
            2) SELECTED_SERVER="localhost.run"; break ;;
            3) SELECTED_SERVER="pinggy"; break ;;
            4) SELECTED_SERVER="serveo"; break ;;
            5) preflight_check ;;
            0)
                echo
                echo -e "  ${C_OK}Goodbye.${RESET}\n"
                trap - EXIT
                exit 0
                ;;
            *)
                status_line err "Invalid choice."
                sleep 1
                ;;
        esac
    done

    echo
    ask_port
    verify_local_server

    case "$SELECTED_SERVER" in
        cloudflared)   run_forever "cloudflared" ;;
        localhost.run) run_forever "localhost.run" ;;
        pinggy)        run_forever "pinggy" ;;
        serveo)        run_forever "serveo" ;;
    esac
}

main "$@"
