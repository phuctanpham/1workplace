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

    single_select "Select master submodule to clean (deinit):" "no" "${top_subs[@]}"
    local rc=$?
    ((rc == 1)) && return
    ((rc == 2)) && return

    local master="$SELECTED_ITEM"

    if [[ -f "${master}/.gitmodules" ]]; then
        mapfile -t children < <(get_submodule_paths "$master")
        if [[ ${#children[@]} -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Master target:${NC} ${master}"

            multi_select "Select child submodule(s) to clean in ${master}:" "${children[@]}"
            local rc_child=$?
            ((rc_child == 1)) && return

            local selected_all_children=false
            if [[ ${#SELECTED_ITEMS[@]} -eq ${#children[@]} ]]; then
                selected_all_children=true
            fi

            if $selected_all_children; then
                read -rp "  All children selected. Also clean master '${master}'? (y/N): " clean_master
                if [[ "${clean_master,,}" == "y" ]]; then
                    _clean_submodule_in_parent "." "$master"
                else
                    local child
                    for child in "${SELECTED_ITEMS[@]}"; do
                        _clean_submodule_in_parent "$master" "$child"
                    done
                fi
            else
                # User selected only some children; do not ask about master.
                local child
                for child in "${SELECTED_ITEMS[@]}"; do
                    _clean_submodule_in_parent "$master" "$child"
                done
            fi
        else
            _clean_submodule_in_parent "." "$master"
        fi
    else
        _clean_submodule_in_parent "." "$master"
    fi

    echo ""
    print_info "Run option 07 to restore any cleaned submodule."
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_06_clean_submodules
