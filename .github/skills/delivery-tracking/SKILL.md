---
name: delivery-tracking
description: 'Required delivery workflow for implementation changes. Use when planning, starting, completing, validating, or reporting code, infrastructure, scripts, configuration, documentation, or test changes; maintains todo.md and changelog.md and invokes the delivery auditor for large change sets.'
user-invocable: false
---

# Delivery Tracking

## Purpose

Keep implementation state and completed release history aligned with the actual working tree and validation evidence.

- `todo.md` tracks planned, active, blocked, and completed work.
- `changelog.md` records completed, implementation-backed changes only.
- The primary implementation agent owns both files.

## Workflow

### 1. Start Work

1. Read `todo.md` and `changelog.md`.
2. Add a specific task to **In Progress**, or move the matching backlog item there.
3. Do not add planned work to `changelog.md`.

### 2. Maintain State

- Keep the active task wording outcome-focused.
- If scope changes materially, update the task before continuing.
- If blocked or partially delivered, leave the task In Progress and record the blocker in the task text.
- Remove or correct stale backlog items when delivered changes make them impossible or obsolete.

### 3. Validate the Delivery

1. Run the narrowest executable validation that covers the changed behavior.
2. Run broader validation when the blast radius spans shared or cross-module behavior.
3. Inspect the final diff for unrelated changes and whitespace errors.
4. Never mark work complete based only on intended edits.

### 4. Audit Large Change Sets

Invoke the `delivery-auditor` subagent before final tracker edits when the logical delivery meets any threshold:

- 10 or more changed files.
- 500 or more changed lines.
- 3 or more top-level repository areas.

Provide the auditor with the implementation objective, validation evidence, and any known pre-existing working-tree changes. The auditor is read-only and returns findings; the primary agent decides and applies any corrections.

### 5. Complete Work

1. Move the task from **In Progress** to **Done** under the current date only after implementation and validation succeed.
2. Add or update the current dated section in `changelog.md`.
3. Use only applicable headings: **Added**, **Changed**, **Fixed**, and **Security**.
4. Include impacted paths where practical.
5. Keep each bullet concise, factual, and attributable to the delivered implementation.
6. Recheck that TODO state, changelog claims, diff contents, and validation results agree.

## Guardrails

- Never delegate edits to `todo.md` or `changelog.md`.
- Never claim deployment, test, or validation success without evidence.
- Never place future work in `changelog.md`.
- Never duplicate tasks or changelog bullets.
- Never include secrets, tokens, passwords, subscription keys, or private data.
- Preserve factual historical entries even when the referenced feature is later removed.