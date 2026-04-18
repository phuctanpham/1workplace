#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

configure_child_submodules_for_master() {
    local master_path="$1" master_alias="$2"

    [[ -f "${master_path}/.gitmodules" ]] || return 0

    mapfile -t children < <(get_submodule_paths "$master_path")
    [[ ${#children[@]} -gt 0 ]] || return 0

    print_section "Configuring child submodules for ${master_path}"
    mapfile -t keys < <(list_private_keys)

    local pending=()
    local c
    for c in "${children[@]}"; do
        local curl
        curl=$(get_submodule_url "$master_path" "$c")
        if [[ "$curl" == git@* ]]; then
            pending+=("$c")
        else
            echo -e "  ${BOLD}Child:${NC} ${c}  ${DIM}(${curl})${NC}"
            print_info "Public / HTTPS URL — no SSH key needed."
            echo ""
        fi
    done

    if [[ ${#pending[@]} -eq 0 ]]; then
        print_info "No SSH child submodules to configure."
        git -C "$master_path" submodule sync --recursive >/dev/null 2>&1 || true
        git -C "$master_path" submodule update --init --recursive >/dev/null 2>&1 || true
        return 0
    fi

    if [[ ${#keys[@]} -eq 0 ]]; then
        print_warn "No SSH keys available — skipping child SSH configuration."
        git -C "$master_path" submodule sync --recursive >/dev/null 2>&1 || true
        git -C "$master_path" submodule update --init --recursive >/dev/null 2>&1 || true
        return 0
    fi

    while [[ ${#pending[@]} -gt 0 ]]; do
        echo -e "${BOLD}Remaining SSH child submodules:${NC}"
        local i
        for i in "${!pending[@]}"; do
            local purl
            purl=$(get_submodule_url "$master_path" "${pending[$i]}")
            printf "  ${YELLOW}%2d)${NC} %s  ${DIM}(%s)${NC}\n" "$((i + 1))" "${pending[$i]}" "$purl"
        done
        echo -e "${DIM}  (space-separated numbers · a = all · s = skip remaining · b = back · q = quit)${NC}"
        echo ""

        local raw
        read -rp "  Child choice: " raw
        check_nav "$raw" || return

        if [[ "${raw,,}" == "s" ]]; then
            print_info "Skipped remaining child submodules."
            break
        fi

        local batch=()
        if [[ "$raw" == "a" ]]; then
            batch=("${pending[@]}")
        else
            local ok=true
            local num
            for num in $raw; do
                if ! [[ "$num" =~ ^[0-9]+$ ]] || ((num < 1 || num > ${#pending[@]})); then
                    print_error "Invalid: '${num}'"
                    ok=false
                    break
                fi
                batch+=("${pending[$((num - 1))]}")
            done
            $ok || continue
            [[ ${#batch[@]} -gt 0 ]] || { print_error "Select at least one child."; continue; }
        fi

        single_select "SSH key for selected child submodule(s):" "yes" "${keys[@]}"
        local rc2=$?
        ((rc2 == 1)) && continue

        if [[ -z "$SELECTED_ITEM" ]]; then
            print_info "No key selected — skipped selected children."
        else
            local chosen
            for chosen in "${batch[@]}"; do
                local curl source_host alias hostname new_url section_key section_name
                curl=$(get_submodule_url "$master_path" "$chosen")
                source_host=$(_url_to_alias "$curl")
                alias=$(_child_alias_from_master_and_url "$master_alias" "$curl")
                hostname=$(_alias_to_hostname "$source_host")

                upsert_ssh_config_entry "$alias" "$hostname" "$SELECTED_ITEM"

                new_url=$(_url_with_alias "$curl" "$alias")
                section_key=$(git -C "$master_path" config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk -v p="$chosen" '$2 == p { print $1; exit }' || true)
                section_name="${section_key%.path}"
                if [[ -n "$section_name" ]]; then
                    git -C "$master_path" config -f .gitmodules "${section_name}.url" "$new_url"
                    git -C "$master_path" config "${section_name}.url" "$new_url" 2>/dev/null || true
                    if git -C "${master_path}/${chosen}" rev-parse --git-dir >/dev/null 2>&1; then
                        git -C "${master_path}/${chosen}" remote set-url origin "$new_url" 2>/dev/null || true
                    fi
                    print_success "Configured child alias URL for ${chosen}"
                else
                    print_warn "Could not resolve .gitmodules section for ${chosen}"
                fi
            done
        fi

        local next_pending=()
        local p
        for p in "${pending[@]}"; do
            local keep=true
            local b
            for b in "${batch[@]}"; do
                if [[ "$p" == "$b" ]]; then
                    keep=false
                    break
                fi
            done
            $keep && next_pending+=("$p")
        done
        pending=("${next_pending[@]}")
        echo ""
    done

    git -C "$master_path" submodule sync --recursive >/dev/null 2>&1 || true
    git -C "$master_path" submodule update --init --recursive >/dev/null 2>&1 || true

    # Re-apply origin alias URLs after checkout to ensure child repos use expected alias.
    local c2
    for c2 in "${children[@]}"; do
        local curl2 alias2 new_url2
        curl2=$(get_submodule_url "$master_path" "$c2")
        [[ "$curl2" == git@* ]] || continue
        alias2=$(_child_alias_from_master_and_url "$master_alias" "$curl2")
        new_url2=$(_url_with_alias "$curl2" "$alias2")
        if git -C "${master_path}/${c2}" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "${master_path}/${c2}" remote set-url origin "$new_url2" 2>/dev/null || true
        fi
    done
}

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

    local master_alias=""
    if $is_ssh; then
        local source_host
        source_host=$(_url_to_alias "$sub_url")

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
            local alias hostname
            alias=$(_master_alias_from_url "$sub_url")
            master_alias="$alias"
            hostname=$(_alias_to_hostname "$source_host")

            upsert_ssh_config_entry "$alias" "$hostname" "$SELECTED_ITEM"

            local master_alias_url
            master_alias_url=$(_url_with_alias "$sub_url" "$alias")
            sub_url="$master_alias_url"
        fi
    fi

    echo ""
    print_info "Running: git submodule add ${sub_url} ${sub_path}"
    if git submodule add "$sub_url" "$sub_path"; then
        print_success "Submodule added!"

        if [[ "$sub_url" == git@* && -n "$master_alias" ]]; then
            git -C "$sub_path" remote set-url origin "$sub_url" 2>/dev/null || true
        fi

        configure_child_submodules_for_master "$sub_path" "${master_alias:-$(basename "$sub_path")}" || true

        # Ensure master and any nested child submodules have working files checked out.
        git -C "$sub_path" submodule update --init --recursive >/dev/null 2>&1 || true

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
