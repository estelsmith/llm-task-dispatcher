# Task Dispatcher

A three-agent task pipeline for [Junie](https://junie.jetbrains.com/) and [Claude Code](https://code.claude.com/).

I built this so I can drop a short task description in a Markdown file, run `/task-dispatcher`, and hand the work off to separate planning, implementation, and verification sub-agents. Each phase only gets the reasoning effort it actually needs (high for planning, low for implementation and verification) so runs don't get spendy, and the task file itself holds every plan, retry, and checkpoint.

## Quick start

```shell
# Clone the repo and install the command + sub-agents into ~/.junie
git clone https://github.com/estelsmith/llm-task-dispatcher.git
cd llm-task-dispatcher
bin/junie install

# Or install into ~/.claude for Claude Code (you can install both)
bin/claude install
```

Any new session can now run `/task-dispatcher`.

## How it works

```
                      you: /task-dispatcher <task-file>
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Task Dispatcher (your session)                      │
│   Writes logs, moves files, counts retries/continuations, routes work   │
│              Uses your session's model and reasoning level              │
└─────────────────────────────────────────────────────────────────────────┘
          │ spawn                    │ spawn                    │ spawn
          ▼                          ▼                          ▼
┌───────────────────┐ plan ┌───────────────────┐ code ┌───────────────────┐
│     Planning      │ ───▶ │  Implementation   │ ───▶ │   Verification    │
│  sonnet-5.5 high  │      │  sonnet-5.5 low   │      │  sonnet-5.5 low   │
└───────────────────┘      └───────────────────┘      └───────────────────┘
                                     ▲                     │         │
                                     │       FAIL          │         │ PASS
                                     └─────────────────────┘         ▼
                                    (up to max_retries times)   completed/
```

For larger tasks, Planning and Implementation can also checkpoint with `PARTIAL` and loop with a fresh context up to `max_continuations` times (default `5`) before moving to the next phase.

- **Task Dispatcher** ([`commands/task-dispatcher.md`](commands/task-dispatcher.md)): runs in your current session using your session's model. It's the only part that touches task state (moving files between folders, writing the log, counting retries and `PARTIAL` continuations, and splitting big plans into step batches). It never edits project code itself, and if a required sub-agent isn't available it stops rather than improvising.
- **Planning** ([`agents/task-dispatcher-planning.md`](agents/task-dispatcher-planning.md)): reads the codebase and writes a plan with target files, steps, and acceptance criteria. On big codebases it can save research notes and checkpoint with `PARTIAL` before finalizing the plan.
- **Implementation** ([`agents/task-dispatcher-implementation.md`](agents/task-dispatcher-implementation.md)): writes the code from the plan, runs the project's checks, and reports back. For larger plans it works through bounded step batches and returns `PARTIAL` checkpoints so each continuation gets a fresh context.
- **Verification** ([`agents/task-dispatcher-verification.md`](agents/task-dispatcher-verification.md)): reviews the diff, runs tests and linters, and returns `PASS` or `FAIL`. On `FAIL`, the dispatcher routes the task back to implementation with the failure details.

Sub-agents never touch the task files directly. They just send a report back, and the dispatcher records it.

## Using it

1. Write a task as a Markdown file in your project's pending folder (by default):
   - Junie: `.junie/tasks/pending/my-task.md`
   - Claude Code: `.claude/tasks/pending/my-task.md`
2. Run the command in a session for that project:
   - Junie: `/task-dispatcher task=my-task.md`
   - Claude Code: `/task-dispatcher my-task.md` (in a local session in the **Code** tab of the Claude Desktop app)
3. Follow the task's progress in its file. The dispatcher moves tasks through these folders:

```
tasks/
├── pending/      # New task requests you write
├── in-progress/  # Tasks being worked on, with their plan, log, and attempts
├── completed/    # Tasks that passed verification
└── discovery/    # Research notes and in-progress planning checkpoints
```

If a run gets interrupted, just run `/task-dispatcher` on the same file again (now in `in-progress/`). It picks up from the recorded `active_agent`, `attempt`, and any `PARTIAL` checkpoint instead of starting over.

If a completed task isn't right, reject it with a reason (for example, `/task-dispatcher Reject my-task.md: the new endpoint is missing input validation`). The dispatcher routes it back to planning or implementation depending on what you flagged.

### Configuration and overrides

You can change the tasks folder (`tasks_dir`), retry limit (`max_retries`, default `3`), continuation limit (`max_continuations`, default `5`), or pass extra guidance (like asking for chunked execution) at four levels, highest precedence first:

1. **Per run in the command prompt:**
   - Junie: `/task-dispatcher task=my-task.md prompt="use a max continuation count of 10. This is a large change."`
   - Claude Code: `/task-dispatcher my-task.md use a max continuation count of 10. This is a large change.`
2. **Per task in the file:** set `max_retries` or `max_continuations` in the task's frontmatter, or ask for chunked execution under `# Human Request`.
3. **Per project in `.task-dispatcher.json`:** drop a `.task-dispatcher.json` in the repo root to override `tasks_dir`, `max_retries`, or `max_continuations` for both Junie and Claude Code without re-running `install`. Every field is optional; omitted keys fall back to your global defaults.
4. **Globally via `.env` or your shell:** set `TASK_DISPATCHER_TASKS_DIR`, `TASK_DISPATCHER_MAX_RETRIES`, or `TASK_DISPATCHER_MAX_CONTINUATIONS` in `.env` (see [`.env.example`](.env.example)) or your shell environment, then re-run `install`.

Example `.task-dispatcher.json` with all supported keys:

```json
{
  "tasks_dir": "agent-tasks",
  "max_retries": 3,
  "max_continuations": 5
}
```

Model and reasoning/effort settings live in static sub-agent frontmatter, so those still have to be set globally at install time via `.env` or environment variables.

## Installer commands

[`bin/junie`](bin/junie) and [`bin/claude`](bin/claude) share the same sub-commands:

| Command           | What it does                                                              |
|-------------------|---------------------------------------------------------------------------|
| `install`         | Installs the command and agents, or updates them after you pull changes   |
| `uninstall`       | Removes only the files this repository installed                          |
| `doctor [--diff]` | Checks that the installed files are present and match the repository      |

Pass `--diff` to `doctor` (for example, `bin/junie doctor --diff` or `bin/claude doctor --diff`) when you want to see what changed after pulling updates, or double-check that your `.env` overrides are taking effect before reinstalling. Missing files are still reported without a diff.

Where the files end up:

| Tool        | Command                                          | Agents             | Home override       |
|-------------|--------------------------------------------------|--------------------|---------------------|
| Junie       | `~/.junie/commands/task-dispatcher.md`           | `~/.junie/agents/` | `JUNIE_HOME`        |
| Claude Code | `~/.claude/skills/task-dispatcher/SKILL.md`      | `~/.claude/agents/` | `CLAUDE_CONFIG_DIR` |

Re-run `install` after pulling updates or changing install-time settings.

## Choosing models

The defaults are:

| Agent          | Junie            | Claude Code                |
|----------------|------------------|----------------------------|
| Planning       | `sonnet`, high   | `claude-sonnet-5-5`, high  |
| Implementation | `sonnet`, low    | `claude-sonnet-5-5`, low   |
| Verification   | `sonnet`, low    | `claude-sonnet-5-5`, low   |

The dispatcher itself has no model setting and just uses your session's model. I'd stick to Sonnet 5.5 on low effort (or Gemini 4 Hydrogen on low effort) for the dispatching session, since it's mostly routing state and doesn't need heavy reasoning.

If you want custom model profiles (like an AI gateway) or different defaults, copy [`.env.example`](.env.example) to `.env`, uncomment what you need, and re-run `install`. You can also set `JUNIE_DEFAULT_MODEL` / `JUNIE_DEFAULT_REASONING` or `CLAUDE_DEFAULT_MODEL` / `CLAUDE_DEFAULT_EFFORT` to apply a blanket default to any agent without a specific override. `.env` is gitignored, and shell environment variables win over `.env`.

```shell
# Copy the template config, edit .env, then re-render and install
cp .env.example .env
bin/junie install
```

## Repository layout

| Path                           | Contents                                                      |
|--------------------------------|---------------------------------------------------------------|
| [`commands/`](commands/)       | The task-dispatcher command template                          |
| [`agents/`](agents/)           | The planning, implementation, and verification agent templates |
| [`bin/junie`](bin/junie)       | Installer for Junie                                           |
| [`bin/claude`](bin/claude)     | Installer for Claude Code                                     |
| [`bin/lib/`](bin/lib/)         | Shared installer logic                                        |
| [`.env.example`](.env.example) | Optional model and pipeline settings                          |
| [`test.sh`](test.sh)           | End-to-end test runner for the Junie pipeline                 |

The files in [`commands/`](commands/) and [`agents/`](agents/) are tool-neutral templates. Each installer swaps `{{placeholder}}` tags for its tool's paths, tool names, and front matter when copying them over. Single-brace fields like `{time}` stay untouched because they're meant for the agents at runtime.

## License
MIT license. Go nuts, do whatever you want, just don't blame me if this breaks something.

See [LICENSE](LICENSE) for details.
