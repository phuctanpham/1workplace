#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

_is_submodule_deinitialized_in_parent() {
    local parent="$1" sub="$2"
    local line

    line=$(git -C "$parent" submodule status -- "$sub" 2>/dev/null | head -n 1 || true)
    if [[ -n "$line" ]]; then
        [[ "${line:0:1}" == "-" ]] && return 0
        return 1
    fi

    # Fallback when gitlink is not present in index: treat missing repo metadata as deinited.
    local full
    if [[ "$parent" == "." ]]; then
        full="$sub"
    else
        full="${parent%/}/${sub}"
    fi

    if [[ -d "$full/.git" || -f "$full/.git" ]]; then
        return 1
    fi
    return 0
}

_child_deinit_counts_for_master() {
    local master="$1"
    local total=0 deinited=0
    local children=()

    mapfile -t children < <(get_submodule_paths "$master" 2>/dev/null || true)
    total=${#children[@]}

    if ((total > 0)); then
        local child
        for child in "${children[@]}"; do
            if _is_submodule_deinitialized_in_parent "$master" "$child"; then
                deinited=$((deinited + 1))
            fi
        done
    fi

    echo "$deinited $total"
}

_select_master_submodule_with_status() {
    local items=("$@")
    SELECTED_ITEM=""

    if [[ ${#items[@]} -eq 0 ]]; then
        print_warn "No items available."
        return 2
    fi

    echo -e "${BOLD}Select master submodule to clean (deinit):${NC}"
    print_nav_hint ""

    local i
    for i in "${!items[@]}"; do
        local master status_color status_text
        master="${items[$i]}"

        if _is_submodule_deinitialized_in_parent "." "$master"; then
            status_color="$RED"
            status_text="deinited"
        else
            status_color="$GREEN"
            status_text="active"
        fi

        local child_info child_deinited child_total child_suffix=""
        child_info=$(_child_deinit_counts_for_master "$master")
        child_deinited="${child_info%% *}"
        child_total="${child_info##* }"
        if ((child_total > 0)); then
            child_suffix="  ${DIM}(child deinited: ${child_deinited}/${child_total})${NC}"
        fi

        printf "  ${YELLOW}%2d)${NC} %s  ${status_color}[%s]${NC}%b\n" "$((i + 1))" "$master" "$status_text" "$child_suffix"
    done
    echo ""

    while true; do
        local raw
        read -rp "  Choice: " raw
        check_nav "$raw" || return 1

        if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw >= 1 && raw <= ${#items[@]})); then
            SELECTED_ITEM="${items[$((raw - 1))]}"
            return 0
        fi

        print_error "Invalid choice — try again."
    done
}

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

    _select_master_submodule_with_status "${top_subs[@]}"
    local rc=$?
    ((rc == 1)) && return
    ((rc == 2)) && return

    local master="$SELECTED_ITEM"

    local master_is_deinited=false
    if _is_submodule_deinitialized_in_parent "." "$master"; then
        master_is_deinited=true
    fi

    local children=()
    if [[ -f "${master}/.gitmodules" ]]; then
        mapfile -t children < <(get_submodule_paths "$master")
    fi

    local not_deinited_children=()
    local child
    for child in "${children[@]}"; do
        if ! _is_submodule_deinitialized_in_parent "$master" "$child"; then
            not_deinited_children+=("$child")
        fi
    done

    echo ""
    echo -e "  ${BOLD}Master target:${NC} ${master}"

    if ! $master_is_deinited; then
        if [[ ${#not_deinited_children[@]} -gt 0 ]]; then
            echo -e "${BOLD}Clean mode for ${master}:${NC}"
            echo "  1) Clean only master submodule"
            echo "  2) Clean master submodule and selected child submodule(s)"
            echo "  3) Clean master submodule and all child submodule(s)"
            echo ""

            while true; do
                read -rp "  Choice: " mode
                check_nav "$mode" || return

                case "$mode" in
                    1)
                        _clean_submodule_in_parent "." "$master"
                        break
                        ;;
                    2)
                        multi_select "Select child submodule(s) to clean in ${master}:" "${not_deinited_children[@]}"
                        local rc_child=$?
                        ((rc_child == 1)) && return

                        _clean_submodule_in_parent "." "$master"
                        for child in "${SELECTED_ITEMS[@]}"; do
                            _clean_submodule_in_parent "$master" "$child"
                        done
                        break
                        ;;
                    3)
                        _clean_submodule_in_parent "." "$master"
                        for child in "${not_deinited_children[@]}"; do
                            _clean_submodule_in_parent "$master" "$child"
                        done
                        break
                        ;;
                    *)
                        print_error "Invalid choice — try again."
                        ;;
                esac
            done
        else
            _clean_submodule_in_parent "." "$master"
        fi
    else
        if [[ ${#not_deinited_children[@]} -gt 0 ]]; then
            print_info "Master is already deinited. Select active child submodule(s) to clean:"
            multi_select "Select child submodule(s) to clean in ${master}:" "${not_deinited_children[@]}"
            local rc_child=$?
            ((rc_child == 1)) && return

            for child in "${SELECTED_ITEMS[@]}"; do
                _clean_submodule_in_parent "$master" "$child"
            done
        else
            print_info "nothing to clean"
        fi
    fi

    echo ""
    print_info "Run option 07 to restore any cleaned submodule."
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_06_clean_submodules
