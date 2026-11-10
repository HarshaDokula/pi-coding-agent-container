# Subagents

> **Purpose:** Delegate independent work to child pi processes and understand the cost/isolation trade-offs.
>
> Back to [README](../README.md) · [documentation index](README.md).


[`@tintinweb/pi-subagents`](https://pi.dev/packages/@tintinweb/pi-subagents) adds
Claude Code-style delegation: the `Agent` tool (foreground or background),
`SubagentWorkflow` (deterministic fan-out scripts), `get_subagent_result`,
`steer_subagent`, and the `/agents` fleet UI.

It is a **declared pi package**, not a per-run `-e` load: installing it writes a
`settings.json` entry plus `agent/npm/` in the data dir, so every later run of
that instance has it and instances that never opted in stay lean.

```bash
make subagents-setup                       # one-time, per data dir (needs network)
make subagents-setup PROJECT_NAME=agent1   # a specific instance
make subagents-setup SUBAGENTS_VERSION=0.23.0
```

The install runs `pi install` inside a throwaway container from this image, so
npm resolves against the pinned pi (`PI_VERSION`). Idempotent; a version bump
drops the previous declaration first.

## When to delegate (and when not to)

Each subagent is a **separate pi process with its own context window**. You get
isolation and parallelism, not free speed: tokens are spent per child, memory is
~200-400 MB each (against `pids_limit: 150`), and nothing is shared except what
you merge back.

| Use a subagent when | Keep it in the main agent when |
|---|---|
| 3+ **independent** units with a merge step ("summarise these 6 modules") | steps depend on each other (plan → implement → verify) |
| the work would **blow the main context** (repo-wide research, long sweeps) | it is a one-file edit |
| you want **parallel review** from different angles | you need the reasoning visible turn by turn |
| a job is **long-running** and you want to keep working meanwhile (`background`) | the task is exploratory and you are still deciding |

Rule of thumb: if you can write the job as *"N independent tasks + how to
combine them"*, delegate. If it reads as a sequence, don't.

## Where things live

- Custom agents: `<PI_DATA_DIR>/agent/agents/<name>.md` (inside the container
  that is `~/.pi/agent/agents/`) or `.pi/agents/<name>.md` in the workspace.
  Frontmatter picks the model, thinking level, and tool scope per agent.
- Subagents run **inside the same container**, so they inherit its egress
  allowlist, read-only root FS, secret redaction, and the same provider keys.
  Delegation widens what the orchestrator can reach (each child has its own
  `tools:`), which is why it stays opt-in.
- Child sessions are persisted like any other; remove the package with
  `pi remove npm:@tintinweb/pi-subagents`.
