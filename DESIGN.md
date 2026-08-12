# Design: Sprig

## Name

**Sprig**. Package `sprig`, function prefix `sprig-`, review major mode `sprig-review-mode`, navigator major mode `sprig-status-mode`. Model-agnostic: the agent backend is not fixed. Rejected: `org-agent` (reserved `org-` prefix, crowded), `owl-mode` (collides with OWL/ontology modes). A sprig is a small shoot off a branch.

## What Sprig is

An Emacs interface for **reviewing and steering** an LLM agent's work, aimed at breaking out of linear chat. A conversation is a read-only, **Magit-like review buffer** (built on `magit-section`) whose one job is to review and steer the agent efficiently: the agent's file edits render inline as a foldable diff, you mark what you care about, and single-key verbs send the agent instructions. There is no chat input line and no Markdown file to edit. The whole set of conversations is driven from a `sprig-status` navigator.

A conversation *is* a `claude` session, and Sprig keeps no store of its own. The CLI already persists each session as JSONL under `~/.claude/projects/<cwd>/<id>.jsonl` on the host where it runs, so history is replayed from that log and survives an Emacs restart because the session id names the file. The transport is a persistent Claude Code session, local or over SSH, via the `claude` CLI's stream-json protocol.

**The ownership crux.** Agentic coding has a problem it does not solve: the author of record understands the code least. The agent writes, the human skims and approves, and ownership erodes along with understanding. Reviewing and steering the agent's edits is the fast path and lives with this. Authoring by hand is the deliberate counterweight: you write a piece of the change yourself and the agent puts it on disk, so for that piece you have engaged with every line because you wrote it. It is the same buffer with one extra verb (`e`), not a separate mode, so you trade speed for ownership one edit at a time, wherever it is worth it.

## The review buffer

### Shape

- Built on `magit-section`: foldable sections, free cursor movement over read-only text, an actionable metadata header, marks, and a transient for verbs.
- Section kinds: the metadata header, user turns, assistant turns, thinking blocks, tool calls and results, plan steps, and diff hunks.
- The metadata header carries title, project directory, model, session id, live status, cost, and tool-render level. It is actionable, not chrome: transients retitle, change the project dir, and switch model, the way Magit's header popups work.

### The crux: diff review

The agent operates on a real repository, so the transcript and a review of the agent's diffs are the *same surface*. You read what it did and reject or reference parts of it without leaving the buffer. This is the centre of the design; everything else serves it.

The hard problem is attribution: a conversation is turn-by-turn, but a git working tree is one cumulative diff against `HEAD`. They do not line up. The model is **two sources**:

1. **Tool-call payloads = attribution.** Every `Edit` / `Write` / `MultiEdit` is a before/after already present in the stream-json. Reconstruct per-turn hunks from these. Precise, cheap, turn-attributed, and works even when the target is not a git repo.
2. **Git working tree = ground truth.** The real uncommitted diff. Catches what payloads cannot: a `Bash` call that runs a formatter, a `sed`, codegen. Changes git shows but no payload explains surface as an **"unattributed changes"** section, exactly where the agent did something off-book worth an eyeball.

The shipped review buffer uses source 1 only. It needs no git plumbing, works over SSH, and delivers most of the review value. Source 2 is a later slice, first needed by hand-authoring (below), since your own diff has no tool payload to reconstruct from.

A possible upgrade makes the metaphor literal: mirror each completed turn as a commit on a hidden ref (`refs/sprig/<session>`), one commit per turn, so attribution and revert come free from git. Costs to weigh first: isolating the user's own uncommitted changes from the agent's, and per-turn snapshot overhead. Under the instruction invariant below, Sprig cannot run this git machinery itself, so even the shadow ref would have to be the agent's doing (a per-turn "record a snapshot" instruction) or the invariant relaxed. That tension is why it is deferred.

### Marks as the universal primitive

Marking is the one gesture everything composes through, the way Magit's region-and-stage selects hunks.

- Marking is the index. `c c` attaches whatever is marked as the context of the next message: a hunk, a plan step, a tool result, a paragraph.
- Marks also drive **actions on the transcript**, with the verb section-type-aware. `c c` is type-agnostic. Type-specific verbs act on the applicable subset: `k` rejects marked hunks (instructs the agent to undo them), `RET` visits, `x` runs a marked code block.
- Verbs marks unlock: re-send a marked past user turn as a fresh turn (`c r`, no history rewrite); mark a hunk then `c c` to frame the message as "about this change" with the hunk inlined, so reviewing-by-replying is one gesture.

### Sending is committing

There is no input area. Sending mirrors Magit's commit gesture. `c` opens a transient:

- `c c` compose and send, which **steers a turn already in flight**. Pops a dedicated `SPRIG_MSG` buffer: your prose on top, a commented preamble below showing exactly what context is attached and what the agent last said, the way `COMMIT_EDITMSG` shows the diff. `C-c C-c` fires, `C-c C-k` aborts. You never guess what you sent. The CLI's stdin stays open across a turn, so a message sent into one is handed to the agent at its next tool-call boundary: it changes course inside the same turn, with no interrupt and no restart. This is what makes watching a turn worthwhile rather than merely tense; the choice on a turn going wrong stops being "let it finish" or "kill it". A steer sent mid-turn does not splice into the transcript where you pressed send, which would break the streaming message in two. It floats pinned just above the state line, marked as not yet taken, and lands in the transcript only once the agent reaches the boundary that takes it, just before that tool call (or at the turn's end if none comes). That is where the agent actually received it, so the floated-then-committed placement is the truthful one, and it matches how the turn later replays from the log. With no turn running, the same verb opens one. There is deliberately no separate steer verb: whether a turn happens to be running is the transport's business, not a distinction the user should have to hold in their head and press a different key for.
- `c q` compose and queue, held until the running turn ends and then sent as a turn of its own. The counterpart to `c c`, and what makes it safe to merge steering into it: `c c` is for the correction worth interrupting the agent's train of thought for, `c q` for the follow-up that is not. Without `c q` the merge would leave nothing that means "not now", and `c c` mid-turn would have to keep refusing, which is the worst of the three answers. A queued message floats like a steer, just below any pending steer and above the state line, so a follow-up waiting its turn is as visible as a correction; it carries an hourglass rather than the steer's arrow, since it is only parked and not yet on the wire. The float is drawn straight from the send queue, so it can never promise a message the queue will not deliver.
- `c Q` drop the queued messages, leaving the turn to run; `k` on a floated queued message takes back just the one under point (the same take-it-back gesture that rejects a diff hunk, since a parked message is another thing point can sit on). Deliberately not folded into `c i`, which sends them: a queued message is the next thing, not the rest of this thing, so stopping the turn does not unmake it, and interrupting with one queued is the useful "stop, do this instead". That leaves `c Q` (or `k`) as the only way to take a queued message back, which it has to be anyway: nothing was sent, so there is nothing to steer or interrupt, and without it a queue would be a thing you could start and never stop. A steer has no such take-back: it is already on the wire, so it cannot be unsent, and `c i` (which stops the whole turn) is the only way to take back mid-turn input. Stopping the turn and meaning it is then `c Q c i`, two gestures that each say one thing, rather than a compound verb that says two.
- `c p` send in plan mode (the agent must return a plan, not act). The plan comes back as a dialog in the buffer, rendered in full: you read it where it is, then `a a` approves or rejects it. The one verb that still refuses mid-turn: it sets the permission mode first, so it cannot fold into a turn running under another one.
- `c r` retry or re-send.
- `c i` interrupt the streaming turn.

### Plan mode

The plan comes back as a markable section tree. Navigate, `TAB` to expand a step, `SPC` / `m` to mark a subset. Annotate a marked step inline ("do this, but keep the old names"). Sending returns a *structured* review: approved steps in order, each with its note, the rest rejected. Plan review becomes staging, not a pasted paragraph of feedback.

## The invariant: Sprig sends instructions, the agent acts

The governing invariant: **Sprig never touches the repository itself.** Every effect on the working tree is mediated through the agent over the stream-json channel that is already open. Review verbs compile to instructions, not local git commands.

- **Reject a hunk** (`k`): an instruction to the agent to undo that change, not a local `git apply -R`. Batch with marks: mark the bad hunks, `c c`, "undo these", one turn.
- **Accept changes**: keep them and clear the review state. A local acknowledgement, no side effect, no commit. Accepting never triggers a commit.
- **Commit** is a *separate* verb: an explicit instruction to the agent to commit the changes. Kept distinct from accept so accepting can never surprise you with a commit.
- **Ground truth diff** (source 2) also comes from the agent running `git diff` and reporting it, not from Sprig shelling out.

Two consequences fall out for free:

- **Remote works from day one.** Nothing Sprig does needs a local or TRAMP git process, because the agent already sits on the repo's host. Sprig only ever sends text down the channel it already has. This is why the design targets SSH from the start rather than bolting it on.
- **Reject is a steer, not an instant revert.** Rejecting costs a round-trip, since the agent does the undo. Marking makes it a batch, but it is still a turn, not a local `git checkout`. That is the honest tradeoff for the invariant.

### Verbs are canned instructions

There is no separate execution engine. Every type-specific verb is sugar over `c c`: it attaches the marked section(s) and fills in a templated instruction instead of making you type it.

- `k` reject = the marked hunk plus a canned "undo this".
- commit = a canned "commit these changes".
- `x` run = the marked code block plus a canned "run this".

The payoff is that the model stays tiny. Sprig does exactly one thing, send an instruction with attached context. The verbs are pre-written messages, not special paths, so a new shortcut is cheap and there is no code executor to build or secure.

### Scope discipline

The review buffer does not replicate Magit. Diff sections support **visit** (`RET`), **reject** (`k`), **accept** (keep and clear the review state), **commit** (a separate explicit instruction), **run** (`x`), and **mark**. The job is to review and steer agent work efficiently, not to be Magit and not to do git.

### Verb dispatch on mixed marks

Only *type-specific set verbs* (`k` and `x`) face this. `c c` is type-agnostic, and `RET` is a point op that ignores marks and acts at point. The rule:

- **Act on the applicable subset, never refuse.** `k` on 2 hunks and 3 paragraphs undoes the hunks and leaves the paragraphs.
- **Always report** what happened ("reject: undoing 2 hunks, ignored 3 non-hunk marks"). Because reject fires a real agent turn, **confirm first when the marked set is heterogeneous**; a pure-hunk batch, the intended flow, goes through without a prompt.
- **Consume only the marks acted on.** The hunks unmark, the paragraphs stay marked for a follow-up `c c`.

In one sentence: type-specific set verbs act on the applicable subset, report and (for destructive ones) confirm on a mixed set, and consume only the marks they touched.

## Authoring by hand

The answer to the ownership crux named under *What Sprig is*. Pure after-the-fact review of the agent's edits invites rubber-stamping, and rubber-stamping is how understanding and ownership erode. The literature on automation bias and overreliance names the failure; the fix here is to let the human write the piece they want to own, in place of reviewing the agent's version of it. This is a verb (`e`), not a mode: no posture to enter, no role to toggle. You reach for it on the edit that matters and stay in the ordinary review flow for the rest.

An earlier design made this a whole posture, a "navigator" role that put the session in `manual` permission mode and hard-blocked the agent's edit tools so you were forced to write. That was dropped: the enforcement was heavier than the value, it froze the agent out of editing wholesale, and the friction of toggling in and out worked against reaching for hand-authoring casually. Staging survives without it, because the courier below never needed the role.

### Authoring through staging buffers

Where you actually write the code is the crux on a remote host, and it forces the mechanism. `RET` visits a file over TRAMP, read-only. If Sprig let you edit that TRAMP buffer and save, Emacs itself would write the remote file, which breaks the invariant that only the agent touches the repo, and TRAMP editing is laggy besides. So you never edit a file in place. You author in a local, non-file-backed **staging buffer**, and the agent puts the bytes on disk. Editing is pure local Emacs, instant and in the correct major mode; the only remote traffic is the agent reading the region and writing it back, both over the stream-json channel already open. This is uniform: local sessions stage the same way, so there is one model and the invariant stays pure on both paths. Direct file editing outside Sprig remains available locally for those who prefer it, with the agent picking the change up from the working tree.

The loop, all under the `e` transient:

- **Seed.** You target a region three ways: `e e` the hunk at point (straight from the model, no round-trip), `e f` a file and optional region hint you name, or `e s` a region the agent suggests from the conversation it is already in. The two agent-read routes fill the buffer from the agent's `Read` result, which the model already parses, so there is no TRAMP read and no invariant breach; the read's bytes (its `cat -n` prefix stripped) are the on-disk `old_string` anchor, and `e s` learns the file from the read itself.
- **Edit.** You change the buffer freely, offline and local.
- **Apply.** `C-c C-c` mirrors the `c c` commit gesture. Sprig records the exact target and content and instructs the agent to write precisely that.
- **Review.** The change lands as a hunk in the working-tree diff, renders as your attributed change, and is now something you can ask the agent to critique. Author, apply, review, in one loop.

**Apply sends the bytes directly, by default.** `C-c C-c` sends the agent your `old_string` and `new_string` in the instruction and asks for one verbatim `Edit`. It is simple, works in every permission mode, and leaves nothing to fail at a permission gate. The cost is that the agent generates the write, so it could in principle drift from your bytes: the mechanism is tamper-*evident*, not tamper-proof, and the working-tree diff that lands is the check. If the `old_string` has drifted off disk the `Edit` simply fails to match and nothing is written, so re-send; drift is safe, not silent.

**The courier is the tamper-proof option (`sprig-courier-edits`).** A live probe against CLI 2.1.224 found the stronger mechanism: a `can_use_tool` allow response may carry an `updatedInput` that *replaces* the tool's arguments, and the CLI honours an `updatedInput` whose `old_string` / `new_string` the agent never proposed, writing the substituted bytes instead. So with the courier on, apply stages the human's `(file, old_string, new_string)` on `sprig--courier` and asks for one `Edit`; when it surfaces as a permission request, `sprig--maybe-courier` allows it and swaps in the staged strings through `updatedInput`, keeping only the agent's resolved absolute path. The agent supplies no content, so it cannot alter a byte: it triggers the write, Sprig writes the bytes. The catch, and why this is not the default: the override only fires *at a permission prompt*, so it refuses the auto-approve modes (`acceptEdits`, `bypassPermissions`) where there is none, and if the edit ever slips past the gate the human's bytes are silently lost to the agent's placeholder. Direct send has no such gate to miss. The strong guarantee is there for those who want it; the robust path is the default.

**Region maps to `Edit`, whole-file to `Write`.** The primary case is a region: the section the agent presented is the `old_string`, your edited buffer is the `new_string`. A useful property falls out, that if the file drifted since the seed read, `old_string` no longer matches and the write fails safely, which is the correct outcome. A new file or a full rewrite is a `Write` of the whole buffer, simpler but with no staleness guard, so region editing is preferred where it applies.

### The staging buffer is a change set

A staging buffer holds regions from several files, not one. The case for it is the author's real job: an implementation usually spans files, and identifying the touch points, then narrowing each to the region that actually changes, is the strategic framing the agent should do so you can write in one place. So the staging buffer is a **change set, not a file**: an ordered list of labelled regions, each tagged with its file and anchored to the `old_string` the agent presented, with read-only headers and editable bodies. The single-file buffer above is just the `N = 1` case, nothing special.

This rides the existing grammar rather than bolting on. The change set is the authoring dual of the multi-hunk review: you already assemble sets by marking across the transcript, so the region set is gathered the same way, and applying it is a verified batch the way `k` rejects a batch. Partial failure reuses the dispatch rule too. Each region applies as its own verified `Edit` (or `Write` for a new file), sequentially; if a region's `old_string` has drifted it fails and stays in the buffer while the rest land, reported per "act on the applicable subset, always report". There is no cross-file transaction, and drift is rare since only your own out-of-band edits can cause it.

Two tensions are worth naming rather than glossing.

- **Scoping is the agent doing design.** If the agent picks the regions, it quietly decides which files change, and a human filling in blanks the agent drew re-enters the very anchoring hand-authoring exists to fight. So the agent only *proposes* the region set; you **curate** it, adding a file it missed, dropping one, resizing a region, and that curation stays a human design act. The buffer is a proposal to edit, not a fixed template. (`e s` is the seed of this: the agent already scopes a single region; the change set generalises it to many, curated.)
- **One buffer, many languages.** A single major mode gives syntax highlighting for free; a change set needs each region fontified in its own file's mode, which is polymode / mmm territory. First-cut stance: best-effort per-region fontification with headers as chrome, and plain text is an acceptable fallback if it proves fiddly.

### The change set as dynamic literate programming

Seen from a distance, this is literate programming with the agent as the weaver. Knuth's *web* is one document ordered by the logic of the change rather than by file boundary, interleaving prose with code chunks; the *tangle* step extracts the code into real files. The change set is the web, the courier apply is the tangle, and the dynamic part is that the agent assembles the chunk set per task instead of the human maintaining a permanent literate source. The real files stay canonical, so this is a transient literate *view* over the code, not a replacement source format, which is what keeps it lightweight.

The concrete thing the lens buys is that the change set may interleave **prose chunks** with the code regions, not only code. The prose is the design intent and the running dialogue with the agent, sitting next to the regions it explains. On apply only the code regions tangle to files; the prose never touches disk. It has a natural home instead, feeding the message to the agent or the commit body, which folds straight back into "sending is committing".

The limit is worth stating so the analogy is not over-read: there is no counterpart to Knuth's *weave*, the published-documentation output, and the web is not canonical here, so this is literate programming as a workflow, not as a source format. The design should not be tempted into persisting the web.

## Store versus view

The buffer is a pure render of an append-only event log, so store and view are separate. And that log already exists: **Sprig does not own it.** The `claude` CLI persists every session as JSONL under `~/.claude/projects/<cwd>/<session-id>.jsonl` on the host where it runs, where `<cwd>` is the working directory with each `/` and `.` turned into `-`. For a remote session that file is on the SSH host, so the store is durable and remote-side with no work from us. A review buffer replays full history by reading that file and mapping its records onto the shared event vocabulary (`sprig-review-session-model`), the store counterpart of the wire parser. The log is really a tree (records link by `uuid`/`parentUuid`) and subagent transcripts are flagged `isSidechain`; the reader follows the main thread and skips sidechains.

So Sprig keeps essentially no local store: just a pointer (session id plus cwd) to locate the file, and even that the navigator could rediscover by scanning the projects directory. Markdown is at most an *export*, not the live truth.

## Modes

- **Review buffer**: `sprig-review-mode`, a read-only major mode on `magit-section`, that owns its session and carries the mark-and-instruction verbs. The only conversation surface.
- **Navigator**: `sprig-status-mode`, a major mode on `tabulated-list`.

## Status

Everything above the "Authoring by hand" heading is **shipped**, and its core now is too: the ground-truth diff parser and the single-region staging buffer, seeded from a hunk in the model, a file you name, or a region the agent suggests, applied by sending the bytes to the agent directly (with the override courier available as the opt-in tamper-proof path). What remains is the on-demand feedback verb and the multi-file change set.

### Shipped

- **Transport.** Parses the `claude` stream-json into a backend-neutral event vocabulary and routes it to a session-owning review buffer through a per-buffer sink. One process per session, local or over SSH (`sprig-remotes`); several sessions can stream at once. Graceful `c i` interrupt over the same stdin channel, leaving the process live.
- **Review buffer** (`sprig-review-mode`). Read-only `magit-section` render of the model. The tool-payload diff engine reconstructs per-file, per-hunk changes from `Edit` / `MultiEdit` / `Write`; file changes render as a foldable coloured diff with their folded result. Also renders assistant prose (markdown-fontified), thinking, a todo checklist (from `TodoWrite` and the granular `TaskCreate` / `TaskUpdate` stream), and `Agent` rows that nest a subagent's whole run and narrate it live.
- **Store.** History is replayed from the CLI's own session JSONL (`sprig-review-session-model`), skipping subagent sidechains; Sprig keeps no store beyond the session id and cwd that locate the file.
- **Marks and verbs.** `SPC` / `m` mark; a verb acts on the marked set or the section at point. `c` transient: `c c` steer-or-send, `c q` queue, `c Q` drop the queue, `c p` plan, `c r` independent review, `c l` resend, `c i` interrupt. `k` reject a hunk or unstage a floated message, `x` run, `C` commit, `a` accept, `RET` visit (over TRAMP when remote), `t` retitle. `s n` new conversation, `s f` fork (`--resume --fork-session`).
- **Plan mode.** `c p` sets the CLI permission mode over stdin (`set_permission_mode`) for one turn.
- **Navigator** (`sprig-status`). Lists the CLI's session logs per project directory across every host (local plus each of `sprig-remotes`), grouped and foldable, with live status glyphs (including `?` waiting-on-you) and a markdown-rendered preview of the last exchange with a time column and sort. Steers a session from the list without opening it (`c` / `a` act on the row's session). The working-directory prompt for a new session completes real paths (locally, or over the session's own SSH transport for a remote host, so no TRAMP) and suggests the directories the host's sessions already run in, drawn from this same cached scan rather than any new config; `S r` shows that list as a view of its own, each root a launch point.
- **Performance.** Settled prose fontification is memoised, and the structural-render coalescing timer adapts to the last render's measured cost.
- **Ground-truth diff parser.** `sprig-review-parse-diff` folds `git diff` into the tool-payload change shape, ready for the feedback slice to render your own diff (source 2 above).
- **Independent review (`c r`).** Asks the session to spawn a subagent (the Task tool) that reviews the uncommitted changes cold, then to address its findings. A subagent has its own context, so it is not the same agent marking its own work, and Sprig already renders the run as a nested `Agent` row; marked sections narrow the review. No new plumbing: the closed review loop is a canned instruction, not a Sprig-orchestrated background session.
- **Authoring by hand (single region).** `e` is a transient with three ways to seed a local `*sprig-stage*` buffer, opened in the file's own major mode: `e e` the hunk at point (straight from the model), `e f` a file and optional region hint you name, and `e s` the region the agent suggests from the conversation it is already in (with an optional nudge, since it already knows the task). The two agent-read routes ask for one `Read` and seed from its result when the turn ends (its bytes reconstructed from the `cat -n` output are the on-disk `old_string` anchor); `e s` learns the file from the read itself, so no file is named up front. You rewrite the buffer and `C-c C-c` applies it: by default apply sends the agent the `old_string` and `new_string` and asks for one verbatim `Edit`, which works in every mode and leaves nothing to fail at a permission gate (the agent does the write, so the resulting diff is the check). Setting `sprig-courier-edits` switches to the tamper-proof path: apply stages the human's `(file, old_string, new_string)` on `sprig--courier` and asks for one `Edit`, and `sprig--maybe-courier` overrides its bytes via `updatedInput` at the permission prompt (probe-confirmed against CLI 2.1.224), so the agent supplies no content; that path refuses the auto-approve modes, since it needs a prompt to override.

### Known gaps

- **Thinking is replay-only:** the live stream parser has no thinking branch, so a turn's reasoning appears only on the next replay.
- A change made by **`Bash` rather than `Edit` / `Write` still shows no diff**: the ground-truth parser (source 2) now exists, but nothing yet runs `git diff` and renders its result, so display is tool-payload only.
- **`/model` and `/clear` have no live verb** (`sprig-model` feeds `--model` at spawn only).
- A **remote** session's `Agent` rows replay without their subagents' steps: those transcripts are files beside the log, and a remote log is read by shell rather than by path, so there is no name to find them by.

### Next

- **Hand-authoring, remaining:** the multi-file **change set** (staging regions from several files at once, then the interleaved prose chunks of the literate-programming lens). Single-region staging is shipped (above), applied by direct send with the override courier as an opt-in.
- **Rendering the human's diff** as attributed hunks via `sprig-review-parse-diff` (the parser exists; nothing yet runs `git diff` and renders its result inline). The `c r` review verb already gives on-demand critique through a subagent; this is the separate display half.
- The richer **markable plan-tree review** from the plan-mode section.
- Finer **`x` granularity** (a code block inside prose, not just a tool command).
- **Incremental section append** (render only the active turn, O(turn) not O(conversation)) for large histories.
- Drawing the **fork forest** in the navigator, now that `s f` makes forks real.

### Deferred

- Merging or comparing branches beyond a plain `diff`.
- Summarising a long transcript to fit the context window.
- Reference-style forks (store only the divergent tail) if copy duplication ever bites.
- Backend abstraction: a stateless messages backend would want the whole transcript replayed, where the `claude` CLI keeps memory server-side and takes only the new turn.

### Open questions

- How thin a backend interface can be while spanning providers that differ this much on memory and resume.
- Whether a subagent's work is reviewable or merely visible: `k` on a hunk a subagent wrote is an instruction to the *main* agent, which did not make the edit itself.
