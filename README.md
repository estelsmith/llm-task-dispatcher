# Task Dispatcher

A multi-agent task pipeline for [Junie](https://junie.jetbrains.com/) and [Claude Code](https://code.claude.com/).

You write a short task description in Markdown and run `/task-dispatcher`. The dispatcher then sends the task through
three specialized sub-agents (planning, implementation and verification) and retries when verification fails. Each task's
progress is kept in a file in your project.

The cost is kept low by giving each phase only the model it needs: a stronger model plans, and a cheaper model writes and
checks the code.

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
 │       Moves task files, writes logs, counts retries, routes work        │
 │              Uses your session's model and reasoning level              │
 └─────────────────────────────────────────────────────────────────────────┘
           │ spawn                    │ spawn                    │ spawn
           ▼                          ▼                          ▼
 ┌───────────────────┐ plan ┌───────────────────┐ code ┌───────────────────┐
 │     Planning      │ ───▶ │  Implementation   │ ───▶ │   Verification    │
 │ sonnet-5.5 medium │      │  haiku-5.5 high   │      │  haiku-5.5 high   │
 └───────────────────┘      └───────────────────┘      └───────────────────┘
                                      ▲                     │         │
                                      │       FAIL          │         │ PASS
                                      └─────────────────────┘         ▼
                                     (up to max_retries times)   completed/
```

- **Task Dispatcher** ([`commands/task-dispatcher.md`](commands/task-dispatcher.md)): the slash command. It runs in your
  current session with your session's model. It's the only part that writes task state: it moves task files between
  folders, records the execution log and phase changes, counts retries, and decides where the task goes next. It never
  edits code itself, and it stops instead of improvising if a required sub-agent isn't available.
- **Planning** ([`agents/task-dispatcher-planning.md`](agents/task-dispatcher-planning.md)): explores the codebase and
  reports a plan with target files, steps and acceptance criteria. It can also report research notes.
- **Implementation** ([`agents/task-dispatcher-implementation.md`](agents/task-dispatcher-implementation.md)): makes the
  code changes from the plan, runs the project's checks, and reports what it changed.
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
└── discovery/    # Research notes reported by the planning agent
```

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

| Agent          | Junie              | Claude Code                  |
|----------------|--------------------|------------------------------|
| Planning       | `sonnet`, medium   | `claude-sonnet-5-5`, medium  |
| Implementation | `haiku`, high      | `claude-haiku-5-5`, high     |
| Verification   | `haiku`, high      | `claude-haiku-5-5`, high     |

The dispatcher itself has no model setting and uses your session's model. It's preferable to choose Haiku 5.5 on medium
effort when dispatching tasks.

To use other models, such as custom model profiles behind an AI gateway, copy [`.env.example`](.env.example) to `.env`,
uncomment the settings you want, and run `install` again. `.env` is gitignored, and variables set in your shell take
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
