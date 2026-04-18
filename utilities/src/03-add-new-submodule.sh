#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

step_03_add_submodule() {
    print_header "03 · Add New Submodule"
    print_nav_hint ""

    echo -e "${BOLD}Submodule URL:${NC}"
    echo -e "${DIM}  SSH   : git@alias:org/repo.git${NC}"
    echo -e "${DIM}  HTTPS : https://github.com/org/repo.git (public)${NC}\n"
    read -rp "  URL: " sub_url
    check_nav "$sub_url" || return
    [[ -z "$sub_url" ]] && {
        print_error "URL cannot be empty."
        pause
        return
    }

    local is_ssh=false
    if [[ "$sub_url" == git@* ]]; then
        is_ssh=true
    elif [[ "$sub_url" != https://* ]]; then
        print_error "URL must start with git@ or https://"
        pause
        return
    fi

    echo ""
    echo -e "${BOLD}Target directory (relative path inside this repo):${NC}"
    echo -e "${DIM}  e.g. libs/repo-b${NC}\n"
    read -rp "  Path: " sub_path
    check_nav "$sub_path" || return
    [[ -z "$sub_path" ]] && {
        print_error "Path cannot be empty."
        pause
        return
    }

    if [[ -f ".gitmodules" ]]; then
        if git config -f .gitmodules --get-regexp 'submodule\..*\.url' 2>/dev/null | awk '{print $2}' | grep -qxF "$sub_url"; then
            print_error "URL already exists in .gitmodules — aborting."
            pause
            return
        fi
        if git config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk '{print $2}' | grep -qxF "$sub_path"; then
            print_error "Path '${sub_path}' already in .gitmodules — aborting."
            pause
            return
        fi
    fi

    if $is_ssh; then
        local original_sub_url="$sub_url"
        local original_alias
        original_alias=$(_url_to_alias "$original_sub_url")
        local custom_alias_applied=0

        mapfile -t keys < <(list_private_keys)
        if [[ ${#keys[@]} -eq 0 ]]; then
            print_warn "No SSH keys found — add one via option 02 first."
            pause
            return
        fi

        echo ""
        single_select "SSH key for this submodule:" "yes" "${keys[@]}"
        local rc=$?
        ((rc == 1)) && return

        if [[ -n "$SELECTED_ITEM" ]]; then
            local alias
            alias=$(_url_to_alias "$sub_url")

            if [[ "$alias" =~ ^(gitlab|github)\.com$ ]]; then
                print_warn "Host is plain '${alias}' — a custom alias is recommended."
                echo -e "${DIM}  Enter custom alias or Enter to keep '${alias}'${NC}"
                read -rp "  Alias: " custom
                check_nav "$custom" || return
                if [[ -n "$custom" ]]; then
                    local repo_part
                    repo_part=$(echo "$sub_url" | sed -E 's/git@[^:]+://')
                    sub_url="git@${custom}:${repo_part}"
                    alias="$custom"
                    custom_alias_applied=1
                fi
            fi

            local hostname
            if (( custom_alias_applied == 1 )); then
                hostname="$original_alias"
            else
                hostname=$(_alias_to_hostname "$alias")
            fi

            if _host_exists "$alias"; then
                local existing_hostname existing_identity expected_identity
                existing_hostname=$(_host_hostname "$alias")
                existing_identity=$(_host_identityfile "$alias")
                expected_identity="${SSH_DIR}/${SELECTED_ITEM}"

                if [[ "$existing_hostname" != "$hostname" || "$existing_identity" != "$expected_identity" ]]; then
                    print_warn "Host alias '${alias}' already exists with different settings:"
                    print_info "Current: HostName=${existing_hostname:-?}, IdentityFile=${existing_identity:-?}"
                    print_info "Wanted : HostName=${hostname}, IdentityFile=${expected_identity}"
                    read -rp "  Update this alias? (y/N): " upd
                    if [[ "${upd,,}" == "y" ]]; then
                        remove_ssh_config_entry "$alias"
                    elif (( custom_alias_applied == 1 )); then
                        print_warn "Keeping existing alias and reverting URL to original host alias."
                        sub_url="$original_sub_url"
                        alias=$(_url_to_alias "$sub_url")
                        hostname=$(_alias_to_hostname "$alias")
                    else
                        print_warn "Keeping existing alias configuration."
                    fi
                fi
            fi

            add_ssh_config_entry "$alias" "$hostname" "$SELECTED_ITEM"
        fi
    fi

    echo ""
    print_info "Running: git submodule add ${sub_url} ${sub_path}"
    if git submodule add "$sub_url" "$sub_path"; then
        print_success "Submodule added!"
        echo ""
        echo -e "${DIM}  Next: git add .gitmodules ${sub_path} && git commit -m 'chore: add submodule'${NC}"
    else
        print_error "git submodule add failed."
    fi

    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_03_add_submodule
