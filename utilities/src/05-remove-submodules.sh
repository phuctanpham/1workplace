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

    echo ""
    print_warn "These will be PERMANENTLY removed (git history, disk, SSH config):"
    local s
    for s in "${SELECTED_ITEMS[@]}"; do
        printf "  ${RED}•${NC} %s" "$s"
        [[ -f "${s}/.gitmodules" ]] && printf "  ${DIM}(has nested — child submodules are not removed individually)${NC}"
        echo ""
    done
    echo ""
    read -rp "  Confirm? (y/N): " confirm
    [[ "${confirm,,}" != "y" ]] && {
        print_info "Aborted."
        return
    }

    local fail_count=0
    for s in "${SELECTED_ITEMS[@]}"; do
        _remove_single_submodule "." "$s" || fail_count=$((fail_count + 1))
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
