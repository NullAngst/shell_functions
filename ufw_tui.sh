#!/usr/bin/env bash
#
# ufw_tui - menu-driven front end for ufw: list, add and remove rules, allow
# or deny by port (80/tcp) or source IP, set default policies,
# enable/disable/reload, or reset.
#
# Usage: sudo ufw_tui

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'ufw_tui: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=ufw_tui

clear_screen() {
    if [ -t 1 ]; then
        if command -v clear >/dev/null 2>&1; then
            clear
        else
            printf '\033[H\033[2J'
        fi
    fi
}

pause() {
    local _
    printf '\n'
    read -r -p "Press Enter to return to menu..." _ || true
}

ask() {
    # $1 prompt, $2 name of the variable to fill. EOF (Ctrl+D) leaves the tool.
    local reply
    if ! read -r -p "$1" reply; then
        printf '\n'
        exit 0
    fi
    printf -v "$2" '%s' "$reply"
}

# ufw failing on one rule (bad port, typo'd IP) shouldn't drop you out of the menu
run_ufw() {
    if ! ufw "$@"; then
        printf '%s: ufw reported an error, nothing was changed by that command.\n' "$prog" >&2
    fi
}

valid_port() {
    # 22, 80/tcp, 6000:6007/udp, or a service name like ssh
    [[ "$1" =~ ^([0-9]{1,5}(:[0-9]{1,5})?|[A-Za-z][A-Za-z0-9-]*)(/(tcp|udp))?$ ]]
}

valid_ip() {
    # IPv4 or IPv6, optionally with a CIDR prefix. ufw does the strict check.
    [[ "$1" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]
}

list_rules() {
    clear_screen
    printf 'Current UFW Rules:\n'
    run_ufw status numbered
    pause
}

remove_rule() {
    local rule_num
    clear_screen
    run_ufw status numbered
    printf '\n'
    ask "Enter the rule number to delete (or 'c' to cancel): " rule_num
    case "$rule_num" in
        c|C|"") return 0 ;;
    esac
    if [[ ! "$rule_num" =~ ^[0-9]+$ ]]; then
        printf 'Not a rule number: %s\n' "$rule_num"
    else
        # ufw asks for its own confirmation here
        run_ufw delete "$rule_num"
    fi
    pause
}

toggle_ufw() {
    local opt
    clear_screen
    printf 'UFW State Management\n'
    printf '1) Enable UFW\n2) Disable UFW\n3) Reload UFW\n4) Cancel\n'
    ask "Select an option: " opt
    case "$opt" in
        1) run_ufw enable ;;
        2) run_ufw disable ;;
        3) run_ufw reload ;;
        4|"") return 0 ;;
        *) printf 'Invalid option.\n' ;;
    esac
    pause
}

new_rule() {
    local opt action port ip_type ip_addr def_opt port_num port_proto
    clear_screen
    printf 'New Rule Menu\n'
    printf '1) Open/Allow Port\n2) Close/Deny Port\n3) Allow specific IP completely\n'
    printf '4) Deny specific IP completely\n5) Set Default Policy\n6) Cancel\n'
    ask "Select an option: " opt

    case "$opt" in
        1|2)
            action=allow
            if [ "$opt" = 2 ]; then
                action=deny
            fi
            ask "Enter port (e.g. 22, 80/tcp, 6000:6007/udp): " port
            if ! valid_port "$port"; then
                printf 'Not a valid port: "%s"\n' "$port" >&2
                pause
                return 0
            fi

            ask "(A)ny IP or (S)pecific IP? [A/s]: " ip_type
            case "$ip_type" in
                s|S)
                    ask "Enter specific IP address: " ip_addr
                    if ! valid_ip "$ip_addr"; then
                        printf 'Not a valid IP address: "%s"\n' "$ip_addr" >&2
                        pause
                        return 0
                    fi
                    # The "from ... to any port" form doesn't take port/proto
                    # combined, the protocol goes in separately via "proto".
                    port_num="${port%%/*}"
                    port_proto=""
                    if [[ "$port" == */* ]]; then
                        port_proto="${port##*/}"
                    fi
                    if [ -n "$port_proto" ]; then
                        run_ufw "$action" proto "$port_proto" from "$ip_addr" to any port "$port_num"
                    else
                        run_ufw "$action" from "$ip_addr" to any port "$port_num"
                    fi
                    ;;
                *)
                    # The simple form takes "port/proto" directly
                    run_ufw "$action" "$port"
                    ;;
            esac
            ;;
        3|4)
            action=allow
            if [ "$opt" = 4 ]; then
                action=deny
            fi
            ask "Enter IP address to $action: " ip_addr
            if ! valid_ip "$ip_addr"; then
                printf 'Not a valid IP address: "%s"\n' "$ip_addr" >&2
                pause
                return 0
            fi
            run_ufw "$action" from "$ip_addr"
            ;;
        5)
            printf '1) Default Allow Incoming\n2) Default Deny Incoming\n'
            printf '3) Default Allow Outgoing\n4) Default Deny Outgoing\n'
            ask "Select option: " def_opt
            case "$def_opt" in
                1) run_ufw default allow incoming ;;
                2) run_ufw default deny incoming ;;
                3) run_ufw default allow outgoing ;;
                4) run_ufw default deny outgoing ;;
                *) printf 'Invalid option.\n' ;;
            esac
            ;;
        *)
            return 0
            ;;
    esac
    pause
}

main() {
    local main_opt reset_confirm

    if [ "$EUID" -ne 0 ]; then
        printf '%s: this must be run as root. Use sudo.\n' "$prog" >&2
        exit 1
    fi
    if ! command -v ufw >/dev/null 2>&1; then
        printf '%s: missing required commands: ufw\n' "$prog" >&2
        exit 1
    fi

    while true; do
        clear_screen
        printf 'UFW Management Utility\n======================\n'
        printf '1) New Rule\n2) List Rules\n3) Remove Rule\n4) Enable / Disable / Reload\n'
        printf '5) Reset UFW to factory defaults\n6) Exit\n'
        ask "Select an option: " main_opt

        case "$main_opt" in
            1) new_rule ;;
            2) list_rules ;;
            3) remove_rule ;;
            4) toggle_ufw ;;
            5)
                ask "Are you sure you want to reset UFW? All rules will be wiped. [y/N]: " reset_confirm
                case "$reset_confirm" in
                    [yY]|[yY][eE][sS])
                        run_ufw --force reset
                        pause
                        ;;
                esac
                ;;
            6|q|Q) clear_screen; exit 0 ;;
            *)
                printf 'Invalid option.\n'
                sleep 1
                ;;
        esac
    done
}

main "$@"
