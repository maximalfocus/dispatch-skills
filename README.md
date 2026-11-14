# dispatch-skills

A management model for building software with a team of AI coding agents, packaged as Agent
Skills for Claude Code, Codex, Pi, and OpenCode.

One project gets one **dispatcher**, one **aide**, and a few **workers**:

| Role | Owns | Never |
|---|---|---|
| **Dispatcher** (`/dispatch`) | what is built next, in what order, by whom, and whether it lands; the user's one channel into the project | writes product code, runs acceptance, merges red |
| **Aide** (`/dispatch-aide`, 副手) | independent end-to-end acceptance on a real environment; the acceptance plan before work starts; test environments and test data | writes product code, judges its own work, merges |
| **Worker** (`/dispatch-worker`) | one issue, one worktree, one PR, the gate green | merges its own PR, talks to the user |

The model rests on five rules (see `CONSTITUTION.md`, Article 10):

1. **One project, one dispatcher, one aide.** Sibling projects (say, a macOS and a Windows
   edition) have sibling teams, each reporting to the user, coordinating through shared checks.
2. **Making and judging are separate.** Workers make; machine checks and the aide judge.
3. **Scripts own the mechanics, agents own the judgment.** Watching, wake-ups, start-up checks,
   capacity, environment locks, and head-pinned merges are scripts. A lesson that relied on an
   agent remembering is fixed in a script.
4. **The user's attention is the scarcest resource.** One ask at a time, with the exact screen
   ready; routine progress is batched; silence never hides a failure.
5. **Records, not recollection.** A team survives restarts and context compaction from GitHub
   state and a short board, not from a growing log.

## Flow

```text
dispatcher: plan → file issue ─────────────→ brief + start worker → watch → land at handed-back head
aide:                 └→ acceptance plan                                        └→ accept on real env
worker:                                      └→ implement → gate → PR → HANDBACK      PASS / FAIL→new issue
```

Hand-offs use fixed, greppable formats (`HANDBACK`, `ACCEPT-REQ`, `ACCEPT`, `ASK`, `XPROJ`),
defined once in `skills/dispatch/SKILL.md`. Works on its own, or with
[idd-skills](https://github.com/maximalfocus/idd-skills) for planning and implementation.

## Install

```sh
git clone https://github.com/maximalfocus/dispatch-skills
dispatch-skills/scripts/install.sh   # links skills into ~/.claude/skills and ~/.agents/skills
```

Then start a session in your project and say `/dispatch`.

## Design

`DESIGN.md` derives the model from its intent: ten intents, nine principles, the decision-rights
matrix, the lifecycle (inception, delivery, release), the quality strategy, the user-attention
model (Know / Decide / Do), flow metrics, continuity, sibling projects, what firstmate taught and
what it cost, and the contract for every mechanism script.

## Status

v0.1: roles, lifecycle, hand-off formats, constitution, and design. The mechanism scripts
(`DESIGN.md` §12) are tracked as issues; until each lands, the skills describe the same check done
by hand, exactly as its contract states.

## Evolution

The methodology changes only through `/dispatch-evolve`: a lesson from a real session either
passes `CONSTITUTION.md` and changes a skill or script, or nothing happens. There is no log.

## Acknowledgements

The supervision ideas — scripts owning mechanics, the human as default authority, decisions held
as durable records, head-pinned merges, never tearing down unlanded work — are learned from
[firstmate](https://github.com/kunchenguid/firstmate) by Kun Chen. The aide role, the acceptance
plan before work, and sibling-project coordination come from running dispatcher-and-aide teams on
real desktop and web projects. No code is copied from firstmate.

## License

MIT
