# Design: Sprig

## Name

**Sprig**. Package `sprig`, function prefix `sprig-`, review major mode `sprig-review-mode`, navigator major mode `sprig-status-mode`. Model-agnostic: the agent backend is not fixed. Rejected: `org-agent` (reserved `org-` prefix, crowded), `owl-mode` (collides with OWL/ontology modes). A sprig is a small shoot off a branch.

## What Sprig is

An Emacs interface for **reviewing and steering** an LLM agent's work, aimed at breaking out of linear chat. A conversation is a read-only, **Magit-like review buffer** (built on `magit-section`) whose one job is to review and steer the agent efficiently: the agent's file edits render inline as a foldable diff, you mark what you care about, and single-key verbs send the agent instructions. There is no chat input line and no Markdown file to edit. The whole set of conversations is driven from a `sprig-status` navigator.

A conversation *is* a `claude` session, and Sprig keeps no store of its own. The CLI already persists each session as JSONL under `~/.claude/projects/<cwd>/<id>.jsonl` on the host where it runs, so history is replayed from that log and survives an Emacs restart because the session id names the file. The transport is a persistent Claude Code session, local or over SSH, via the `claude` CLI's stream-json protocol.

**The ownership crux.** Agentic coding has a problem it does not solve: the author of record understands the code least. The agent writes, the human skims and approves, and ownership erodes along with understanding. Sprig's default posture, reviewing and steering the agent's edits, is the fast path and lives with this. Navigator mode is the deliberate counterweight: a slower posture that trades throughput for the one thing skimming cannot buy, which is that the human has engaged with every line, because the human wrote it. The two postures are the same buffer with the roles rotated, so you move between speed and ownership without changing tools.

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

The shipped review buffer uses source 1 only. It needs no git plumbing, works over SSH, and delivers most of the review value. Source 2 is a later slice, and navigator mode (below) is what first brings it in, since the human's own diff has no tool payload to reconstruct from.

A possible upgrade makes the metaphor literal: mirror each completed turn as a commit on a hidden ref (`refs/sprig/<session>`), one commit per turn, so attribution and revert come free from git. Costs to weigh first: isolating the user's own uncommitted changes from the agent's, and per-turn snapshot overhead. Under the instruction invariant below, Sprig cannot run this git machinery itself, so even the shadow ref would have to be the agent's doing (a per-turn "record a snapshot" instruction) or the invariant relaxed. That tension is why it is deferred.

### Marks as the universal primitive

Marking is the one gesture everything composes through, the way Magit's region-and-stage selects hunks.

- Marking is the index. `c c` attaches whatever is marked as the context of the next message: a hunk, a plan step, a tool result, a paragraph.
- Marks also drive **actions on the transcript**, with the verb section-type-aware. `c c` is type-agnostic. Type-specific verbs act on the applicable subset: `k` rejects marked hunks (instructs the agent to undo them), `RET` visits, `x` runs a marked code block.
- Verbs marks unlock: re-send a marked past user turn as a fresh turn (`c r`, no history rewrite); mark a hunk then `c c` to frame the message as "about this change" with the hunk inlined, so reviewing-by-replying is one gesture.

### Sending is committing

There is no input area. Sending mirrors Magit's commit gesture. `c` opens a transient:

- `c c` compose and send, which **steers a turn already in flight**. Pops a dedicated `SPRIG_MSG` buffer: your prose on top, a commented preamble below showing exactly what context is attached and what the agent last said, the way `COMMIT_EDITMSG` shows the diff. `C-c C-c` fires, `C-c C-k` aborts. You never guess what you sent. The CLI's stdin stays open across a turn, so a message sent into one is handed to the agent at its next tool-call boundary: it changes course inside the same turn, with no interrupt and no restart. This is what makes watching a turn worthwhile rather than merely tense; the choice on a turn going wrong stops being "let it finish" or "kill it". With no turn running, the same verb opens one. There is deliberately no separate steer verb: whether a turn happens to be running is the transport's business, not a distinction the user should have to hold in their head and press a different key for.
- `c q` compose and queue, held until the running turn ends and then sent as a turn of its own. The counterpart to `c c`, and what makes it safe to merge steering into it: `c c` is for the correction worth interrupting the agent's train of thought for, `c q` for the follow-up that is not. Without `c q` the merge would leave nothing that means "not now", and `c c` mid-turn would have to keep refusing, which is the worst of the three answers.
- `c Q` drop the queued messages, leaving the turn to run. Deliberately not folded into `c i`, which sends them: a queued message is the next thing, not the rest of this thing, so stopping the turn does not unmake it, and interrupting with one queued is the useful "stop, do this instead". That leaves `c Q` as the only way to take a queued message back, which it has to be anyway: nothing was sent, so there is nothing to steer or interrupt, and without it a queue would be a thing you could start and never stop. Stopping the turn and meaning it is then `c Q c i`, two gestures that each say one thing, rather than a compound verb that says two.
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

## Navigator mode (mixed-initiative)

The second posture, and the answer to the ownership crux named under *What Sprig is*. Pure after-the-fact review of the agent's edits invites rubber-stamping, and rubber-stamping is how understanding and ownership erode. The literature on automation bias and overreliance names the failure; pair programming names the fix, which is to rotate roles and give the navigator an explicit job. So Sprig gains a role you toggle. In the default **driver** posture the agent drives and you review its edits, as everything above describes. In the **navigator** posture the roles rotate: you write the code yourself, and the agent's job is feedback on what you wrote, not edits of its own.

The inversion is clean because it flips the *subject* of the buffer, not its machinery. In the driver posture the subject is the agent's edits, reconstructed from tool payloads. In navigator mode the subject is your working-tree diff, which is exactly source 2, "ground truth via git", now made central. The agent obtains it the invariant-respecting way, by running `git diff` itself, and Sprig parses that Bash result into the same foldable hunks the tool-payload path produces. Feedback then renders as prose anchored to those hunks, and marks compose as ever: mark a hunk of your own diff, `c c`, "is this the right approach?".

**The wall is a role-gated permission handler.** A live probe against CLI 2.1.224 settles the mechanism. Navigator mode switches the session into the CLI's `manual` permission mode over the same `set_permission_mode` channel plan mode already uses, so every tool call surfaces as a `can_use_tool` request on the stdio permission channel instead of running unprompted. Sprig's handler, gated by a per-buffer role flag, denies the edit family (`Edit` / `Write` / `MultiEdit` / `NotebookEdit`) and auto-allows the read family (`Read`, `Grep`, `Glob`, `Bash`), so the agent physically cannot write code. This is the anti-laziness lever, enforced by the mode rather than left to discipline. It toggles live with no respawn, and because the deny is Sprig-side the courier carve-out below is just the same handler allowing one matching write. A `--append-system-prompt` line is spawn-time and cannot change on a live toggle, so the navigator instruction (you are the navigator, do not edit, hint rather than solve, the triadic "withhold the solution" pattern) rides in as a sent turn on the switch. Two known costs: `Bash` stays allowed and is an escape hatch (`sed -i`, `echo >`), so the wall is belt-and-braces, not airtight; and `manual` routes read tools through the handler too, one cheap local round-trip each, which is the price of not hard-disallowing edits at spawn (`--disallowedTools` would refuse the courier write as well, and could not toggle live).

**Feedback is on demand, never proactive.** The trigger is a verb, not a watcher. You write, then you ask. This is the Horvitz rule that invited proactivity keeps the user's sense of control, and it is also the cheapest to build and the least token-hungry. A canned "review my changes" verb, in the family of `k` / `x` / `C`, attaches your working-tree diff (or the marked subset of it) and asks for feedback. On-save and on-green boundary triggers, and any continuous watching, are explicitly out for navigator v1.

**Rotation is the mixed-initiative control.** The role toggle is one keystroke and shows in the metadata header beside the permission mode, the way plan mode's status already shows there. Getting the agent to write again is a deliberate flip back to driver, so the rotation is the discipline: there is no "just do it" that quietly relaxes the wall. Role is Sprig-side live-session state; the CLI log does not carry it, so it is not persisted, and a reopened session defaults to driver.

### Authoring through staging buffers

Where the navigator actually writes code is the crux on a remote host, and it forces the mechanism. `RET` visits a file over TRAMP, read-only. If navigator mode let you edit that TRAMP buffer and save, Emacs itself would write the remote file, which breaks the invariant that only the agent touches the repo, and TRAMP editing is laggy besides. So the navigator never edits a file in place. You author in a local, non-file-backed **staging buffer**, and the agent is the courier that puts the bytes on disk. Editing is pure local Emacs, instant and in the correct major mode; the only remote traffic is the agent reading the region and writing it back, both over the stream-json channel already open. This is uniform: local sessions stage the same way, so there is one model and the invariant stays pure on both paths. Direct file editing outside Sprig remains available locally for those who prefer it, with the agent picking the change up from the working tree.

The loop:

- **Seed.** You target a region: mark a hunk or a symbol, or "let me edit `bar`". Sprig fills the staging buffer from the agent's `Read` result, which the model already parses, so there is no TRAMP read and no invariant breach. If the region is already in a recent `Read` in the transcript, seed from that with no round-trip; otherwise the seed costs one `Read` turn.
- **Edit.** You change the buffer freely, offline and local.
- **Apply.** Sending mirrors the `c c` commit gesture. Sprig records the exact target and content and instructs the agent to write precisely that.
- **Review.** The change lands as a hunk in the working-tree diff, renders as your attributed change, and is now something you can ask the navigator to critique. Author, courier, review, in one loop.

**The agent is a courier that cannot tamper.** The apply verb is a narrow carve-out in the hard block: `Edit` / `Write` stay denied, except that the role-gated handler approves the one resulting write whose payload matches the staging buffer byte-for-byte, and denies any deviation. The probe confirmed the `can_use_tool` request carries the `old_string` / `new_string` in its input, so the handler compares the agent's proposed edit against the staging region at permission time, before a byte is written. This reuses the handler that already inspects every tool payload, and it gives the courier side the same enforced guarantee the hard block gives the author side: the human writes every byte, and the agent transcribes without being able to edit under cover of transcribing. Trusting the instruction instead would be less build, but it would reopen exactly the authoring gap the mode exists to close, so the equality check is part of navigator v1, not a later hardening.

**Region maps to `Edit`, whole-file to `Write`.** The primary case is a region: the section the agent presented is the `Edit` `old_string`, your edited buffer is the `new_string`, and Sprig holds both and builds the exact call. A useful property falls out, that if the file drifted since the seed read, `old_string` no longer matches and the write fails safely, which is the correct outcome. A new file or a full rewrite is a `Write` of the whole buffer, simpler but with no staleness guard, so region editing is preferred where it applies.

### The staging buffer is a change set

A staging buffer holds regions from several files, not one. The case for it is the navigator's real job: an implementation usually spans files, and identifying the touch points, then narrowing each to the region that actually changes, is the strategic framing the agent should do so the human can write in one place. So the staging buffer is a **change set, not a file**: an ordered list of labelled regions, each tagged with its file and anchored to the `old_string` the agent presented, with read-only headers and editable bodies. The single-file buffer above is just the `N = 1` case, nothing special.

This rides the existing grammar rather than bolting on. The change set is the authoring dual of the multi-hunk review: you already assemble sets by marking across the transcript, so the region set is gathered the same way, and applying it is a verified batch the way `k` rejects a batch. Partial failure reuses the dispatch rule too. Each region applies as its own verified `Edit` (or `Write` for a new file), sequentially; if a region's `old_string` has drifted it fails and stays in the buffer while the rest land, reported per "act on the applicable subset, always report". There is no cross-file transaction, and drift is rare in navigator mode since only the user's own out-of-band edits can cause it.

Two tensions are worth naming rather than glossing.

- **Scoping is the agent doing design.** If the navigator picks the regions, it quietly decides which files change, and a human filling in blanks the agent drew is a subtle re-entry of the anchoring the mode exists to fight. So the agent only *proposes* the region set; the human **curates** it, adding a file it missed, dropping one, resizing a region, and that curation stays a human design act. The buffer is a proposal to edit, not a fixed template.
- **One buffer, many languages.** A single major mode gives syntax highlighting for free; a change set needs each region fontified in its own file's mode, which is polymode / mmm territory. Navigator v1 stance: best-effort per-region fontification with headers as chrome, and plain text is an acceptable fallback if it proves fiddly.

### The change set as dynamic literate programming

Seen from a distance, this is literate programming with the agent as the weaver. Knuth's *web* is one document ordered by the logic of the change rather than by file boundary, interleaving prose with code chunks; the *tangle* step extracts the code into real files. The change set is the web, the courier apply is the tangle, and the dynamic part is that the agent assembles the chunk set per task instead of the human maintaining a permanent literate source. The real files stay canonical, so this is a transient literate *view* over the code, not a replacement source format, which is what keeps it lightweight.

The concrete thing the lens buys is that the change set may interleave **prose chunks** with the code regions, not only code. The prose is the design intent and the running dialogue with the navigator, sitting next to the regions it explains. On apply only the code regions tangle to files; the prose never touches disk. It has a natural home instead, feeding the message to the navigator or the commit body, which folds straight back into "sending is committing".

The limit is worth stating so the analogy is not over-read: there is no counterpart to Knuth's *weave*, the published-documentation output, and the web is not canonical here, so this is literate programming as a workflow, not as a source format. The design should not be tempted into persisting the web.

## Store versus view

The buffer is a pure render of an append-only event log, so store and view are separate. And that log already exists: **Sprig does not own it.** The `claude` CLI persists every session as JSONL under `~/.claude/projects/<cwd>/<session-id>.jsonl` on the host where it runs, where `<cwd>` is the working directory with each `/` and `.` turned into `-`. For a remote session that file is on the SSH host, so the store is durable and remote-side with no work from us. A review buffer replays full history by reading that file and mapping its records onto the shared event vocabulary (`sprig-review-session-model`), the store counterpart of the wire parser. The log is really a tree (records link by `uuid`/`parentUuid`) and subagent transcripts are flagged `isSidechain`; the reader follows the main thread and skips sidechains.

So Sprig keeps essentially no local store: just a pointer (session id plus cwd) to locate the file, and even that the navigator could rediscover by scanning the projects directory. Markdown is at most an *export*, not the live truth.

## Modes

- **Review buffer**: `sprig-review-mode`, a read-only major mode on `magit-section`, that owns its session and carries the mark-and-instruction verbs. The only conversation surface.
- **Navigator**: `sprig-status-mode`, a major mode on `tabulated-list`.

## Status

Everything above the "Navigator mode" heading is **shipped**. Navigator mode itself is designed but not yet built; it is the next major slice.

### Shipped

- **Transport.** Parses the `claude` stream-json into a backend-neutral event vocabulary and routes it to a session-owning review buffer through a per-buffer sink. One process per session, local or over SSH (`sprig-remote`); several sessions can stream at once. Graceful `c i` interrupt over the same stdin channel, leaving the process live.
- **Review buffer** (`sprig-review-mode`). Read-only `magit-section` render of the model. The tool-payload diff engine reconstructs per-file, per-hunk changes from `Edit` / `MultiEdit` / `Write`; file changes render as a foldable coloured diff with their folded result. Also renders assistant prose (markdown-fontified), thinking, a todo checklist (from `TodoWrite` and the granular `TaskCreate` / `TaskUpdate` stream), and `Agent` rows that nest a subagent's whole run and narrate it live.
- **Store.** History is replayed from the CLI's own session JSONL (`sprig-review-session-model`), skipping subagent sidechains; Sprig keeps no store beyond the session id and cwd that locate the file.
- **Marks and verbs.** `SPC` / `m` mark; a verb acts on the marked set or the section at point. `c` transient: `c c` steer-or-send, `c q` queue, `c Q` drop the queue, `c p` plan, `c r` resend, `c i` interrupt. `k` reject, `x` run, `C` commit, `a` accept, `RET` visit (over TRAMP when remote), `t` retitle. `s n` new conversation, `s f` fork (`--resume --fork-session`).
- **Plan mode.** `c p` sets the CLI permission mode over stdin (`set_permission_mode`) for one turn.
- **Navigator** (`sprig-status`). Lists the CLI's session logs per project directory across every host (local plus `sprig-remote`), grouped and foldable, with live status glyphs (including `?` waiting-on-you) and a markdown-rendered preview of the last exchange with a time column and sort. Steers a session from the list without opening it (`c` / `a` act on the row's session).
- **Performance.** Settled prose fontification is memoised, and the structural-render coalescing timer adapts to the last render's measured cost.

### Known gaps

- **Thinking is replay-only:** the live stream parser has no thinking branch, so a turn's reasoning appears only on the next replay.
- A change made by **`Bash` rather than `Edit` / `Write` leaves no diff**, since attribution is from tool payloads and the git ground-truth source (source 2) is deferred.
- **`/model` and `/clear` have no live verb** (`sprig-model` feeds `--model` at spawn only).
- A **remote** session's `Agent` rows replay without their subagents' steps: those transcripts are files beside the log, and a remote log is read by shell rather than by path, so there is no name to find them by.

### Next

- **Navigator mode**, the whole mixed-initiative design above: the role toggle and hard block, on-demand feedback on the human's `git diff` (which needs the ground-truth diff source), and the staging-buffer / change-set authoring surface.
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
