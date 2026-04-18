#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

_clean_submodule_in_parent() {
    local parent="$1" sub="$2"
    local full
    if [[ "$parent" == "." ]]; then
        full="$sub"
    else
        full="${parent%/}/${sub}"
    fi

    echo ""
    echo -e "  ${BOLD}Cleaning:${NC} ${parent}/${sub}"

    git -C "$parent" submodule deinit -f -- "$sub" 2>/dev/null \
        && print_success "Deinitialized ${sub}" \
        || print_warn "deinit had warnings for ${sub}"

    git -C "$parent" restore --staged -- "$sub" 2>/dev/null || true
    git -C "$parent" rm --cached -- "$sub" 2>/dev/null || true

    local gm_key gm_section
    gm_key=$(git -C "$parent" config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk -v p="$sub" '$2 == p {print $1; exit}' || true)
    if [[ -n "$gm_key" ]]; then
        gm_section="${gm_key%.path}"
        git -C "$parent" config --remove-section "$gm_section" 2>/dev/null || true
    fi

    rm -rf "$full" 2>/dev/null || true
    if [[ "$parent" == "." ]]; then
        rm -rf ".git/modules/${sub}" 2>/dev/null || true
    else
        rm -rf "${parent}/.git/modules/${sub}" 2>/dev/null || true
    fi

    mkdir -p "$full" 2>/dev/null || true
    print_info "Working tree reset: ${full}"
}

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
        if [[ -f "${s}/.gitmodules" ]]; then
            mapfile -t children < <(get_submodule_paths "$s")
            if [[ ${#children[@]} -gt 0 ]]; then
                echo ""
                echo -e "  ${BOLD}Target:${NC} ${s}"
                echo -e "${BOLD}This master contains child submodules. What do you want to clean?${NC}"
                echo "  1) Clean master '${s}' only"
                echo "  2) Clean only selected child submodule(s)"
                echo "  3) Skip"
                echo ""
                read -rp "  Choice: " mode
                check_nav "$mode" || return

                case "$mode" in
                    1)
                        _clean_submodule_in_parent "." "$s"
                        ;;
                    2)
                        multi_select "Select child submodule(s) to clean in ${s}:" "${children[@]}"
                        local rc_child=$?
                        ((rc_child == 1)) && continue

                        local child
                        for child in "${SELECTED_ITEMS[@]}"; do
                            _clean_submodule_in_parent "$s" "$child"
                        done
                        ;;
                    *)
                        print_info "Skipped '${s}'."
                        ;;
                esac
                continue
            fi
        fi

        _clean_submodule_in_parent "." "$s"
    done

    echo ""
    print_info "Run option 07 to restore any cleaned submodule."
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_06_clean_submodules
