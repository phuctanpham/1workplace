#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

step_06_clean_submodules() {
    print_header "06 · Clean Submodule(s)"
    echo -e "${DIM}  Deinitialises submodules so VSCode Source Control stops tracking them.${NC}"
    echo -e "${DIM}  .gitmodules entries are preserved. Use option 07 to restore.${NC}\n"

    mapfile -t top_subs < <(get_submodule_paths ".")
    if [[ ${#top_subs[@]} -eq 0 ]]; then
        print_warn "No submodules in .gitmodules."
        pause
        return
    fi

    multi_select "Select submodule(s) to clean (deinit):" "${top_subs[@]}"
    local rc=$?
    ((rc == 1)) && return

    local s
    for s in "${SELECTED_ITEMS[@]}"; do
        echo ""
        echo -e "  ${BOLD}Cleaning:${NC} ${s}"

        git submodule deinit -f "$s" 2>/dev/null \
            && print_success "Deinitialized ${s}" \
            || print_warn "deinit had warnings for ${s}"

        if [[ -d "$s" ]]; then
            find "$s" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} + 2>/dev/null || true
            print_info "Working tree cleared: ${s}"
        fi
    done

    echo ""
    print_info "Run option 07 to restore any cleaned submodule."
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_06_clean_submodules
