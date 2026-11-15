---
name: dispatch-evolve
description: >-
  Evolve the dispatch methodology: take a lesson from real dispatcher, aide, or worker sessions,
  filter it through CONSTITUTION.md, and either change a skill or script and propose a reviewed PR
  (pass) or do nothing (fail). No logs. Use when the user says /dispatch-evolve or "improve the
  dispatch skills".
argument-hint: "[lesson | session trace path | 'scan']"
---

# dispatch-evolve — methodology evolution

## First: read the constitution

Read `CONSTITUTION.md` in full. It is the gate. Articles 1–5 decide whether anything changes;
Article 10 decides whether the change keeps the model whole.

## Trigger modes

- **Lesson**: the user or a dispatcher names something that went wrong or right, with a trace.
- **Trace**: a path to a session transcript; find the stalls, wrong merges, needless asks, false
  passes, and lost hand-offs in it.
- **Scan**: read recent dispatcher sessions for repeated patterns (Article 3 needs multiple
  independent occurrences for a behavioral claim).

## The filter loop

1. State the finding in one sentence with the evidence (session, time, verbatim quote).
2. Classify it (Article 4). Runtime or tooling detail stays out unless it changes the model.
3. Decide where it belongs (Article 5 and 10.3): a mechanical fix is a script under `scripts/`
   with a test; a judgment fix is a sentence in one skill. Prefer the script. Prefer deleting a
   sentence the script replaces.
4. Apply the bar (Article 3), including the equal-or-better check against a run it might worsen.
5. **Fail** → stop. Write nothing anywhere.
6. **Pass** → edit, run `scripts/size-gate.sh` and `scripts/validate.sh`.

## GATE: commit and publish

Only on a pass with both scripts printing `PASS`: deliver through a focused PR per Article 9 and
report the merge SHA. Anything red → fix or drop the change; never publish over a red gate.

## Never

- Keep a log, backlog, or "maybe later" list of findings.
- Add a role, a hierarchy level, or a second way to ask the user without the user asking.
- Turn a mechanical lesson into a reminder sentence when a script can enforce it.

## After completion

If this skill itself misled the pass, that is a lesson too: run it back through the same filter.
