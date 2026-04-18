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

    multi_select "Select submodule(s) to permanently remove:" "${top_subs[@]}"
    local rc=$?
    ((rc == 1)) && return

    local fail_count=0
    local s
    for s in "${SELECTED_ITEMS[@]}"; do
        echo ""
        echo -e "  ${BOLD}Target:${NC} ${s}"

        if [[ -f "${s}/.gitmodules" ]]; then
            mapfile -t children < <(get_submodule_paths "$s")
            if [[ ${#children[@]} -gt 0 ]]; then
                echo -e "${BOLD}This master contains child submodules. What do you want to remove?${NC}"
                echo "  1) Remove master submodule '${s}' (and all its children)"
                echo "  2) Remove only selected child submodule(s)"
                echo "  3) Skip"
                echo ""
                read -rp "  Choice: " mode
                check_nav "$mode" || return

                case "$mode" in
                    1)
                        read -rp "  Confirm remove master '${s}'? (y/N): " confirm_master
                        if [[ "${confirm_master,,}" == "y" ]]; then
                            _remove_single_submodule "." "$s" || fail_count=$((fail_count + 1))
                        else
                            print_info "Skipped master '${s}'."
                        fi
                        ;;
                    2)
                        multi_select "Select child submodule(s) to remove from ${s}:" "${children[@]}"
                        local rc_child=$?
                        ((rc_child == 1)) && continue

                        read -rp "  Confirm remove selected child submodule(s) from '${s}'? (y/N): " confirm_child
                        if [[ "${confirm_child,,}" == "y" ]]; then
                            local child
                            for child in "${SELECTED_ITEMS[@]}"; do
                                _remove_single_submodule "$s" "$child" || fail_count=$((fail_count + 1))
                            done
                        else
                            print_info "Skipped child removals for '${s}'."
                        fi
                        ;;
                    *)
                        print_info "Skipped '${s}'."
                        ;;
                esac
                continue
            fi
        fi

        read -rp "  Confirm remove '${s}'? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            _remove_single_submodule "." "$s" || fail_count=$((fail_count + 1))
        else
            print_info "Skipped '${s}'."
        fi
    done

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
