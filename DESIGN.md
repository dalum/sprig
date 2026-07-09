# Design: Sprig - non-linear agent conversations in Markdown

## Name

**Sprig**. Package `sprig`, function prefix `sprig-`, editing minor mode `sprig-mode`, navigator major mode `sprig-status-mode`. Model-agnostic: the agent backend is not fixed. Rejected: `org-agent` (reserved `org-` prefix, crowded), `owl-mode` (collides with OWL/ontology modes). A sprig is a small shoot off a branch, which matches the fork-by-copy model below.

## Goal

An Emacs package for conversing with an LLM agent, breaking out of linear chat. You hold many conversations at once and fork any of them to explore several directions in parallel. Conversations are plain Markdown files you edit directly. The non-linear structure lives between files and is driven from a Magit-like control buffer.

## Architecture

Two surfaces, cleanly separated.

### The conversation is a plain Markdown file

- One *branch* is one Markdown file, a plain linear transcript.
- You *edit it directly*: type your turns, the agent streams its replies in.
- No in-file tree, no nesting, no drawers-as-branches. A long conversation stays a flat, readable file.
- The model emits Markdown, so its output lands with zero conversion. This was the "models emit Markdown, not Org" friction; it is gone.

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

Tool calls and results render inline but are transcript-only: `sprig--turns` strips them from the assistant text it assembles, and the CLI keeps its own tool memory server-side, so they never feed back into the model. Results can be large, so `sprig-render-tools` sets how much is written: `none`, `calls` (default: show each call, omit its result), or `full`. A file overrides the default with a `sprig_tools:` frontmatter line, set by `sprig-set-tool-display`. Because results are omitted at render time rather than hidden, the level applies to turns rendered afterwards.

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

- **Done (v0.3):** the sentinel-based Markdown transcript and turn parser (`sprig--turns`), streaming replies plus inline tool calls and results, the editor chrome (hidden sentinels, tool/result headers, reply rules, user-input face), tool-body folding with the structural edit guard, a per-file tool-render level, session persistence in frontmatter, and interrupt. Single file, one turn at a time, over the `claude` CLI (local or via SSH with `sprig-remote`).
- **Next slice:** fork-by-copy plus the `sprig-status` navigator, and the stateless-backend replay path that makes "context is the whole file" literal.

## First build slice (as shipped)

Context assembly plus send against one file: parse a Markdown branch file into a role-tagged message list, stream a reply into a sentinel-delimited reply span. It is the heart of the design and testable on a single file, with no navigator or fork machinery yet.

## Superseded

Earlier drafts put the whole tree inside one Org file: branches as headings, turns as `:reply:` drawers, `:FORK_FROM:` property anchors, and concurrent streams multiplexed into one buffer via markers. Replaced by one Markdown file per branch and fork-by-copy. Kept from that draft: the verbs (`send` / `fork` / `interrupt`) and the principle that a fork freezes its parent, now realized as a file copy.
