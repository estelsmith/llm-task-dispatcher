#!/usr/bin/env bash
set -euo pipefail

# End-to-end test harness for the Junie task-dispatcher pipeline.
#
# Runs the dispatcher inside an isolated detached git worktree with an isolated
# temporary JUNIE_HOME, runs deterministic Tier A (task archive & deliverables)
# and Tier B (Junie session transcript/summary) assertions, optionally runs a
# Tier C LLM-as-a-judge pass (--deep), and tears down the worktree on exit.

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_TASK="agent-tasks/draft/test-task.md"
DEFAULT_MAX_STEPS=150

JUNIE_ARG="${JUNIE_BIN:-}"
TASK_ARG="$DEFAULT_TASK"
MODEL_ARG="${JUNIE_TEST_MODEL:-}"
MAX_STEPS="$DEFAULT_MAX_STEPS"
EXPECT_RETRY="auto"
DEEP_AUDIT=0
KEEP_ARTIFACTS=0
DRY_RUN=0

if [[ -t 1 ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BOLD=""
    RESET=""
fi

usage() {
    cat <<EOF
Usage: ./test.sh [options]

Automated end-to-end test runner for the task-dispatcher pipeline.

Options:
  --junie <impl>      Junie executable to run: "safehouse", "local", or a path/command.
                      Defaults to \$JUNIE_BIN if set, else ~/bin/junie-safehouse if
                      executable, else ~/.local/bin/junie.
  --task <path>       Task fixture markdown file (default: $DEFAULT_TASK).
  --model <id>        Optional --model override passed to Junie for the dispatcher.
  --max-steps <n>     Max steps for the Junie invocation (default: $DEFAULT_MAX_STEPS).
  --expect-retry      Require Attempt 1 FAIL -> Attempt 2 PASS retry loop (auto-enabled
                      for test-task*.md fixtures).
  --no-expect-retry   Do not require the 2-attempt retry loop (for custom fixtures).
  --deep              Run optional Tier C LLM-as-a-judge semantic audit after Tier A/B.
  --keep              Preserve temporary JUNIE_HOME and copied artifacts after pass.
  --dry-run           Prepare worktree, isolated JUNIE_HOME, install & doctor checks,
                      and print the Junie command without invoking the LLM.
  -h, --help          Show this help message.

Environment variables:
  JUNIE_BIN           Same as --junie (overridden by --junie).
  JUNIE_TEST_MODEL    Same as --model (overridden by --model).
EOF
}

log_info() {
    printf '%s==>%s %s\n' "$BOLD" "$RESET" "$*"
}

log_pass() {
    printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

log_err() {
    printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2
}

expand_tilde() {
    local p="$1"
    if [[ "$p" == "~" ]]; then
        printf '%s\n' "$HOME"
    elif [[ "$p" == "~/"* ]]; then
        printf '%s/%s\n' "$HOME" "${p#~/}"
    else
        printf '%s\n' "$p"
    fi
}

resolve_junie_bin() {
    local spec="$1"
    local expanded

    if [[ -z "$spec" ]]; then
        if [[ -x "$HOME/bin/junie-safehouse" ]]; then
            printf '%s\n' "$HOME/bin/junie-safehouse"
            return 0
        elif [[ -x "$HOME/.local/bin/junie" ]]; then
            printf '%s\n' "$HOME/.local/bin/junie"
            return 0
        elif command -v junie >/dev/null 2>&1; then
            command -v junie
            return 0
        fi
        log_err "No Junie executable found (checked ~/bin/junie-safehouse, ~/.local/bin/junie, PATH)."
        return 1
    fi

    case "$spec" in
        safehouse)
            expanded="$HOME/bin/junie-safehouse"
            ;;
        local|direct)
            expanded="$HOME/.local/bin/junie"
            ;;
        *)
            expanded="$(expand_tilde "$spec")"
            ;;
    esac

    if [[ "$expanded" == */* ]]; then
        if [[ ! -x "$expanded" ]]; then
            log_err "Junie executable not found or not executable: $expanded"
            return 1
        fi
        printf '%s\n' "$expanded"
        return 0
    fi

    if command -v "$expanded" >/dev/null 2>&1; then
        command -v "$expanded"
        return 0
    fi

    log_err "Junie command not found on PATH: $expanded"
    return 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --junie)
            [[ $# -ge 2 ]] || { log_err "--junie requires a value"; exit 2; }
            JUNIE_ARG="$2"
            shift 2
            ;;
        --junie=*)
            JUNIE_ARG="${1#--junie=}"
            shift
            ;;
        --task)
            [[ $# -ge 2 ]] || { log_err "--task requires a value"; exit 2; }
            TASK_ARG="$2"
            shift 2
            ;;
        --task=*)
            TASK_ARG="${1#--task=}"
            shift
            ;;
        --model)
            [[ $# -ge 2 ]] || { log_err "--model requires a value"; exit 2; }
            MODEL_ARG="$2"
            shift 2
            ;;
        --model=*)
            MODEL_ARG="${1#--model=}"
            shift
            ;;
        --max-steps)
            [[ $# -ge 2 ]] || { log_err "--max-steps requires a value"; exit 2; }
            MAX_STEPS="$2"
            shift 2
            ;;
        --max-steps=*)
            MAX_STEPS="${1#--max-steps=}"
            shift
            ;;
        --expect-retry)
            EXPECT_RETRY="1"
            shift
            ;;
        --no-expect-retry)
            EXPECT_RETRY="0"
            shift
            ;;
        --deep)
            DEEP_AUDIT=1
            shift
            ;;
        --keep)
            KEEP_ARTIFACTS=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_err "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! "$MAX_STEPS" =~ ^[0-9]+$ || "$MAX_STEPS" -lt 1 ]]; then
    log_err "--max-steps must be a positive integer (got '$MAX_STEPS')"
    exit 2
fi

JUNIE_EXEC="$(resolve_junie_bin "$JUNIE_ARG")"

if [[ "$TASK_ARG" = /* ]]; then
    TASK_SRC="$TASK_ARG"
else
    TASK_SRC="$REPO_ROOT/$TASK_ARG"
fi
if [[ ! -f "$TASK_SRC" ]]; then
    log_err "Task fixture file not found: $TASK_SRC"
    exit 1
fi
TASK_FILENAME="$(basename "$TASK_SRC")"
TASK_ID="${TASK_FILENAME%.md}"

# Auto-select a LiteLLM custom model if --model / JUNIE_TEST_MODEL is unset and LITELLM_MASTER_KEY is present.
if [[ -z "$MODEL_ARG" ]]; then
    MODEL_ARG="$(python3 - "$REPO_ROOT" "$HOME/.junie/settings.json" "${JUNIE_DEFAULT_MODEL:-}" "${LITELLM_MASTER_KEY:-}" <<'PY'
import json, pathlib, re, sys

repo = pathlib.Path(sys.argv[1])
settings_path = pathlib.Path(sys.argv[2])
default_model = sys.argv[3].strip()
litellm_key = sys.argv[4]

if default_model:
    print(default_model)
    sys.exit(0)

env_vars = {}
env_file = repo / ".env"
if env_file.is_file():
    for raw in env_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" in line:
            k, v = line.split("=", 1)
            v = v.strip().strip('"').strip("'")
            env_vars[k.strip()] = v

if env_vars.get("JUNIE_DEFAULT_MODEL"):
    print(env_vars["JUNIE_DEFAULT_MODEL"])
    sys.exit(0)

if litellm_key:
    if settings_path.is_file():
        try:
            s = json.loads(settings_path.read_text(encoding="utf-8"))
            acp_model = s.get("acpLastSelectedModel", "")
            m = re.search(r"(custom:[^:]+)$", acp_model)
            if m:
                print(m.group(1))
                sys.exit(0)
        except Exception:
            pass
    for key in ("JUNIE_IMPLEMENTATION_MODEL", "JUNIE_PLANNING_MODEL", "JUNIE_VERIFICATION_MODEL"):
        val = env_vars.get(key, "")
        if val.startswith("custom:"):
            print(val)
            sys.exit(0)
PY
)"
fi

if [[ "$EXPECT_RETRY" == "auto" ]]; then
    if [[ "$TASK_ID" == test-task* ]]; then
        EXPECT_RETRY="1"
    else
        EXPECT_RETRY="0"
    fi
fi

# Resolve tasks_dir using the same precedence as the dispatcher (.task-dispatcher.json -> env -> .junie/tasks).
TASKS_DIR="$(python3 - "$REPO_ROOT" "${TASK_DISPATCHER_TASKS_DIR:-}" <<'PY'
import json, pathlib, sys
repo = pathlib.Path(sys.argv[1])
env_dir = sys.argv[2].strip().rstrip("/")
cfg_path = repo / ".task-dispatcher.json"
tasks_dir = env_dir or ".junie/tasks"
if cfg_path.is_file():
    data = json.loads(cfg_path.read_text())
    if isinstance(data, dict) and isinstance(data.get("tasks_dir"), str) and data["tasks_dir"].strip():
        tasks_dir = data["tasks_dir"].strip().rstrip("/")
print(tasks_dir)
PY
)"

RUN_BASE_RAW="$(mktemp -d "${TMPDIR:-/tmp}/task-dispatcher-test.XXXXXX")"
RUN_BASE="$(cd -P "$RUN_BASE_RAW" && pwd)"
WORKDIR="$RUN_BASE/worktree"
TMP_JUNIE_HOME="$RUN_BASE/junie-home"
RUN_DIR="$RUN_BASE/run"
mkdir -p "$TMP_JUNIE_HOME" "$RUN_DIR"

WORKTREE_ADDED=0

cleanup() {
    local exit_code=$?
    set +e

    local preserve=0
    if [[ "$exit_code" -ne 0 || "$KEEP_ARTIFACTS" -eq 1 ]]; then
        preserve=1
    fi

    if [[ "$preserve" -eq 1 && "$WORKTREE_ADDED" -eq 1 && -d "$WORKDIR" ]]; then
        mkdir -p "$RUN_DIR/artifacts"
        if [[ -d "$WORKDIR/$TASKS_DIR" ]]; then
            cp -R "$WORKDIR/$TASKS_DIR" "$RUN_DIR/artifacts/" 2>/dev/null || true
        fi
        if [[ -d "$WORKDIR/testing" ]]; then
            cp -R "$WORKDIR/testing" "$RUN_DIR/artifacts/" 2>/dev/null || true
        fi
    fi

    if [[ "$WORKTREE_ADDED" -eq 1 ]]; then
        git -C "$REPO_ROOT" worktree remove --force "$WORKDIR" >/dev/null 2>&1 || true
        git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    fi

    if [[ "$preserve" -eq 0 ]]; then
        rm -rf "$RUN_BASE"
    else
        echo "" >&2
        if [[ "$exit_code" -ne 0 ]]; then
            log_warn "Test failed (exit $exit_code). Preserved diagnostic artifacts at:"
        else
            log_info "Preserved test artifacts (--keep):"
        fi
        echo "  Run dir:        $RUN_DIR" >&2
        echo "  JUNIE_HOME:     $TMP_JUNIE_HOME" >&2
        if [[ -f "$RUN_DIR/junie-output.json" ]]; then
            echo "  Junie JSON:     $RUN_DIR/junie-output.json" >&2
        fi
        local session_dir
        session_dir="$(find "$TMP_JUNIE_HOME/sessions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1 || true)"
        if [[ -n "$session_dir" ]]; then
            echo "  Session dir:    $session_dir" >&2
            [[ -f "$session_dir/summary.json" ]] && echo "  Summary JSON:   $session_dir/summary.json" >&2
            [[ -f "$session_dir/transcript.md" ]] && echo "  Transcript:     $session_dir/transcript.md" >&2
        fi
        if [[ -d "$RUN_DIR/artifacts" ]]; then
            echo "  Task artifacts: $RUN_DIR/artifacts" >&2
        fi
    fi

    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

log_info "Setting up isolated worktree at $WORKDIR (HEAD=$HEAD_SHA)"
git -C "$REPO_ROOT" worktree add --quiet --detach "$WORKDIR" "$HEAD_SHA"
WORKTREE_ADDED=1
WORKDIR="$(cd -P "$WORKDIR" && pwd)"
WORKTREE_GIT_DIR="$(cd -P "$(git -C "$WORKDIR" rev-parse --git-dir)" && pwd)"

log_info "Setting up isolated JUNIE_HOME at $TMP_JUNIE_HOME"
if [[ -d "$HOME/.junie/models" ]]; then
    cp -R "$HOME/.junie/models" "$TMP_JUNIE_HOME/models"
fi
if [[ -f "$HOME/.junie/settings.json" ]]; then
    cp "$HOME/.junie/settings.json" "$TMP_JUNIE_HOME/settings.json"
else
    printf '{"braveMode":"ON","subagentsMode":"Auto"}\n' > "$TMP_JUNIE_HOME/settings.json"
fi
if [[ -f "$HOME/.junie/allowlist.json" ]]; then
    cp "$HOME/.junie/allowlist.json" "$TMP_JUNIE_HOME/allowlist.json"
fi

log_info "Installing dispatcher templates into isolated JUNIE_HOME"
JUNIE_HOME="$TMP_JUNIE_HOME" "$REPO_ROOT/bin/junie" install
JUNIE_HOME="$TMP_JUNIE_HOME" "$REPO_ROOT/bin/junie" doctor

mkdir -p "$WORKDIR/$TASKS_DIR/pending"
cp "$TASK_SRC" "$WORKDIR/$TASKS_DIR/pending/$TASK_FILENAME"

# Render the /task-dispatcher slash command template with YAML frontmatter stripped and $task substituted.
RENDERED_PROMPT_FILE="$RUN_DIR/prompt.txt"
python3 - "$TMP_JUNIE_HOME/commands/task-dispatcher.md" "$TASK_FILENAME" "$RENDERED_PROMPT_FILE" <<'PY'
import pathlib, re, sys

cmd_path = pathlib.Path(sys.argv[1])
task_name = sys.argv[2]
out_path = pathlib.Path(sys.argv[3])

text = cmd_path.read_text(encoding="utf-8")
m = re.match(r"^---\r?\n.*?\r?\n---\r?\n?", text, flags=re.DOTALL)
body = text[m.end():] if m else text
body = body.replace("$task", task_name).lstrip("\r\n")
out_path.write_text(body, encoding="utf-8")
PY
PROMPT_TEXT="$(cat "$RENDERED_PROMPT_FILE")"

JUNIE_ARGS=(
    "--project=$WORKDIR"
    "--agent-location=$TMP_JUNIE_HOME/agents"
    "--agent-default-location=false"
    "--command-location=$TMP_JUNIE_HOME/commands"
    "--command-default-location=false"
    "--output-format=json"
    "--json-output-file=$RUN_DIR/junie-output.json"
    "--skip-update-check"
    "--max-steps=$MAX_STEPS"
)
if [[ -n "$MODEL_ARG" ]]; then
    JUNIE_ARGS+=("--model=$MODEL_ARG")
fi

# Configure Safehouse overrides via environment (no policy file edits needed).
# When using a non-safehouse binary (e.g. ~/.local/bin/junie), these are harmlessly ignored.
SAFEHOUSE_ADD_DIRS_VAL="${SAFEHOUSE_ADD_DIRS:+$SAFEHOUSE_ADD_DIRS:}$TMP_JUNIE_HOME:$RUN_DIR:$WORKTREE_GIT_DIR"
SAFEHOUSE_ADD_DIRS_RO_VAL="${SAFEHOUSE_ADD_DIRS_RO:+$SAFEHOUSE_ADD_DIRS_RO:}$REPO_ROOT/.git"
SAFEHOUSE_ENV_PASS_VAL="${SAFEHOUSE_ENV_PASS:+$SAFEHOUSE_ENV_PASS,}JUNIE_HOME"
if [[ -n "${JUNIE_API_KEY:-}" ]]; then
    SAFEHOUSE_ENV_PASS_VAL="$SAFEHOUSE_ENV_PASS_VAL,JUNIE_API_KEY"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    log_pass "Dry run setup verified:"
    echo "  JUNIE_BIN:             $JUNIE_EXEC"
    echo "  MODEL:                 ${MODEL_ARG:-<default>}"
    echo "  WORKDIR:               $WORKDIR"
    echo "  TMP_JUNIE_HOME:        $TMP_JUNIE_HOME"
    echo "  TASKS_DIR:             $TASKS_DIR"
    echo "  TASK_FILENAME:         $TASK_FILENAME"
    echo "  SAFEHOUSE_WORKDIR:     $WORKDIR"
    echo "  SAFEHOUSE_ENV_PASS:    $SAFEHOUSE_ENV_PASS_VAL"
    echo "  SAFEHOUSE_ADD_DIRS:    $SAFEHOUSE_ADD_DIRS_VAL"
    echo "  SAFEHOUSE_ADD_DIRS_RO: $SAFEHOUSE_ADD_DIRS_RO_VAL"
    echo "  JUNIE_ARGS:            ${JUNIE_ARGS[*]}"
    exit 0
fi

log_info "Executing task-dispatcher via $JUNIE_EXEC (task=$TASK_FILENAME, max-steps=$MAX_STEPS)"
(
    cd "$WORKDIR"
    export JUNIE_HOME="$TMP_JUNIE_HOME"
    export SAFEHOUSE_WORKDIR="$WORKDIR"
    export SAFEHOUSE_ADD_DIRS="$SAFEHOUSE_ADD_DIRS_VAL"
    export SAFEHOUSE_ADD_DIRS_RO="$SAFEHOUSE_ADD_DIRS_RO_VAL"
    export SAFEHOUSE_ENV_PASS="$SAFEHOUSE_ENV_PASS_VAL"
    "$JUNIE_EXEC" "${JUNIE_ARGS[@]}" "$PROMPT_TEXT"
)

log_info "Running Tier A (task archive & deliverables) and Tier B (Junie session) verification"
python3 - "$WORKDIR" "$TMP_JUNIE_HOME" "$TASKS_DIR" "$TASK_FILENAME" "$HEAD_SHA" "$EXPECT_RETRY" "$RUN_DIR/junie-output.json" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

workdir = pathlib.Path(sys.argv[1])
junie_home = pathlib.Path(sys.argv[2])
tasks_dir = pathlib.Path(sys.argv[3])
task_filename = sys.argv[4]
head_sha = sys.argv[5]
expect_retry = sys.argv[6] == "1"
junie_output_file = pathlib.Path(sys.argv[7])

task_id = task_filename[:-3] if task_filename.endswith(".md") else task_filename
errors = []

def check(cond, msg):
    if not cond:
        errors.append(msg)
    else:
        print(f"  [OK] {msg}")

# --- Tier A: Task Archive & Deliverable Checks ---
print("Tier A: Verifying task archive & workspace deliverables...")
completed_file = workdir / tasks_dir / "completed" / task_filename
in_progress_file = workdir / tasks_dir / "in-progress" / task_filename
pending_file = workdir / tasks_dir / "pending" / task_filename

check(completed_file.is_file(), f"Completed task file exists at {tasks_dir}/completed/{task_filename}")
check(not in_progress_file.exists(), f"Task removed from {tasks_dir}/in-progress/")
check(not pending_file.exists(), f"Task removed from {tasks_dir}/pending/")

if completed_file.is_file():
    content = completed_file.read_text(encoding="utf-8")
    fm_match = re.match(r"^---\r?\n(.*?)\r?\n---\r?\n", content, flags=re.DOTALL)
    check(fm_match is not None, "Completed task file has YAML frontmatter")
    fm = {}
    if fm_match:
        for line in fm_match.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                fm[k.strip()] = v.strip().strip('"').strip("'")

        check(fm.get("id") == task_id, f"frontmatter.id == {task_id!r} (got {fm.get('id')!r})")
        check(fm.get("status") == "COMPLETED", f"frontmatter.status == 'COMPLETED' (got {fm.get('status')!r})")
        check(fm.get("active_agent") == "none", f"frontmatter.active_agent == 'none' (got {fm.get('active_agent')!r})")
        check(fm.get("continuation_count") == "0", f"frontmatter.continuation_count == '0' (got {fm.get('continuation_count')!r})")
        check(fm.get("base_commit") == head_sha, f"frontmatter.base_commit matches HEAD ({head_sha[:10]}...)")
        if expect_retry:
            check(fm.get("attempt") == "2", f"frontmatter.attempt == '2' (got {fm.get('attempt')!r})")
            check(fm.get("retry_count") == "1", f"frontmatter.retry_count == '1' (got {fm.get('retry_count')!r})")
        else:
            attempt_ok = fm.get("attempt", "").isdigit() and int(fm["attempt"]) >= 1
            check(attempt_ok, f"frontmatter.attempt >= 1 (got {fm.get('attempt')!r})")

    for heading in (
        "# Human Request",
        "# Agent Pipeline State",
        "## Baseline",
        "## Agent Execution Log",
        "## Plan",
        "## Implementation Details",
        "## Verification Feedback",
    ):
        check(heading in content, f"Task file contains section {heading!r}")

    # Split major sections cleanly by top/level-2 headings
    def extract_h2(text, title):
        m = re.search(rf"^## {re.escape(title)}\s*$", text, flags=re.MULTILINE)
        if not m:
            return ""
        rest = text[m.end():]
        nxt = re.search(r"^##\s", rest, flags=re.MULTILINE)
        return rest[:nxt.start()] if nxt else rest

    plan_sec = extract_h2(content, "Plan")
    for sub in ("#### Target Files", "#### Architectural Constraints & Guidelines", "#### Implementation Steps", "#### Acceptance Criteria"):
        check(sub in plan_sec, f"## Plan contains {sub!r}")
    checked_boxes = re.findall(r"^- \[x\] ", plan_sec, flags=re.MULTILINE)
    unchecked_boxes = re.findall(r"^- \[ \] ", plan_sec, flags=re.MULTILINE)
    check(len(checked_boxes) > 0 and len(unchecked_boxes) == 0,
          f"All acceptance criteria in ## Plan are checked ({len(checked_boxes)} checked, {len(unchecked_boxes)} unchecked)")

    log_sec = extract_h2(content, "Agent Execution Log")
    log_lines = [ln.strip() for ln in log_sec.splitlines() if ln.strip().startswith("- ")]
    expected_sequence = [
        "[router] Ingested task",
        "[router] Routed task to the tri-agent pipeline.",
        "[planning]",
        "transitioned from planning to implementation",
        "[implementation]",
        "transitioned from implementation to verification",
        "[verification]",
    ]
    if expect_retry:
        expected_sequence += [
            "transitioned from verification to implementation",
            "[implementation]",
            "transitioned from implementation to verification",
            "[verification]",
        ]
    expected_sequence.append("[router] Verification passed; task completed and moved to completed/.")

    cursor = 0
    matched_all = True
    missing_marker = None
    for marker in expected_sequence:
        found = False
        while cursor < len(log_lines):
            if marker in log_lines[cursor]:
                found = True
                cursor += 1
                break
            cursor += 1
        if not found:
            matched_all = False
            missing_marker = marker
            break
    check(matched_all, f"Agent Execution Log contains full ordered sequence" + (f" (missing: {missing_marker!r})" if missing_marker else ""))

    impl_sec = extract_h2(content, "Implementation Details")
    verif_sec = extract_h2(content, "Verification Feedback")
    if expect_retry:
        check("### Attempt 1" in impl_sec and "### Attempt 2" in impl_sec,
              "## Implementation Details records ### Attempt 1 and ### Attempt 2")
        a1_verif = re.search(r"### Attempt 1\b(.*?)(?=### Attempt 2\b|\Z)", verif_sec, flags=re.DOTALL)
        a2_verif = re.search(r"### Attempt 2\b(.*)", verif_sec, flags=re.DOTALL)
        check(bool(a1_verif and "**Verdict:** FAIL" in a1_verif.group(1)),
              "## Verification Feedback ### Attempt 1 has Verdict: FAIL")
        check(bool(a2_verif and "**Verdict:** PASS" in a2_verif.group(1)),
              "## Verification Feedback ### Attempt 2 has Verdict: PASS")

# Fixture-specific checks for test-task*.md
if task_id.startswith("test-task"):
    research_file = workdir / tasks_dir / "discovery" / f"{task_id}-research.md"
    check(research_file.is_file(), f"Discovery research file exists at {tasks_dir}/discovery/{task_id}-research.md")
    if research_file.is_file():
        r_text = research_file.read_text(encoding="utf-8")
        check("## Planning Progress" not in r_text, "Discovery file has no leftover ## Planning Progress section")

    testing_dir = workdir / "testing"
    sh_files = sorted(testing_dir.glob("*.sh")) if testing_dir.is_dir() else []
    check(len(sh_files) >= 2, f"testing/ contains at least 2 .sh scripts (found {[p.name for p in sh_files]})")

    math_outputs = []
    expected_stdout = "2 + 3 = 5\n6 * 7 = 42\n10 / 4 = 2.5"
    for p in sh_files:
        syntax = subprocess.run(["bash", "-n", str(p)], cwd=workdir, capture_output=True, text=True)
        check(syntax.returncode == 0, f"bash -n {p.relative_to(workdir)} passes")

        run_res = subprocess.run(["bash", str(p)], cwd=workdir, capture_output=True, text=True)
        check(run_res.returncode == 0, f"bash {p.relative_to(workdir)} exits 0")
        if run_res.stdout.strip() == expected_stdout:
            math_outputs.append(p.name)

    check(len(math_outputs) >= 1, f"At least one testing/*.sh script prints exact expected math lines ({math_outputs})")

# --- Tier B: Junie Session Inspection ---
print("Tier B: Verifying isolated Junie session artifacts...")
if junie_output_file.is_file():
    try:
        out_json = json.loads(junie_output_file.read_text(encoding="utf-8"))
        check(isinstance(out_json, dict), "junie-output.json is valid JSON")
    except Exception as exc:
        check(False, f"junie-output.json is valid JSON ({exc})")

sessions_root = junie_home / "sessions"
session_dirs = [p for p in sessions_root.iterdir() if p.is_dir()] if sessions_root.is_dir() else []
check(len(session_dirs) == 1, f"Isolated JUNIE_HOME contains exactly 1 session directory (found {len(session_dirs)})")

if len(session_dirs) == 1:
    sdir = session_dirs[0]
    summary_path = sdir / "summary.json"
    tasks_path = sdir / "tasks.json"
    transcript_path = sdir / "transcript.md"

    check(summary_path.is_file(), "Session summary.json exists")
    if summary_path.is_file():
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        check(summary.get("lifecycle") == "COMPLETED", f"summary.json lifecycle == 'COMPLETED' (got {summary.get('lifecycle')!r})")

        subagents = summary.get("subagents") or []
        def agent_num(item):
            m = re.search(r"(\d+)$", str(item.get("id", "")))
            return int(m.group(1)) if m else 0
        subagents_sorted = sorted(subagents, key=agent_num)
        agent_names = [s.get("name") or s.get("agentName") for s in subagents_sorted]
        allowed = {"task-dispatcher-planning", "task-dispatcher-implementation", "task-dispatcher-verification"}

        check(all(name in allowed for name in agent_names),
              f"No substitute/general_purpose subagents spawned (agents={agent_names})")
        check(all(s.get("status") == "Finished" for s in subagents_sorted),
              "All spawned subagents finished with status 'Finished'")

        if expect_retry:
            expected_agents = [
                "task-dispatcher-planning",
                "task-dispatcher-implementation",
                "task-dispatcher-verification",
                "task-dispatcher-implementation",
                "task-dispatcher-verification",
            ]
            check(agent_names == expected_agents,
                  f"Subagent sequence matches expected 5-step retry pipeline (got {agent_names})")

    if tasks_path.is_file():
        tdata = json.loads(tasks_path.read_text(encoding="utf-8"))
        t_items = tdata if isinstance(tdata, list) else tdata.get("tasks", [tdata])
        all_done = bool(t_items) and all(item.get("status") == "COMPLETED" for item in t_items if isinstance(item, dict))
        check(all_done, "tasks.json shows COMPLETED status")

    if transcript_path.is_file():
        t_text = transcript_path.read_text(encoding="utf-8")
        # Check dispatcher did not use bash to edit task files under tasks_dir
        bad_bash = []
        for line in t_text.splitlines():
            if line.startswith("### Ran ") or line.startswith("### Failed to run "):
                if str(tasks_dir) in line and re.search(r"(cat\s*>|>>|tee\s|sed\s+-i|perl\s+-i|python[23]?\s+-c)", line):
                    bad_bash.append(line)
        check(not bad_bash, f"Dispatcher did not use Bash to edit files under {tasks_dir}/")

    subagent_dir = sdir / "subagents"
    subagent_transcripts = sorted(subagent_dir.glob("agent-*-transcript.md")) if subagent_dir.is_dir() else []
    subagent_task_writes = []
    edit_prefix_re = re.compile(rf"^### (?:Edited|Created|Wrote) {re.escape(str(tasks_dir))}/", re.MULTILINE)
    for st in subagent_transcripts:
        st_text = st.read_text(encoding="utf-8")
        if edit_prefix_re.search(st_text):
            subagent_task_writes.append(st.name)
    check(not subagent_task_writes, f"No subagent modified files in {tasks_dir}/ ({subagent_task_writes})")

if errors:
    print("\nVerification failures:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
PY

log_pass "Tier A & Tier B deterministic checks passed."

if [[ "$DEEP_AUDIT" -eq 1 ]]; then
    log_info "Running Tier C LLM-as-a-judge semantic audit (--deep)"
    SESSION_DIR="$(find "$TMP_JUNIE_HOME/sessions" -maxdepth 1 -mindepth 1 -type d | head -n 1)"
    JUDGE_OUTPUT="$RUN_DIR/judge-output.json"
    JUDGE_PROMPT=$(cat <<EOF
You are auditing a completed task-dispatcher run in strict read-only mode (do not create, edit, or delete any files).
Inspect these files:
1. $WORKDIR/$TASKS_DIR/completed/$TASK_FILENAME
2. $SESSION_DIR/transcript.md
3. All files matching $SESSION_DIR/subagents/agent-*-transcript.md

Evaluate these semantic protocol invariants:
- Planning compared at least two non-integer bash math approaches in its research notes (if applicable to the task).
- If this was the retry fixture, Attempt 1 intentionally introduced/left a failing defect and did not fix it before verification, and Attempt 2 fixed it cleanly.
- Before every subagent spawn, the dispatcher re-read the task file from disk (checkpoint before every spawn).
- No subagent edited files under $TASKS_DIR/.

Reply ONLY with valid JSON (no markdown fences) matching:
{"pass": true, "reasons": ["short bullet per check"]}
Set "pass" to false if ANY invariant failed.
EOF
)
    # Run the judge using a separate temporary JUNIE_HOME so it doesn't pollute the tested session's JUNIE_HOME.
    JUDGE_JUNIE_HOME="$RUN_BASE/judge-junie-home"
    mkdir -p "$JUDGE_JUNIE_HOME"
    [[ -d "$TMP_JUNIE_HOME/models" ]] && cp -R "$TMP_JUNIE_HOME/models" "$JUDGE_JUNIE_HOME/models"
    [[ -f "$TMP_JUNIE_HOME/settings.json" ]] && cp "$TMP_JUNIE_HOME/settings.json" "$JUDGE_JUNIE_HOME/settings.json"

    JUDGE_ARGS=(
        "--project=$WORKDIR"
        "--agent-default-location=false"
        "--command-default-location=false"
        "--output-format=json"
        "--json-output-file=$JUDGE_OUTPUT"
        "--skip-update-check"
        "--max-steps=20"
    )
    [[ -n "$MODEL_ARG" ]] && JUDGE_ARGS+=("--model=$MODEL_ARG")

    (
        cd "$WORKDIR"
        export JUNIE_HOME="$JUDGE_JUNIE_HOME"
        export SAFEHOUSE_WORKDIR="$WORKDIR"
        export SAFEHOUSE_ADD_DIRS="$SAFEHOUSE_ADD_DIRS_VAL:$JUDGE_JUNIE_HOME:$SESSION_DIR"
        export SAFEHOUSE_ADD_DIRS_RO="$SAFEHOUSE_ADD_DIRS_RO_VAL"
        export SAFEHOUSE_ENV_PASS="$SAFEHOUSE_ENV_PASS_VAL"
        "$JUNIE_EXEC" "${JUDGE_ARGS[@]}" "$JUDGE_PROMPT"
    )

    python3 - "$JUDGE_OUTPUT" <<'PY'
import json, pathlib, re, sys

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
data = json.loads(raw)
result_text = data.get("result") or data.get("output") or data.get("message") or raw
if not isinstance(result_text, str):
    result_text = json.dumps(result_text)

m = re.search(r"\{.*\}", result_text, flags=re.DOTALL)
if not m:
    print(f"Judge did not return JSON:\n{result_text}", file=sys.stderr)
    sys.exit(1)

verdict = json.loads(m.group(0))
print("Tier C Judge verdict:", json.dumps(verdict, indent=2))
if verdict.get("pass") is not True:
    sys.exit(1)
PY
    log_pass "Tier C semantic audit passed."
fi

log_pass "All pipeline tests passed!"
