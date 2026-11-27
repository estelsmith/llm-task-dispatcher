# Shared installer logic sourced by the per-tool scripts in bin/ (like bin/junie
# and bin/claude). Scripts need to define TOOL_NAME, HOME_ENV_VAR, DEFAULT_HOME,
# and PLACEHOLDERS before calling `main "$@"`, and can override install_path()
# when files land somewhere different (like Claude Code skills).
#
# Sourcing this loads .env at the repo root if present, though shell env vars
# still win. Shared settings (TASK_DISPATCHER_TASKS_DIR,
# TASK_DISPATCHER_MAX_RETRIES, TASK_DISPATCHER_MAX_CONTINUATIONS) live here so
# every tool picks them up.
#
# Install-time tags use {{name}}; single-brace {name} fields are left untouched
# because they're runtime placeholders for the agents (like {time} in logs).

set -euo pipefail

# Lives in bin/lib/, so the repo root is two levels up.
REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Repo directories mirrored into the tool's home directory.
MANAGED_DIRS=(commands agents)

# Optional KEY=value config loaded by load_env.
ENV_FILE="$REPO_ROOT/.env"

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; RESET=""
fi

# Parse .env line by line rather than sourcing it so we don't execute arbitrary
# shell or clobber variables already set in the environment.
load_env() {
    local line key value
    [[ -f "$ENV_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#export }"
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            echo "${RED}error:${RESET} invalid line in $ENV_FILE: $line" >&2
            exit 1
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        [[ -n "${!key+set}" ]] || export "$key=$value"
    done < "$ENV_FILE"
}

# Join non-empty args with newlines so optional front matter fields don't leave blank lines.
join_lines() {
    local out="" line
    for line in "$@"; do
        [[ -n "$line" ]] && out+="${out:+$'\n'}$line"
    done
    printf '%s' "$out"
}

# Read a non-negative integer setting into $1, falling back to $3 when $2 is unset or empty.
read_int_setting() {
    local out_var="$1" env_var="$2" default_val="$3" val
    val="${!env_var:-$default_val}"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
        echo "${RED}error:${RESET} $env_var must be a non-negative integer (got '$val')" >&2
        exit 1
    fi
    printf -v "$out_var" '%s' "$val"
}

# Read TASK_DISPATCHER_TASKS_DIR into $1 (stripping trailing slashes) or fall back to $2.
read_tasks_dir() {
    local out_var="$1" default_val="$2" val
    val="${TASK_DISPATCHER_TASKS_DIR:-$default_val}"
    while [[ "$val" == */ ]]; do
        val="${val%/}"
    done
    if [[ -z "${val//[[:space:]]/}" ]]; then
        echo "${RED}error:${RESET} TASK_DISPATCHER_TASKS_DIR must not be '/' or whitespace" >&2
        exit 1
    fi
    printf -v "$out_var" '%s' "$val"
}

init_home_dir() {
    TARGET_HOME_DIR="${!HOME_ENV_VAR:-$DEFAULT_HOME}"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  install     Install or update the dispatcher command and agents in ${TARGET_HOME_DIR}
  uninstall   Remove only the files this repo installed from ${TARGET_HOME_DIR}
  doctor      Check that installed files exist and match the repo (pass --diff to see diffs)
  help        Show this help

Set ${HOME_ENV_VAR} to point somewhere other than ${DEFAULT_HOME/#$HOME/~}.
EOF
}

# Default path mapping: keep the repo-relative path. Tool scripts (like bin/claude) override this when needed.
install_path() {
    printf '%s\n' "$1"
}

# Clean up empty parent dirs up to TARGET_HOME_DIR so uninstall doesn't leave stray folders behind.
remove_empty_parents() {
    local dir
    dir="$(dirname "$1")"
    while [[ "$dir" == "$TARGET_HOME_DIR"/* ]]; do
        rmdir "$dir" 2>/dev/null || break
        dir="$(dirname "$dir")"
    done
}

# List every managed markdown template as a repo-relative path (like "agents/foo.md").
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

# Render {{placeholder}} tags in a template and fail if any unknown ones are left over.
render() {
    local rel="$1" content key value i leftover
    local all_placeholders=("${PLACEHOLDERS[@]}" "${COMMON_PLACEHOLDERS[@]}")
    # Append and strip a trailing 'x' because command substitution eats trailing newlines.
    content="$(cat "$REPO_ROOT/$rel"; printf x)"
    content="${content%x}"
    for ((i = 0; i < ${#all_placeholders[@]}; i += 2)); do
        key="{{${all_placeholders[i]}}}"
        value="${all_placeholders[i + 1]}"
        if [[ -z "$value" ]]; then
            # Drop whole lines that only hold an empty placeholder so optional front matter doesn't leave blank lines.
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
        dest="$TARGET_HOME_DIR/$(install_path "$rel")"
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
    local rel dest removed=0 missing=0
    while IFS= read -r rel; do
        dest="$TARGET_HOME_DIR/$(install_path "$rel")"
        if [[ -e "$dest" || -L "$dest" ]]; then
            rm -f "$dest"
            remove_empty_parents "$dest"
            echo "${GREEN}removed${RESET}    $dest"
            removed=$((removed + 1))
        else
            echo "not found  $dest"
            missing=$((missing + 1))
        fi
    done < <(managed_files)
    echo
    echo "Done: $removed removed, $missing not found."
}

cmd_doctor() {
    local show_diff=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --diff) show_diff=1 ;;
            -h|--help) usage; return 0 ;;
            *)
                echo "${RED}error:${RESET} unknown option for doctor: '$1'" >&2
                echo >&2
                usage >&2
                return 2
                ;;
        esac
        shift
    done

    local rel dest rendered ok=0 problems=0 need_sep=0
    rendered="$(mktemp)"
    echo "${TOOL_NAME} home: $TARGET_HOME_DIR"
    echo "Repository: $REPO_ROOT"
    if [[ -f "$ENV_FILE" ]]; then
        echo "Settings: $ENV_FILE"
    else
        echo "Settings: defaults (no .env file)"
    fi
    echo
    while IFS= read -r rel; do
        dest="$TARGET_HOME_DIR/$(install_path "$rel")"
        if [[ $need_sep -eq 1 ]]; then
            echo
            need_sep=0
        fi
        if ! render "$rel" > "$rendered"; then
            echo "${RED}invalid${RESET}    $REPO_ROOT/$rel"
            problems=$((problems + 1))
        elif [[ ! -e "$dest" ]]; then
            echo "${RED}missing${RESET}    $dest"
            problems=$((problems + 1))
        elif ! cmp -s "$rendered" "$dest"; then
            echo "${RED}differs${RESET}    $dest"
            if [[ $show_diff -eq 1 ]]; then
                diff -u -L "$dest (installed)" -L "$rel (updated)" "$dest" "$rendered" || true
                need_sep=1
            fi
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
    shift || true
    case "$command" in
        install)   cmd_install ;;
        uninstall) cmd_uninstall ;;
        doctor)    cmd_doctor "$@" ;;
        help|-h|--help) usage ;;
        *)
            echo "${RED}error:${RESET} unknown command '$command'" >&2
            echo >&2
            usage >&2
            exit 2
            ;;
    esac
}

load_env

read_int_setting _task_dispatcher_max_retries TASK_DISPATCHER_MAX_RETRIES 3
read_int_setting _task_dispatcher_max_continuations TASK_DISPATCHER_MAX_CONTINUATIONS 5

COMMON_PLACEHOLDERS=(
    max-retries       "$_task_dispatcher_max_retries"
    max-continuations "$_task_dispatcher_max_continuations"
)
