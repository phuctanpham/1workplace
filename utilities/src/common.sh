#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

# Colors
RED='\033[0;31m';    GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';  MAGENTA='\033[0;35m'
BOLD='\033[1m';      DIM='\033[2m';      NC='\033[0m'

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"

# Shared state (set by pickers)
SELECTED_ITEMS=()
SELECTED_ITEM=""

print_header() {
    local title="$1"
    local width=54
    local line
    printf -v line '%*s' "$width" ''
    line="${line// /─}"
    echo ""
    echo -e "${BOLD}${BLUE}┌${line}┐${NC}"
    printf "${BOLD}${BLUE}│  %-50s  │${NC}\n" "$title"
    echo -e "${BOLD}${BLUE}└${line}┘${NC}"
    echo ""
}

print_section() { echo -e "\n${BOLD}${CYAN}▸ $1${NC}"; }
print_success() { echo -e "${GREEN}  ✔ $1${NC}"; }
print_error()   { echo -e "${RED}  ✖ $1${NC}"; }
print_warn()    { echo -e "${YELLOW}  ⚠ $1${NC}"; }
print_info()    { echo -e "${DIM}  ℹ $1${NC}"; }
print_nav_hint() { echo -e "${DIM}  (b = back · q = quit${1})${NC}\n"; }

# Returns: 0=ok, 1=back, exits on q
check_nav() {
    case "${1,,}" in
        q)
            echo ""
            print_info "Quitting…"
            exit 0
            ;;
        b)
            return 1
            ;;
    esac
    return 0
}

pause() {
    echo ""
    read -rp "  Press Enter to continue…"
}

_ensure_ssh_dir() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
}

require_git_repo() {
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        echo ""
        print_error "This option requires running from inside a git repository."
        echo ""
        return 1
    fi
    return 0
}

list_private_keys() {
    local f base
    for f in "$SSH_DIR"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == *.pub ]] && continue
        [[ "$base" =~ ^(config|known_hosts|authorized_keys)$ ]] && continue
        head -1 "$f" 2>/dev/null | grep -q "PRIVATE KEY" || continue
        echo "$base"
    done
}

matching_public_key_file() {
    local key_name="$1"
    local key_path="${SSH_DIR}/${key_name}"
    local stem="${key_name%.*}"

    if [[ -f "${key_path}.pub" ]]; then
        echo "${key_name}.pub"
        return 0
    fi

    if [[ "$stem" != "$key_name" && -f "${SSH_DIR}/${stem}.pub" ]]; then
        echo "${stem}.pub"
        return 0
    fi

    return 1
}

_url_to_alias() { echo "$1" | sed -E 's/git@([^:]+):.*/\1/'; }

_repo_path_from_url() {
    echo "$1" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##'
}

_repo_name_from_url() {
    local repo_path
    repo_path=$(_repo_path_from_url "$1")
    basename "$repo_path"
}

_master_alias_from_url() {
    _repo_name_from_url "$1"
}

_child_alias_from_master_and_url() {
    local master_alias="$1" child_url="$2" child_name
    child_name=$(_repo_name_from_url "$child_url")
    echo "${master_alias}-${child_name}"
}

_url_with_alias() {
    local url="$1" alias="$2" repo_path
    repo_path=$(_repo_path_from_url "$url")
    echo "git@${alias}:${repo_path}.git"
}

_alias_to_hostname() {
    local alias="$1" hn
    hn=$(awk "/^Host[[:space:]]+${alias}$/{found=1} found && /HostName/{print \$2; exit}" "$SSH_CONFIG" 2>/dev/null)
    if [[ -n "$hn" ]]; then
        echo "$hn"
        return
    fi
    echo "$alias" | grep -qi gitlab && echo "gitlab.com" && return
    echo "github.com"
}

_host_exists() { grep -qE "^Host[[:space:]]+${1}$" "$SSH_CONFIG" 2>/dev/null; }

_host_hostname() {
    local alias="$1"
    awk -v h="$alias" '
        /^Host[[:space:]]+/ { in_host = ($2 == h) }
        in_host && /^  HostName[[:space:]]+/ { print $2; exit }
    ' "$SSH_CONFIG" 2>/dev/null
}

_host_identityfile() {
    local alias="$1"
    awk -v h="$alias" '
        /^Host[[:space:]]+/ { in_host = ($2 == h) }
        in_host && /^  IdentityFile[[:space:]]+/ { print $2; exit }
    ' "$SSH_CONFIG" 2>/dev/null
}

add_ssh_config_entry() {
    local alias="$1" hostname="$2" key_file="$3"
    if _host_exists "$alias"; then
        print_warn "Host alias '${alias}' already in SSH config — skipped."
        return
    fi
    printf '\nHost %s\n  HostName %s\n  User git\n  IdentityFile %s/%s\n  IdentitiesOnly yes\n' "$alias" "$hostname" "$SSH_DIR" "$key_file" >> "$SSH_CONFIG"
    print_success "SSH config: added Host ${alias} → ${hostname} (key: ${key_file})"
}

upsert_ssh_config_entry() {
    local alias="$1" hostname="$2" key_file="$3"
    local expected_identity existing_hostname existing_identity
    expected_identity="${SSH_DIR}/${key_file}"

    if _host_exists "$alias"; then
        existing_hostname=$(_host_hostname "$alias")
        existing_identity=$(_host_identityfile "$alias")
        if [[ "$existing_hostname" == "$hostname" && "$existing_identity" == "$expected_identity" ]]; then
            print_info "SSH config already matches for ${alias}"
            return 0
        fi
        remove_ssh_config_entry "$alias"
    fi

    add_ssh_config_entry "$alias" "$hostname" "$key_file"
}

remove_ssh_config_entry() {
    local alias="$1"
    _host_exists "$alias" || return
    awk -v h="$alias" '
        /^Host[[:space:]]/ { skip = ($2 == h) }
        !skip              { print }
    ' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"
    print_success "SSH config: removed Host ${alias}"
}

remove_ssh_config_entries_by_prefix() {
    local prefix="$1"
    local hosts=()
    mapfile -t hosts < <(awk '/^Host[[:space:]]+/ {print $2}' "$SSH_CONFIG" 2>/dev/null | grep -E "^${prefix}-" || true)
    local h
    for h in "${hosts[@]}"; do
        remove_ssh_config_entry "$h"
    done
}

multi_select() {
    local title="$1"
    shift
    local items=("$@")
    SELECTED_ITEMS=()

    if [[ ${#items[@]} -eq 0 ]]; then
        print_warn "No items available to select."
        return 2
    fi

    echo -e "${BOLD}${title}${NC}"
    print_nav_hint " · space-separated numbers · a = all"

    local i
    for i in "${!items[@]}"; do
        printf "  ${YELLOW}%2d)${NC} %s\n" "$((i + 1))" "${items[$i]}"
    done
    echo ""

    while true; do
        read -rp "  Choice: " raw
        check_nav "$raw" || return 1
        [[ "$raw" == "a" ]] && {
            SELECTED_ITEMS=("${items[@]}")
            return 0
        }

        local ok=true chosen=()
        local num
        for num in $raw; do
            if ! [[ "$num" =~ ^[0-9]+$ ]] || ((num < 1 || num > ${#items[@]})); then
                print_error "Invalid: '${num}'"
                ok=false
                break
            fi
            chosen+=("${items[$((num - 1))]}")
        done
        $ok && [[ ${#chosen[@]} -gt 0 ]] && {
            SELECTED_ITEMS=("${chosen[@]}")
            return 0
        }
        $ok && print_error "Select at least one item."
    done
}

single_select() {
    local title="$1" allow_empty="$2"
    shift 2
    local items=("$@")
    SELECTED_ITEM=""

    if [[ ${#items[@]} -eq 0 ]]; then
        print_warn "No items available."
        return 2
    fi

    local extra_hint=""
    [[ "$allow_empty" == "yes" ]] && extra_hint=" · Enter = none (public repo)"
    echo -e "${BOLD}${title}${NC}"
    print_nav_hint "$extra_hint"

    local i
    for i in "${!items[@]}"; do
        printf "  ${YELLOW}%2d)${NC} %s\n" "$((i + 1))" "${items[$i]}"
    done
    echo ""

    while true; do
        read -rp "  Choice: " raw
        check_nav "$raw" || return 1
        if [[ -z "$raw" && "$allow_empty" == "yes" ]]; then
            SELECTED_ITEM=""
            return 0
        fi
        if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw >= 1 && raw <= ${#items[@]})); then
            SELECTED_ITEM="${items[$((raw - 1))]}"
            return 0
        fi
        print_error "Invalid choice — try again."
    done
}

get_submodule_paths() {
    local dir="${1:-.}"
    [[ -f "$dir/.gitmodules" ]] || return 0
    git -C "$dir" config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk '{print $2}'
}

get_submodule_url() {
    local dir="$1" name="$2"
    git -C "$dir" config -f .gitmodules "submodule.${name}.url" 2>/dev/null
}

_remove_single_submodule() {
    local parent="$1" sub="$2"
    local full="${parent%/}/${sub}"
    local had_error=0

    echo ""
    echo -e "  ${BOLD}Removing:${NC} ${sub}"

    # Remove SSH config entries for the target submodule and legacy aliases.
    local url
    url=$(get_submodule_url "$parent" "$sub" 2>/dev/null || true)
    if [[ "$url" == git@* ]]; then
        local master_alias legacy_alias
        master_alias=$(_master_alias_from_url "$url")
        legacy_alias=$(_url_to_alias "$url")
        remove_ssh_config_entry "$master_alias"
        [[ "$legacy_alias" != "$master_alias" ]] && remove_ssh_config_entry "$legacy_alias"

        # If removing a master submodule, also remove all prefixed child aliases.
        if [[ "$parent" == "." ]]; then
            remove_ssh_config_entries_by_prefix "$master_alias"
        fi
    fi

    # If this submodule has nested children, remove their SSH blocks by exact alias too.
    if [[ -f "${full}/.gitmodules" ]]; then
        print_info "Removing SSH config entries for nested children…"
        local master_alias
        master_alias=$(basename "$sub")
        [[ "$url" == git@* ]] && master_alias=$(_master_alias_from_url "$url")
        local children
        mapfile -t children < <(get_submodule_paths "$full" 2>/dev/null || true)
        local child
        for child in "${children[@]}"; do
            local child_url
            child_url=$(get_submodule_url "$full" "$child" 2>/dev/null || true)
            if [[ "$child_url" == git@* ]]; then
                local child_alias
                child_alias=$(_child_alias_from_master_and_url "$master_alias" "$child_url")
                remove_ssh_config_entry "$child_alias"
            fi
        done
    fi

    if git -C "$parent" submodule deinit -f "$sub" >/dev/null 2>&1; then
        print_info "Deinitialized ${sub}"
    else
        print_warn "deinit had warnings for ${sub}"
    fi

    if [[ -d "$full/.git" || -f "$full/.git" ]]; then
        git -C "$full" remote remove origin >/dev/null 2>&1 || true
    fi

    # Remove tracked files, then also clear any remaining cached entry if needed.
    if git -C "$parent" rm -f "$sub" >/dev/null 2>&1; then
        print_info "git rm -f ${sub}"
    else
        print_warn "git rm -f failed for ${sub}"
        had_error=1
    fi

    if git -C "$parent" rm --cached "$sub" >/dev/null 2>&1; then
        print_info "git rm --cached ${sub}"
    else
        print_info "git rm --cached not needed for ${sub}"
    fi

    # Remove matching submodule section from .gitmodules by path.
    local gm_key gm_section
    gm_key=$(git -C "$parent" config -f .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk -v p="$sub" '$2 == p {print $1; exit}' || true)
    if [[ -n "$gm_key" ]]; then
        gm_section="${gm_key%.path}"
        git -C "$parent" config -f .gitmodules --remove-section "$gm_section" >/dev/null 2>&1 || true
        git -C "$parent" config --remove-section "$gm_section" >/dev/null 2>&1 || true
        print_info "Removed config section ${gm_section}"
    fi

    if [[ "$parent" == "." ]]; then
        rm -rf ".git/modules/${sub}" || had_error=1
    else
        rm -rf "${parent}/.git/modules/${sub}" || had_error=1
    fi
    rm -rf "$full" || had_error=1

    if ((had_error == 0)); then
        print_success "Removed ${sub}"
        return 0
    fi

    print_warn "Finished ${sub} with warnings."
    return 1
}
