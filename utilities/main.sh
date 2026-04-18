#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# shellcheck source=src/common.sh
source "${SRC_DIR}/common.sh"

option_title() {
    case "$(basename "$1")" in
        01-list-validate-ssh-keys.sh) echo "01 · List & Validate SSH Keys" ;;
        02-add-new-ssh-key.sh) echo "02 · Add New SSH Key" ;;
        03-add-new-submodule.sh) echo "03 · Add New Submodule" ;;
        04-scan-child-submodules.sh) echo "04 · Scan Child Submodules" ;;
        05-remove-submodules.sh) echo "05 · Remove Submodule(s)" ;;
        06-clean-submodules.sh) echo "06 · Clean Submodule(s)  (hide from VSCode)" ;;
        07-update-restore-submodules.sh) echo "07 · Update / Restore Submodule(s)" ;;
        *) echo "$(basename "$1")" ;;
    esac
}

list_option_scripts() {
    local scripts=()
    local f
    for f in "${SRC_DIR}"/[0-9][0-9]-*.sh; do
        [[ -f "$f" ]] || continue
        scripts+=("$f")
    done
    printf '%s\n' "${scripts[@]}"
}

main_menu() {
    mapfile -t option_scripts < <(list_option_scripts)
    if [[ ${#option_scripts[@]} -eq 0 ]]; then
        print_error "No option scripts found in ${SRC_DIR}."
        exit 1
    fi

    while true; do
        print_header "SSH & Submodule Manager"

        local i
        for i in "${!option_scripts[@]}"; do
            local label
            label=$(option_title "${option_scripts[$i]}")
            printf "  ${YELLOW}%s)${NC} %s\n" "$((i + 1))" "$label"
        done
        printf "  ${YELLOW}%s)${NC} %s\n" "q" "Quit"

        echo ""
        read -rp "  Option: " opt

        case "${opt,,}" in
            q)
                print_info "Goodbye!"
                exit 0
                ;;
        esac

        if [[ "$opt" =~ ^[0-9]+$ ]] && ((opt >= 1 && opt <= ${#option_scripts[@]})); then
            echo ""
            sh "${option_scripts[$((opt - 1))]}"
            continue
        fi

        print_error "Unknown option '${opt}'."
    done
}

_ensure_ssh_dir

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo ""
    print_warn "Not inside a git repository."
    print_warn "Submodule options (03–07) require running this from a repo root."
    echo ""
fi

main_menu