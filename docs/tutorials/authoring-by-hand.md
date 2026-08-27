# Authoring by hand: writing code yourself

Normally in Sprig the agent writes and you review. Its edits render in the
review buffer for you to accept, reject, or steer. That is the fast path.

Sometimes you want the opposite: to write a particular piece of the change
**yourself**, so you actually understand and own it, rather than skimming a diff
the agent produced. Sprig lets you do that with one verb, `e`, without leaving
the review buffer or switching into any special mode.

The catch on a remote machine is that Sprig must never write your files itself
(only the agent touches the repo, which is what makes remote sessions work). So
you author in a throwaway **staging buffer**, and the agent writes your bytes to
disk for you.

This tutorial covers hand-authoring as it stands today.

## The loop

Authoring a change is four steps: open a staging buffer, edit it, send it, and
let the agent apply it.

### 1. Open a staging buffer with `e`

In the **session buffer**, press **`e`** to open the staging menu. It offers
three ways to fill the buffer, differing only in how the region is chosen:

- **`e e` — the hunk at point.** With point on a `+`/`-` line of a change
  already shown in the buffer, the staging buffer opens straight away, seeded
  with that region's current text.
- **`e f` — a file you name.** Sprig asks you for a file, then for an optional
  region hint. The hint is free text the agent reads, like `the save function`
  or `lines 10-40`; leave it blank to take the whole file. The agent reads that
  region and the staging buffer opens once its read comes back.
- **`e s` — let the agent suggest.** The agent already knows the task from your
  conversation, so it works out the single most relevant file and region to edit
  next, reads exactly that, and the staging buffer opens on it. You can add a
  short nudge at the prompt, or just press `RET` to lean on the conversation.
  Use this when you know the change you want but not yet where it lands.

`e f` and `e s` involve the agent reading, so the buffer opens once that read
comes back (you will see a brief "…to seed a staging buffer" message meanwhile).

In the **changeset review** (`d`), `e` needs no menu: the review already has the
whole diff with its line numbers, so `e` stages what you are looking at straight
away, and no more than that. It takes the region when one is active; else the
hunk you marked with `SPC`, since marking a chunk is naming it; else just the
one line point is on. It widens to the whole hunk only where there is no line to
take: the `@@` heading, a file heading, or a removed line, which is not in the
file to begin with. Either way you land in the same staging buffer, and the rest
of the loop below is the same.

Two selections it refuses, because neither is a block the agent could match.
One spanning two hunks: git showed you neither the lines between them nor how
many, so the two spans are not one block. And one of pure removals: those lines
are not on disk, so there is nothing to anchor an edit to. Both say so rather
than staging something that would fail later.

### 2. Edit it

The staging buffer opens in the file's own major mode, so you get proper syntax
highlighting and indentation. Edit it however you like. This is plain local
Emacs, instant even when the session runs on a remote host, and it is not backed
by a file, so a stray `C-x C-s` writes nothing.

### 3. Send with `C-c C-c`

When you are happy, press **`C-c C-c`** to send your edit, or **`C-c C-k`** to
throw it away.

### 4. The agent applies it

On `C-c C-c`, Sprig sends the agent your exact text and asks it to make that one
edit, verbatim. Your change lands in the working tree as a normal diff.

Because the agent does the write, glance at the resulting diff to confirm it
matches what you typed. If you want a stronger guarantee, set
`sprig-courier-edits`: your bytes then stay in Emacs and are substituted into the
agent's edit at its permission prompt, so the agent cannot change a character.
That is safer but needs the edit to prompt, so it refuses the auto-approve modes
(more on that below).

From there it is just like any other change: review it, commit it with **`C`**,
ask the agent to critique it with `c c`, or press **`c r`** to have it spawn a
subagent that reviews the changes with fresh eyes and then acts on the findings.

## A worked example

You have been discussing with the agent that `parse_config` in `config.py` needs
a guard clause, and you want to write it yourself.

1. `e s`, then `RET` (the agent already knows the task from your chat). It reads
   `parse_config` and a staging buffer opens with its current source in Python
   mode. (Or `e f`, `config.py`, `the parse_config function`, to point it
   yourself.)
2. You add your guard clause at the top of the function.
3. `C-c C-c`. Sprig sends the agent your version and asks it to apply that one
   edit; your change lands.
4. The change shows as a diff in the review buffer. You skim it to confirm it is
   what you wrote, then press `C` to commit, or `c c` to ask "any edge cases I
   missed?" before committing.

## Good to know

- **No mode to enter.** `e` works from the ordinary review flow, in the session
  buffer or the changeset review. You do not switch the agent into anything
  first.
- **It knows where your block sits.** From the changeset review, the
  instruction names the line the block starts at, so a one-line edit whose text
  appears elsewhere in the file still lands in the right place. That is what
  makes taking a single line the sane default there. A hunk staged
  from the session buffer cannot say: an `Edit` payload knows the bytes it
  replaced but never the line they sat on.
- **One edit per send.** A single `C-c C-c` asks for exactly one edit, your text
  applied verbatim. Nothing else is touched.
- **Check the diff.** The agent does the write, so it could in principle drift
  from your bytes. The resulting diff is your check; if it does not match, send
  again. For a hard guarantee instead of a check, see the courier option below.
- **Drift fails safe.** If the file changed under you between the read and the
  apply (because you edited it out of band, say), the edit simply fails to match
  and nothing is written. Send it again.
- **The courier option.** Set `sprig-courier-edits` to have Sprig substitute
  your exact bytes into the agent's edit at its permission prompt, so the agent
  cannot alter them. Stronger, but it needs the edit to prompt: in a mode that
  auto-approves edits (`acceptEdits`, `bypassPermissions`) there is no prompt to
  override, so it refuses rather than risk writing the wrong bytes. Change the
  mode with `P` first, or leave `sprig-courier-edits` off.

## Why bother

The honest reason: the author of record usually understands the code least. A
diff you skimmed and approved gives you far weaker ownership than a change you
wrote line by line. Hand-authoring is the deliberate, slower counterpart to
Sprig's fast review-and-steer default. Reach for it on the edits where
understanding matters more than speed, and let the agent drive the rest.
