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

The user may also speak to the aide directly; what the aide records goes back to the dispatcher
(below).

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

**Why the aide is required and resident.** A team of only a dispatcher and workers has nobody
independent to say whether what landed works: the dispatcher would judge its own landing (P1), and
"the gate is green" would quietly become "done". Automated end-to-end suites do not remove the
role; they are the aide's tools, and someone independent of the makers still has to own the
environments, run the suites against the landed head, judge what a red or flaky result means, and
clean up the test data. The aide is also resident, not started per request, because its work spans
the issue: it writes the plan before a worker starts (P5), holds environment locks and sign-ins
between runs, and must find its own test data to delete it. Its *execution* scales; the role does
not: first the project's own end-to-end suite, then scripted checks the aide runs, then acceptance
executors (one per environment). Only the aide gives a verdict.

**When the user speaks to the aide.** The user may talk to the dispatcher or the aide, and often
will talk to the aide about an environment or a result. The aide answers, records what the user
said (verbatim, dated) on the issue, and tells the dispatcher, so the records stay whole. A
decision that belongs to the dispatcher — scope, order, acceptance criteria, landing — the aide
hands over and does not make: a direct conversation is not a second path around the decision
rights. Anything the aide needs *from* the user still becomes an Ask through the dispatcher: there
is one ask queue, so the user never has two open asks from one project.

## 4. Lifecycle

**Phase 0 — Inception** (answers I4, I6; most current projects skipped it). Done when:

1. Requirements source exists (PRD with the end customer's core needs as a short list).
2. Design baseline: architecture, design system or tokens, data and integration boundaries.
3. Acceptance strategy: which environments, which stacks need which E2E (section 5), risk tiers,
   and the model family the aide judges on.
4. Environment readiness: the aide's verification kit (section 5) has run end to end on every
   environment without the user's hands (sign-ins persisted, OS prompts cleared, test data area
   agreed).
5. Gates: the test command, required CI checks (including any sibling project's shared code), and
   the merge grant are recorded; each role's guard is installed and seen denying one forbidden act
   (`role-guard --probe <role>`).
6. Team rules written: grants, data and credential limits, stakeholder rules, WIP limit,
   standing orders.

**Phase 1 — Delivery** (flow). Each issue moves:
`ready → in progress → handed back → landed → accepted` (or `→ failed`, which files a new issue).
An issue is **Ready** when its acceptance criteria are observable, the aide's plan is attached,
its dependencies have landed, and the environment it needs exists. It is **Done** when the gate
is green, it has landed at the handed-back head, the aide has posted PASS (or NOT-RUN with a reason
the dispatcher accepted and reported), and user-facing docs are updated.

**The Brief is the dispatcher's product.** A worker cannot ask a question mid-task without
stopping, and cannot see its siblings, so the Brief carries everything it would otherwise guess:
the WHY, the acceptance bar, pointers plus every upstream Hand-back it depends on in full, what it
may write, what it must never do, a timebox that turns a stall into a hand-back, and the project's
standing orders. A field the dispatcher cannot fill is a sign the issue is not scoped yet, so it is
not Ready. Standing orders exist because instructions given in conversation decay each time an
agent restarts or compacts; written once as numbered lines in the project's rules and carried in
every Brief, they cost nothing to repeat.

**Pilot, then fan out; earn unattended running.** The first issue of a project runs alone through
brief, land, and acceptance. It tests the Brief template, the gate, the acceptance plan, and the
issue size while a flaw costs one worker, not three. Running while the user is away is the last
step of a trust curve, not the default: the user's dated grant in the project's rules must allow
it, and it is earned by four conditions: one issue run end to end while the user watched, an aide
that drives the product without the user, a stop-the-line at every stage, and every failure that
repeated in earlier runs turned into a check. A loop that has not earned trust only produces
unchecked work faster.

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

**The verification kit** is what makes acceptance repeatable instead of heroic. Phase 0 ends with
a project-local skill the aide owns that launches the product to a usable state, checks the
instance is worth driving, drives it with the project's real handles, captures evidence of the
real user path and its side effects, and cleans up without destroying that evidence; plus a
feature map that says, per user-facing feature, how a user reaches it and which end state proves
it. It is proven by a full run before the environment is declared ready, and reconciled with the
product at each milestone, because a map that drifts from the product passes things that broke.
The kit is test tooling in the aide's ownership, never product code; the product's own suite stays
the workers'.

**What a verdict may claim.** Each step records how it ran: driven live, or the project's suite at
the requested head. Reading code, a type check, or green CI is an input, never a pass. A FAIL needs
a failure shown at the requested head; a defect the base already had is filed separately unless
the change reproduces it or makes it newly reachable, and for tier 1 the core scenario also runs
on the previous accepted head so a regression is told from an old defect (where none exists — a
project's first issue — the base head stands in and is recorded). An executor's result that
does not name its head and method does not count. Where more than one vendor is available, the
aide and its executors run on a model family the workers are not on, because a judge that shares
the maker's blind spots is a weaker judge.

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
count is a design defect to remove, not a cost to accept. The user may start a conversation with
the dispatcher or the aide (section 3); only the dispatcher sends Asks.

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

The dispatcher and the aide are long-lived sessions and will compact or die. So: the board is
regenerated from GitHub, open asks are issues labelled `ask`, grants live in the project rules,
acceptance plans and verdicts are issue comments, and at each milestone (or when the context is
large) each of them **rotates**: it writes a short handover from those records and a fresh session
continues. The aide's handover also names the environment locks it holds and the test data it has
not yet deleted. A rotation that loses anything is a bug in the records, not in the new
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

## 11. Lessons from firstmate, pstack, and agent-governance-toolkit, and costs avoided

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

[pstack](https://github.com/cursor/plugins/tree/main/pstack) (Lauren Tan, MIT) runs fleets of
coding agents through playbooks for orchestration, autopilot queues, and landing. Its ideas are
restated here in this model's terms; no text is copied.

| pstack evidence | Rule in dispatch-skills |
|---|---|
| Orchestrate's brief template until October 2026: if the coordinator cannot fill a field, the unit is not scoped; upstream reports are pasted in full because a worker cannot see its siblings | The Brief carries CONTEXT, FORBIDDEN, TIMEBOX, and STANDING; an unfillable field means not Ready |
| Its standing-orders register until October 2026: carried verbatim at every spawn and resume, because directives decay between restarts and each lost one costs the user a turn | Standing orders in the project's rules, carried verbatim in every Brief and restart |
| A pilot unit through the whole path before fan-out, so a flawed brief costs one agent | The first issue runs alone; the template is fixed before more workers start |
| The overnight guide: trust is earned before a loop runs alone | Unattended running needs a recorded grant and the four conditions in section 4 |
| create-verification-skill: a project-local skill that launches, health-checks, drives, evidences, and cleans up the app, with a per-feature map, proven by one full run; maintain-verification-skill reconciles the map with the app | The aide's verification kit is the Phase 0 deliverable and is reconciled at each milestone (section 5) |
| Orchestrate: a PR's verifier is not its author and sits on another model family; shipping: only a non-author's verdict counts; Autopilot: a PR is blocked only by a problem it provably causes (a red run at its head, or a doc line it made wrong), and a defect the base already had blocks only when the change reproduces it or makes it newly reachable | Verdict rules in section 5; the aide runs on a model family apart from the workers' where one is available |
| Swarm: a lane result missing its SHAs or method is dropped and re-run once; a gap is not a pass | An executor result without its head and method is re-run once, then NOT-RUN |
| Autopilot merge prep: retest when the base changed what the patch touches, depends on, or is called by, and otherwise do not rebase for every move of trunk | `land` refuses with "update needed" when the base changed a file the PR also changes; the dispatcher asks for an update when the base changed code the PR calls or that calls it; the worker merges the base in (no rebase, no force-push); otherwise no update |
| Autopilot: loosening a gate needs a verifier's proof plus a fresh countersign, since whoever owns the queue benefits from green; a disabled check always comes back out | A gate-loosening PR needs the aide's evidence; a disabled check needs an issue to restore it; `land` refuses declared gate files unless the dispatcher names an open issue carrying that evidence |
| Earlier Orchestrate: retry by failure mode, two retries then replan; a late worker is reconciled against current state; every spawned child is accounted for | Retry by cause in the dispatcher's resume step; the board shows every worker's end |
| Earlier Orchestrate: once roughly 70% of the budget is spent, spawn nothing more and finish the verified work | Fixed-date work stops starting once about 70% of its time is gone |
| In October 2026 it deleted ~3,000 lines of orchestration scripts, including the bookkeeping store that mirrored forge state | GitHub stays the authority; scripts check facts and keep no second copy of the project |

[agent-governance-toolkit](https://github.com/microsoft/agent-governance-toolkit) (Microsoft, MIT)
checks each agent action with deterministic code before it runs. It is runtime middleware, not a
delivery model, so only its principles carry over.

| agent-governance-toolkit evidence | Rule in dispatch-skills |
|---|---|
| Its README: prompt-level safety ("please follow the rules") is not a control surface | Each role's Never items that a script can recognise are denied by `role-guard`, a PreToolUse hook, not left to prose (Article 10.3) |
| Its Claude Code hook exits 2 when policy evaluation fails; its LIMITATIONS: with no policies loaded the default is allow, and a dashboard still says "governed" | `role-guard` denies on a missing config or unknown role; `start` confirms a worker only after its guard denied a probe, and Phase 0 sees every role's guard deny once |
| Its identity spec: scope chains only narrow; delegation never grants more than the delegator holds | Article 8: delegation only narrows, from the user's rules to a Brief to a scout |
| A 408-line LIMITATIONS document: it governs actions, not reasoning; its audit records attempts, not outcomes | Section 13 states this model's own limits |
| Cryptographic agent identity, trust scores, privilege rings, a Merkle audit chain, SDKs in five languages; its README says most teams run only policy enforcement and audit logging, and its LIMITATIONS says the full stack may be overkill for simple use cases | Not adopted: every role posts as the user's gh login and GitHub is the record; generic command safety (destructive commands, secrets, network) is left to such a tool run alongside |

## 12. Mechanics contracts

Each mechanism is one small bash script with a test; firstmate's version of each is cited so the
reason survives. "Fact" means a file, an exit code, or GitHub state; no script reads a terminal
screen or prose to decide anything (Article 10.5).

| Script | Contract | Why (firstmate evidence) |
|---|---|---|
| `watch` (`skills/dispatch/scripts/watch.sh`) | loop every 15 s; touch a beacon; queue `handback` and `verdict` only for `HANDBACK`/`ACCEPT` comment lines whose author is trusted — the login `gh api user` reports (or `DISPATCH_TRUSTED_LOGINS`, and a watcher that cannot learn its own login without that list exits 1 rather than run deaf) or an `author_association` in `DISPATCH_TRUSTED_AUTHORS` (default OWNER/COLLABORATOR) — anyone else's line is noted once on stderr, never a wake; `head` when a handed-back PR's live head moved, `idle` for a worker idle ≥ 5 min with no hand-back just before, `error` after 20 failed GitHub polls; queue rows `epoch, seq, kind, key, payload`, each key once; one watcher per project, reclaimed under a steal mutex; exit 0 with wakes, 124 quiet, 3 already running | swallowed and doubled wakes, alarm floods; a public commenter forging a hand-back |
| `drain` (`skills/dispatch/scripts/drain.sh`) | print queued wakes (124 when empty); `--ack-through <seq>` removes them only after they were handled, so a crash re-handles rather than loses | a finished worker's last event was absorbed and missed |
| `turnend-guard` (`skills/dispatch/scripts/turnend-guard.sh`) | Stop hook: if work is in flight (worker records exist) and the watcher is not healthy (lock pid alive, beacon younger than 5 min, waited for up to 5 s because `autoarm` starts it at the same Stop), block the stop (exit 2) with the repair line, which is "handle the waiting wakes" when wakes are queued; at most 3 blocks in a row, then allow loudly; inert inside worker worktrees and in a session whose `DISPATCH_ROLE` is not the dispatcher's | sessions sat blind for hours after a turn ended unarmed |
| `autoarm` (`skills/dispatch/scripts/autoarm.sh`) | Claude Code: a Stop hook with `asyncRewake` (a plain async hook does not wake an idle session) runs the watcher in the foreground and exits 2 with the wakes, which wakes the idle session; it stops the watcher before the hook's own timeout and wakes once to re-arm, so an idle session is never left unarmed; a watcher that fails wakes with the reason, 3 times at most. Codex: `autoarm --checkpoint`, a blocking `watch --seconds 180` call the dispatcher makes before it would stop. `autoarm --hooks` prints the dispatcher's hooks (this, `turnend-guard`, `role-guard`) | the same blind-turn incidents |
| `start` (`skills/dispatch/scripts/start.sh`, with `runtime.sh`) | read the Brief's `ISSUE`, `BASE`, `WORKTREE`, `TIMEBOX` (`90m`, `2h`) and `LIMITS write= deny=` fields, and fail on one it cannot read; create a linked worktree; pre-register folder trust in the agent's config; write the worker's role and LIMITS paths into its `role-guard` config; launch the agent with the Brief and per-worker hooks that write `busy` (a prompt was submitted), `idle` (the turn ended), or `ended` (the session is over) to the worker's state file; write `<id>.meta` with the Brief's TIMEBOX; open it in a workspace (herdr) or window (tmux) of its own, never a split of the dispatcher's screen; confirm `busy` within 60 s and a denied `role-guard --probe worker`, or fail and leave no record; name every session `<prefix>-<part>` (`-dispatch`, `-aide`, `-aide2`, the issue number for a worker, `scout-<number>` for a scout; the prefix is the `Session-prefix:` rule line or the main checkout's directory name; `start --name <role>` names the session it runs in; in herdr the name is the workspace's, one workspace per session, so the agent list and the space list show the name and nothing else); refuse over the WIP limit (`WIP-limit:` rule line, default 3) with exit 75 (queued); the watcher then wakes `overdue` once per worker and TIMEBOX when a busy worker passes it with no new push (a new push restarts the TIMEBOX) | workers wedged on a trust dialog; surplus workers burning turns |
| `inbox` (`skills/dispatch/scripts/inbox.sh`) | messages are files `NNN.msg` (atomic rename, never reused); the worker's terminal receives one constant line naming the inbox; the worker acknowledges with `inbox.sh ack <NNN>`; re-ring every 90 s up to 3 times, then one wake; never ring a busy session (it is rung when its turn ends) or a dead one (one wake at once); `watch` runs the rings on every poll | text typed into terminals was lost or swallowed |
| `envlock` (`skills/dispatch/scripts/envlock.sh`) | `acquire|release|status <env>`; holder file `pid, role, issue, since`, in the project's one state dir so every worktree sees it; the holder is the calling session (the nearest ancestor that is not a shell) or `--pid`; others get exit 75; only the holder releases; reclaim only when the holder's pid is provably dead; an unreadable lock counts as held | (new here) two holders driving one machine |
| `land` (`skills/dispatch/scripts/land.sh`) | `land <pr> --head <sha>`: re-read live state; refuse unless open, not draft, mergeable, live head = `<sha>`, and every required check reported `SUCCESS` at that head (required names are GitHub's for the base branch plus the project's `Required-checks:` rule line; a name that never reported, a skipped or neutral one, and a base with no known required check all refuse); refuse with "update needed" when the integration branch moved past the PR's merge base and changed a file the PR also changes (a fact the script can check; whether the base changed code the PR calls or that calls it is the dispatcher's judgment before calling `land`), and otherwise require no update; the worker repairs it by merging the base into its branch, never by a rebase or force-push, and hands back the new head; refuse a PR touching a path listed on the project's `Gate-files:` line unless the dispatcher passes `--gate-change <issue>` naming an open issue where the aide recorded evidence that the gate still guards (and, for a disabled check, the issue to restore it; the script checks that the issue is open and holds a comment, the dispatcher that the evidence is enough); then squash-merge pinned to the head and delete the remote branch; exit 0 landed, 2 refused with one line per reason, 1 unreadable | a required check that never reported counted as passing |
| `teardown` (`skills/dispatch/scripts/teardown.sh`) | remove a worktree only when its HEAD is on a remote ref, contained in the merged PR's head (`--pr`), or identical in content to the base (`--base`); a scout (`--scout --report <file>`) only when its report exists outside the worktree, keeping its branch when the HEAD is nowhere else; otherwise refuse (exit 2); never forced, so uncommitted or untracked files refuse too; `--worker <id>` clears that worker's state files and closes the terminal `start` opened for it, so finished sessions do not pile up; a refusal closes nothing | unlanded work must never be discarded |
| `board` (`skills/dispatch/scripts/board.sh`) | render ≤ 80 lines from `gh` issue/PR lists, worker state files, and open `ask` issues, to the screen and to `.dispatch/board.md` (overwritten); list each worker started since the last stage report (from the start log `start` appends to; `board --stage-reported` marks the report) with its end, the first that holds: replaced (a later start for the issue), landed (its branch's PR merged), running (records present, session busy or idle), absorbed (records gone, issue closed); flag any that is none of these; never store progress of its own | a board that stored state drifted from the truth |
| `role-guard` (`skills/dispatch/scripts/role-guard.sh`) | PreToolUse hook for every role, configured per session by `start` (or the project settings for the dispatcher and aide, each session launched with `DISPATCH_ROLE`) with the role and its paths (`role=`, `root=`, `write=`, `deny=`); it judges the file tools and the text of a shell command, not what a script does when run: deny the dispatcher the agent tool's built-in subagent/task delegation, a comment with an `ACCEPT` verdict line (a line starting `ACCEPT `, as `watch` reads it; `ACCEPT-REQ` stays its own), and a write outside the paths its config names (the board, Briefs, the project's rules); deny a worker `gh pr merge`, a force-push, a rebase, a write outside its Brief's LIMITS paths, and a comment with an `ACCEPT` line; deny the aide `gh pr merge` and a write outside its kit and the evidence area the project rules allow; deny (exit 2) when the config is missing or unreadable or the role is unknown, never allow by default; `role-guard --probe <role>` feeds one forbidden act through each role-guard hook in the session's settings and passes only if one denied it as that role (so a missing hook, a matcher that misses the tool, a missing config, and another role's config all fail), and `start` confirms a worker only after its probe was denied | delegated work escaped every guard; supervision down 73 min. agent-governance-toolkit: a guard with no policy loaded allows everything while looking installed |

Supported runtimes: Claude Code and Codex, in tmux or herdr, through one small runtime file
(`skills/dispatch/scripts/runtime.sh`). Worker permissions follow the mode the user configured; the
scripts never add a permission-bypass flag. Claude Code takes a worker's hooks per session. Codex
runs only hooks its user has reviewed and trusted, so its hooks are user-level and installed once
(`start.sh --codex-hooks` prints them); until then `start` refuses a Codex worker.

## 13. Known limits

- **Guards are tripwires, not a sandbox.** `role-guard` runs as the same OS user as the agents it
  checks; an agent with a shell can reach around a pattern (a script it writes, an alias). It
  catches drift and mistakes. Isolation against a determined agent is the runtime's job: a
  sandbox, a separate account.
- **One identity for every role.** Workers, the aide, and the dispatcher post as the same gh
  login, so GitHub cannot tell an aide's `ACCEPT` line from anyone else's. `role-guard` denies a
  worker or the dispatcher posting one where it can see it; past that, a verdict is trusted
  because the aide's session wrote it.
- **Records show attempts and claims; only acceptance shows outcomes.** A green check, a
  Hand-back, and a merged PR say what was tried and claimed. Only the aide's run on a real
  environment says what the product does.
- **No runtime action governance.** The skills do not police what a worker's commands do to
  files, networks, or secrets beyond its role's Never list. A project that needs that runs a
  dedicated policy tool alongside; this model does not reimplement one.
