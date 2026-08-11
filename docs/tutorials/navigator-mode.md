# Navigator mode: writing the code yourself

Normally in Sprig the agent writes and you review. This is **driver** mode:
the agent edits files, and its changes render in the review buffer for you to
accept, reject, or steer.

**Navigator mode flips that.** You write the code, and the agent is held to
reading and advising. It cannot touch your files. The point is to get the
understanding and ownership that come from writing every line yourself, while
still having the agent on hand to consult.

> **A note on the word "navigator."** Sprig's session list (`M-x sprig-status`)
> is also called "the navigator" in the main README. That is a different thing.
> This tutorial is about the driver/navigator **role** inside a single review
> buffer, not the list view. Same word, two meanings; sorry.

This tutorial covers navigator mode as it stands today.

## Turning it on

Open a session's review buffer, then press **`V`** to toggle between driver and
navigator. When you are in navigator, the state line at the top shows a
`navigator` tag, and the agent's file-writing tools (`Edit`, `Write`, and
friends) are blocked. It can still read the tree, run `git`, and answer you.

Press **`V`** again to hand the keyboard back to the agent.

Switching is live. There is no restart, and it works the same for a local
session or one running over SSH.

## Asking for feedback

Feedback is on demand, not proactive. The agent will not interrupt you; you ask
when you want a second opinion.

Use the ordinary message verb **`c c`** to ask it something:

- "Does this approach look right?"
- "Where should this function live?"
- "Review what I just wrote."

If you want to point at specific code, mark those sections with **`SPC`** first,
then `c c`; the marked text rides along as context. The agent replies in the
review buffer and writes nothing.

## Writing a change: the staging buffer

You never edit a file in place. Editing a file directly (over TRAMP on a remote
host, say) would let Emacs write the repo, which breaks Sprig's one rule: only
the agent touches disk. Instead you author in a throwaway **staging buffer**,
and the agent couriers your bytes onto disk for you.

The loop is four steps.

### 1. Open a staging buffer with `e`

Press **`e`** to open the staging menu. It offers three ways to fill the
buffer, differing only in how the region is chosen:

- **`e e` — the hunk at point.** With point on a `+`/`-` line of a change
  already shown in the buffer, the staging buffer opens straight away, seeded
  with that region's current text.
- **`e f` — a file you name.** Sprig asks you for a file, then for an optional
  region hint. The hint is free text the agent reads, like `the save function`
  or `lines 10-40`; leave it blank to take the whole file. The agent reads that
  region, and the staging buffer opens once its read comes back.
- **`e s` — let the agent suggest.** You describe what you want to do ("add a
  guard clause to config parsing"). The agent works out the single most
  relevant file and region, reads exactly that, and the staging buffer opens on
  it. Use this when you know the change you want but not yet where it lands.

`e f` and `e s` involve the agent, so the buffer opens once its read comes back
(you will see a brief "…to seed a staging buffer" message meanwhile). These two
are the important ones: they let you edit a region the diff does not already
show, which is most real authoring.

### 2. Edit it

The staging buffer opens in the file's own major mode, so you get proper syntax
highlighting and indentation. Edit it however you like. This is plain local
Emacs, instant even when the session runs on a remote host.

### 3. Stage with `C-c C-c`

When you are happy, press **`C-c C-c`** to stage your edit, or **`C-c C-k`** to
throw it away.

### 4. The agent couriers it to disk

On `C-c C-c`, Sprig records exactly what you wrote and asks the agent to make
one edit to that file. When the agent's edit call comes through, Sprig
**replaces its content with your bytes**. The agent supplies nothing of its own,
so it cannot change a character of your work; it only carries it to disk.

Your change then lands in the working tree as a normal diff. From there it is
just like any other change: review it, commit it with **`C`**, or ask the agent
to critique it.

## A worked example

You are in a remote session and want to add a guard clause to `parse_config` in
`config.py`, by hand.

1. `V` to enter navigator mode. The state line shows `navigator`.
2. `e f`. At the prompt, enter `config.py`, then `the parse_config function` as
   the region hint. (Or `e s` and describe the change, to let the agent find
   the spot for you.)
3. The agent reads it; a staging buffer opens with `parse_config`'s current
   source in Python mode.
4. You add your guard clause at the top of the function.
5. `C-c C-c`. Sprig asks the agent to write the file; your version lands.
6. The change shows as a diff in the review buffer. You press `C` to commit, or
   `c c` to ask "any edge cases I missed?" before committing.

## Good to know

- **One write per stage.** A single `C-c C-c` sanctions exactly one write.
  Every other edit the agent might attempt stays blocked.
- **Drift fails safe.** If the file changed under you between the read and the
  apply (because you edited it out of band, say), the edit simply fails and
  nothing is written. Stage it again.
- **`Bash` is still allowed.** The wall blocks the edit tools, but the agent can
  still run shell commands, so a determined agent could write through `sed` or a
  redirect. Treat navigator mode as a discipline aid, not a hard sandbox.
- **The role is per session and not saved.** Reopening a session starts in
  driver mode; press `V` to go back to navigator.

## Why bother

The honest reason: the author of record usually understands the code least. A
flow that is slower but makes you engage with every line gives you far stronger
ownership and a much better mental model than accepting a diff you skimmed.
Navigator mode is the deliberate, hands-on counterpart to Sprig's fast
review-and-steer default. Reach for it when understanding matters more than
speed.
