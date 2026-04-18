#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

step_07_update_submodules() {
    print_header "07 · Update / Restore Submodule(s)"

    mapfile -t top_subs < <(get_submodule_paths ".")
    if [[ ${#top_subs[@]} -eq 0 ]]; then
        print_warn "No submodules in .gitmodules."
        pause
        return
    fi

    multi_select "Select submodule(s) to update / restore:" "${top_subs[@]}"
    local rc=$?
    ((rc == 1)) && return

    local s
    for s in "${SELECTED_ITEMS[@]}"; do
        echo ""
        echo -e "  ${BOLD}Updating:${NC} ${s}"

        git submodule sync "$s" 2>/dev/null
        if git submodule update --init "$s"; then
            print_success "Updated ${s}"
        else
            print_error "Failed to update ${s} — check SSH config / key."
            continue
        fi

        if [[ -f "${s}/.gitmodules" ]]; then
            print_info "Found nested submodules — updating…"
            local child
            while IFS= read -r child; do
                printf "    ${DIM}↳ updating %s${NC}\n" "$child"
                git -C "$s" submodule sync "$child" 2>/dev/null || true
                if git -C "$s" submodule update --init "$child"; then
                    print_success "  Updated ${child}"
                else
                    print_error "  Failed:  ${child}"
                fi
            done < <(get_submodule_paths "$s")
        fi
    done

    echo ""
    print_success "All done."
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_07_update_submodules
