# dispatch-skills

A management model for building software with a team of AI coding agents, packaged as Agent
Skills for Claude Code, Codex, Pi, and OpenCode.

One project gets one **dispatcher**, one **aide**, and a few **workers**:

| Role | Owns | Never |
|---|---|---|
| **Dispatcher** (`/dispatch`) | what is built next, in what order, by whom, and whether it lands; the only role that asks the user for anything | writes product code, runs acceptance, merges red |
| **Aide** (`/dispatch-aide`, 副手) | independent end-to-end acceptance on a real environment; the acceptance plan before work starts; test environments and test data; required and resident for all of delivery | writes product code, judges its own work, merges, asks the user anything |
| **Worker** (`/dispatch-worker`) | one issue, one worktree, one PR, the gate green | merges its own PR, talks to the user |

The model rests on seven rules (see `CONSTITUTION.md`, Article 10):

1. **One project, one dispatcher, one aide.** Both are required and resident for the whole of
   delivery; automated suites are the aide's tools, not a replacement for it. A second aide,
   in its own lane, joins only when the user asks for one. Sibling projects
   (say, a macOS and a Windows edition) have sibling teams, each reporting to the user,
   coordinating through shared checks.
2. **Making and judging are separate.** Workers make; machine checks and the aide judge.
3. **Scripts own the mechanics, agents own the judgment.** Watching, wake-ups, start-up checks,
   capacity, environment locks, and head-pinned merges are scripts. A lesson that relied on an
   agent remembering is fixed in a script.
4. **The user's attention is the scarcest resource.** One ask at a time, with the exact screen
   ready; routine progress is batched; silence never hides a failure. The user may speak to the
   dispatcher or the aide; only the dispatcher asks the user for anything, and a worker's
   questions reach the user only through the dispatcher.
5. **Facts, not screens.** State comes from structured signals — hook-written files, exit codes,
   PR and issue state — never from parsing a terminal screen or prose.
6. **Domain-neutral.** The skills and scripts carry no business-domain or vendor-system
   knowledge; that lives in each project's rules, and the model only gives it a place.
7. **Records, not recollection.** A team survives restarts and context compaction from GitHub
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
real desktop and web projects. No code is copied from firstmate. Briefing, standing orders,
piloting, and earning unattended running draw on
[pstack](https://github.com/cursor/plugins/tree/main/pstack) by Lauren Tan (MIT), restated rather
than copied.

## License

MIT
