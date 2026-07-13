# Design: Sprig - non-linear agent conversations in Markdown

## Name

**Sprig**. Package `sprig`, function prefix `sprig-`, editing minor mode `sprig-mode`, navigator major mode `sprig-status-mode`. Model-agnostic: the agent backend is not fixed. Rejected: `org-agent` (reserved `org-` prefix, crowded), `owl-mode` (collides with OWL/ontology modes). A sprig is a small shoot off a branch, which matches the fork-by-copy model below.

## Goal

An Emacs package for conversing with an LLM agent, breaking out of linear chat. You hold many conversations at once and fork any of them to explore several directions in parallel. Conversations are plain Markdown files you edit directly. The non-linear structure lives between files and is driven from a Magit-like control buffer.

## Current direction: the review buffer (2026-07)

A pivot, driven by how the tool is actually used. In practice the workflow is a single, linear history that is never hand-edited and never forked. So editing-in-place and the fork forest are shelved for now. The sections below this one (editable Markdown, fork by copy, the forest) describe the earlier direction and are kept for context, not because they are the plan.

What replaces them: the conversation stops being an editable Markdown file and becomes a **read-only, Magit-like review buffer** whose one job is to review and steer agent work efficiently. Not a chat client. No input line at the bottom. A projection of state you move a cursor around, with convenient shortcuts.

### Shape

- Built on `magit-section`: foldable sections, free cursor movement over read-only text, an actionable metadata header, marks, and a transient for verbs.
- Section kinds: the metadata header, user turns, assistant turns, thinking blocks, tool calls and results, plan steps, and diff hunks.
- The metadata header carries title, project directory, model, session id, live status, cost, and tool-render level. It is actionable, not chrome: transients retitle, change the project dir, switch model, the way Magit's header popups work.

### The crux: diff review

The agent operates on a real repository, so the transcript and a review of the agent's diffs are the *same surface*. You read what it did and reject or reference parts of it without leaving the buffer. This is the centre of the design, everything else serves it.

The hard problem is attribution: a conversation is turn-by-turn, but a git working tree is one cumulative diff against `HEAD`. They do not line up. The model is **two sources**:

1. **Tool-call payloads = attribution.** Every `Edit` / `Write` / `MultiEdit` is a before/after already present in the stream-json. Reconstruct per-turn hunks from these. Precise, cheap, turn-attributed, and works even when the target is not a git repo.
2. **Git working tree = ground truth.** The real uncommitted diff. Catches what payloads cannot: a `Bash` call that runs a formatter, a `sed`, codegen. Changes git shows but no payload explains surface as an **"unattributed changes"** section, which is exactly where the agent did something off-book worth an eyeball.

**v1 uses source 1 only** (tool-payload reconstruction). It needs no git plumbing, works over SSH, and delivers most of the review value. Ground truth via git is a later slice.

A possible phase-2 upgrade makes the metaphor literal: mirror each completed turn as a commit on a hidden ref (`refs/sprig/<session>`), one commit per turn. Turns become commits, attribution and revert come free from git. Costs to weigh first: isolating the user's own uncommitted changes from the agent's, and per-turn snapshot overhead. Note that under the instruction invariant below, Sprig cannot run this git machinery itself, so even the shadow ref would have to be the agent's doing (a per-turn "record a snapshot" instruction), or the invariant relaxed. This tension is why it is deferred.

### Marks as the universal primitive

Marking is the one gesture everything composes through, the way Magit's region-and-stage selects hunks.

- Marking is the index. `c c` attaches whatever is marked as the context of the next message: a hunk, a plan step, a tool result, a paragraph.
- Marks also drive **actions on the transcript**, with the verb section-type-aware. `c c` is type-agnostic. Type-specific verbs act on the applicable subset: `k` rejects marked hunks (instructs the agent to undo them, see below), `RET` visits, `x` runs a marked code block.
- Verbs marks unlock: re-send a marked past user turn as a fresh turn (`c r`, no history rewrite); mark a hunk then `c c` to frame the message as "about this change" with the hunk inlined, so reviewing-by-replying is one gesture.

### Sending is committing

There is no input area. Sending mirrors Magit's commit gesture. `c` opens a transient:

- `c c` compose and send. Pops a dedicated `SPRIG_MSG` buffer: your prose on top, a commented preamble below showing exactly what context is attached and what the agent last said, the way `COMMIT_EDITMSG` shows the diff. `C-c C-c` fires, `C-c C-k` aborts. You never guess what you sent.
- `c p` send in plan mode (the agent must return a plan, not act).
- `c r` retry or re-send.
- `c i` interrupt the streaming turn.

### Plan mode

The plan comes back as a markable section tree. Navigate, `TAB` to expand a step, `SPC` / `m` to mark a subset. Annotate a marked step inline ("do this, but keep the old names"). Sending returns a *structured* review: approved steps in order, each with its note, the rest rejected. Plan review becomes staging, not a pasted paragraph of feedback.

### Store versus view

A read-only projection no longer needs the file to double as the editable surface, so store and view separate. The buffer becomes a pure render of an append-only event log.

The endgame resolution: **that log already exists, and sprig does not own it.** The `claude` CLI persists every session as JSONL under `~/.claude/projects/<cwd>/<session-id>.jsonl` on the host where it runs, where `<cwd>` is the working directory with each `/` and `.` turned into `-`. For a remote session that file is on the SSH host, so the store is durable and remote-side with no work from us. A review buffer replays full history by reading that file and mapping its records onto the shared event vocabulary (`sprig-review-session-model`), the store counterpart of the wire parser. The log is really a tree (records link by `uuid`/`parentUuid`) and subagent transcripts are flagged `isSidechain`; v1 reads the main thread and skips sidechains.

So sprig keeps essentially no local store: just a pointer (session id plus cwd) to locate the file, and even that the navigator could rediscover by scanning the projects directory. The `sprig:` sentinels and the edit guard, which existed only to make an editable Markdown file safely re-parseable, lose their reason to exist. Markdown becomes at most an *export*, not the live truth.

### Sprig sends instructions, the agent acts

The governing invariant: **Sprig never touches the repository itself.** Every effect on the working tree is mediated through the agent over the stream-json channel that is already open. Review verbs compile to instructions, not local git commands.

- **Reject a hunk** (`k`): an instruction to the agent to undo that change, not a local `git apply -R`. Batch with marks: mark the bad hunks, `c c`, "undo these", one turn.
- **Accept changes**: keep them and clear the review state. A local acknowledgement, no side effect, no commit. Accepting never triggers a commit.
- **Commit** is a *separate* verb: an explicit instruction to the agent to commit the changes. Kept distinct from accept so accepting can never surprise you with a commit.
- **Ground truth diff** (the phase-2 git source) also comes from the agent running `git diff` and reporting it, not from Sprig shelling out.

Two consequences fall out for free:

- **Remote works from day one.** Nothing Sprig does needs a local or TRAMP git process, because the agent already sits on the repo's host. Sprig only ever sends text down the channel it already has. This is why the design targets SSH from the start rather than bolting it on. It also retires the earlier "drop into `magit-status` to commit" seam, which never worked cleanly against a remote repo.
- **Reject is a steer, not an instant revert.** Rejecting costs a round-trip, since the agent does the undo. Marking makes it a batch, but it is still a turn, not a local `git checkout`. That is the honest tradeoff for the invariant.

### Verbs are canned instructions

There is no separate execution engine. Every type-specific verb is sugar over `c c`: it attaches the marked section(s) and fills in a templated instruction instead of making you type it.

- `k` reject = the marked hunk plus a canned "undo this".
- commit = a canned "commit these changes".
- `x` run = the marked code block plus a canned "run this". In v1: it needs no new machinery, it is the same shortcut as `k` and commit with a different pre-filled instruction, so there is no reason to defer it.

The payoff is that the model stays tiny. Sprig does exactly one thing, send an instruction with attached context. The verbs are pre-written messages, not special paths, so a new shortcut is cheap and there is no code executor to build or secure.

### Scope discipline

v1 does not replicate Magit. Diff sections support **visit** (`RET`), **reject** (`k`, an instruction to undo), **accept** (keep and clear the review state), **commit** (a separate explicit instruction), **run** (`x`, an instruction to run a marked code block), and **mark**. The job is to review and steer agent work efficiently, not to be Magit and not to do git.

### Verb dispatch on mixed marks

Only *type-specific set verbs* (`k` and `x`) face this. `c c` is type-agnostic, and `RET` is a point op that ignores marks and acts at point. The rule:

- **Act on the applicable subset, never refuse.** `k` on 2 hunks and 3 paragraphs undoes the hunks and leaves the paragraphs.
- **Always report** what happened ("reject: undoing 2 hunks, ignored 3 non-hunk marks"). Because reject fires a real agent turn, **confirm first when the marked set is heterogeneous**; a pure-hunk batch, the intended flow, goes through without a prompt.
- **Consume only the marks acted on.** The hunks unmark, the paragraphs stay marked for a follow-up `c c`.

In one sentence: type-specific set verbs act on the applicable subset, report and (for destructive ones) confirm on a mixed set, and consume only the marks they touched.

### Build progress

- **Done (2026-07-13):** the data foundation and the renderer.
  - `sprig-review.el` (pure, offline-tested): the tool-payload diff engine (`sprig-review-tool-changes`) reconstructs per-file, per-hunk changes from `Edit` / `MultiEdit` / `Write` payloads, with add/remove stats and a unified-diff formatter; the review model (`sprig-review-build`) folds the transport event vocabulary into an ordered block model (coalesced assistant text, tool calls with reconstructed changes and paired results, errors). Reuses sprig.el's transport, needs no live session or git.
  - `sprig-review-mode.el`: a read-only `magit-section` major mode that projects the model into rows, a metadata header, assistant prose, tool calls whose file changes render as a foldable coloured diff with their (folded) result. Each section carries its model plist on the `value` slot, so the verbs can read the object under point without re-parsing. Its ERT suite loads magit-section and runs separately from the process-free suite.
  - Packaging: `magit-section` declared in `Package-Requires`; the Emacs floor moved to 28.1 to match. magit-section and its deps (`compat`, `cond-let`, `llama`) are vendored under a gitignored `.deps/` for offline byte-compile and tests only.
  - Live sink: `sprig-review-consume` folds each transport event into the buffer's accumulated model and re-renders, the counterpart of the Markdown sink's `sprig--dispatch`. Re-rendering from the whole event list keeps the buffer a pure projection; magit-section's visibility cache preserves user folds across the refresh and point is carried to the same section. Offline-tested (incremental build, fold and point preservation, reset).
  - Store reader: `sprig-review-session-model` replays the CLI's stored session JSONL (see "Store versus view") into the model, skipping subagent sidechains. The model and renderer gained `user`, `thinking`, and `title` blocks, since the log carries them. Validated against real logs (a 480-line session reconstructed 42 hunks from 39 Edits and 3 Writes). This settles the store-vs-view split: history comes from the CLI's own log, not a sprig store.
- **Next:** the glue that opens a review buffer for a session, read the JSONL to replay history (locally, or over SSH with `sprig-remote`), then attach the live wire sink for the in-flight turn. Then the mark-and-instruction verbs (`c c`, `k`, accept, commit, `x`) and the `c` transient, reading the plist under point. The wire sink covers smooth token streaming (the file only lands complete messages); the file covers durable history and thinking.

## Architecture

Two surfaces, cleanly separated.

### The conversation is a plain Markdown file

- One *branch* is one Markdown file, a plain linear transcript.
- You *edit it directly*: type your turns, the agent streams its replies in.
- No in-file tree, no nesting, no drawers-as-branches. A long conversation stays a flat, readable file.
- The model emits Markdown, so its output lands with zero conversion. This was the "models emit Markdown, not Org" friction; it is gone.

### A branch can start in memory

A branch does not need a file to exist. A branch is defined by `sprig-mode` being on in a buffer, not by `buffer-file-name`. `sprig-new` opens a *scratch branch*: a live conversation in an unsaved buffer. It connects, streams, titles, and shows up in the navigator like any other branch, because all persistence (session id, title, working directory) is written into the buffer's frontmatter, which rides along the moment the buffer is saved.

`sprig-save` writes a scratch branch to disk, defaulting the filename to a slug of its `title:` under a navigator scan directory. From then on it is an ordinary file branch. Saving is optional: a scratch branch you never save is a deliberate throwaway. To keep that from being a silent accident, killing an unsaved scratch branch that still holds a transcript or a live session asks first; an empty or already-saved buffer is killed without a prompt.

So the "one branch is one Markdown file" model holds for anything you keep, while a conversation can begin with zero ceremony, the Magit-scratch gesture: start now, name and file it later, or not at all. Forking (below) still produces files, since it copies frozen ancestry; scratch branches are only about deferring the file for a *new* root.

### The structure is a forest of files

- A *directory* is the forest: a set of branch files plus their fork links.
- *Forking copies a file* up to the fork point, then the copy diverges. The frozen ancestry is inlined into the new file, so each file is a complete, standalone transcript.
- Fork links live in each file's YAML frontmatter (`parent:`, `forked_at:`, `id:`). The navigator reconstructs the forest from these.

### The navigator is Magit for Sprig state

A dedicated `sprig-status` buffer, built on `magit-section` and `transient`. It is a control surface over state, not a rendered chat.

- Shows the forest of branch files: title or summary, status (idle / streaming / interrupted), fork edges.
- Single-key transient verbs: open (jump to the file buffer), fork, new root, prune, interrupt, rename.
- The files are the working tree; `sprig-status` is `magit-status`.

## Why this shape

- *Direct-edit Markdown* satisfies the wish for plain text files and dissolves the Markdown-vs-Org conversion problem.
- *Fork by copy* inlines frozen ancestry, so context assembly collapses to "send the file". No recursive ancestor walk.
- *One stream per file* makes concurrency and interrupt trivial and unambiguous, no marker registry inside a shared buffer.
- *Complexity moves out of the text* into the navigator and the filesystem, keeping each transcript simple.
- Branch comparison is a plain `diff` of two files.

## File format

A branch file is Markdown with YAML frontmatter:

```markdown
---
title: Chase the caching idea
claude_session: 7f3a…            # CLI session id, for --resume
sprig_tools: calls               # optional: none | calls | full
---

how should context assembly work?

<!-- sprig:reply id=r1 -->

You'd walk the transcript top to bottom…

<!-- sprig:end id=r1 -->

what about forks?

<!-- sprig:reply id=r2 -->

Each fork freezes its parent by copying…

<!-- sprig:end id=r2 -->
```

- *User turns* are plain prose in the gaps. *Assistant turns* are the spans between a `sprig:reply` sentinel and its `sprig:end`.
- Delimiters are inserted by `send`, not hand-typed. You type prose below the last reply; `send` opens a reply span and streams into it.
- Each reply span carries a stable id (`r1`, `r2`, …) for references: fork anchors, status, and the interrupted flag.
- Frontmatter holds the CLI session id and display settings today; the fork machinery will add branch identity and the fork link (`id:`, `parent:`, `forked_at:`).
- A titleless branch is named automatically after its first exchange: a short throwaway agent run turns the opening user turn and reply into a `title:`, the same recipe the CLI uses to name its own sessions. A hand-written `title:` is left alone. This is what gives a scratch branch a real navigator name, and a good default filename, before it is ever saved.

## In-file structure: sentinels, not prose

Structure lives entirely in invisible HTML-comment *sentinels*, never in the prose. An earlier draft wrapped replies in `<details>` blocks so they would fold in Emacs and collapse on GitHub, but a tool that printed `</details>` (or any HTML) could forge the delimiter and break parsing. Moving structure into `sprig:` comment sentinels keeps agent output, which is arbitrary text, from ever being mistaken for markup. The consequence is that the files are for Emacs, not GitHub.

The sentinel kinds, each an HTML comment alone on its line at column 0:

- `<!-- sprig:reply id=rN -->` … `<!-- sprig:end id=rN -->` bracket one assistant turn.
- `<!-- sprig:tool id=… name=… -->` … `<!-- sprig:tool-end id=… -->` wrap a tool call, its input in a fenced block between them.
- `<!-- sprig:result id=… -->` … `<!-- sprig:result-end id=… -->` wrap that call's result.

`sprig-mode` draws *chrome* over the raw sentinels so the buffer reads as chat, not markup:

- Each sentinel line is hidden behind an overlay; a tool call shows a `🔧 name` header, a result an `↳ result` header, and a reply span a faint rule at its start and end.
- Tool bodies fold to their header (`C-c C-f`); the full text stays in the file.
- The user's own turns get a distinguishing face, so input reads apart from output.
- A structural *edit guard* makes the hidden sentinels and any folded body reject interactive deletion, so a stray backspace at a boundary cannot silently corrupt the structure. Sprig's own writes opt out via `inhibit-read-only`.

Because sentinels delimit everything, block boundaries are unambiguous no matter what the agent prints.

## Tool activity in the transcript

Tool calls and results render inline but are transcript-only: `sprig--turns` strips them from the assistant text it assembles, and the CLI keeps its own tool memory server-side, so they never feed back into the model. Results can be large, so `sprig-render-tools` sets how much is written: `none` (default: no tool blocks), `calls` (show each call, omit its result), or `full`. A file overrides the default with a `sprig_tools:` frontmatter line, set by `sprig-set-tool-display`. Because results are omitted at render time rather than hidden, the level applies to turns rendered afterwards.

## Context assembly

Read the file top to bottom, map user prose and reply spans to roles, strip each reply's tool and result blocks to leave the prose, send. That is the whole algorithm; `sprig--turns` produces exactly this role-tagged list. Forking froze the ancestry into the file already, so there is no ancestor walk. (Today's `claude` CLI transport keeps memory server-side and takes only the new user turn; the full-replay path that makes this literal is the deferred stateless backend.)

## Interaction

Core verbs, available from both the editing buffer and the navigator:

- *send* - collect the file as a message list, stream the reply into a new reply span (a `sprig:reply`/`sprig:end` pair).
- *fork* - copy this file up to the fork point into a new branch file, set frontmatter, open it.
- *interrupt* - abort this buffer's stream (see below).

Minor verbs:

- *discard* - delete a reply block when the partial is junk.
- *prune*, *rename*, *new root* - from the navigator.

## Interruption

Stopping a streaming reply is first class, mirroring the CLI "seen enough, stop, redirect" gesture. One stream per buffer makes this simple.

- *Atomic abort.* Kill this buffer's stream and close the reply span cleanly with its `sprig:end` sentinel, so the file is never left half-written.
- *Keep and mark the partial.* The truncated reply stays as a real turn, marked interrupted (`<!-- sprig:reply id=... interrupted -->`). Context assembly treats it as a normal turn, and the marker tells the model on the next send that its previous turn was cut off.
- *Point drops to a fresh user turn* right after the partial, ready for an immediate redirect.
- *Discard is separate*: interrupt keeps and marks, discard deletes.

## Concurrency

Many branches can stream at once, each in its own file and buffer. Emacs Lisp is single-threaded, so this is many async requests interleaving on the main loop, not true parallelism.

- *One process per buffer.* No shared-buffer marker registry; each stream owns its file.
- *Session-level registry* maps file to process so `sprig-status` can show which branches are live and route interrupt.
- *Out-of-band status.* The navigator surfaces activity across files, so a stream finishing in a file you are not viewing is visible there. A mode-line indicator per buffer covers the focused case.

## Modes

- *Editing buffer*: `markdown-mode` plus a `sprig-mode` minor mode adding send / fork / interrupt and the editor chrome: sentinel hiding, tool/result headers, reply rules, the user-input face, tool-body folding, and the structural edit guard.
- *Navigator*: `sprig-status-mode`, a major mode on `magit-section` + `transient`.

## Deferred

- Merging or comparing branches beyond plain `diff`.
- Summarising a long transcript to fit the context window.
- Roles beyond user and assistant (system, tool).
- Running code blocks: not Babel; a section or buffer action on a code block ("run this").
- Reference-style forks (store only the divergent tail) if copy duplication ever bites. Copy is the default.

## Open questions

- Backend abstraction: how thin an interface over different agent providers. The `claude` CLI keeps memory server-side and resumes by session id, so it wants only the new user turn; a stateless messages backend wants the whole transcript replayed. Fork-by-copy needs the replay path.
- How thinking / reasoning is represented in the transcript. Tool calls are settled (see the sentinel and tool-activity sections); thinking is not yet surfaced.
- Keybindings for the verbs in each surface.

Resolved: turn delimiting (invisible `sprig:` sentinels, chosen over `<details>` so agent output cannot forge a delimiter) and tool-call representation (sentinel-delimited fenced blocks with header chrome and a render level).

## Build status

- **Done:** the sentinel-based Markdown transcript and turn parser (`sprig--turns`), streaming replies plus inline tool calls and results, the editor chrome (hidden sentinels, tool/result headers, reply rules, user-input face), tool-body folding with the structural edit guard, a per-file tool-render level, session persistence in frontmatter, interrupt, automatic titling of a titleless branch, and the `sprig-status` navigator in a first flat-list form (open / connect / interrupt / disconnect / preview, plus scratch branches via `sprig-new` / `sprig-save` and a kill guard). Single file, one turn at a time, over the `claude` CLI (local or via SSH with `sprig-remote`); several buffers can stream at once.
- **Next slice:** fork-by-copy (and the rename / prune verbs it unblocks, plus the `id:` / `parent:` / `forked_at:` fork links), then the stateless-backend replay path that makes "context is the whole file" literal.

## First build slice (as shipped)

Context assembly plus send against one file: parse a Markdown branch file into a role-tagged message list, stream a reply into a sentinel-delimited reply span. It is the heart of the design and testable on a single file, with no navigator or fork machinery yet.

## Superseded

Earlier drafts put the whole tree inside one Org file: branches as headings, turns as `:reply:` drawers, `:FORK_FROM:` property anchors, and concurrent streams multiplexed into one buffer via markers. Replaced by one Markdown file per branch and fork-by-copy. Kept from that draft: the verbs (`send` / `fork` / `interrupt`) and the principle that a fork freezes its parent, now realized as a file copy.
