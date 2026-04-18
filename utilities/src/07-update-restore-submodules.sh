#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

_submodule_section_for_path() {
    local path="$1"
    git config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null \
        | awk -v p="$path" '$2 == p { print $1; exit }'
}

_submodule_url_for_path() {
    local path="$1" key section
    key=$(_submodule_section_for_path "$path" || true)
    [[ -n "$key" ]] || return 1
    section="${key%.path}"
    git config -f .gitmodules --get "${section}.url" 2>/dev/null
}

_submodule_section_for_path_at() {
    local dir="$1" path="$2"
    git -C "$dir" config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null \
        | awk -v p="$path" '$2 == p { print $1; exit }'
}

_submodule_url_for_path_at() {
    local dir="$1" path="$2" key section
    key=$(_submodule_section_for_path_at "$dir" "$path" || true)
    [[ -n "$key" ]] || return 1
    section="${key%.path}"
    git -C "$dir" config -f .gitmodules --get "${section}.url" 2>/dev/null
}

_has_gitlink_in_index_at() {
    local dir="$1" path="$2"
    git -C "$dir" ls-files --stage -- "$path" 2>/dev/null | awk '{print $1}' | grep -q '^160000$'
}

_has_gitlink_in_head_at() {
    local dir="$1" path="$2"
    git -C "$dir" ls-tree -d HEAD -- "$path" 2>/dev/null | awk '{print $1}' | grep -q '^160000$'
}

_has_gitlink_in_index() {
    local path="$1"
    _has_gitlink_in_index_at "." "$path"
}

_has_gitlink_in_head() {
    local path="$1"
    _has_gitlink_in_head_at "." "$path"
}

_ensure_child_gitlink_tracked() {
    local parent_dir="$1" child_path="$2"
    local url section_name

    if _has_gitlink_in_index_at "$parent_dir" "$child_path"; then
        return 0
    fi

    if _has_gitlink_in_head_at "$parent_dir" "$child_path"; then
        if git -C "$parent_dir" restore --source=HEAD --staged --worktree -- "$child_path" >/dev/null 2>&1; then
            print_info "  Restored nested gitlink from HEAD: ${child_path}"
            return 0
        fi
    fi

    url=$(_submodule_url_for_path_at "$parent_dir" "$child_path" || true)
    if [[ -z "$url" ]]; then
        print_warn "  Skipped ${child_path} (declared in .gitmodules but URL not found)."
        return 1
    fi

    section_name=$(_submodule_section_for_path_at "$parent_dir" "$child_path" || true)
    section_name="${section_name#submodule.}"
    section_name="${section_name%.path}"
    [[ -n "$section_name" ]] || section_name="$child_path"

    if [[ -d "${parent_dir}/${child_path}" && -z "$(ls -A "${parent_dir}/${child_path}" 2>/dev/null)" ]]; then
        rmdir "${parent_dir}/${child_path}" 2>/dev/null || true
    fi

    if git -C "$parent_dir" submodule add -f --name "$section_name" "$url" "$child_path" >/dev/null 2>&1; then
        print_info "  Re-attached nested gitlink: ${child_path}"
        return 0
    fi

    print_warn "  Skipped ${child_path} (declared in .gitmodules but could not attach)."
    return 1
}

_ensure_gitlink_tracked() {
    local path="$1" url section_name

    if _has_gitlink_in_index "$path"; then
        return 0
    fi

    if _has_gitlink_in_head "$path"; then
        if git restore --source=HEAD --staged --worktree -- "$path" >/dev/null 2>&1; then
            print_info "Restored gitlink from HEAD: ${path}"
            return 0
        fi
    fi

    url=$(_submodule_url_for_path "$path" || true)
    if [[ -z "$url" ]]; then
        print_error "Cannot restore ${path}: no URL in .gitmodules."
        return 1
    fi

    section_name=$(_submodule_section_for_path "$path" || true)
    section_name="${section_name#submodule.}"
    section_name="${section_name%.path}"
    [[ -n "$section_name" ]] || section_name="$path"

    # Keep add deterministic when an empty placeholder directory exists.
    if [[ -d "$path" && -z "$(ls -A "$path" 2>/dev/null)" ]]; then
        rmdir "$path" 2>/dev/null || true
    fi

    if git submodule add -f --name "$section_name" "$url" "$path" >/dev/null 2>&1; then
        print_info "Re-attached gitlink: ${path}"
        return 0
    fi

    print_error "Failed to re-attach gitlink for ${path}."
    return 1
}

_is_submodule_deinitialized_in_parent() {
    local parent="$1" sub="$2"
    local line

    line=$(git -C "$parent" submodule status -- "$sub" 2>/dev/null | head -n 1 || true)
    if [[ -n "$line" ]]; then
        [[ "${line:0:1}" == "-" ]] && return 0
        return 1
    fi

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

_ssh_child_identifiers_for_master() {
    local master_alias="$1"
    [[ -f "$SSH_CONFIG" ]] || return 0

    awk -v p="${master_alias}-" '
        /^Host[[:space:]]+/ {
            alias = $2
            if (index(alias, p) == 1) {
                child = substr(alias, length(p) + 1)
                if (child != "") {
                    print child
                }
            }
        }
    ' "$SSH_CONFIG" 2>/dev/null | sort -u
}

_child_paths_for_identifiers_in_parent() {
    local parent_dir="$1"
    shift
    local wanted=("$@")

    mapfile -t parent_children < <(get_submodule_paths "$parent_dir")
    [[ ${#parent_children[@]} -gt 0 ]] || return 0

    local id child child_url child_repo_name child_base
    for id in "${wanted[@]}"; do
        for child in "${parent_children[@]}"; do
            child_url=$(_submodule_url_for_path_at "$parent_dir" "$child" || true)
            child_repo_name=""
            if [[ -n "$child_url" ]]; then
                child_repo_name=$(_repo_name_from_url "$child_url")
            fi
            child_base=$(basename "$child")

            if [[ "$id" == "$child" || "$id" == "$child_base" || ( -n "$child_repo_name" && "$id" == "$child_repo_name" ) ]]; then
                echo "$child"
                break
            fi
        done
    done
}

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

        local master_was_deinited=false
        local restore_mode=""
        local preselected_child_ids=()
        if _is_submodule_deinitialized_in_parent "." "$s"; then
            master_was_deinited=true

            local master_url master_alias
            master_url=$(_submodule_url_for_path "$s" || true)
            master_alias=""
            if [[ "$master_url" == git@* ]]; then
                master_alias=$(_master_alias_from_url "$master_url")
            fi

            local ssh_children=()
            if [[ -n "$master_alias" ]]; then
                mapfile -t ssh_children < <(_ssh_child_identifiers_for_master "$master_alias")
            fi

            if [[ ${#ssh_children[@]} -gt 0 ]]; then
                print_info "Found child submodule candidates from .ssh/config."
                echo -e "${BOLD}Restore mode for ${s}:${NC}"
                echo "  1) Restore only master submodule"
                echo "  2) Restore master submodule and selected child submodule(s)"
                echo "  3) Restore master submodule and all child submodule(s)"
                echo ""
                read -rp "  Choice: " restore_mode
                check_nav "$restore_mode" || return

                case "$restore_mode" in
                    2)
                        multi_select "Select child submodule(s) to restore in ${s} (from .ssh/config):" "${ssh_children[@]}"
                        local rc_child=$?
                        ((rc_child == 1)) && continue
                        preselected_child_ids=("${SELECTED_ITEMS[@]}")
                        ;;
                    3)
                        preselected_child_ids=("${ssh_children[@]}")
                        ;;
                    *)
                        preselected_child_ids=()
                        ;;
                esac
            fi
        fi

        if ! _ensure_gitlink_tracked "$s"; then
            continue
        fi

        git submodule sync -- "$s" 2>/dev/null || true
        if git submodule update --init -- "$s"; then
            print_success "Updated ${s}"
        else
            print_error "Failed to update ${s} — check SSH config / key."
            continue
        fi

        if [[ -f "${s}/.gitmodules" ]]; then
            mapfile -t children < <(get_submodule_paths "$s")
            if [[ ${#children[@]} -gt 0 ]]; then
                local targets=()

                if $master_was_deinited; then
                    if [[ -n "$restore_mode" ]]; then
                        case "$restore_mode" in
                            2)
                                mapfile -t targets < <(_child_paths_for_identifiers_in_parent "$s" "${preselected_child_ids[@]}")
                                ;;
                            3)
                                targets=("${children[@]}")
                                ;;
                            *)
                                targets=()
                                ;;
                        esac

                        if [[ "$restore_mode" == "2" && ${#preselected_child_ids[@]} -gt 0 && ${#targets[@]} -eq 0 ]]; then
                            print_warn "No selected child aliases matched ${s}/.gitmodules paths."
                        fi
                    else
                        print_info "Found nested submodules."
                        echo -e "${BOLD}Restore mode for ${s}:${NC}"
                        echo "  1) Restore only master submodule"
                        echo "  2) Restore master submodule and selected child submodule(s)"
                        echo "  3) Restore master submodule and all child submodule(s)"
                        echo ""
                        read -rp "  Choice: " mode
                        check_nav "$mode" || return

                        case "$mode" in
                            2)
                                multi_select "Select child submodule(s) to restore in ${s}:" "${children[@]}"
                                local rc_child=$?
                                ((rc_child == 1)) && continue
                                targets=("${SELECTED_ITEMS[@]}")
                                ;;
                            3)
                                targets=("${children[@]}")
                                ;;
                            *)
                                targets=()
                                ;;
                        esac
                    fi
                else
                    local deinited_children=()
                    local child
                    for child in "${children[@]}"; do
                        if _is_submodule_deinitialized_in_parent "$s" "$child"; then
                            deinited_children+=("$child")
                        fi
                    done

                    if [[ ${#deinited_children[@]} -eq 0 ]]; then
                        print_info "nothing to restore"
                        continue
                    fi

                    print_info "Found deinited child submodule(s)."
                    multi_select "Select deinited child submodule(s) to restore in ${s}:" "${deinited_children[@]}"
                    local rc_child=$?
                    ((rc_child == 1)) && continue
                    targets=("${SELECTED_ITEMS[@]}")
                fi

                for child in "${targets[@]}"; do
                    printf "    ${DIM}↳ updating %s${NC}\n" "$child"
                    if ! _ensure_child_gitlink_tracked "$s" "$child"; then
                        continue
                    fi
                    git -C "$s" submodule sync "$child" 2>/dev/null || true
                    if git -C "$s" submodule update --init --recursive "$child"; then
                        print_success "  Updated ${child}"
                    else
                        print_error "  Failed:  ${child}"
                    fi
                done
            fi
        elif ! $master_was_deinited; then
            print_info "nothing to restore"
        fi
    done

    echo ""
    print_success "All done."
    pause
}

_ensure_ssh_dir
require_git_repo || exit 1
step_07_update_submodules
