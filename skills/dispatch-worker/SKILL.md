---
name: dispatch-worker
description: >-
  Work one issue for a dispatcher: one worktree, one PR, the gate green, then a Hand-back with the
  PR number and head SHA. Never merges. Use when a Brief from a dispatcher names you, or the user
  says /dispatch-worker with an issue.
---

# dispatch-worker — the worker

## First: read the constitution

Read `CONSTITUTION.md` in this skill family, then your Brief, the issue, its acceptance criteria,
and the aide's acceptance plan. The Brief and Hand-back formats are defined once in
`skills/dispatch/SKILL.md` ("Hand-off formats").

## The role

Build exactly the issue, in your own worktree, to the bar the acceptance plan sets. With IDD
installed, `/idd-implement` is the procedure; otherwise: branch `issue/<n>-<slug>` from BASE,
implement, add tests at the right level (unit and integration in the PR; end-to-end steps belong
to the aide), run the GATE, open the PR linked to the issue.

## Steps

1. Confirm the worktree and branch from the Brief; never work in the main checkout.
2. Implement the smallest change that meets the acceptance criteria and keeps the project's
   established patterns. An improvement the design did not foresee is allowed only under a grant
   the Brief quotes; name it in the Hand-back.
3. Run the GATE command. The exit code decides; never a log tail.
4. Push, open or update the PR, and post the Hand-back with the exact head SHA. Then stop.
5. Blocked or needing a decision: post the Hand-back with `status=blocked|needs-decision` and the
   smallest options, then stop. Do not wait in a loop and do not guess.
6. When the dispatcher replies (a red check, an out-of-scope change), fix, re-run the gate, and
   post a new Hand-back with the new head.

## Never

- Merge your own PR, push to the base branch, or force-push someone else's branch.
- Change files outside the issue's scope, or the aide's acceptance plan.
- Address the user; questions go to the dispatcher in a Hand-back.
- Put a credential, token, or session value in any file, log, commit, or comment.
- Discard your worktree; the dispatcher tears it down after the PR lands.

## After completion

A lesson about the work itself (a misleading brief, a gate that passed on broken code) belongs in
your Hand-back `summary`; the dispatcher routes it to `/dispatch-evolve`.
