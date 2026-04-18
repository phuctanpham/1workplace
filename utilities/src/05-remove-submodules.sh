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

_master_alias_for_path() {
    local master_path="$1"
    local master_url
    master_url=$(get_submodule_url "." "$master_path" 2>/dev/null || true)
    if [[ "$master_url" == git@* ]]; then
        _master_alias_from_url "$master_url"
    else
        basename "$master_path"
    fi
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

_remove_selected_child_aliases() {
    local master_alias="$1"
    shift
    local child
    for child in "$@"; do
        remove_ssh_config_entry "${master_alias}-${child}"
    done
}

_remove_child_submodule_lightweight() {
    local master_path="$1" master_alias="$2" child_id="$3"
    local child_path="$child_id"
    local child_repo="${master_path%/}/${child_path}"
    local child_alias="${master_alias}-${child_id}"

    echo ""
    echo -e "  ${BOLD}Child target:${NC} ${master_path}/${child_path}"

    if git -C "$child_repo" rev-parse --git-dir >/dev/null 2>&1; then
        local origin_url
        origin_url=$(git -C "$child_repo" remote get-url origin 2>/dev/null || true)
        if [[ -n "$origin_url" ]]; then
            if git -C "$child_repo" remote remove origin >/dev/null 2>&1; then
                print_info "Removed child origin remote: ${origin_url}"
            else
                print_warn "Could not remove child origin remote for ${child_path}"
            fi
        else
            print_info "No child origin remote to remove for ${child_path}"
        fi
    else
        print_info "Child repo not initialized: ${child_repo}"
    fi

    if git -C "$master_path" rev-parse --git-dir >/dev/null 2>&1; then
        local gitlinks=()
        mapfile -t gitlinks < <(git -C "$master_path" ls-files --stage 2>/dev/null | awk '$1 == "160000" {print $4}')

        if [[ ${#gitlinks[@]} -gt 0 ]]; then
            local p
            for p in "${gitlinks[@]}"; do
                if [[ "$p" == "$child_id" || "$(basename "$p")" == "$child_id" ]]; then
                    child_path="$p"
                    child_repo="${master_path%/}/${child_path}"
                    break
                fi
            done
        fi

        if git -C "$master_path" rm --cached -- "$child_path" >/dev/null 2>&1; then
            print_info "Removed child from index: ${child_path}"
        else
            print_warn "Could not remove child from index: ${child_path}"
        fi
    else
        print_warn "Master repo not initialized; cannot run git rm --cached for child ${child_path}"
    fi

    remove_ssh_config_entry "$child_alias"
}

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
    local master_alias
    master_alias=$(_master_alias_for_path "$master")

    local master_is_removed=false
    if _is_submodule_deinitialized_in_parent "." "$master"; then
        master_is_removed=true
    fi

    local child_ids=()
    mapfile -t child_ids < <(_ssh_child_identifiers_for_master "$master_alias")

    echo ""
    echo -e "  ${BOLD}Master target:${NC} ${master}"
    print_info "Child submodule source: .ssh/config (prefix: ${master_alias}-)"

    if ! $master_is_removed; then
        if [[ ${#child_ids[@]} -gt 0 ]]; then
            echo -e "${BOLD}Remove mode for ${master}:${NC}"
            echo "  1) Keep master submodule and remove selected child submodule(s)"
            echo "  2) Remove both master submodule and all child submodule(s)"
            echo ""

            while true; do
                read -rp "  Choice: " mode
                check_nav "$mode" || return

                case "$mode" in
                    1)
                        multi_select "Select child submodule(s) to remove from ${master}:" "${child_ids[@]}"
                        local rc_child=$?
                        ((rc_child == 1)) && return
                        local child
                        for child in "${SELECTED_ITEMS[@]}"; do
                            _remove_child_submodule_lightweight "$master" "$master_alias" "$child"
                        done
                        break
                        ;;
                    2)
                        local child
                        for child in "${child_ids[@]}"; do
                            _remove_child_submodule_lightweight "$master" "$master_alias" "$child"
                        done
                        _remove_single_submodule "." "$master" || fail_count=$((fail_count + 1))
                        break
                        ;;
                    *)
                        print_error "Invalid choice — try again."
                        ;;
                esac
            done
        else
            _remove_single_submodule "." "$master" || fail_count=$((fail_count + 1))
        fi
    else
        if [[ ${#child_ids[@]} -gt 0 ]]; then
            print_info "Master is already removed/deinited."
            multi_select "Select deinited child submodule(s) to remove from ${master}:" "${child_ids[@]}"
            local rc_child=$?
            ((rc_child == 1)) && return

            local child
            for child in "${SELECTED_ITEMS[@]}"; do
                _remove_child_submodule_lightweight "$master" "$master_alias" "$child"
            done
        fi

        _remove_single_submodule "." "$master" || fail_count=$((fail_count + 1))
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
