#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

step_04_scan_child_submodules() {
    print_header "04 · Scan Child Submodules"

    mapfile -t top_subs < <(get_submodule_paths ".")
    if [[ ${#top_subs[@]} -eq 0 ]]; then
        print_warn "No submodules in current repo."
        pause
        return
    fi

    local nested_parents=()
    local s
    for s in "${top_subs[@]}"; do
        [[ -f "${s}/.gitmodules" ]] && nested_parents+=("$s")
    done

    if [[ ${#nested_parents[@]} -eq 0 ]]; then
        print_warn "None of your top-level submodules contain nested submodules."
        pause
        return
    fi

    multi_select "Select parent submodule(s) to scan:" "${nested_parents[@]}"
    local rc=$?
    ((rc == 1)) && return

    mapfile -t keys < <(list_private_keys)

    local parent
    for parent in "${SELECTED_ITEMS[@]}"; do
        print_section "Scanning: ${parent}"

        mapfile -t children < <(get_submodule_paths "$parent")
        if [[ ${#children[@]} -eq 0 ]]; then
            print_warn "No nested submodules found in ${parent}"
            continue
        fi

        echo ""
        local c
        for c in "${children[@]}"; do
            local curl
            curl=$(get_submodule_url "$parent" "$c")
            printf "  ${YELLOW}•${NC} %-30s  ${DIM}%s${NC}\n" "$c" "$curl"
        done
        echo ""

        for c in "${children[@]}"; do
            local curl
            curl=$(get_submodule_url "$parent" "$c")
            echo -e "  ${BOLD}Configure:${NC} ${c}  ${DIM}(${curl})${NC}"

            if [[ "$curl" == git@* ]]; then
                if [[ ${#keys[@]} -eq 0 ]]; then
                    print_warn "No SSH keys available — skipping."
                    continue
                fi
                single_select "SSH key for '${c}':" "yes" "${keys[@]}"
                local rc2=$?
                ((rc2 == 1)) && continue

                if [[ -n "$SELECTED_ITEM" ]]; then
                    local alias
                    alias=$(_url_to_alias "$curl")
                    local hostname
                    hostname=$(_alias_to_hostname "$alias")
                    add_ssh_config_entry "$alias" "$hostname" "$SELECTED_ITEM"
                fi
            else
                print_info "Public / HTTPS URL — no SSH key needed."
            fi
            echo ""
        done
    done

    print_section "Syncing submodule config"
    git submodule sync --recursive && print_success "git submodule sync --recursive done"
    echo ""
    print_info "Run option 07 to initialise / update the submodules."
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_04_scan_child_submodules
