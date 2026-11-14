# Design of the dispatch model

This document derives the model from its intent. The skills are the operational form; this is the
reasoning a change must stay consistent with (`CONSTITUTION.md`, Article 10).

## 1. Intent

The model was not designed on paper first. It grew out of one person running teams of AI coding
agents on real products, and the intent behind it can be read off what that person kept asking for:

| # | Intent | Evidence (what the user said or corrected) |
|---|---|---|
| I1 | **Ship fast**, with many agents in parallel | "push at full strength", "can you send more workers?" |
| I2 | **The user decides; the user is not the hands** | "one thing at a time, open the exact page", "let the aide do it, I don't want to do this" |
| I3 | **Quality is proven on the real product**, not argued in review | acceptance tests replace peer review; a problem found becomes a new issue |
| I4 | **Evidence, not guessing**; design before building | "don't work blindly, every improvement needs a basis", "design the key points before starting" |
| I5 | **Never idle, never silent** | "are you progressing?", "how do we prevent idling, without flooding the screen?" |
| I6 | **A controlled process**: requirements, issues, a tracker | "did you use the PRD and IDD? is there a list controlling progress?" |
| I7 | **Delegated improvement** toward the end customer's core needs | standing grant: anyone may improve what the design missed if it serves those needs |
| I8 | **Honesty**: designed ≠ run, reading ≠ pass | the habits carried into every project's rules |
| I9 | **Separate projects, separate reporting**, kept in parity | two editions, two dispatchers, "same features, same version" |
| I10 | **Replicable**: the same team shape for any new system | "start a new dispatcher and aide that work like your team" |

## 2. Principles (each answers one or more intents)

- **P1 Separation of duties** (I3, I8): the one who makes never judges. Workers make; the gate and
  the aide judge; the dispatcher decides whether it lands. This is independent verification and
  validation, applied to agents.
- **P2 Flow over utilization** (I1, I5): throughput comes from finishing, not starting. Limit work
  in progress, stop starting when the line is broken, and make every wait visible. Idle agents
  are fine; idle *work* (a hand-back nobody picks up) is the waste.
- **P3 Management by exception** (I2, I5): the user hears outcomes at stage boundaries and
  exceptions as they happen; everything else is batched. Silence must mean "on track", so a failure
  is never silent.
- **P4 Attention is a budget** (I2): every interaction with the user is classified and costed
  (section 6). The design goal is to drive the user's *Do* work toward zero and keep *Decide* work
  small and well-prepared.
- **P5 Shift acceptance left** (I3, I4): the aide writes how an issue will be accepted before a
  worker starts (acceptance-test-driven development). The worker builds to a known bar.
- **P6 Commander's intent** (I7): briefs carry *why* (the end customer's core needs) as well as
  *what*, so a worker can make a good local decision and a sound improvement without asking.
- **P7 Scripts own mechanics** (I5, I10): anything with one right answer is a script; agents
  spend judgment only where judgment is needed. A failure that came from forgetting is fixed by a
  script, never by a reminder.
- **P8 Records over recollection** (I6, I10): state lives in GitHub and a bounded board, so any
  session can be replaced without loss. Long-lived agent sessions are rotated, not trusted.
- **P9 Evidence-based change** (I4): the methodology and each project change only on evidence:
  metrics, acceptance results, traces. No metric, no claim.

## 3. Structure

```text
                 user (decides; stakeholder contact; the only one who can sign in)
                   │  stage reports · one ask at a time
     ┌─────────────┴─────────────┐            sibling project (own team, own reports)
     │        dispatcher         │◄──XPROJ──► dispatcher ─ aide ─ workers
     │ plan · brief · land ·     │
     │ report · own the board    │
     └──┬──────────────┬─────────┘
  Brief │              │ ACCEPT-REQ
        ▼              ▼
   workers (≤ WIP)    aide ── acceptance executors (one per environment, optional)
   one issue each     owns environments, test data, verdicts
        │                 ▲
        └─ HANDBACK ──────┘ (after land)
   scouts: research, documents, operations, stakeholder materials — reports, never PRs
```

Decision rights (R = does it, A = decides, C = consulted, I = informed):

| Decision | User | Dispatcher | Aide | Worker |
|---|---|---|---|---|
| Product scope, priorities between goals | A | R/C | C | – |
| Next slice, order, who works on it | I | A/R | C | – |
| Acceptance criteria and plan | I | A | R | C |
| How to implement an issue | – | C | – | A/R |
| Merge to the integration branch | grant | A/R (under grant) | – | – |
| Acceptance verdict | I | I | A/R | – |
| Release | A | R | C (PASS required) | – |
| Improvement beyond the design | I (in report) | A (under grant) | R/C | R/C |
| Anything destructive, irreversible, or credential-touching | A | – | – | – |

A *grant* is the user's dated, verbatim permission recorded in the project's rules; without one,
the dispatcher's A becomes an Ask.

## 4. Lifecycle

**Phase 0 — Inception** (answers I4, I6; most current projects skipped it). Done when:

1. Requirements source exists (PRD with the end customer's core needs as a short list).
2. Design baseline: architecture, design system or tokens, data and integration boundaries.
3. Acceptance strategy: which environments, which stacks need which E2E (section 5), risk tiers.
4. Environment readiness: the aide has run one smoke test end to end on every environment
   without the user's hands (sign-ins persisted, OS prompts cleared, test data area agreed).
5. Gates: the test command, required CI checks (including any sibling project's shared code), and
   the merge grant are recorded.
6. Team rules written: grants, data and credential limits, stakeholder rules, WIP limit.

**Phase 1 — Delivery** (flow). Each issue moves:
`ready → in progress → handed back → landed → accepted` (or `→ failed`, which files a new issue).
An issue is **Ready** when its acceptance criteria are observable, the aide's plan is attached,
its dependencies have landed, and the environment it needs exists. It is **Done** when the gate
is green, it has landed at the handed-back head, the aide has posted PASS (or NOT-RUN with a reason
the dispatcher accepted and reported), and user-facing docs are updated.

Classes of service: **expedite** (broken integration branch, a severe acceptance failure, a
release blocker — stops new starts until cleared), **fixed date** (release, demo), **standard**,
**improvement**. Expedite is the *andon cord*: anyone may pull it; the dispatcher must answer it.

**Phase 2 — Release.** Feature freeze for the candidate, aide release smoke on every target,
version and notes aligned with sibling projects, user approval, publish, and a short retrospective
whose proven lessons go to the project rules or `/dispatch-evolve`.

## 5. Quality strategy

| Layer | Who | When | Blocks |
|---|---|---|---|
| Unit and integration tests | worker | in the PR | the merge (gate) |
| Required CI checks, incl. sibling shared-code builds | machine | on every PR | the merge |
| Acceptance against the plan | aide | after land, per issue | Done; files new issues |
| Exploratory session (charter-based) | aide | once per milestone | nothing; files issues |
| Release smoke on every target | aide | per release | the release |
| Escaped-defect review | dispatcher + aide | when the user or stakeholder finds a bug | changes the plan template |

Acceptance depth follows risk: **tier 1** (money, data, security, irreversible writes, core
flows) gets the full plan on the real environment every time; **tier 2** gets the core path;
**tier 3** (copy, styling) is covered by visual checks and the milestone exploratory session.

## 6. The user's attention

Every interaction is one of three kinds:

- **Know** — stage reports and exceptions. Outcome first, plain words, no internal ids.
- **Decide** — a choice only the user can make. One at a time, prepared as an Ask with the
  smallest compliant option first and a recommendation.
- **Do** — a physical act only the user can perform (sign in, approve an OS prompt, upload under
  their account). The design target is zero: the aide does everything it is allowed to; what
  remains is scheduled into one prepared session ("three sign-ins, pages already open, in order")
  before it blocks work, and presented one step at a time inside that session.

The dispatcher measures asks per day and time-to-answer, and reports the Do count; a rising Do
count is a design defect to remove, not a cost to accept.

## 7. Flow metrics (reported briefly at each stage)

- **Throughput**: issues accepted per day. **Lead time**: issue filed → accepted.
- **First-pass acceptance**: share of issues that PASS the first time. Low means unclear criteria
  or a weak gate.
- **Escaped defects**: bugs found by the user or stakeholder after PASS. Each one changes the
  acceptance plan or the gate.
- **Wait time**: minutes a hand-back or verdict waited for the dispatcher. The target is minutes,
  not hours; anything else means the watcher failed.
- **Asks**: Decide and Do counts per day.

## 8. Continuity

The dispatcher is a long-lived session and will compact or die. So: the board is regenerated from
GitHub, open asks are issues labelled `ask`, grants live in the project rules, and at each milestone (or when
the context is large) the dispatcher **rotates**: it writes a short handover from those records and
a fresh session continues. A rotation that loses anything is a bug in the records, not in the new
session.

## 9. Sibling projects

Sibling projects (two editions of one product, a frontend and a backend owned separately) each
have a full team and report to the user separately. Between them:

- **Shared code has one owner**; the other side's required checks build it, so a breaking change
  fails before it lands.
- **Parity** is a user rule in both projects' rules; a feature issue in one files its twin in the
  other through an XPROJ message.
- **Versions** are announced by whichever side releases first; neither bumps silently.
- Environments are separate or locked; one side never drives the other's machines or workers.

## 10. What this design deliberately leaves out

- A hierarchy above the dispatcher (no "dispatcher of dispatchers"). The user is the integrator.
- Peer-review rounds that hold PRs open. Machine gates and acceptance replace them; a project may
  opt back in.
- An unlimited worker count. WIP is a recorded limit the user can raise.
- Per-vendor adapters in the skills. Runtime details live in scripts.

## 11. Lessons taken from firstmate, and costs avoided

[firstmate](https://github.com/kunchenguid/firstmate) proved most of the supervision ideas this
model uses. Its history (about 1,200 commits in five months) also shows what they cost when left
unbounded; each row is a rule here.

| firstmate evidence | Rule in dispatch-skills |
|---|---|
| `bin/` grew from 8.7k to 160k lines; 63% of commits are fixes | A hard budget: ≤ 16 scripts, ≤ 2,500 script lines in total, enforced by the size gate |
| ~90 fixes from reading vendor terminal screens to guess agent state | State comes only from structured signals: hook-written files, exit codes, PR and issue state. Never parse a terminal screen; prevent first-run dialogs by configuration instead of detecting them |
| Always-loaded rules peaked at 18k words; the 9k cap came late and was exceeded 28 more times | Skill caps enforced in CI from day one; a cut deletes rules, it does not move them elsewhere |
| 18 harness adapters, 13 multiplexer backends, side projects (voice, social bots) | Support Claude Code and Codex, with tmux or herdr, through one small runtime file; everything else is out of scope |
| Scripts that parsed prose to find authorization or "complete" answers | Scripts check facts (a SHA matches, a check is green, a file exists); meaning is judged by agents and the user |
| "No concurrency cap", then memory, quota, spend, and thermal limits added after incidents | A fixed WIP limit by default (3), raised only by a recorded grant |
| Alarm-noise fixes from the first week to the last | Every notification needs a decision and carries a dedupe key; a repeated alarm for the same key is suppressed until its state changes |
| "Done" means the PR gate passed; no test environments, data, or stakeholder in its contract | Done needs the aide's acceptance on a real environment; the aide owns environments and test data |
| One funnel: every outcome passes through one first mate and a tree of secondmates | Sibling projects have sibling teams that each report to the user |
| Two reverts against 760 fixes; a deprecated shim kept 83 days | Deletion counts as progress; a superseded mechanism is deleted in the same change |

## 12. Mechanics contracts

Each mechanism is one small bash script with a test; firstmate's version of each is cited so the
reason survives. "Fact" means a file, an exit code, or GitHub state; no script reads a terminal
screen or prose to decide anything (Article 10.5).

| Script | Contract | Why (firstmate evidence) |
|---|---|---|
| `watch` (`skills/dispatch/scripts/watch.sh`) | loop every 15 s; touch a beacon; queue `handback` and `verdict` only for `HANDBACK`/`ACCEPT` comment lines whose author has write access (`author_association` in `DISPATCH_TRUSTED_AUTHORS`, default OWNER/MEMBER/COLLABORATOR; anyone else's line is noted once on stderr, never a wake), `head` when a handed-back PR's live head moved, `idle` for a worker idle ≥ 5 min with no hand-back just before, `error` after 20 failed GitHub polls; queue rows `epoch, seq, kind, key, payload`, each key once; one watcher per project, reclaimed under a steal mutex; exit 0 with wakes, 124 quiet, 3 already running | swallowed and doubled wakes, alarm floods; a public commenter forging a hand-back |
| `drain` (`skills/dispatch/scripts/drain.sh`) | print queued wakes (124 when empty); `--ack-through <seq>` removes them only after they were handled, so a crash re-handles rather than loses | a finished worker's last event was absorbed and missed |
| `turnend-guard` | Stop hook: if work is in flight (worker state files exist) and the watcher is not healthy (lock pid alive, beacon younger than 5 min), block the stop (exit 2) with the repair line; at most 3 blocks, then allow loudly; inert inside worker worktrees | sessions sat blind for hours after a turn ended unarmed |
| `autoarm` | Claude Code: an async Stop hook runs the watcher in the foreground and exits 2 with the wake reason, which wakes the idle session. Codex: a blocking `watch --once --seconds 180` checkpoint call instead | the same blind-turn incidents |
| `start` | create a linked worktree; pre-register folder trust in the agent's config; launch the agent with the Brief and per-worker hooks that write `busy`/`idle`/`turn-ended` to the worker's state file; write `<id>.meta`; confirm `busy` within 60 s or fail; refuse over the WIP limit with exit 75 (queued) | workers wedged on a trust dialog; surplus workers burning turns |
| `inbox` | messages are files `NNN.msg` (atomic rename, never reused); the worker's terminal receives one constant line naming the inbox; re-ring every 90 s up to 3 times, then one wake; never ring a dead or busy session | text typed into terminals was lost or swallowed |
| `envlock` | `acquire|release|status <env>`; holder file `pid, role, issue, since`; others get exit 75; reclaim only when the holder's pid is provably dead | (new here) two holders driving one machine |
| `land` | `land <pr> --head <sha>`: re-read live state; refuse unless open, not draft, mergeable, live head = `<sha>`, and every required check reported green at that head; then squash-merge pinned to the head and delete the branch | a required check that never reported counted as passing |
| `teardown` | remove a worktree only when its HEAD is on a remote ref, contained in the merged PR's head, or identical in content to the base; a scout only when its report exists; otherwise refuse | unlanded work must never be discarded |
| `board` | render ≤ 80 lines from `gh` issue/PR lists, worker state files, and open `ask` issues; never store progress of its own | a board that stored state drifted from the truth |
| `subagent-guard` | PreToolUse hook for the dispatcher: deny the agent tool's built-in subagent/task delegation, so all work goes through `start` and stays visible | delegated work escaped every guard; supervision down 73 min |

Supported runtimes: Claude Code and Codex, in tmux or herdr, through one small runtime file. Worker
permissions follow the mode the user configured; the scripts never add a permission-bypass flag.
