# Design: Sprig

## Name

**Sprig**. Package `sprig`, function prefix `sprig-`, review major mode `sprig-session-mode`, navigator major mode `sprig-status-mode`. Model-agnostic: the agent backend is not fixed. Rejected: `org-agent` (reserved `org-` prefix, crowded), `owl-mode` (collides with OWL/ontology modes). A sprig is a small shoot off a branch.

## What Sprig is

An Emacs interface for **reviewing and steering** an LLM agent's work, aimed at breaking out of linear chat. A conversation is a read-only, **Magit-like session buffer** (built on `magit-section`) whose one job is to review and steer the agent efficiently: the agent's file edits render inline as a foldable diff, you mark what you care about, and single-key verbs send the agent instructions. There is no chat input line and no Markdown file to edit. The whole set of conversations is driven from a `sprig-status` navigator.

A conversation *is* a `claude` session, and Sprig keeps no store of its own. The CLI already persists each session as JSONL under `~/.claude/projects/<cwd>/<id>.jsonl` on the host where it runs, so history is replayed from that log and survives an Emacs restart because the session id names the file. The transport is a persistent Claude Code session, local or over SSH, via the `claude` CLI's stream-json protocol.

**The ownership crux.** Agentic coding has a problem it does not solve: the author of record understands the code least. The agent writes, the human skims and approves, and ownership erodes along with understanding. Reviewing and steering the agent's edits is the fast path and lives with this. Authoring by hand is the deliberate counterweight: you write a piece of the change yourself and the agent puts it on disk, so for that piece you have engaged with every line because you wrote it. It is the same buffer with one extra verb (`e`), not a separate mode, so you trade speed for ownership one edit at a time, wherever it is worth it.

## The session buffer

### Shape

- Built on `magit-section`: foldable sections, free cursor movement over read-only text, an actionable metadata header, marks, and a transient for verbs.
- Section kinds: the metadata header, user turns, assistant turns, thinking blocks, tool calls and results, plan steps, and diff hunks.
- The metadata header carries title, project directory, model, session id, live status, cost, and tool-render level. It is actionable, not chrome: transients retitle, change the project dir, and switch model, the way Magit's header popups work.

### The crux: diff review

The agent operates on a real repository, so the transcript and a review of the agent's diffs are the *same surface*. You read what it did and reject or reference parts of it without leaving the buffer. This is the centre of the design; everything else serves it.

The hard problem is attribution: a conversation is turn-by-turn, but a git working tree is one cumulative diff against `HEAD`. They do not line up. The model is **two sources**:

1. **Tool-call payloads = attribution.** Every `Edit` / `Write` / `MultiEdit` is a before/after already present in the stream-json. Reconstruct per-turn hunks from these. Precise, cheap, turn-attributed, and works even when the target is not a git repo.
2. **Git working tree = ground truth.** The real uncommitted diff. Catches what payloads cannot: a `Bash` call that runs a formatter, a `sed`, codegen. Changes git shows but no payload explains surface as an **"unattributed changes"** section, exactly where the agent did something off-book worth an eyeball.

The inline session buffer uses source 1 only. It needs no git plumbing, works over SSH, and delivers most of the review value. Source 2 now ships as the **changeset review** (`sprig-session-review`, `d`): a magit-like view of the net working-tree diff, annotated line by line (see "The changeset review" below) that Sprig reads by running `git diff` directly, so it catches a `Bash` change with no payload and shows your own hand-authored edits. It reuses the review grammar (the same hunk sections, marks, and `c c` comment path, routed back to the session), and it works remotely too, reading the diff over the session's SSH transport rather than TRAMP. Folding it into the inline transcript as an "unattributed changes" section is still to come.

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

The governing invariant: **Sprig never *mutates* the repository itself.** Every effect on the working tree is mediated through the agent over the stream-json channel that is already open. Review verbs that change the tree compile to instructions, not local git commands. A *read* of the tree is allowed (Sprig may run `git diff` to see the working state); the invariant governs writes, since it is a write that the remote path cannot do locally.

- **Reject a hunk** (`k`): an instruction to the agent to undo that change, not a local `git apply -R`. Batch with marks: mark the bad hunks, `c c`, "undo these", one turn.
- **Accept changes**: keep them and clear the review state. A local acknowledgement, no side effect, no commit. Accepting never triggers a commit.
- **Commit** is a *separate* verb: an explicit instruction to the agent to commit the changes. Kept distinct from accept so accepting can never surprise you with a commit.
- **Ground truth diff** (source 2) is read by the changeset review (`sprig-session-review`, `d`) running `git diff` itself, a read the invariant permits. Locally that is `git diff` in the repo; for a remote session it rides the same SSH transport the navigator reads logs over (`sprig--remote-sh`, `cd DIR && git diff`), never TRAMP. So the read stays off the agent and off TRAMP on both paths.

Two consequences fall out for free:

- **Remote works from day one.** No *mutation* Sprig does needs a local or TRAMP git process, because the agent already sits on the repo's host. Sprig only ever sends text down the channel it already has. This is why the design targets SSH from the start rather than bolting it on. (Reading the diff for the `d` buffer is the one git Sprig runs itself, and it rides that same SSH channel remotely, so it needs no local or TRAMP git either.)
- **Reject is a steer, not an instant revert.** Rejecting costs a round-trip, since the agent does the undo. Marking makes it a batch, but it is still a turn, not a local `git checkout`. That is the honest tradeoff for the invariant.

### Verbs are canned instructions

There is no separate execution engine. Every type-specific verb is sugar over `c c`: it attaches the marked section(s) and fills in a templated instruction instead of making you type it.

- `k` reject = the marked hunk plus a canned "undo this".
- commit = a canned "commit these changes".
- `x` run = the marked code block plus a canned "run this".

The payoff is that the model stays tiny. Sprig does exactly one thing, send an instruction with attached context. The verbs are pre-written messages, not special paths, so a new shortcut is cheap and there is no code executor to build or secure.

### Scope discipline

The session buffer does not replicate Magit. Diff sections support **visit** (`RET`), **reject** (`k`), **accept** (keep and clear the review state), **commit** (a separate explicit instruction), **run** (`x`), and **mark**. The job is to review and steer agent work efficiently, not to be Magit and not to do git.

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

## The changeset review

The session buffer reviews the agent's work *turn by turn*, which is the right unit while a turn is happening and the wrong one afterwards. Afterwards the question is not "what did that turn do" but "is this change good", and that is a pass over a changeset, not a scroll back through a conversation. `sprig-review-mode` (`d`) is that pass: every change in the working tree against `sprig-review-base`, as one navigable diff, annotated line by line, handed back in a single round.

**Comments are drafts, and publishing is one turn.** Nothing reaches the agent until `c p`. This is Gerrit's model rather than a chat's, and it is the whole reason the surface earns its place: a review composed as a whole says something a stream of individual messages cannot, because the reviewer has seen all of it before saying any of it. It also costs one turn instead of *n*. Publishing rides the ordinary compose buffer, so "sending is committing" holds here too: you write the covering note over the serialised comments and see exactly what goes out.

**Positions come from git, and only from git.** A tool payload is positionless: an `Edit` knows the bytes it replaced, never the line they sat on. So line-anchored review can ride source 2 (the working-tree diff) and not source 1, and the two sources' change plists differ accordingly. Both carry `:hunks`, the payload-shaped runs the transcript renders; only a parsed git diff also carries `:unified`, one entry per `@@` section with every line numbered on both sides, context included. That asymmetry is a fact about the sources, not a gap to close, so it is in the model rather than hidden behind it.

**Anchors are text, not line numbers.** A draft records the file, the side, the line range, *and* the text of the lines it was written against. A refresh re-anchors every draft: unchanged text keeps its line, moved text follows, and text gone from the diff is flagged orphaned and floated to the top of its file, never dropped. Line numbers are the first thing a fresh diff invalidates, so they are a hint about where to look and the text is the identity. A review tool that silently loses a comment is worse than one that has none, and one that silently re-points a comment at a line that now means something else is worse still.

**It writes nothing.** Reading the tree is a read, which the invariant permits, and Sprig does it itself (locally, or over the session's own SSH transport for a remote tree, never TRAMP). Publishing is an instruction like every other verb. Hand-authoring is reachable from a hunk (`e`), seeded with that hunk's new side, and applies through the staging path above, so even the edits you write yourself land through the agent.

**What it does not do.** It shows the whole working tree, the agent's changes and your own together, because that is what "is this change good" is actually asking about; separating the agent's from yours is the same unsolved attribution problem the shadow-ref idea above would fix. There is no approve/request-changes disposition: `a` already accepts and `C` already commits, and a second path to the same place would only invite the two to disagree. Drafts do not survive killing the buffer, since Sprig owns no store; they are one plist, so persisting them later is small if it proves worth it.

## Store versus view

The buffer is a pure render of an append-only event log, so store and view are separate. And that log already exists: **Sprig does not own it.** The `claude` CLI persists every session as JSONL under `~/.claude/projects/<cwd>/<session-id>.jsonl` on the host where it runs, where `<cwd>` is the working directory with each `/` and `.` turned into `-`. For a remote session that file is on the SSH host, so the store is durable and remote-side with no work from us. A session buffer replays full history by reading that file and mapping its records onto the shared event vocabulary (`sprig-session-log-model`), the store counterpart of the wire parser. The log is really a tree (records link by `uuid`/`parentUuid`) and subagent transcripts are flagged `isSidechain`; the reader follows the main thread and skips sidechains.

So Sprig keeps essentially no local store: just a pointer (session id plus cwd) to locate the file, and even that the navigator could rediscover by scanning the projects directory. Markdown is at most an *export*, not the live truth.

## Detach and reattach: the session broker

The store survives a disconnect; the live process does not. A running session is a `claude` child wired straight to its transport (`ssh HOST 'cd DIR && exec claude ...'`), so dropping the SSH link hangs claude's stdin EOF and a SIGHUP on it and it dies. Because the JSONL is durable and Sprig already resumes from it (`--resume`), a *finished* turn is never lost; the one casualty is an **in-flight turn**, a long agent run cut off when you close the laptop. Closing that gap is the whole point of the broker.

A probe settled the load-bearing fact first: a `claude` stream-json process does **not** self-exit on idle stdin and does **not** care which client feeds it. Given a persistent holder that keeps its stdin open, a session survives with no client attached, a reattaching client drives the next turn on the same live process, and its stdout replays cleanly from a saved byte offset. That is exactly a broker's job, so the design is sound rather than hopeful.

The **broker** is a per-user, per-host long-lived process (a `systemd --user` unit, or a `setsid` launcher started on first use) that owns each session's claude child. It holds each child's stdin open (the holder fd, so no client's coming and going ever hits EOF), appends its stdout to a per-session spool file, and exposes attach over a Unix socket. A client attaches with `ssh HOST sprig-broker attach SESSION` and gets, in order: a replay of the spool from the byte offset it left off at (cut at newline boundaries, since `--include-partial-messages` streams mid-message lines), then the live tail, plus a stdin path back to the holder. Auth and forwarding ride the existing SSH channel, so there is no new exposed surface. The spool is a transient reattach buffer, not a second store: the CLI's JSONL stays the truth, and the spool can be trimmed to the last turn boundary once no client needs the older bytes.

Sprig's transport gains exactly one mode. A remote session becomes `ssh HOST sprig-broker (spawn|attach) ...` in place of the direct `exec claude`. Session identity stays the CLI's own session id, so the broker degrades gracefully: if it dies, a client falls back to today's behaviour, resuming the JSONL by id, losing only an in-flight turn. The broker is never required for correctness; it only buys process durability across disconnects.

A **permission dialog with no client attached** simply stalls the turn. Sprig runs claude with `--permission-prompt-tool stdio`, so mid-turn claude can raise a control_request (a permission prompt, an `AskUserQuestion`) when nobody is listening. The broker keeps it and waits for a client to reattach and answer, rather than deciding for you: an auto-deny corrupts the turn silently and an auto-allow is unsafe, whereas a stalled turn is recoverable and already has a home in the navigator's `?` waiting-on-you glyph. The broker exists to keep an unattended turn *running*, not to make it run unattended; a dialog is exactly the point where a turn should wait for you. Re-delivery is what makes this work: a reattach normally resumes at the live tail (settled history comes from the JSONL, not the spool), which would skip past a request raised while detached and hang the child forever. So the broker tracks each control_request the child emits by spool offset and clears it when a client's control_response answers it; a reattach with any request still pending rewinds to the oldest one, so its prompt streams again and the reattached client can answer it. A blocked child emits nothing after the prompt, so the rewind replays only the unanswered prompts, never settled history the JSONL already holds.

**Discovery rides the scan, not a query.** So the navigator can tell which sessions the broker still holds, the broker drops a marker beside each held session's log, `<id>.sprig-live`, exactly the way a star is an `<id>.sprig-star` file (it finds the log by globbing for the id, so it never reproduces the CLI's cwd-mangling). The navigator's one scan already tests for a sibling star per log; it now tests for the live marker in the same pass, so liveness costs no extra round trip. Opening `sprig-status` then reattaches every held session in the background (attach-only, so a stale marker from a crashed daemon can neither respawn a dead session nor start a daemon, and is tried once), and the session's live turn streams without your opening it and sending a throwaway message. The marker is a hint; the attach is the truth. And the hint is verified: markers survive a daemon that dies without cleanup (a machine restart), which would show a dead session as running for good, so each scan that reports held sessions is followed by one broker `list` query, and any marker the broker does not vouch for is removed and its row downgraded to disconnected. A `list` with no daemon running answers an empty held set without starting one; a transport failure proves nothing and changes nothing.

## Modes

- **Session buffer**: `sprig-session-mode`, a read-only major mode on `magit-section`, that owns its session and carries the mark-and-instruction verbs. The only conversation surface.
- **Changeset review**: `sprig-review-mode`, a read-only major mode on `magit-section` over the working-tree diff, carrying the draft-comment verbs. Owns no session; it publishes to one.
- **Navigator**: `sprig-status-mode`, a major mode on `tabulated-list`.

Three of them share a change shape and a rendering grammar, which is why those live apart from all three: `sprig-change.el` (the change plist and the two engines that build it, pure and free of `magit-section`) and `sprig-render.el` (the change faces, the file and hunk sections, and marks).

## Status

Everything above the "Authoring by hand" heading is **shipped**, and its core now is too: the ground-truth diff parser and the single-region staging buffer, seeded from a hunk in the model, a file you name, or a region the agent suggests, applied by sending the bytes to the agent directly (with the override courier available as the opt-in tamper-proof path). What remains is the on-demand feedback verb and the multi-file change set.

### Shipped

- **Transport.** Parses the `claude` stream-json into a backend-neutral event vocabulary and routes it to a session-owning session buffer through a per-buffer sink. One process per session, local or over SSH (`sprig-remotes`); several sessions can stream at once. Graceful `c i` interrupt over the same stdin channel, leaving the process live.
- **Session buffer** (`sprig-session-mode`). Read-only `magit-section` render of the model. The tool-payload diff engine reconstructs per-file, per-hunk changes from `Edit` / `MultiEdit` / `Write`; file changes render as a foldable coloured diff with their folded result. Also renders assistant prose (markdown-fontified), thinking, a todo checklist (from `TodoWrite` and the granular `TaskCreate` / `TaskUpdate` stream), and `Agent` rows that nest a subagent's whole run and narrate it live.
- **Store.** History is replayed from the CLI's own session JSONL (`sprig-session-log-model`), skipping subagent sidechains; Sprig keeps no store beyond the session id and cwd that locate the file.
- **Marks and verbs.** `SPC` / `m` mark; a verb acts on the marked set or the section at point. `c` transient: `c c` steer-or-send, `c q` queue, `c Q` drop the queue, `c p` plan, `c r` independent review, `c l` resend, `c i` interrupt. `k` reject a hunk or unstage a floated message, `x` run, `C` commit, `a` accept, `RET` visit (over TRAMP when remote), `t` retitle. `s n` new conversation, `s f` fork (`--resume --fork-session`).
- **Plan mode.** `c p` sets the CLI permission mode over stdin (`set_permission_mode`) for one turn.
- **Navigator** (`sprig-status`). Lists the CLI's session logs per project directory across every host (local plus each of `sprig-remotes`), grouped and foldable, with live status glyphs (including `?` waiting-on-you) and a markdown-rendered preview of the last exchange with a time column and sort. Steers a session from the list without opening it (`c` / `a` act on the row's session). The working-directory prompt for a new session completes real paths (locally, or over the session's own SSH transport for a remote host, so no TRAMP) and suggests the directories the host's sessions already run in, drawn from this same cached scan rather than any new config; `S S` shows that list as a view of its own, each root a launch point.
- **Performance.** Settled prose fontification is memoised, and the structural-render coalescing timer adapts to the last render's measured cost.
- **Ground-truth diff parser.** `sprig-parse-diff` folds `git diff` into the tool-payload change shape, so the stat, formatter, and renderer all consume it unchanged (source 2 above).
- **Changeset review (`sprig-session-review`, `d`).** The working-tree diff as a review pass: an index of the changed files, then each as foldable unified hunks with old/new line numbers, read by running `git diff` directly (a read the invariant permits) and over the session's SSH transport when remote. `c c` drafts a comment on the line at point or on the region; drafts render inline under the line they annotate, `c e` re-edits one, `k` takes one back, `c Q` discards the lot. `g` re-reads the diff and re-anchors every draft by its recorded text, orphaning rather than dropping the ones whose lines have gone. `c p` publishes the whole set as one turn through the ordinary compose buffer, grouped by file and ordered by line, each comment quoting its lines. `e` hand-authors the hunk at point instead, seeded with its new side; `c m` sends a plain message about the marked hunks. Positions come from the git diff's new `:unified` view (`sprig-parse-diff`), which a tool payload cannot supply.
- **Independent review (`c r`).** Asks the session to spawn a subagent (the Task tool) that reviews the uncommitted changes cold, then to address its findings. A subagent has its own context, so it is not the same agent marking its own work, and Sprig already renders the run as a nested `Agent` row; marked sections narrow the review. No new plumbing: the closed review loop is a canned instruction, not a Sprig-orchestrated background session.
- **Authoring by hand (single region).** `e` is a transient with three ways to seed a local `*sprig-stage*` buffer, opened in the file's own major mode: `e e` the hunk at point (straight from the model), `e f` a file and optional region hint you name, and `e s` the region the agent suggests from the conversation it is already in (with an optional nudge, since it already knows the task). The two agent-read routes ask for one `Read` and seed from its result when the turn ends (its bytes reconstructed from the `cat -n` output are the on-disk `old_string` anchor); `e s` learns the file from the read itself, so no file is named up front. You rewrite the buffer and `C-c C-c` applies it: by default apply sends the agent the `old_string` and `new_string` and asks for one verbatim `Edit`, which works in every mode and leaves nothing to fail at a permission gate (the agent does the write, so the resulting diff is the check). Setting `sprig-courier-edits` switches to the tamper-proof path: apply stages the human's `(file, old_string, new_string)` on `sprig--courier` and asks for one `Edit`, and `sprig--maybe-courier` overrides its bytes via `updatedInput` at the permission prompt (probe-confirmed against CLI 2.1.224), so the agent supplies no content; that path refuses the auto-approve modes, since it needs a prompt to override.

### Known gaps

- **Thinking is replay-only:** the live stream parser has no thinking branch, so a turn's reasoning appears only on the next replay.
- A change made by **`Bash` rather than `Edit` / `Write` shows no diff *inline***: the changeset review (`d`) renders the net working-tree diff (local or remote), but the inline transcript is still tool-payload only.
- **`/model` and `/clear` have no live verb** (`sprig-model` feeds `--model` at spawn only).
- A **remote** session's `Agent` rows replay without their subagents' steps: those transcripts are files beside the log, and a remote log is read by shell rather than by path, so there is no name to find them by.

### Next

- **Hand-authoring, remaining:** the multi-file **change set** (staging regions from several files at once, then the interleaved prose chunks of the literate-programming lens). Single-region staging is shipped (above), applied by direct send with the override courier as an opt-in.
- **Rendering the working-tree diff inline** as an "unattributed changes" section in the transcript (the changeset review `d` ships the standalone view, local and remote; folding it into the transcript is the remaining half).
- **Persisting draft comments** across an Emacs restart, if composing a long review across sessions turns out to matter. They are one plist, deliberately, so this is small; it is not done because Sprig owns no store and a draft would be the first thing it did.
- **Separating the agent's changes from your own** in the review, which is the same attribution problem the shadow-ref idea above would settle.
- The richer **markable plan-tree review** from the plan-mode section.
- Finer **`x` granularity** (a code block inside prose, not just a tool command).
- **Incremental section append** (render only the active turn, O(turn) not O(conversation)) for large histories.
- Drawing the **fork forest** in the navigator, now that `s f` makes forks real.
- The **session broker** for detach and reattach (design above): a per-host holder process so a remote session survives a dropped SSH link and its in-flight turn is not lost. The broker core (spawn, attach, spool, detach, reattach-by-offset, stop, plus a single `open` verb that attaches-or-spawns) is built and tested against a real session in `broker/`, and Sprig now drives it behind the opt-in `sprig-use-broker`: a remote session runs `python3 BROKER open ...` in place of `exec claude`, shipping the broker to the host on first use and reattaching by CLI session id (a fork never attaches to its live parent). Opening the navigator auto-reattaches held sessions in the background, discovered by a `<id>.sprig-live` marker the broker drops beside each held log (found by the same scan that reads the stars, no extra query) and reattached attach-only so a stale marker is harmless; `sprig-status-auto-reattach` gates it. A held session no buffer has attached to yet reads as `held` (a `◌` glyph, alive on its host) rather than `disconnected`, so it survives the live filter and sorts as alive. Setting `sprig-use-broker` to `all` extends the same path to **local** sessions: a local session runs `python3 BROKER open ...` as a direct child of Emacs reaching a detached local daemon, so it outlives Emacs itself and a later `sprig-status` reattaches to it, exactly as a remote one survives a dropped SSH link. Because a resume names its session id up front, the broker seeds the `<id>.sprig-live` marker from that id at spawn rather than waiting to scrape it out of the stream, so a resumed-but-idle session reads as `held` at once instead of only after its next turn. Detaching the daemon takes more than `setsid`: a bare `setsid` child still sits in the SSH login's `systemd` `session-N.scope`, which `logind` tears down on logout and, where `KillUserProcesses=yes` (the `systemd` default), kills every process in, daemon included. So the daemon is started as a transient `systemd-run --user` unit under `user@UID.service`, which logout leaves alone, with the old `setsid` launcher as the fallback when `systemd-run` is absent; this survival then depends on lingering being on for the user (`loginctl enable-linger`), without which the user manager itself stops at logout. `SPRIG_BROKER_NO_SYSTEMD` forces the `setsid` path (the shell test sets it, so a run never touches the real user manager). The one thing not yet machine-verified is a live end-to-end attach from Emacs over a real SSH link; the command construction (remote and local), install, resume/fork, marker parsing, reattach, and held-status logic are unit-tested, and the marker lifecycle (including the eager resume seed), attach-only refusal, and detach/reattach are covered by the broker's own shell test. Remaining: multiplexing polish, spool trim, and re-adopting live children on a daemon restart.

### Deferred

- Merging or comparing branches beyond a plain `diff`.
- Summarising a long transcript to fit the context window.
- Reference-style forks (store only the divergent tail) if copy duplication ever bites.
- Backend abstraction: a stateless messages backend would want the whole transcript replayed, where the `claude` CLI keeps memory server-side and takes only the new turn.

### Open questions

- How thin a backend interface can be while spanning providers that differ this much on memory and resume.
- Whether a subagent's work is reviewable or merely visible: `k` on a hunk a subagent wrote is an instruction to the *main* agent, which did not make the edit itself.
- For the **broker**: the spool retention policy (last turn boundary, or last acked offset across clients); and how a broker and a newer Sprig negotiate version skew on attach. (Whether local sessions route through it too is now settled: `sprig-use-broker` set to `all` brokers them, at the cost of a local daemon, so a local session survives an Emacs restart.)
