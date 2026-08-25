# sprig

Sprig is an Emacs interface for **reviewing and steering** an LLM agent's work, aimed at breaking out of linear chat.

**The shape:** you never edit a transcript. A conversation is a read-only, **Magit-like session buffer** (built on `magit-section`) whose one job is to review and steer the agent efficiently: the agent's file edits render inline as a foldable diff, you mark what you care about, and single-key verbs send the agent instructions. The whole set of conversations is driven from a `sprig-status` navigator. There is no chat input line and no Markdown file to edit.

**The other half is the changeset review** (`d`): everything the agent has changed in the working tree, as one navigable diff with line numbers, where you comment on individual lines, edit what you would rather write yourself, and hand the whole review back in a single turn. Comments are drafts until you publish, so a review is composed as a whole rather than dribbled out a message at a time. The session buffer is for steering a turn in flight; this is for judging the change once it exists.

**The store is the CLI's own log.** A conversation *is* a `claude` session. The CLI already persists each session as a JSONL log under `~/.claude/projects/<cwd>/<id>.jsonl` on the host where it runs, so Sprig keeps no store of its own: history is replayed from that log, and it survives an Emacs restart because the session id names the file. The transport is a persistent **Claude Code session**, local or over **SSH**, via the `claude` CLI's stream-json protocol, so it uses whatever the CLI is logged in as (a Claude **Pro/Max subscription** works, no API key needed).

The agent runs with its normal tools. Sprig answers the CLI's interactive control requests over the same stream: when a tool needs approval that the CLI's own permission configuration does not already grant, Sprig asks you (rather than the headless auto-deny), and it enables the interactive tools that stay dark otherwise, so `AskUserQuestion` renders as a choice and plan-mode approval works. Every one of those questions is asked **in the session buffer**, never the minibuffer, and answering none of them blocks. Set `sprig-permission-function` to `always` to approve every escalation automatically and keep to pure after-the-fact review.

## How it works

Emacs runs one long-lived process per session, owned by its session buffer:

```
claude -p --input-format stream-json --output-format stream-json \
       --include-partial-messages --verbose
```

Sprig appends `--model`, `--append-system-prompt`, and `--resume` as configured. It writes a user-message JSON line to stdin; the CLI streams assistant token deltas back on stdout, which Sprig parses into a small backend-neutral event vocabulary and folds into the session buffer's model, re-rendering as the turn arrives. The session id is captured from the CLI; because the CLI names its own log file after it, that is all Sprig needs to replay the conversation later or resume it with `--resume`.

Because the whole protocol is plain stdio, running the session on a remote host is just prefixing the command with `ssh HOST`. List a host in `sprig-remotes` and its sessions, and their logs, live there instead. The remote box is where `claude` must be installed and logged in. Sprig never touches git itself: an accept, reject, or commit is an *instruction sent to the agent*, which is what makes the remote path work from day one.

## Requirements

- Emacs 28.1+ (uses the built-in `json-parse-string` / `json-serialize`).
- `magit-section` 4.0+, for the session buffer. It is declared in the package headers, so `package.el` / straight install it (and its own deps) automatically.
- `claude` CLI v2.1+ on the machine that runs the session (local or the SSH host), logged in (`claude` then `/login`).
- `markdown-mode` is optional; when present, prose in the session buffer is fontified with its faces.

## Install

Put the `.el` files on your `load-path`, then:

```elisp
(require 'sprig)

;; Run sessions on remote servers over SSH (one group each; nil = local only):
(setq sprig-remotes '("you@your-server"))  ;; add more hosts to list them all
(setq sprig-model   "claude-opus-4-8")     ;; or nil for the CLI default

;; The navigator lists local and every remote's sessions in groups; cap each one:
(setq sprig-status-max-sessions 30)
```

With `use-package` and a local checkout:

```elisp
(use-package sprig
  :load-path "~/Projects/sprig"
  :custom
  (sprig-remotes '("you@your-server"))
  (sprig-model "claude-opus-4-8")
  (sprig-status-max-sessions 30))
```

## SSH tips

- Use key-based auth and an SSH `ControlMaster` so reconnects are instant:

  ```
  # ~/.ssh/config
  Host your-server
      User you
      ControlMaster auto
      ControlPath ~/.ssh/cm-%r@%h:%p
      ControlPersist 10m
  ```

- If `claude` isn't on the non-interactive `PATH` over SSH, set the full path:

  ```elisp
  (setq sprig-program "/home/you/.local/bin/claude")
  ```

## Usage

1. `M-x sprig-status` opens the navigator, listing every stored session, newest first and grouped by the host it runs on (`local`, plus a `remote you@your-server` group for each host in `sprig-remotes`); `/` narrows it to a project or title.
2. `RET` (or `o`) on a row opens that session's session buffer, replaying its full history, on the host that row came from. `s n` starts a fresh session on the host of the group point is in, prompting for its working directory. That prompt suggests the directories the host's existing sessions already run in (no configuration, drawn from the same scan the navigator uses) and completes deeper paths live: on the local filesystem, or over SSH for a remote host. A prefix argument (`C-u s n`, or `C-u M-x sprig-session-open`) forces that one session onto the local machine wherever point sits. `s c` starts a fresh session and drops you straight into a prompt for its first message (`s p` the same but in plan mode), and `s f` forks the session at point into one of its own. `M-x sprig-session-open` does the same directly. You can also steer a session without opening it: `c` and `a` in the navigator are the session buffer's own steering transients, acting on the session under point, so `c c` composes for it and `a a` answers its waiting question from the list.
3. In the session buffer, review the agent's work: prose reads as prose, and every tool call folds to a one-line heading naming what it touched. Move with `n` / `p`, and `TAB` on an edit to unfold its diff.
4. Steer it: mark sections with `SPC`, then use a verb (below). `c c` composes a message and sends it; the session starts or resumes automatically on the first send.
5. `d` opens the **changeset review**: `d d` for the uncommitted changes, `d m` for the whole branch against main. Navigate the changed files, `c c` to comment on a line or a marked region, `c p` to publish every comment to the agent in one turn. See [Changeset review](#changeset-review).
6. `c i` interrupts a streaming turn (in the navigator too, on the session at point). The CLI ends the turn cleanly and the session stays live, so the next send continues it with no resume; if the CLI does not honour the request within `sprig-interrupt-timeout`, Sprig falls back to killing the turn and the session resumes on the next send.

The session lives on past the buffer: reopen it any time from the navigator, or resume it with `c o` there. Nothing is saved by you, because the CLI's log already is the record.

### Commands

| Command | Binding | Does |
|---|---|---|
| `sprig-status` | `M-x` | Open the navigator listing stored sessions and their status |
| `sprig-session-open` | `M-x` | Open a session buffer (start fresh, or resume an id) |
| `sprig-session-connect` | `M-x` | Start or resume the session owned by the current session buffer |
| `sprig-session-open-file` | `M-x` | Replay a session-log `.jsonl` file directly (offline, read-only) |
| `sprig-session-review` | `d d` | Open the changeset review over the session's working tree |
| `sprig-login` | `M-x` | Log the CLI in for `sprig-config-directory`, in your local browser (once per host) |

### Navigator

`M-x sprig-status` opens a `*sprig-status*` buffer listing every stored `claude` session, newest first and capped to `sprig-status-max-sessions`, plus any open session buffer that owns a live session. Each row shows a status glyph (`▶` streaming, `?` waiting on you, `●` idle, `○` disconnected), the session's project (from its own `cwd`), its title (a name you set, else the CLI's generated `ai-title`), a short session id, and when it was created (its first log record's timestamp). It refreshes itself as sessions start, stream, and finish. An active session (any open one, so anything but a disconnected `○` log) shows an inline preview of its last exchange under its row, on its own with no toggle: a state line first (what the turn is doing or how it ended, the permission mode when it is a notable one, and the context in use, `✓  turn over  ·  plan  ·  134.0k`, mirroring the session buffer's own), then your last prompt as one line, then the agent's final message as one line, each dated with its own time (`HH:MM`) and trimmed with an ellipsis where it runs past the window. Both are teasers; open the row with `RET` for the full transcript, landing on the last message so the newest reply is what you see. The message is the last block of prose the turn produced, not the running narration between its tool calls: that is the answer, the plan, or the question, and the rest is scaffolding. It updates live as the turn streams, so a running row shows the last message as it grows under the `▶  working…` line rather than only once the turn settles. `/` narrows the list to sessions whose project or title match a substring, and `l a` lifts the cap to show every session. Rows sort newest-created-first by `Created` within each group, so a session keeps its place as it runs rather than jumping to the top each turn; `l s` (or `sprig-status-sort`, or a click on a column header) sorts by another column, and repeating it flips the direction, shown as `↓Created` in the mode line. `S S` opens a roots view for the host of the group point is in: the distinct directories its sessions run in (the same list the working-directory prompt suggests), each a line where `RET` starts a fresh session there.

**Every host at once.** The list is grouped by the host a session runs on, under a foldable heading per group: `local`, plus a `remote you@your-server` group for each host in `sprig-remotes`. Each host is scanned and capped on its own, so a busy one cannot crowd the others out, and none is hidden behind a `setq`. `s n` starts its session on the host of the group point is in, which is why a group with no sessions is still headed: the heading is the place you stand to start the first one there. Opening a row pins its session buffer to the host the row came from, since a session id only resumes on the host holding its log. `TAB` on a heading folds its whole group away (the count stays, so `▸ remote you@your-server (12)` tells you what is hidden) and unfolds it again, the way `magit` folds a section.

```
▾ local (2)
● Fix the navigator's grouping        sprig       a1b2c3d4
○ Tidy the diff reconstruction        sprig       9f8e7d6c

▸ remote you@your-server (1)
▸ remote you@other-box (4)
```

| Key | Does |
|---|---|
| `n` / `p` | Move to the next / previous session, skipping headings and preview lines |
| `RET` / `o` | Open the session's session buffer (replaying its log), on the host it ran on, landing on the last message |
| `s` | Start a session: `s n` a fresh conversation on the group point is in (`C-u s n` forces it local; a session row seeds the directory), `s c` the same but straight into a prompt for its first message, `s p` the same in plan mode, `s f` fork the session at point into one of its own |
| `TAB` | Fold or unfold the host group under point (a heading or any row within it), the way `magit` folds a section |
| `c` | Steer the session at point, the session buffer's `c` transient without leaving the list: `c c` compose & send, `c y` / `c n` answer yes / no, `c p` plan mode, `c r` independent review (subagent), `c l` resend, `c i` interrupt, `c z` compact, `c b` a side question (writes no log), `c q` / `c Q` queue / drop, `c o` open & connect, `c d` disconnect |
| `a` | Answer the structured question the session at point is waiting on: `a a` one at a time, `a r` take the recommended, `a s` skip |
| `P` | Set the permission mode of the session at point (open and live), the session buffer's `P` without leaving the list: `P p` plan, `P a` auto, `P e` accept edits, `P m` manual, `P b` bypass |
| `d` | Remove the session at point: `d d` disconnect (its log is kept), `d D` delete permanently, log and all (asks first; no undo) |
| `l` | Switch the view: `l l` toggle live-only (hide disconnected `○`), `l a` toggle show-all (lift the cap), `l g` toggle the CLI's subagent (`agent-*`) transcripts in, `l s` sort, `l /` filter. Each toggle shows `[on]` in the popup while active |
| `/` | Filter the list by project or title (empty clears) |
| `S` | Show transient: `S S` opens the roots view for the host of the group point is in (each root a line where `RET` starts a session there) |
| `T` | Title transient for the session at point (saves to the log): `T a` ask the agent, `T m` set by hand (see [Retitling](#retitling)) |
| `*` | Star or unstar the session at point: a starred session floats to the top of its host group (whatever the sort) with a `★` by its project. The star is a `<id>.sprig-star` marker written beside the session's own log, so it lives with the session on its host, survives restarts, and any navigator on that host sees it |
| `g` | Refresh the list |
| `q` | Bury the navigator |

### Session buffer

The session buffer is a read-only, Magit-like view of one session. It replays the whole transcript from the CLI's session log (`~/.claude/projects/<cwd>/<id>.jsonl` on the session host) and, once connected, streams the in-flight turn in live. A remote session's log is fetched over SSH in the **background**, so opening the row returns at once and the replayed history fills in when the fetch lands rather than freezing Emacs on the round trip; `g` re-reads the same way. The agent's file edits render inline as a foldable diff, reconstructed from the `Edit` / `MultiEdit` / `Write` tool calls. Move with `n` / `p`, fold with `TAB`.

Every tool call folds to its one-line heading, so a long turn reads as a list of what the agent did rather than as pages of diff; `TAB` opens the change you want to review. Set `sprig-session-expand-diffs` to `t` to have diff-bearing tools render open instead. A `TodoWrite` heading carries the plan's progress (`2/5 done`) and unfolds to the checklist itself, each item marked done, in progress, or pending, rather than to a bare tool result. A CLI that instead drives its plan through the granular `TaskCreate`/`TaskUpdate` tools gets the same checklist: those calls fold into one running `Tasks` list rather than showing as their own rows, and a fresh snapshot appears wherever the plan next moved.

An `Agent` call carries its **subagent's whole run inside it**. While the subagent works, the row says what it is doing and moves as it goes (`Agent  Find note.txt contents  ▸ Explore: Reading note.txt`), which is the only sign of life during what can be minutes of silence. Unfold the row and its steps are there, each an ordinary tool section that folds to a line, `TAB`s open, and shows a real diff where the subagent edited a file; its report sits below them, after the work that led to it. The steps nest rather than joining the transcript on purpose: they are the subagent's work, not the main agent's, and a session buffer that mixed the two would attribute an `ls` to whoever happened to be reading.

Turns carry no role labels. Your own turns are tinted (`sprig-session-user`) and the agent's are not, which is the whole of the distinction, and only prose is padded with a blank line, so a turn's tool calls stay packed into one list.

Every block is dated in the left margin, the way `magit-log` dates a commit, so the stamp costs the prose no width and can never be mistaken for something the agent said. Replayed history is dated from the session log's own record timestamps, and a live turn is dated when it reaches the buffer; both show in local time. `sprig-session-timestamp-format` sets the format (a wider format like `"%m-%d %H:%M"` dates a conversation spanning days, `nil` drops the timestamps, and the margin sizes itself to fit).

Below the last message is the **state line**, which says outright whether anything is still going on: `▷ sent, awaiting reply` once your message is away but before the agent has answered, `▶ working…` while its turn streams in, `▼ compacting…` while the session is compacting its context, `✓ turn over` once it lands (what it cost is in the header), `✗ turn failed` when it did not, and `● idle` for replayed history (which carries no turn of its own). Compacting outranks the turn's own state because it stops the turn for a minute or more, and an automatic one lands mid-turn uninvited, which is exactly when you would otherwise wonder why nothing is moving. A compaction that fails says so inline, with the reason: the CLI reports the turn itself as a success, so nothing else would tell you. It also carries `☑ 4/5` whenever the agent is working to a plan, whether that plan arrived as a whole `TodoWrite` list or was built up through the granular task tools: the checklist itself is back up the buffer, and scrolling to it to learn how far in the agent is defeats a line whose job is to say what is going on. It stays dim and does not escalate, for the same reason the context readout does not: the line already carries the state's colour and the context's, and a third would make an ordinary running turn read as three warnings. It says `N queued` while `c q` messages wait on the turn, since a message that fires by itself must not be invisible. It sits at the bottom because that is where you are reading when a turn is coming in, and the side bar carries a rule in the same colour, so the gutter ends the turn as plainly as the line does. A turn being over is the thing you wait on, so the buffer states it rather than leaving you to notice that nothing has moved. The line also carries the context in use, since it sits where you are reading: the latest turn's prompt size in tokens. The CLI never reports the true window (it is a client-side constant, and a 1M session is indistinguishable from a 200k one by its model id), so rather than a percentage against a guess, the count itself lights up once it grows large, amber past `sprig-context-large-tokens` (150k, Anthropic's own large-context marker) and red past `sprig-context-huge-tokens` (200k, long-context territory). It is coloured on its own terms rather than in the state's colour, so it says how big the context is and nothing about the turn: a normal context stays dim even while a turn (itself amber) is streaming.

It is also the steering surface. Marking is the one selection primitive; a verb acts on the marked sections, or the section at point when nothing is marked. Every change-touching verb is an instruction sent to the agent (Sprig itself never runs git):

| Key | Does |
|---|---|
| `RET` | Visit the file the section points to (over SSH/TRAMP if remote); on a waiting question, open the answer dialog, as `a a` does |
| `g` | Re-read the session log into the buffer (its history is seeded once at open, never re-read after) |
| `t` | Retitle the buffer's header (display only; the CLI owns the stored title) |
| `T` | Title transient (saves to the log): `T a` ask the agent, `T m` set by hand, `T t` relabel the header only (see [Retitling](#retitling)) |
| `SPC` / `m` | Toggle the mark on the section at point |
| `U` | Clear all marks |
| `k` | Take it back: on a diff hunk, ask the agent to undo the marked (or point) hunks (steers, so a bad hunk can be called out while the turn is still running); on a floated queued message, unstage just that one (a steer cannot go this way, since it is already on the wire) |
| `x` | Run: ask the agent to run the marked tool call's command, or the fenced shell command in the prose block at point (a command it proposed but did not execute). Steers, so it lands in a turn already running |
| `C` | Commit: ask the agent to commit the current changes |
| `d` | Open the session's net working-tree diff in a separate buffer (see [Diff buffer](#diff-buffer)); works local or remote |
| `a` | Transient for the agent's structured dialog: `a a` answer, `a r` take the recommended, `a s` skip |
| `c` | Transient, listing every verb: `c c` compose & send (steering a running turn), `c q` compose & queue for after this turn, `c Q` drop the queued messages, `c y` / `c n` answer the agent's last prose question yes / no, `c p` compose in plan mode, `c r` an independent review of the latest changes (the agent spawns a subagent to critique them cold, then addresses its findings; marked sections narrow it), `c l` resend last turn, `c i` interrupt (anything queued then goes), `c z` compact the context (`C-u c z` steers the summary; queued behind a running turn, since a compaction is its own turn), `c b` a side question that leaves the turn and the log alone (see [Side questions](#side-questions)), and `c k` / `c C` / `c x` for reject / commit / run |
| `s` | Transient for starting a session of its own: `s n` new conversation, `s c` new then straight into a first-message prompt, `s p` the same in plan mode, `s f` fork this one |
| `P` | Transient for the permission mode (the CLI's own modes, as the shift-tab cycle names them): `P p` plan (agent plans, makes no edits), `P a` auto (normal: allowed tools run, rest prompt), `P e` accept edits (auto-approve edits), `P m` manual (prompt for every call), `P b` bypass (auto-approve everything, incl. shell) |

`c c` opens a compose buffer (`C-c C-c` sends, `C-c C-k` cancels); any marked sections are attached to the message as context, and the first send starts or resumes the session. `c p` sends the turn in plan mode (the agent plans rather than acts), switched over the session's control channel. The mode is **sticky**, the way Claude Code's own is: a plain `c c` afterwards carries on in plan mode rather than dropping out of it, so steering a plan stays a plan. You leave plan mode deliberately, by approving an `ExitPlanMode` plan or with the `P` transient (`P a` back to auto, `P e` accept-edits), which is also how you set the mode by hand at any time. The header shows the permission mode while it is not the normal one, and the mode line carries it too (`[plan]`, `[acceptEdits]`, ...).

Where `c` steers the conversation the buffer already owns, `s` is where a session of its own begins. `s n` starts a fresh conversation in this session's directory, leaving this one alone; `s c` does the same but opens its first-message prompt straight away (`s p` in plan mode); `M-x sprig-session-open` asks for a different directory. `s f` **forks**: the new buffer replays this history and carries it on under a session id of its own, so the two diverge from here and the parent's log is never written to again. The CLI forks from the end of a session, so the branch starts from where the conversation now stands, not from point; the fork itself is only made on its first send, until which the new buffer is just a replay.

**`c c` steers the turn already in flight**, rather than waiting it out or killing it. The CLI's stdin stays open for the length of a turn, so the message is handed to the agent at its next tool-call boundary: it reads it and changes course *within the same turn*, no interrupt and no restart. Until the agent reaches that boundary the message is not a transcript turn yet, so it **floats** pinned just above the state line, tinted as yours and marked `⤷` as not-yet-taken; it folds into the conversation at the point the agent actually took it, rather than splitting the streaming reply in two. Watching a turn head the wrong way, `c c` is the cheap correction and `c i` the expensive one. With no turn running the same `c c` just opens one, so there is nothing to decide and nothing to remember: you say the thing, and the message goes to the agent as directly as it can.

**`c q` queues instead**, holding the message until the running turn ends and then sending it as a turn of its own. It is the counterpart, not a variant: `c c` is for a correction, which is worth interrupting the agent's train of thought for, and `c q` is for the follow-up that is not (*"when you're done, update the README"*), which is not worth derailing work that is going fine. A queued message **floats** the same way a steer does, just below any pending steer and marked `⧖` (it is only parked, not yet on the wire, so an hourglass rather than the steer's arrow), so a follow-up waiting its turn is as visible as a correction. The state line shows `2 queued` while anything waits, since a message that fires by itself must not be invisible. Each queued message gets a turn of its own, one per turn.

`c i` **sends** anything queued, because an interrupt ends the turn through the same path a normal finish does, and a queued message is the next thing rather than the rest of this thing. So interrupting with one queued reads as *"stop, do this instead"*. **`c Q` drops the queue** and leaves the turn alone: it is the only way to take the whole queue back, since nothing has been sent and there is therefore nothing to steer or interrupt. **`k`** on a floated queued message takes just that one back (the same take-it-back gesture that rejects a diff hunk), where `c Q` clears the lot; `k` on a steer cannot help, since a steer is already on the wire (`c i` is the only way to stop mid-turn input, and it stops the whole turn). To stop the turn and mean it, `c Q` then `c i`, two gestures that each say one thing. A dropped message is echoed to `*Messages*` rather than binned in silence, since nothing else is holding it.

Which of the two `c c` does is settled when you send, not when you start composing, so a turn ending while you are still typing changes nothing you have to think about. `c p` is the one verb that still refuses mid-turn: a plan turn sets the permission mode first, so it cannot fold into a turn already running under another one.

When the agent calls `AskUserQuestion` mid-turn, the question renders **in the buffer**, with its options, and the state line turns to `? waiting on you`: the turn is not working, it is stopped, and it is stopped on you. The session buffer stays a session buffer, so answering has a buffer of its own, the way `c c` composes in one:

| Key | Does |
|---|---|
| `a a` | Answer, one question at a time, in `*sprig-answer*` (`RET` or `1`-`9` picks, `o` types an answer of your own, `C-c C-c` skips one, `C-c C-k` skips the rest); on a plan, approve or reject |
| `a r` | Take the option each question recommends, without opening anything; on a plan, approve |
| `a s` | Skip; the agent goes on unanswered |

The choice rides back to the agent and the question settles in place, showing what was said. Nothing blocks: the CLI's request is handled inside the process filter, so a prompt there would hold Emacs itself for as long as the question went unanswered.

**A plan** (`ExitPlanMode`) comes the same way, and renders in full, fontified: `a a` approves or rejects it (a rejection reads the feedback the agent plans again against), `a r` approves. Approving used to be a `y-or-n-p` naming the plan's first line, over a buffer that rendered the plan nowhere at all.

**A tool wanting permission** comes the same way too, showing what it wants to run: `a a` allows or denies it, `a s` denies. `a r` refuses to touch it, one keypress allowing an unread call being the wrong thing to make easy. Set `sprig-permission-function` to `always` to skip the asking, or to `sprig-permission-prompt` for the old minibuffer prompt, which blocks. When it presents a plan (`ExitPlanMode`), the plan renders in the buffer and Sprig asks you to approve it or reject it with feedback; approval exits plan mode and the agent starts work, a rejection sends your feedback back for a revised plan.

### Changeset review

`d` opens the **changeset review**: the changes as one navigable diff you annotate line by line and hand back in a single round. `d d` reviews the uncommitted changes, `d m` the whole branch against main or master, and `d b` against a base you name. Where the session buffer reconstructs each edit from its tool payload turn by turn, this is the one cumulative diff of the whole tree, so it also catches a change made by `Bash` (a formatter, a `sed`, codegen) that has no payload to render from, and your own hand-authored edits alongside the agent's.

It opens as the list of changed files, one line each with its stat, folded. That is the shape of the changeset, and it is the first thing a review wants: forty files unrolled is not a shape, and there is no separate index above them because the folded headings already are one. `TAB` opens the file at point into unified hunks with old and new line numbers in the margin, `S-TAB` cycles the whole buffer, `n` / `p` move, `RET` visits the file at the line under point. A file carrying a comment opens itself, and says so on its heading, because a draft you cannot see is worse than a longer buffer.

**`g` holds your place.** Re-reading the diff keeps the line under point and the files you had open, so a refresh after the agent has worked is a re-read rather than a fresh start. The line is found again by its own text rather than by buffer offset or line number, the same way a draft comment is re-anchored, which is what makes it survive both the diff above it growing and the file around it gaining lines. Where that text now appears twice, the nearest to the old number wins. If the agent has unwritten the very line you were reading, point falls back to roughly where it was.

**The code is syntax-highlighted and the change lives in the gutter.** Reviewing is mostly reading code, so the code carries the colours you read it in normally, in the file's own major mode, and whether a line was added or removed is said by the line-number columns and the `+`/`-` marker instead of by painting the whole line. A removed line colours its old-side number, an added one its new-side number, and the marker stays so colour is never the only signal. Each side of a hunk is fontified as one block, so a multi-line string or comment inside the hunk comes out right; one that opens *before* the hunk cannot, since only the diff is read and never the file. Results are memoised, so re-rendering after every comment stays cheap. `sprig-review-fontify-code` turns it off, which puts the colour back on the whole line.

**Comments are drafts.** `c c` comments on the line at point, or on the region if one is active, in a small buffer (`C-c C-c` files it, `C-c C-k` throws it away). The comment renders inline under the line it annotates. Nothing reaches the agent until you publish, so a review is composed as a whole rather than dribbled out a message at a time. `c e` re-edits the draft at point, `k` takes it back, and `c Q` discards the lot.

**`c p` publishes.** Every draft goes out in one turn, grouped by file and ordered by line, each quoting the lines it annotates so the agent can find them without guessing. It opens the ordinary compose buffer first, so you write the covering note and see exactly what goes out before it does; `C-c C-c` in the session buffer does the same.

**Comments survive a refresh, honestly.** A draft records the file, the side, the line range, *and* the text of the lines it was written against. `g` re-anchors every one: text still at its line keeps the line, text that moved follows it, and text that has gone from the diff is marked orphaned and floated to the top of its file with a note saying so. A comment you wrote is never dropped on your behalf, and never left pointing at a line number that now means something else.

**`e` writes it yourself.** Some feedback is quicker to write than to describe. `e` on a hunk opens the staging buffer seeded with that hunk's new side, the context and added lines exactly as they stand on disk, and `C-c C-c` there asks the agent to apply your edit (see [Authoring by hand](#authoring-by-hand)). `c m` is the other escape hatch: a plain message about the marked hunks, for feedback about the change as a whole rather than a line of it.

**What it diffs against.** Three scopes, and the summary line at the top always says which one it is showing, next to the file count and the total stat.

| Verb | Scope | Runs |
|---|---|---|
| `d d` | Uncommitted changes: what the tree has that the last commit does not | `git diff HEAD` |
| `d m` | The whole branch: commits *and* uncommitted work, from where you diverged | `git diff --merge-base <default>` |
| `d b` | Whatever you name | as below |

`d m` is the scope a pull request would show, and it is the one to reach for once the agent has been committing as it goes. It is deliberately not `git diff main`: that compares against main's *tip*, so every commit main has gained since you branched shows up inverted, as changes you appear to have reverted. Nor is it `git diff main...HEAD`, which fixes that but drops your uncommitted work. `--merge-base` is both halves and neither bug.

**`d m` finds the default branch rather than assuming one.** Some repos call it `main`, some `master`, some something else, and some carry both part-way through a rename. It looks for every name in `sprig-review-default-branches` (`main`, `master`, `trunk`, `develop`, `default`) as a local branch and as any remote's, in one `git for-each-ref`. One match wins outright. Several, which is the both-`main`-and-`master` case, are broken by the forge's own `origin/HEAD` rather than by list order, so a repo mid-rename resolves to the branch it actually uses. None still asks `origin/HEAD`, which catches a project whose default is `release`. A local branch is preferred over a remote-tracking one, since it is what you would type and it diffs without a fetch, but `origin/main` alone is a perfectly good base and is used when there is no local branch. If nothing answers, `d m` prompts you for a base instead of refusing.

`b` inside the review changes the scope in place and re-reads. Prefer it to reopening: the drafts come across, re-anchored by their recorded text the way `g` re-anchors them, so widening the scope halfway through a review keeps the comments you have already written. The base is buffer-local, so two reviews of one session can sit at different scopes.

`sprig-review-base` sets the default (`"HEAD"`). A plain branch name there gets the `--merge-base` treatment above; anything containing `..` is passed to `git diff` verbatim, so `"main...HEAD"` still means exactly what git says it means. Untracked files are never shown, since `git diff` omits them.

**Why the line numbers come from git.** An `Edit` payload knows the bytes it replaced but never the line they sat on, so line-anchored review can only ride the working-tree diff. Sprig reads that diff by running `git diff` itself, which is a read, not a change, so it keeps to the instruction invariant: every *write*, publish included, still goes through the agent. For a remote session the diff is read over the same SSH transport the navigator reads logs over, not TRAMP; only an optional `RET` file visit uses TRAMP.

### Side questions

`c b` asks a quick side question about the session without disturbing it, the way Claude Code's own `/btw` does. It opens a compose buffer the way `c c` does (`C-c C-c` asks it, `C-c C-k` cancels); asking fires a throwaway one-shot that **forks the session** (so the question sees the whole conversation), streams the answer into a `*sprig-btw*` buffer, and vanishes. The panel reveals its markdown the same way a review reply does, a completed paragraph at a time (see `sprig-session-defer-live-prose`), so nothing shows raw first and then re-renders. It is a separate process, so it neither opens a turn nor waits on one: you can ask while a turn is streaming, and the real session carries on untouched. It also works from the navigator (`c b` on the row at point), so you can ask about a session without opening it.

**It writes no log.** The fork runs with the CLI's `--no-session-persistence`, so nothing is saved to disk and no stray row appears in the navigator; the parent session's own log is never touched either. Any sections you marked ride along as context, exactly as `c c` attaches them.

The one honest limit is mid-turn. A `--resume` fork sees the conversation only up to the last saved turn, because the CLI does not flush the in-flight turn to the log until it ends. So when a turn is streaming, Sprig adds that turn's live text to the question itself, from its own model, which is what lets a mid-turn side question see what the agent is doing now. The settled history keeps its real turn structure; only the in-flight tail is added as text rather than as its own turns. One side question runs at a time.

### Retitling

`T` is the title transient, in the session buffer or on the navigator row at point. `T a` asks the agent for a fresh title: it reuses the side-question fork, so it sees the whole conversation and disturbs nothing, and asks for one short title; when the answer lands it is proposed in the minibuffer for you to accept with `RET` or edit. `T m` skips the agent and lets you type a title straight away. In the session buffer `T t` (and the plain `t` key) relabels the open buffer's header only, which does not persist; `T a` and `T m` stick.

The rename sets the session's **user title**, the same thing the CLI's own `/rename` sets, not the auto-generated `ai-title` Sprig usually shows. For a live session Sprig sends `/rename` down the wire it already holds, letting the CLI write the title itself; for a closed one it writes the same `custom-title` record straight to the log. A user title is never regenerated, so it always wins over the generated one and never gets buried when you keep working. As a bonus, Sprig now also shows titles you set with the CLI's own `/rename`, which it used to ignore.

## Tutorials

Task-focused guides live under [`docs/tutorials/`](docs/tutorials/):

- [Authoring by hand: writing code yourself](docs/tutorials/authoring-by-hand.md) — write a piece of the change yourself with `e` in a session buffer, and let the agent write your bytes to disk without Sprig touching the repo itself.

## Options

| Variable | Default | Meaning |
|---|---|---|
| `sprig-remotes` | `nil` | SSH destinations the navigator lists a `remote` group for, one per host; the first is the primary remote new sessions default to. Nil = local only |
| `sprig-program` | `"claude"` | Path to the CLI on the session host |
| `sprig-directory` | `nil` | Fallback working directory for a new session |
| `sprig-config-directory` | `nil` | `CLAUDE_CONFIG_DIR` for sprig's sessions, keeping their logs and login separate from `~/.claude` (nil = the CLI default). Log in there once with `M-x sprig-login` |
| `sprig-model` | `"claude-opus-4-8"` | Model id, or nil for CLI default |
| `sprig-interrupt-timeout` | `5` | Seconds to wait for a graceful `c i` interrupt before killing the turn (nil = wait forever) |
| `sprig-system-prompt` | short hint | Appended system prompt, or nil |
| `sprig-ssh-program` | `"ssh"` | SSH client program |
| `sprig-ssh-args` | `("-T" "-A")` | Extra SSH args (`-A` forwards your agent to the host) |
| `sprig-extra-args` | `nil` | Extra `claude` args |
| `sprig-supported-dialog-kinds` | `("ask_user_question" "exit_plan_mode")` | Dialog kinds Sprig tells the CLI it can answer; declaring a kind is what enables the tool behind it (nil disables both) |
| `sprig-permission-function` | `nil` | `nil` asks in the session buffer, as a dialog. A function is called with a tool name and input (non-nil allows, nil denies); set it to `always` to auto-approve. Such a function runs in the process filter and must not prompt |
| `sprig-error-buffer` | `"*sprig-errors*"` | Buffer where a failed session's command and stderr are logged |
| `sprig-status-max-sessions` | `30` | Newest stored sessions the navigator lists at once (nil = no cap; `l a` lifts it live) |
| `sprig-status-directories` | `nil` | Deprecated: when set, seeds the navigator's initial `/` filter with the first entry's project name |
| `sprig-status-ignore-directories` | `nil` | Regexps matched against a session's encoded project directory; matches are hidden from the navigator (e.g. throwaway `/tmp` / SDK-probe runs) |
| `sprig-session-refresh-delay` | `0.1` | Floor, in seconds, for coalescing structural events before a re-render; widens toward the last render's cost on a big buffer |
| `sprig-session-refresh-delay-max` | `0.5` | Ceiling, in seconds, on that adaptive coalescing delay; bounds how late a structural update can appear on a long history |
| `sprig-session-expand-diffs` | `nil` | Render a diff-bearing tool call open instead of folded to its heading |
| `sprig-review-base` | `"HEAD"` | Default scope of the `d` changeset review. `"HEAD"` = uncommitted changes; a branch name = the whole branch from the merge base, commits and uncommitted work (`d m` picks this per review); anything with `..` goes to `git diff` verbatim. Buffer-local once `b` changes it |
| `sprig-review-fontify-code` | `t` | Syntax-highlight reviewed code in each file's own major mode, and move the added/removed colour to the line-number gutter. Nil colours the whole line instead |
| `sprig-review-default-branches` | `("main" "master" "trunk" "develop" "default")` | Names `d m` looks for as the default branch, best first, local and remote-tracking. A tie is broken by `origin/HEAD`, not by this order |
| `sprig-review-quote-lines` | `6` | Lines a published comment quotes back at the agent before truncating with an ellipsis |
| `sprig-session-timestamp-format` | `"%H:%M"` | `format-time-string` format for the left-margin timestamp on each block, in local time (nil = no timestamps, no margin) |
| `sprig-session-fontify-markdown` | `t` | Fontify review prose with `markdown-mode` faces when it is installed |
| `sprig-session-defer-live-prose` | `t` | Reveal a streaming reply a whole paragraph at a time, fontified, rather than showing the half-typed last paragraph raw (nil streams it raw, in place) |
| `sprig-session-fontify-async` | `t` | Fontify a settled block off the render's critical path: it paints raw at once and gains its markdown faces on the next idle moment |
| `sprig-session-fontify-idle-delay` | `0.15` | Idle seconds before the deferred markdown fontifier runs |
| `sprig-session-incremental-render` | `t` | Redraw only the changed tail of a session buffer on a structural event, keeping the unchanged block prefix in place (nil forces a full redraw each time) |
| `sprig-session-debug-render` | `nil` | Log each re-render's model-build and draw cost (and whether it was an incremental tail or a full redraw) to `*Messages*`; a diagnostic for redraw lag |
| `sprig-context-large-tokens` | `150000` | Context size at which the state line flags the context large (amber); nil disables |
| `sprig-context-huge-tokens` | `200000` | Context size at which the state line flags the context very large (red); nil disables |

The navigator scans every session log under `~/.claude/projects/` (or under `sprig-config-directory`'s `projects/` when that is set), newest first, and reads each session's own `cwd` and `ai-title` records for its project and title. It does this once per host it lists, each with a cap of its own. The CLI also writes each subagent it spawns as its own `agent-*` log, one level deeper under `<project>/<id>/subagents/`; those are steps of a session rather than sessions you drive, so they are pruned from the scan (before the newest-N cap, so they never crowd real sessions out) unless `l g` toggles them in. A remote host's logs live on the SSH box and are scanned over the same SSH the transport uses, in a single round trip that finds the newest logs and slurps their fields together, so a host with hundreds of sessions still lists quickly; an SSH `ControlMaster` (see [SSH tips](#ssh-tips)) is still worth setting up.

**The scan is cached, and it never blocks a live turn.** A streaming session re-renders the navigator up to once a second, but the stored logs do not change within a turn except the live session's own, whose row is built from its in-memory buffer, not the scan. So the scan is cached: a live tick reuses it rather than re-reading the disk (or re-crossing SSH, which would freeze Emacs). Structural moments (a session opening, ending, or being removed, and `g`) mark the cache stale, keeping the old rows on screen while the next render re-reads. Every re-read runs in a **background process** and repaints when it lands, so no refresh ever blocks Emacs, on the disk or the network: a local scan runs the same `find | sort | slurp` shell pass a remote one does, just without the `ssh` wrapper. A remote host's first scan runs in the background too, so even opening the navigator with a remote configured never waits on the round trip; only the first scan of the **local** host is synchronous, a cheap capped `find` on no network, paid once so the list paints populated. On top of that, a live tick that changes nothing visible skips the reprint entirely: the render is computed to a signature and compared, so a stream that has not moved the last message, the state, or the times costs no buffer work at all. The navigator also shares each session's built model with its own session buffer rather than rebuilding it, so a row's status and inline preview cost nothing beyond the build the buffer already paid.

**A session buffer redraws only its changed tail, only while you are looking at it.** A structural event (a new tool call, a result, the turn ending) used to rebuild the whole buffer, which is `O(conversation)`: on a long session that redraw runs into hundreds of milliseconds, and with several sessions streaming at once it stutters the rest of Emacs. Two things keep it cheap. The model is built incrementally: the buffer keeps its running fold and folds only the newly-arrived events into it, rather than re-folding the whole history each time (`sprig-session-build` stays the one-shot path for a stored log or a preview). And the render keeps the unchanged block prefix in place and re-inserts only the new tail and the state line (`sprig-session-incremental-render`), so a streamed turn costs `O(new events)`, not `O(conversation)`. A refresh that changed only the state line redraws just that line. On top of that a buffer shown in no window stays pending and is drawn the moment it next appears, while its model still updates for the navigator's status and preview; and fontifying a settled markdown block, the heavier half of a redraw, runs off the critical path (`sprig-session-fontify-async`): the block paints as raw prose at once and gains its markdown faces on the next idle moment.

**A streaming reply arrives a paragraph at a time, fontified.** Showing the half-typed last paragraph raw is markdown noise no one reads, so by default (`sprig-session-defer-live-prose`) a live text block reveals only the paragraphs that have completed, already fontified, and withholds the one still being typed until it ends (a blank line) or the turn settles. The paragraphs a live render draws fontify synchronously, so none flash raw; opening a long buffer still fontifies off the critical path. Set it to nil to stream prose raw in place instead, the older behaviour.

One small, deliberate cost of the incremental path: the header's `Cost` line is left out of what forces a full redraw, so it can lag behind a streaming turn and catches up on the next full render (a title, mode, or session change, or reopening the buffer).

### A separate config directory

By default sprig shares the CLI's `~/.claude`, so its sessions sit alongside any you start from a plain `claude` shell. Set `sprig-config-directory` to give sprig its own `CLAUDE_CONFIG_DIR`: its session logs, settings, and login then live there instead, and the navigator lists only sessions started under it. An XDG-friendly value:

```elisp
(require 'xdg)
(setq sprig-config-directory (expand-file-name "sprig/claude" (xdg-config-home)))
```

A fresh config dir starts logged out. A session runs headless (over the stream-json protocol) and cannot drive the interactive login itself, so run `M-x sprig-login` once per host. It runs `claude auth login` down a pipe with the config dir set, opens the authorization URL in your local browser (the right place: the login is your account, not the host's), and reads the code the browser shows back into the minibuffer for you to paste. It works the same for a remote session, over SSH. Every headless sprig session on that host then reuses the stored credentials. Settings and `CLAUDE.md` under that dir are also separate from your main `~/.claude`.

## Status / caveats

- v0.16.0, written against `claude` 2.1.x. The protocol round-trip (streaming, multi-turn memory, session resume, plan-mode switch) is verified against the real CLI; the Elisp itself has had light exercise, so expect a rough edge or two.
- One turn at a time per session (several sessions can stream at once).
- The host is per-session: the primary remote (the first of `sprig-remotes`) is the default for a session started outside the navigator, and inside it the group point is in decides. The navigator lists every host, so a local session no longer drops off the list once its session buffer is closed. Session ids are per-host: a session started on one machine (or the SSH host) cannot resume on another, which is why opening a row pins its buffer to the host the row came from. When the CLI reports the stored id is unknown, Sprig drops it and starts a fresh session automatically; the session buffer keeps showing the replayed history, but the new session does not carry the earlier turns' server-side memory.
- Interrupt is graceful: `c i` asks the CLI to end the turn cleanly (an `interrupt` control request) and keeps the session live, so the next send continues it with no resume. If the CLI refuses the request (an error receipt) or does not honour it within `sprig-interrupt-timeout` seconds, Sprig falls back to killing the process, and the session resumes on the next send.
- The *inline* diffs are reconstructed from tool-call payloads (`Edit` / `MultiEdit` / `Write`), so a `Bash`-driven edit is not attributed in the transcript. The net working-tree diff (`d`, see [Diff buffer](#diff-buffer)) does show it, local or remote; folding it back into the transcript inline is still to come.
- A **remote** session's `Agent` rows replay without their subagents' steps. Those transcripts are files beside the log rather than records inside it, and a remote log is read by shell over SSH rather than opened by path, so there is no name to find them by. The narration and the report are unaffected; only the replayed steps are missing, and only over SSH.
- Thinking is shown on replay, not live. The reasoning is read back from the session log, so it appears on the next `g`, but the live stream parser does not surface it as it arrives.
- The `sprig-status` navigator ships as a flat session list; the fork forest it will grow into is not built yet.

## Development

After editing any of the source files, `M-x sprig-reload` re-loads all of them from disk in dependency order, so a change takes effect without restarting Emacs. Open buffers keep their state and pick up the new definitions. Edited faces take effect too: `defface` is a no-op on an already-defined face, so the reload undefines sprig's own faces first, and a face you have customized or themed keeps that.

`sprig-tests.el` is an ERT suite covering the process-free layers (the stream-json transport and its event vocabulary, command construction, the session model and tool-payload diff engine, the stored-session log parser, and the navigator's session enumeration). It needs no extra dependencies and runs offline, starting no session:

```
emacs -Q --batch -L . -l sprig.el -l sprig-tests.el -f ert-run-tests-batch-and-exit
```

The session buffer (`sprig-session-mode.el`) has its own suite in `sprig-session-mode-tests.el`, which loads `magit-section`. Point the load path at wherever it is installed (locally, the vendored `.deps/` used for development):

```
emacs -Q --batch -L . -L .deps/compat -L .deps/cond-let -L .deps/llama \
      -L .deps/magit-section \
      -l sprig.el -l sprig-change.el -l sprig-render.el -l sprig-session.el \
      -l sprig-session-mode.el -l sprig-session-mode-tests.el \
      -f ert-run-tests-batch-and-exit
```

## Direction

The review-and-steer model is the point of the project. See [DESIGN.md](DESIGN.md) for the full write-up. In short:

- A conversation is a read-only session buffer; the crux is reviewing the agent's actual file changes inline and steering them.
- Sprig never touches git: accept, reject, and commit are instructions sent to the agent, which keeps the remote path working from day one.
- The store is the CLI's own session log, so Sprig persists nothing and replays history from it.
- A `sprig-status` buffer navigates the sessions, one process per session, many able to stream at once.
