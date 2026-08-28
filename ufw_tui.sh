#!/usr/bin/env bash

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Use sudo."
   exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
    echo "Error: ufw is not installed or not in PATH." >&2
    exit 1
fi

# Splits "PORT" or "PORT/PROTO" into PORT_NUM and PORT_PROTO globals.
parse_port_proto() {
    local input="$1"
    if [[ "$input" == */* ]]; then
        PORT_NUM="${input%%/*}"
        PORT_PROTO="${input##*/}"
    else
        PORT_NUM="$input"
        PORT_PROTO=""
    fi
}

list_rules() {
    clear
    echo "Current UFW Rules:"
    ufw status numbered
    echo ""
    read -p "Press Enter to return to menu..."
}

remove_rule() {
    clear
    ufw status numbered
    echo ""
    read -p "Enter the rule number to delete (or 'c' to cancel): " rule_num
    if [[ "${rule_num,,}" != "c" ]]; then
        ufw delete "$rule_num"
        echo ""
        read -p "Press Enter to return to menu..."
    fi
}

toggle_ufw() {
    clear
    echo "UFW State Management"
    echo "1) Enable UFW"
    echo "2) Disable UFW"
    echo "3) Reload UFW"
    echo "4) Cancel"
    read -p "Select an option: " opt
    case $opt in
        1) ufw enable ;;
        2) ufw disable ;;
        3) ufw reload ;;
        4) return ;;
        *) echo "Invalid option." ;;
    esac
    read -p "Press Enter to return to menu..."
}

new_rule() {
    clear
    echo "New Rule Menu"
    echo "1) Open/Allow Port"
    echo "2) Close/Deny Port"
    echo "3) Allow specific IP completely"
    echo "4) Deny specific IP completely"
    echo "5) Set Default Policy"
    echo "6) Cancel"
    read -p "Select an option: " opt

    case $opt in
        1|2)
            local action="allow"
            [[ "$opt" == "2" ]] && action="deny"

            read -p "Enter port number (e.g., 22 or 80/tcp): " port
            if [[ -z "$port" ]]; then
                echo "Error: No port entered." >&2
                read -p "Press Enter to return to menu..."
                return
            fi

            read -p "(A)ny IP or (S)pecific IP? [A/s]: " ip_type
            if [[ "${ip_type,,}" == "s" ]]; then
                read -p "Enter specific IP address: " ip_addr
                if [[ -z "$ip_addr" ]]; then
                    echo "Error: No IP entered." >&2
                    read -p "Press Enter to return to menu..."
                    return
                fi
                # ufw's "from ... to any port" syntax does not accept "port/proto"
                # combined; the protocol has to be passed separately via "proto".
                parse_port_proto "$port"
                if [[ -n "$PORT_PROTO" ]]; then
                    ufw "$action" proto "$PORT_PROTO" from "$ip_addr" to any port "$PORT_NUM"
                else
                    ufw "$action" from "$ip_addr" to any port "$PORT_NUM"
                fi
            else
                # Simple form does accept "port/proto" shorthand directly.
                ufw "$action" "$port"
            fi
            ;;
        3)
            read -p "Enter IP address to allow: " ip_addr
            if [[ -z "$ip_addr" ]]; then
                echo "Error: No IP entered." >&2
                read -p "Press Enter to return to menu..."
                return
            fi
            ufw allow from "$ip_addr"
            ;;
        4)
            read -p "Enter IP address to deny: " ip_addr
            if [[ -z "$ip_addr" ]]; then
                echo "Error: No IP entered." >&2
                read -p "Press Enter to return to menu..."
                return
            fi
            ufw deny from "$ip_addr"
            ;;
        5)
            echo "1) Default Allow Incoming"
            echo "2) Default Deny Incoming"
            echo "3) Default Allow Outgoing"
            echo "4) Default Deny Outgoing"
            read -p "Select option: " def_opt
            case "$def_opt" in
                1) ufw default allow incoming ;;
                2) ufw default deny incoming ;;
                3) ufw default allow outgoing ;;
                4) ufw default deny outgoing ;;
                *) echo "Invalid option." ;;
            esac
            ;;
        *)
            return
            ;;
    esac
    echo ""
    read -p "Press Enter to return to menu..."
}

while true; do
    clear
    echo "UFW Management Utility"
    echo "======================"
    echo "1) New Rule"
    echo "2) List Rules"
    echo "3) Remove Rule"
    echo "4) Enable / Disable / Reload"
    echo "5) Reset UFW to factory defaults"
    echo "6) Exit"
    read -p "Select an option: " main_opt

    case $main_opt in
        1) new_rule ;;
        2) list_rules ;;
        3) remove_rule ;;
        4) toggle_ufw ;;
        5)
            read -p "Are you sure you want to reset UFW? All rules will be wiped. [y/N]: " reset_confirm
            if [[ "${reset_confirm,,}" == "y" ]]; then
                ufw --force reset
                read -p "Press Enter to return to menu..."
            fi
            ;;
        6) clear; exit 0 ;;
        *) 
            echo "Invalid option."
            sleep 1
            ;;
    esac
done
