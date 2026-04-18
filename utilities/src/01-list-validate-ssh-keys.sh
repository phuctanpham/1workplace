#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

step_01_list_keys() {
    print_header "01 · List & Validate SSH Keys"

    mapfile -t keys < <(list_private_keys)
    if [[ ${#keys[@]} -eq 0 ]]; then
        print_warn "No SSH private keys found in ${SSH_DIR}."
        pause
        return
    fi

    multi_select "Select keys to validate:" "${keys[@]}"
    local rc=$?
    ((rc == 1)) && return
    ((rc == 2)) && {
        pause
        return
    }

    print_section "Validation Results"

    local key
    for key in "${SELECTED_ITEMS[@]}"; do
        local kpath="${SSH_DIR}/${key}"
        echo ""
        echo -e "  ${BOLD}${MAGENTA}▶ ${key}${NC}"

        local perms
        perms=$(stat -c "%a" "$kpath" 2>/dev/null || stat -f "%OLp" "$kpath" 2>/dev/null || echo "???")
        if [[ "$perms" =~ ^[46]00$ ]]; then
            print_success "Permissions OK (${perms})"
        else
            print_warn "Permissions ${perms} — fixing to 600…"
            chmod 600 "$kpath"
        fi

        local fp
        fp=$(ssh-keygen -l -f "$kpath" 2>/dev/null) \
            && print_success "Fingerprint: ${fp}" \
            || print_error "Cannot read fingerprint"

        if pub_file=$(matching_public_key_file "$key"); then
            print_success "Public key: ${pub_file}"
        else
            print_warn "No matching .pub file"
        fi

        local hosts
        hosts=$(grep -B5 "IdentityFile.*${key}" "$SSH_CONFIG" 2>/dev/null | awk '/^Host[[:space:]]/{print $2}' | tr '\n' ' ' || true)
        if [[ -z "$hosts" ]]; then
            print_warn "Not assigned to any SSH config Host alias"
            continue
        fi
        print_info "Config aliases: ${hosts}"
        local h
        for h in $hosts; do
            printf "    Testing git@%-30s … " "${h}"
            local out
            out=$(ssh -T -o BatchMode=yes -o ConnectTimeout=6 "git@${h}" 2>&1 || true)
            if echo "$out" | grep -qiE "(welcome|authenticated|hi |successfully)"; then
                echo -e "${GREEN}✔ OK${NC}"
            else
                echo -e "${RED}✖ Failed${NC}  — ${out}"
            fi
        done
    done

    pause
}

_ensure_ssh_dir
step_01_list_keys
