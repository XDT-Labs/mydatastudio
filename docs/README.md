# docs

How feature work is planned, decided and tracked in this repo, plus operational runbooks.

| Where | What it holds | Changes over time? |
|---|---|---|
| [`ROADMAP.md`](ROADMAP.md) | One row per feature: status, plan, ADR, notes | Yes, whenever a status changes |
| [`plans/`](plans/) | One plan per feature: *what* we're building and *how* | Yes, as the work moves along |
| [`adr/`](adr/) | Architecture Decision Records: *why* we made a lasting choice | No, once accepted |
| [`runbooks/`](runbooks/) | Step-by-step operational procedures | Yes, when the code they depend on changes |

## `plans/`: one file per feature

A plan is the brief handed to whoever builds the feature, including a sub-agent. It has to stand
on its own: someone with only the plan and the repo should be able to build it and tell when
they're finished.

- **Name:** `plans/<feature>.md`, in kebab-case (`social-twitter-archive.md`).
- **Contents:** context (what exists today), scope, design, phases, open questions, and a
  **Done when** section with checkable criteria.
- **It changes as the work does.** Tick off phases, record what was built and what turned out
  differently. A finished plan stays in the folder as the record of how the feature was built.
- **Frontmatter** at the top gives the plan's status, read by people and scripts alike:

  ```yaml
  ---
  status: in-progress      # see the status values below
  adr: 0001                # the ADR this plan depends on, or none
  remaining: [phase-5, C3] # short ids for what's left; empty when done
  ---
  ```

## `adr/`: one file per lasting decision

An ADR records an architectural choice that's significant or hard to reverse: the schema, the
process model, a library or protocol we commit to. It covers the options considered and why one
won. Most features need a plan but no ADR. Write one when someone is likely to ask "why did we do
it this way?" a year from now.

- **Name:** `adr/NNNN-<decision>.md`, numbered in order (`0001-llm-tool-registry.md`). Numbers
  are never reused.
- **Status:** `Proposed` → `Accepted`, or later `Superseded by NNNN`.
- **Accepted ADRs aren't edited.** To change a decision, write a new ADR that supersedes the old
  one, and change only the old one's status line.

## `ROADMAP.md`: the index

One row per feature: its status, links to its plan and ADR, and a one-line note on where it
stands. Use it to see everything at a glance and pick what to work on next.

- **Add a row** as soon as a feature is known, even before it has a plan (status `idea`).
- **Keep it in step with the plans.** When a plan's frontmatter `status` changes, update its
  row in the same change. The plan is the source of truth; the roadmap mirrors it.
- **Rows stay when work is done:** set them to `done`.

### Status values

| Status | Meaning |
|---|---|
| `idea` | Known gap, no plan written yet |
| `proposed` | Plan or ADR written, not yet agreed |
| `ready` | Agreed and detailed enough to hand off |
| `in-progress` | Being built; the plan's `remaining` lists what's left |
| `done` | Shipped and verified |
| `parked` | Deliberately waiting on something (named in the row's Notes) |

## `runbooks/`: operational procedures

A runbook is step-by-step instructions for operating the app or its data: a migration to run, a
rebuild to trigger, a way to recover from a known failure. Runbooks aren't features, so they
aren't plans and don't go on the roadmap.

- **Name:** `runbooks/<procedure>.md` (`reembed.md`).
- **Contents:** when you'd need it, the exact steps, what it costs (time, disk, downtime), how to
  check it worked, and what to do if it's needed again.
- **Keep them runnable.** When the code a runbook depends on changes, update the runbook in the
  same change, or delete it if the procedure no longer applies.
