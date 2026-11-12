# Shared installer for the task dispatcher command and agents.
#
# Sourced by the per-tool scripts in bin/ (e.g. bin/junie, bin/claude), which
# must define the following before calling `main "$@"`:
#
#   TOOL_NAME        Human-readable tool name, e.g. "Junie".
#   HOME_ENV_VAR     Name of the environment variable overriding the home directory.
#   DEFAULT_HOME     Default home directory, e.g. "$HOME/.junie".
#   PLACEHOLDERS     Alternating name/value pairs. A value may span multiple lines
#                    and may be empty; a placeholder that is alone on its line and
#                    renders empty removes the whole line.
#
# Repository files are vendor-neutral templates. Install-time placeholders use
# the {{name}} syntax; single-brace {name} fields are left untouched because they
# are template fields meant for the agent itself (e.g. {time} in log entries).

set -euo pipefail

# This file lives in bin/lib/, so the repository root is two levels up.
REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Repository directories that are mirrored into the tool's home directory.
MANAGED_DIRS=(commands agents)

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; RESET=""
fi

init_home_dir() {
    TARGET_HOME_DIR="${!HOME_ENV_VAR:-$DEFAULT_HOME}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  install     Install or update the task dispatcher command and agents into
              ${TARGET_HOME_DIR}
  uninstall   Remove the installed command and agents from ${TARGET_HOME_DIR}
  doctor      Verify the installed files are in place and match the repository
  help        Show this help

Set ${HOME_ENV_VAR} to use a ${TOOL_NAME} home directory other than ${DEFAULT_HOME/#$HOME/~}.
EOF
}

# Prints the repository-relative path (e.g. "agents/foo.md") of every managed file.
list_managed_files() {
    local dir file
    for dir in "${MANAGED_DIRS[@]}"; do
        [[ -d "$REPO_ROOT/$dir" ]] || continue
        for file in "$REPO_ROOT/$dir"/*.md; do
            [[ -f "$file" ]] || continue
            printf '%s/%s\n' "$dir" "$(basename "$file")"
        done
    done
}

# Prints the repository file (relative path) with every {{placeholder}} replaced
# by its tool-specific value. Fails if any {{placeholder}} is left over.
render() {
    local rel="$1" content key value i leftover
    # Append and strip a sentinel so trailing newlines survive command substitution.
    content="$(cat "$REPO_ROOT/$rel"; printf x)"
    content="${content%x}"
    for ((i = 0; i < ${#PLACEHOLDERS[@]}; i += 2)); do
        key="{{${PLACEHOLDERS[i]}}}"
        value="${PLACEHOLDERS[i + 1]}"
        if [[ -z "$value" ]]; then
            # Drop lines holding only an empty placeholder (e.g. in front matter).
            content="${content//$'\n'"$key"$'\n'/$'\n'}"
        fi
        content="${content//"$key"/$value}"
    done
    leftover="$(printf '%s' "$content" | grep -oE '\{\{[^{}[:space:]]+\}\}' | sort -u | tr '\n' ' ' || true)"
    if [[ -n "$leftover" ]]; then
        echo "${RED}error:${RESET} unknown placeholder(s) in $rel: $leftover" >&2
        return 1
    fi
    printf '%s' "$content"
}

managed_files() {
    local files
    files="$(list_managed_files)"
    if [[ -z "$files" ]]; then
        echo "${RED}error:${RESET} no files found in ${MANAGED_DIRS[*]} under $REPO_ROOT" >&2
        exit 1
    fi
    printf '%s\n' "$files"
}

cmd_install() {
    local rel dest rendered installed=0 updated=0 unchanged=0
    rendered="$(mktemp)"
    while IFS= read -r rel; do
        dest="$TARGET_HOME_DIR/$rel"
        if ! render "$rel" > "$rendered"; then
            rm -f "$rendered"
            exit 1
        fi
        mkdir -p "$(dirname "$dest")"
        if [[ ! -e "$dest" ]]; then
            cp "$rendered" "$dest"
            echo "${GREEN}installed${RESET}  $dest"
            installed=$((installed + 1))
        elif cmp -s "$rendered" "$dest"; then
            echo "unchanged  $dest"
            unchanged=$((unchanged + 1))
        else
            cp "$rendered" "$dest"
            echo "${YELLOW}updated${RESET}    $dest"
            updated=$((updated + 1))
        fi
    done < <(managed_files)
    rm -f "$rendered"
    echo
    echo "Done: $installed installed, $updated updated, $unchanged unchanged."
}

cmd_uninstall() {
    local rel dest dir removed=0 missing=0
    while IFS= read -r rel; do
        dest="$TARGET_HOME_DIR/$rel"
        if [[ -e "$dest" || -L "$dest" ]]; then
            rm -f "$dest"
            echo "${GREEN}removed${RESET}    $dest"
            removed=$((removed + 1))
        else
            echo "not found  $dest"
            missing=$((missing + 1))
        fi
    done < <(managed_files)

    # Clean up directories we may have created, but only if they are empty.
    for dir in "${MANAGED_DIRS[@]}"; do
        rmdir "$TARGET_HOME_DIR/$dir" 2>/dev/null || true
    done
    echo
    echo "Done: $removed removed, $missing not found."
}

cmd_doctor() {
    local rel dest rendered ok=0 problems=0
    rendered="$(mktemp)"
    echo "${TOOL_NAME} home: $TARGET_HOME_DIR"
    echo "Repository: $REPO_ROOT"
    echo
    while IFS= read -r rel; do
        dest="$TARGET_HOME_DIR/$rel"
        if ! render "$rel" > "$rendered"; then
            echo "${RED}invalid${RESET}    $REPO_ROOT/$rel"
            problems=$((problems + 1))
        elif [[ ! -e "$dest" ]]; then
            echo "${RED}missing${RESET}    $dest"
            problems=$((problems + 1))
        elif ! cmp -s "$rendered" "$dest"; then
            echo "${RED}differs${RESET}    $dest"
            problems=$((problems + 1))
        else
            echo "${GREEN}ok${RESET}         $dest"
            ok=$((ok + 1))
        fi
    done < <(managed_files)
    rm -f "$rendered"
    echo
    if [[ $problems -gt 0 ]]; then
        echo "${RED}Problems found${RESET}: $ok ok, $problems with issues. Run '$(basename "$0") install' to fix."
        return 1
    fi
    echo "${GREEN}All good${RESET}: $ok files installed and up to date."
}

main() {
    init_home_dir
    local command="${1:-help}"
    case "$command" in
        install)   cmd_install ;;
        uninstall) cmd_uninstall ;;
        doctor)    cmd_doctor ;;
        help|-h|--help) usage ;;
        *)
            echo "${RED}error:${RESET} unknown command '$command'" >&2
            echo >&2
            usage >&2
            exit 2
            ;;
    esac
}
