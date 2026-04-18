#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

step_02_add_key() {
    print_header "02 · Add New SSH Key"
    print_nav_hint ""

    echo -e "${BOLD}Paste your SSH PRIVATE key.${NC}"
    echo -e "${DIM}  (Paste all lines, then type END on its own line)${NC}\n"

    local private_key="" line
    while IFS= read -r line; do
        case "$line" in
            q)
                print_info "Quitting…"
                exit 0
                ;;
            b)
                return
                ;;
            END)
                break
                ;;
        esac
        private_key+="${line}"$'\n'
    done

    if ! echo "$private_key" | grep -q "PRIVATE KEY"; then
        print_error "Doesn't look like a valid private key. Aborting."
        pause
        return
    fi

    echo ""
    echo -e "${BOLD}Paste your SSH PUBLIC key (single line):${NC}"
    print_nav_hint " · Enter to skip"
    read -rp "  > " public_key
    check_nav "$public_key" || return

    if [[ -n "$public_key" ]] && ! echo "$public_key" | grep -qE "^(ssh-|ecdsa-)"; then
        print_warn "Doesn't look like a standard public key — saving anyway."
    fi

    echo ""
    echo -e "${BOLD}Key name${NC} ${DIM}(saved as ~/.ssh/<name>)${NC}"
    print_nav_hint ""
    while true; do
        read -rp "  Name: " key_name
        check_nav "$key_name" || return
        [[ -n "$key_name" ]] && break
        print_error "Name cannot be empty."
    done

    local kpath="${SSH_DIR}/${key_name}"

    if [[ -f "$kpath" ]]; then
        print_warn "${kpath} already exists."
        read -rp "  Overwrite? (y/N): " ow
        [[ "${ow,,}" != "y" ]] && {
            print_info "Aborted."
            return
        }
    fi

    printf '%s' "$private_key" > "$kpath"
    chmod 600 "$kpath"
    print_success "Private key → ${kpath} (chmod 600)"

    if [[ -n "$public_key" ]]; then
        echo "$public_key" > "${kpath}.pub"
        chmod 644 "${kpath}.pub"
        print_success "Public key  → ${kpath}.pub (chmod 644)"
    fi

    if ssh-keygen -l -f "$kpath" >/dev/null 2>&1; then
        print_success "Validated: $(ssh-keygen -l -f "$kpath")"
    else
        print_error "Key validation failed — file may be corrupted."
    fi

    pause
}

_ensure_ssh_dir
step_02_add_key
