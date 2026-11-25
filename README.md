# Task Dispatcher

A multi-agent task pipeline for [Junie](https://junie.jetbrains.com/) and [Claude Code](https://code.claude.com/).

You write a short task description in Markdown and run `/task-dispatcher`. The dispatcher then sends the task through
three specialized sub-agents (planning, implementation and verification) and retries when verification fails. Each task's
progress is kept in a file in your project.

The cost is kept low by giving each phase only the reasoning effort it needs: planning uses high reasoning effort, while
implementation and verification run at low effort.

## Quick start

```shell
git clone https://github.com/estelsmith/llm-task-dispatcher.git
cd llm-task-dispatcher
bin/junie install
```

That's it. Any new Junie session can now use the `/task-dispatcher` command.

For Claude Code, run `bin/claude install` instead (or as well).

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

For large tasks, Planning and Implementation can also checkpoint with `PARTIAL` and loop with a fresh context up to
`max_continuations` times (default `5`) before moving to the next phase.

- **Task Dispatcher** ([`commands/task-dispatcher.md`](commands/task-dispatcher.md)): the slash command. It runs in your
  current session with your session's model. It's the only part that writes task state: it moves task files between
  folders, records the execution log and phase changes, counts retries and `PARTIAL` continuations, splits large
  implementation plans into step batches, re-spawns `Planning` or `Implementation` on `PARTIAL` checkpoints, and decides
  where the task goes next. It never edits code itself, and it stops instead of improvising if a required sub-agent
  isn't available.
- **Planning** ([`agents/task-dispatcher-planning.md`](agents/task-dispatcher-planning.md)): explores the codebase and
  reports a plan with target files, steps and acceptance criteria. It can also report research notes, and for large
  codebases it can checkpoint intermediate discovery (`PARTIAL`) before finalizing the plan.
- **Implementation** ([`agents/task-dispatcher-implementation.md`](agents/task-dispatcher-implementation.md)): makes the
  code changes from the plan, runs the project's checks, and reports what it changed. For large plans, it works through
  bounded step batches and returns `PARTIAL` checkpoints so each continuation starts with a fresh context.
- **Verification** ([`agents/task-dispatcher-verification.md`](agents/task-dispatcher-verification.md)): reviews the
  diff, runs tests and linters, and reports a `PASS` or `FAIL` verdict. On `FAIL`, the dispatcher sends the task back to
  implementation with the failure details.

The sub-agents never touch the task files; they only send a report back to the dispatcher.

## Using it

1. Write a task as a Markdown file in your project's pending folder:
   - Junie: `.junie/tasks/pending/my-task.md`
   - Claude Code: `.claude/tasks/pending/my-task.md`
2. Run the command in a session for that project:
   - Junie: `/task-dispatcher task=my-task.md`
   - Claude Code: `/task-dispatcher my-task.md` (in a local session in the **Code** tab of the Claude Desktop app)
3. Follow the task's progress in its file. The dispatcher uses these folders under the tasks directory:

```
tasks/
├── pending/      # New task requests you write
├── in-progress/  # Tasks being worked on, with their plan, log and attempts
├── completed/    # Tasks that passed verification
└── discovery/    # Research notes and in-progress planning checkpoints
```

To resume an interrupted task, re-run `/task-dispatcher` on the same task file (now in `in-progress/`); the dispatcher
picks up from the recorded `active_agent`, `attempt`, and any saved `PARTIAL` checkpoint instead of restarting from
scratch. You can also tune `max_retries` (default `3`) and `max_continuations` (default `5`) in the task's
frontmatter, or ask for chunked execution in `# Human Request`.

To reject a completed task, run the command with a reason, for example
`/task-dispatcher Reject my-task.md: the new endpoint is missing input validation`. The dispatcher sends it back to
planning or implementation, depending on the reason.

## Installer commands

[`bin/junie`](bin/junie) and [`bin/claude`](bin/claude) take the same sub-commands:

| Command     | What it does                                                              |
|-------------|---------------------------------------------------------------------------|
| `install`   | Installs the command and agents, or updates them after you pull changes   |
| `uninstall` | Removes only the files this repository installed                          |
| `doctor`    | Checks that the installed files are present and match the repository      |

Where the files go:

| Tool        | Command                                          | Agents             | Home override       |
|-------------|--------------------------------------------------|--------------------|---------------------|
| Junie       | `~/.junie/commands/task-dispatcher.md`           | `~/.junie/agents/` | `JUNIE_HOME`        |
| Claude Code | `~/.claude/skills/task-dispatcher/SKILL.md`      | `~/.claude/agents/` | `CLAUDE_CONFIG_DIR` |

Re-run `install` after updating this repository or changing your settings.

## Choosing models

The defaults are:

| Agent          | Junie            | Claude Code                |
|----------------|------------------|----------------------------|
| Planning       | `sonnet`, high   | `claude-sonnet-5-5`, high  |
| Implementation | `sonnet`, low    | `claude-sonnet-5-5`, low   |
| Verification   | `sonnet`, low    | `claude-sonnet-5-5`, low   |

The dispatcher itself has no model setting and uses your session's model. It's preferable to choose Sonnet 5.5 on low
effort, or Gemini 4 Hydrogen on low effort, when dispatching tasks.

To use other models, such as custom model profiles behind an AI gateway, copy [`.env.example`](.env.example) to `.env`,
uncomment the settings you want, and run `install` again. Set `JUNIE_DEFAULT_MODEL` / `JUNIE_DEFAULT_REASONING` or
`CLAUDE_DEFAULT_MODEL` / `CLAUDE_DEFAULT_EFFORT` to apply a default model or reasoning effort to all agents without a
per-agent override. `.env` is gitignored, and variables set in your shell take
precedence over it.

```shell
cp .env.example .env
bin/junie install
```

## Repository layout

| Path                           | Contents                                                      |
|--------------------------------|---------------------------------------------------------------|
| [`commands/`](commands/)       | The task-dispatcher command template                          |
| [`agents/`](agents/)           | The planning, implementation and verification agent templates |
| [`bin/junie`](bin/junie)       | Installer for Junie                                           |
| [`bin/claude`](bin/claude)     | Installer for Claude Code                                     |
| [`bin/lib/`](bin/lib/)         | Shared installer code                                         |
| [`.env.example`](.env.example) | Optional model settings                                       |

The files in [`commands/`](commands/) and [`agents/`](agents/) are tool-neutral templates. They contain `{{placeholder}}`
values that each installer fills in with its tool's values (paths, tool names, front matter) when it copies them.
Single-brace fields such as `{time}` are left as they are, because they're meant for the agents.
