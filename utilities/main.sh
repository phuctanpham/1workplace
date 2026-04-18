#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"

# shellcheck source=src/common.sh
. "${SRC_DIR}/common.sh"

option_title() {
    case "$(basename "$1")" in
        01-list-validate-ssh-keys.sh) echo "List & Validate SSH Keys" ;;
        02-add-new-ssh-key.sh) echo "Add New SSH Key" ;;
        03-add-new-submodule.sh) echo "Add New Submodule (incl. child scan)" ;;
        05-remove-submodules.sh) echo "Remove Submodule(s)" ;;
        06-clean-submodules.sh) echo "Clean Submodule(s)  (hide from VSCode)" ;;
        07-update-restore-submodules.sh) echo "Update / Restore Submodule(s)" ;;
        *) echo "$(basename "$1")" ;;
    esac
}

option_code() {
    local base
    base="$(basename "$1")"
    echo "${base%%-*}"
}

list_option_scripts() {
    found_any=0
    for f in "${SRC_DIR}"/[0-9][0-9]-*.sh; do
        [ -f "$f" ] || continue
        found_any=1
        echo "$f"
    done

    if [ "$found_any" -eq 0 ]; then
        return 1
    fi

    return 0
}

main_menu() {
    option_scripts="$(list_option_scripts || true)"
    if [ -z "$option_scripts" ]; then
        print_error "No option scripts found in ${SRC_DIR}."
        exit 1
    fi

    while true; do
        print_header "SSH & Submodule Manager"

        printf '%s\n' "$option_scripts" | while IFS= read -r script; do
            [ -n "$script" ] || continue
            code=$(option_code "$script")
            label=$(option_title "$script")
            printf "  ${YELLOW}%s)${NC} %s\n" "$code" "$label"
        done
        printf "  ${YELLOW}%s)${NC} %s\n" "q" "Quit"

        echo ""
        read -rp "  Option: " opt

        case "$opt" in
            q|Q)
                print_info "Goodbye!"
                exit 0
                ;;
        esac

        case "$opt" in
            ''|*[!0-9]*)
                print_error "Unknown option '${opt}'."
                continue
                ;;
        esac

        if [ "${#opt}" -eq 1 ]; then
            opt="0${opt}"
        fi

        script=$(printf '%s\n' "$option_scripts" | awk -v o="$opt" '
            {
                n = split($0, p, "/")
                b = p[n]
                split(b, parts, "-")
                if (parts[1] == o) {
                    print $0
                    exit
                }
            }
        ')
        if [ -n "$script" ]; then
            echo ""
            sh "$script"
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