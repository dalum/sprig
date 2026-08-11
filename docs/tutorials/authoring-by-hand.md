# Authoring by hand: writing code yourself

Normally in Sprig the agent writes and you review. Its edits render in the
review buffer for you to accept, reject, or steer. That is the fast path.

Sometimes you want the opposite: to write a particular piece of the change
**yourself**, so you actually understand and own it, rather than skimming a diff
the agent produced. Sprig lets you do that with one verb, `e`, without leaving
the review buffer or switching into any special mode.

The catch on a remote machine is that Sprig must never write your files itself
(only the agent touches the repo, which is what makes remote sessions work). So
you author in a throwaway **staging buffer**, and the agent couriers your bytes
to disk for you, unable to change a character of them.

This tutorial covers hand-authoring as it stands today.

## The loop

Authoring a change is four steps: open a staging buffer, edit it, stage it, and
let the agent courier it.

### 1. Open a staging buffer with `e`

Press **`e`** to open the staging menu. It offers three ways to fill the buffer,
differing only in how the region is chosen:

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

### 2. Edit it

The staging buffer opens in the file's own major mode, so you get proper syntax
highlighting and indentation. Edit it however you like. This is plain local
Emacs, instant even when the session runs on a remote host, and it is not backed
by a file, so a stray `C-x C-s` writes nothing.

### 3. Stage with `C-c C-c`

When you are happy, press **`C-c C-c`** to stage your edit, or **`C-c C-k`** to
throw it away.

### 4. The agent couriers it to disk

On `C-c C-c`, Sprig records exactly what you wrote and asks the agent to make one
edit to that file. When the agent's edit call comes up for permission, Sprig
**replaces its content with your bytes**. The agent supplies nothing of its own,
so it cannot change a character of your work; it only carries it to disk.

Your change then lands in the working tree as a normal diff. From there it is
just like any other change: review it, commit it with **`C`**, ask the agent to
critique it with `c c`, or press **`c r`** to have it spawn a subagent that
reviews the changes with fresh eyes and then acts on the findings.

## A worked example

You have been discussing with the agent that `parse_config` in `config.py` needs
a guard clause, and you want to write it yourself.

1. `e s`, then `RET` (the agent already knows the task from your chat). It reads
   `parse_config` and a staging buffer opens with its current source in Python
   mode. (Or `e f`, `config.py`, `the parse_config function`, to point it
   yourself.)
2. You add your guard clause at the top of the function.
3. `C-c C-c`. Sprig asks the agent to write the file; your version lands.
4. The change shows as a diff in the review buffer. You press `C` to commit, or
   `c c` to ask "any edge cases I missed?" before committing.

## Good to know

- **No mode to enter.** `e` works from the ordinary review flow. You do not
  switch the agent into anything first.
- **One write per stage.** A single `C-c C-c` sanctions exactly one write, with
  your exact bytes. Nothing else is affected.
- **Drift fails safe.** If the file changed under you between the read and the
  apply (because you edited it out of band, say), the edit simply fails and
  nothing is written. Stage it again.
- **Auto-approve modes are refused.** The courier works by overriding the edit
  at its permission prompt. If your session is in a mode that auto-approves
  edits (`acceptEdits`, `bypassPermissions`), there is no prompt to override, so
  staging refuses rather than risk writing the wrong bytes. Change the mode with
  `P` first.

## Why bother

The honest reason: the author of record usually understands the code least. A
diff you skimmed and approved gives you far weaker ownership than a change you
wrote line by line. Hand-authoring is the deliberate, slower counterpart to
Sprig's fast review-and-steer default. Reach for it on the edits where
understanding matters more than speed, and let the agent drive the rest.
