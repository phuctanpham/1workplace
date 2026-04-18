#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

step_05_remove_submodule() {
    print_header "05 · Remove Submodule(s)"

    mapfile -t top_subs < <(get_submodule_paths ".")
    if [[ ${#top_subs[@]} -eq 0 ]]; then
        print_warn "No submodules in .gitmodules."
        pause
        return
    fi

    single_select "Select master submodule to remove:" "no" "${top_subs[@]}"
    local rc=$?
    ((rc == 1)) && return
    ((rc == 2)) && return

    local master="$SELECTED_ITEM"
    local fail_count=0

    echo ""
    echo -e "  ${BOLD}Master target:${NC} ${master}"

    if [[ -f "${master}/.gitmodules" ]]; then
        mapfile -t children < <(get_submodule_paths "$master")
        if [[ ${#children[@]} -gt 0 ]]; then
            multi_select "Select child submodule(s) to remove from ${master}:" "${children[@]}"
            local rc_child=$?
            ((rc_child == 1)) && return

            local selected_all_children=false
            if [[ ${#SELECTED_ITEMS[@]} -eq ${#children[@]} ]]; then
                selected_all_children=true
            fi

            if $selected_all_children; then
                read -rp "  All children selected. Also remove master '${master}'? (y/N): " rm_master
                if [[ "${rm_master,,}" == "y" ]]; then
                    _remove_single_submodule "." "$master" || fail_count=$((fail_count + 1))
                else
                    local child
                    for child in "${SELECTED_ITEMS[@]}"; do
                        _remove_single_submodule "$master" "$child" || fail_count=$((fail_count + 1))
                    done
                fi
            else
                # User selected only some children; do not ask about master.
                local child
                for child in "${SELECTED_ITEMS[@]}"; do
                    _remove_single_submodule "$master" "$child" || fail_count=$((fail_count + 1))
                done
            fi
        else
            read -rp "  Confirm remove master '${master}'? (y/N): " confirm
            if [[ "${confirm,,}" == "y" ]]; then
                _remove_single_submodule "." "$master" || fail_count=$((fail_count + 1))
            else
                print_info "Skipped '${master}'."
            fi
        fi
    else
        read -rp "  Confirm remove master '${master}'? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            _remove_single_submodule "." "$master" || fail_count=$((fail_count + 1))
        else
            print_info "Skipped '${master}'."
        fi
    fi

    echo ""
    if ((fail_count > 0)); then
        print_warn "Completed with ${fail_count} submodule(s) having warnings."
    else
        print_success "Completed removal for selected submodule(s)."
    fi

    print_info "Commit: git add .gitmodules && git commit -m 'chore: remove submodule(s)'"
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_05_remove_submodule
