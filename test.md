---
sprig_tools: none
claude_session: bbb149e9-6d4e-4a05-98c7-ecff002429a9
---

Awesome!

<!-- sprig:reply id=r1 -->

Glad it's working. Shout if you want to tackle the unfolded-body lock question or anything else.
<!-- sprig:end id=r1 -->
What's the unfolded-body lock question?

<!-- sprig:reply id=r2 -->

It's the leftover from the deletion-guard work. Here's the state:

The edit guard now protects two things in both fold states: the hidden **sentinels** (the `sprig:` markers that delimit structure) and any **folded** block's body. So a collapsed block is fully locked, and you can never delete the markers that parsing relies on.

But when you **unfold** a tool block, its body becomes plain visible text, and that text is editable, the fences and the tool output. The probe showed this: folded = 0 leaks, unfolded = 15 (all inside the expanded body).

I left it that way on purpose, because:

- It's not dangerous. sprig parses off the sentinels, not the fences, so editing an unfolded body can't move a block boundary or break turn parsing. Worst case you mangle the visible markdown of one block, and it's recoverable.
- Unfolding is a deliberate act, and editing text you can see is normal.

**The question:** do you want to go stricter, so an entire reply is read-only regardless of fold state, meaning you can only ever edit your own turns (the gaps between replies)? That's roughly a one-line change: have the guard cover the reply span even when it's shown. The tradeoff is you'd lose the ability to hand-edit an agent's reply, which you can do freely today.

My take: leave it as is. The current invariant (structure can't be corrupted) is the important one, and locking visible replies is more restrictive than it's worth. But it's your call.
<!-- sprig:end id=r2 -->
Let's leave it

<!-- sprig:reply id=r3 -->

Sounds good. Leaving it as is.
<!-- sprig:end id=r3 -->
Do we have something missing from the DESIGN.md?

<!-- sprig:reply id=r4 -->

Let me read DESIGN.md and compare it against where the code actually is now.

<!-- sprig:tool id=toolu_019zcKuTtRKUTm1SRDQRUXGk name=Bash -->
```bash
cd "/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig" && ls -la && echo "=== DESIGN.md ===" && wc -l DESIGN.md 2>&1
```
<!-- sprig:tool-end id=toolu_019zcKuTtRKUTm1SRDQRUXGk -->

<!-- sprig:tool id=toolu_01H6XULQFJUUp7srT7t1ait8 name=Read -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_01H6XULQFJUUp7srT7t1ait8 -->

Yes, quite a bit. DESIGN.md still describes the **`<details>`/`<summary>` transcript format**, which the last two commits replaced with the invisible `sprig:` sentinel scheme. So the design doc is describing a format the code no longer uses. Concretely:

**Stale (describes the old `<details>` world):**
- **File format** (lines 44–78): the example shows `<details><summary>assistant</summary>` wrappers with a `sprig:reply` marker inside. Reality now: a reply is a paired `<!-- sprig:reply id=rN -->` … `<!-- sprig:end id=rN -->`, tool calls/results are their own `sprig:tool`/`sprig:result` sentinel pairs, and there's no `<details>` anywhere. The "collapses natively on GitHub" rationale is gone too, the files are Emacs-only now.
- **Context assembly / send / interruption / modes** (82, 88, 101, 116): all still say "`<details>` block". Interrupt now closes with `<!-- sprig:end -->` and flags the open sentinel `interrupted` (the marking idea survived, the `<details>` wording didn't).
- **Build status** (134–137): pegged at "v0.2 … streaming into `<details>` blocks". We're at 0.3.1 with a different renderer.

**Resolved open questions that should move out of "Open questions":**
- Line 130 "turn delimiting: `<details>` is the working choice; confirm it parses and folds cleanly", it didn't, and *why* is the interesting design fact: tool output could contain `</details>` and be mistaken for markup, so structure moved into invisible sentinels. That's a decision worth recording.
- Line 131 "how tool calls … are represented", now answered: sentinel-delimited fenced blocks with header chrome, folding, and a render level (`none`/`calls`/`full`). (Thinking is still unrepresented, so that half stays open.)

**Missing entirely (built, undocumented):**
- The sentinel grammar and its rationale.
- Overlay chrome: tool/result headers, reply dividers, the user-input face.
- The structural **edit guard** (can't delete sentinels/folded bodies).
- The **tool-render setting** and `sprig_tools:` frontmatter.
- The `sprig-remote` SSH transport.

**Still correctly deferred (genuinely not built):** fork-by-copy, the `sprig-status` navigator, and the stateless-replay path. DESIGN's "Next slice" framing for those is accurate.

Want me to update DESIGN.md to match, folding the resolved questions into the design and adding a short "sentinel format + editor chrome" section? I'd keep the fork/navigator vision intact since that's still the roadmap.
<!-- sprig:end id=r4 -->
Update it

<!-- sprig:reply id=r5 -->

Let me read the exact current text of the sections I'll rewrite so my edits match precisely.

<!-- sprig:tool id=toolu_01CNtt8sDrYWQmsqbfkz5q8Y name=Read -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_01CNtt8sDrYWQmsqbfkz5q8Y -->

Now I'll rewrite the File format section and add the sentinel/chrome and tool-activity sections (keeping lines unwrapped per your convention):

<!-- sprig:tool id=toolu_01YEr7o9arjz1gW1CcSRdqWF name=Edit -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_01YEr7o9arjz1gW1CcSRdqWF -->

Now the send verb, interruption, and modes:

<!-- sprig:tool id=toolu_0132SdqL7vYkwhKoav4JQ7L9 name=Edit -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_0132SdqL7vYkwhKoav4JQ7L9 -->

<!-- sprig:tool id=toolu_018RrX4ah8HdWNAL3M7RUu9n name=Edit -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_018RrX4ah8HdWNAL3M7RUu9n -->

<!-- sprig:tool id=toolu_01LA71cfRqBFCNag69WEDJTi name=Edit -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_01LA71cfRqBFCNag69WEDJTi -->

Now the resolved open questions, build status, and the "as shipped" line:

<!-- sprig:tool id=toolu_016Pp2ZXSntSCMFgJ8AF19jS name=Edit -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_016Pp2ZXSntSCMFgJ8AF19jS -->

<!-- sprig:tool id=toolu_01TZtqsokWy4fatqnRnvkPzE name=Edit -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_01TZtqsokWy4fatqnRnvkPzE -->

<!-- sprig:tool id=toolu_01HyQqCSKKyLooYLf4A7hhPN name=Edit -->
```
/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig/DESIGN.md
```
<!-- sprig:tool-end id=toolu_01HyQqCSKKyLooYLf4A7hhPN -->

Let me check no stale `<details>` references remain and skim the result:

<!-- sprig:tool id=toolu_0176qbeDChYiMKhTwHgZfHbb name=Bash -->
```bash
cd "/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig" && echo "=== remaining <details> / v0.2 / drawer refs ===" && grep -n 'details\|v0\.2\|drawer' DESIGN.md || echo "(none)" 
```
<!-- sprig:tool-end id=toolu_0176qbeDChYiMKhTwHgZfHbb -->

DESIGN.md is updated. All remaining `<details>` mentions are deliberate (the "why we dropped it" explanation, the resolved-questions note, and the Org-draft history).

What changed:
- **File format** example and bullets now show the `sprig:reply`/`sprig:end` sentinel spans and realistic frontmatter (`claude_session`, `sprig_tools`).
- Added **"In-file structure: sentinels, not prose"** (the grammar, the chrome, the edit guard, and *why* sentinels beat `<details>`) and **"Tool activity in the transcript"** (the render level, and that tool blocks never re-enter context).
- **Context assembly / send / interruption / modes** rewritten off `<details>` onto reply spans.
- **Open questions**: retired turn-delimiting and tool-call representation into a "Resolved" line; kept thinking-representation, backend abstraction, keybindings.
- **Build status** bumped to v0.3 with the real feature list and the local/SSH transport.
- Left the fork-by-copy and navigator vision intact as the roadmap.

Want me to commit and push this (docs-only)?
<!-- sprig:end id=r5 -->
Yes

<!-- sprig:reply id=r6 -->

<!-- sprig:tool id=toolu_01Wi1cMViEYYhNt5oyYU5fdk name=Bash -->
```bash
cd "/home/dalum/Sync/Default Folder/.emacs.d/straight/repos/sprig" && git add DESIGN.md && git commit -F - <<'EOF' && echo "=== push ===" && git -c credential.helper='!gh auth git-credential' push origin main 2>&1 | tail -6
Update DESIGN.md for the sentinel transcript format

The design doc still described the `<details>`/`<summary>` reply blocks
that the sentinel scheme replaced. Rewrite the file format, context
assembly, send, interruption, and modes onto the `sprig:reply`/`sprig:end`
spans, and add sections on the sentinel grammar and editor chrome (why
sentinels beat `<details>`, the header/rule chrome, the structural edit
guard) and on the tool-render level.

Retire the now-settled open questions (turn delimiting, tool-call
representation) and refresh the build status to v0.3.
EOF
```
<!-- sprig:tool-end id=toolu_01Wi1cMViEYYhNt5oyYU5fdk -->

Pushed. `main` is at `474cf18` on `origin` (`e123bc1..474cf18`). DESIGN.md now matches the sentinel-based implementation.
<!-- sprig:end id=r6 -->
Does it hide tools now?

<!-- sprig:reply id=r7 -->

Let me verify the actual gating for both tool calls and results at each level, so I give you a precise answer rather than a guess.

Yes, at the level you asked for. Confirmed behaviour by rendering level:

| `sprig_tools` | tool call shown | result shown |
|---|---|---|
| `none` | no | no |
| **`calls` (default)** | **yes** | **no** |
| `full` | yes | yes |

So on the default, the noisy **results are hidden**, while the short tool **call** (e.g. `🔧 Bash` + the command) still shows so you can see what the agent did. That matches your original ask ("we don't need to render the tool use results").

Two things to note:

- If you want to hide the tool **calls** too, set `none`, either `M-x sprig-set-tool-display` or a `sprig_tools: none` frontmatter line.
- It applies to turns rendered **after** the setting is in effect. A transcript that already streamed with results in it keeps them; start a new turn (or new file) to see the hiding. Also, if the file has an explicit `sprig_tools:` line, that wins over the `calls` default.

Want the default changed to `none` instead?
<!-- sprig:end id=r7 -->
Default should be none

<!-- sprig:reply id=r8 -->

Also fix the DESIGN.md line that called `calls` the default:

Default is now `none` (no tool calls or results rendered), compiles clean. Bumped to 0.3.2 and fixed the docs.

Commit and push?
<!-- sprig:end id=r8 -->
Do it

<!-- sprig:reply id=r9 -->

Pushed. `main` is at `5b5c045` on `origin` (`474cf18..5b5c045`). Tool rendering now defaults to `none`.
<!-- sprig:end id=r9 -->
