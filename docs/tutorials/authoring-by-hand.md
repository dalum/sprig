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

Authoring a change is four steps: open a staging buffer, edit it, file it, and
publish the review so the agent applies it.

### 1. Open a staging buffer with `e`

In the **changeset review** (`d`), press **`e`**. There is no menu: the review
already holds the whole diff with its line numbers, so `e` stages what you are
looking at straight away, and no more than that.

- **The region**, when one is active, so you can pull out three lines rather
  than a whole hunk.
- **The hunk you marked** with `SPC`, since marking a chunk is naming it. It
  outranks whatever line point is resting on.
- **The line point is on**, otherwise. This is the common case and the grain
  most hand-authored feedback wants.

It widens to the whole hunk only where there is no line to take: the `@@`
heading, a file heading, or a removed line, which is not in the file to begin
with.

`e` is a transient, so there are three other routes when the line is not the
grain you want:

- **`e h`** — the whole hunk, without having to find its `@@` line first.
- **`e b`** — the block around point. The diff shows three lines of context, so
  the hunk you are reading is usually part of a function rather than one; this
  re-runs `git diff` for that file with far more context (`sprig-review-block-context`)
  and bounds the block by indentation. `C-u N e b` climbs N levels out.
- **`e d`** — the whole function around point, bounded by the file's own major
  mode rather than by indentation, which is the only way to tell a docstring at
  column zero from the start of a block.

The wider reads are still `git diff`, over the transport the review already
uses, so they work on a remote tree with nothing extra and come back with the
same line numbers. Each says how many lines it handed you, and says so when the
block ran to the end of what was read rather than to a line of code.

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

### 3. File it with `C-c C-c`

When you are happy, press **`C-c C-c`** to file the edit, or **`C-c C-k`** to
throw it away.

Filing does not send anything. The edit becomes a **draft**, exactly like a
comment: it appears inline under the lines it replaces, `c e` re-opens it seeded
with what you wrote, and `k` takes it back. That is the point of a review being
composed as a whole rather than dribbled out an edit at a time. Because a draft
is local, you can write one before the session has even started.

### 4. Publish, and the agent applies it

`c p` publishes the review: your comments and your edits in one turn. Each edit
carries both blocks in full, and the covering instruction says they are not
suggestions to interpret, but one `Edit` each, character for character. Your
change lands in the working tree as a normal diff.

Because the agent does the write, glance at the resulting diff to confirm it
matches what you typed. `g` in the review re-reads the tree, so the check is one
key.

From there it is just like any other change: review it, commit it with **`C`**,
ask the agent to critique it with `c c`, or press **`c r`** to have it spawn a
subagent that reviews the changes with fresh eyes and then acts on the findings.

## A worked example

The agent has changed `parse_config` in `config.py`, and reading the diff you
decide the guard clause it wrote is wrong and it is quicker to write the right
one than to describe it.

1. `d d` to open the review, `TAB` on `config.py`, and move to the guard line.
2. `e`. A staging buffer opens on that line, in Python mode.
3. You write the guard you actually want, then `C-c C-c`. It is filed as a
   draft, and shows up inline under the line it replaces.
4. You carry on reading. Two files later you leave an ordinary comment with
   `c c`.
5. `c p` publishes both in one turn: your comment for the agent to answer, and
   your edit for it to apply verbatim.
6. `g` re-reads the diff once the turn lands, and you check what it wrote is
   what you typed.

## Good to know

- **No mode to enter.** `e` works from the ordinary review flow. You do not
  switch the agent into anything first.
- **It knows where your block sits.** The instruction names the line the block
  starts at, so a one-line edit whose text appears elsewhere in the file still
  lands in the right place. That is what makes taking a single line the sane
  default. The review can say it because it reads its line numbers from git; an
  `Edit` payload knows the bytes it replaced but never the line they sat on,
  which is why hand-authoring lives in the review and not in the transcript.
- **One `Edit` per staged block.** Each block you stage asks for exactly one
  edit, your text applied verbatim. Nothing else is touched.
- **A staged edit re-anchors.** In the review, a draft edit records the lines it
  was written against, so if the agent moves them before you publish, it is
  flagged as orphaned and published asking to be checked rather than applied
  blind.
- **Check the diff.** The agent does the write, so it could in principle drift
  from your bytes. The resulting diff is your check; if it does not match, stage
  it again.
- **Drift fails safe.** If the file changed under you between staging and the
  apply (because you edited it out of band, say), the edit simply fails to match
  and nothing is written. Stage it again. Within the review, drift that happens
  before you publish is caught earlier still: the draft is re-anchored on `g`
  and flagged orphaned.

## Why bother

The honest reason: the author of record usually understands the code least. A
diff you skimmed and approved gives you far weaker ownership than a change you
wrote line by line. Hand-authoring is the deliberate, slower counterpart to
Sprig's fast review-and-steer default. Reach for it on the edits where
understanding matters more than speed, and let the agent drive the rest.
