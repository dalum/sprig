;;; sprig-session-mode.el --- Read-only session transcript buffer for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.34.0
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The read-only, Magit-like session buffer (see DESIGN.md, "Current
;; direction: the session buffer").  It projects a session model built by
;; `sprig-session-build' into `magit-section' rows: a metadata header,
;; assistant prose, and tool calls whose file changes render as a foldable
;; diff with their result.  The buffer is read-only; you move a cursor
;; over it and fold with the usual magit-section keys (TAB / C-TAB).
;;
;; This file is the *view*.  It carries the model's plists on each
;; section's `value' slot (an Edit's hunk lives on its hunk section, a
;; tool call on its tool section), so the mark-and-instruction verbs that
;; come next can read the object under point without re-parsing text.
;;
;; The offline ERT suite for the pure model and diff engine
;; (sprig-session.el) needs no magit-section; the tests for this renderer
;; live in sprig-session-mode-tests.el and load magit-section, so they run
;; separately from the process-free suite.

;;; Code:

(require 'magit-section)
(require 'diff-mode)                     ; for the diff-* faces
(require 'iso8601)                       ; for the log's own timestamps
(require 'sprig-change)
(require 'sprig-render)
(require 'sprig-review)
(require 'sprig-session)
(require 'subr-x)
(require 'eieio)
(require 'transient)
(require 'seq)

(declare-function sprig--review-deliver "sprig" (text &optional mode))
(declare-function sprig--review-steer "sprig" (text))
(declare-function sprig--review-queue "sprig" (text))
(declare-function sprig--review-unqueue "sprig" (text))
(declare-function sprig--review-drop-queue "sprig" ())
(declare-function sprig--review-answer-dialog "sprig" (id input answers))
(declare-function sprig--review-approve-plan "sprig" (id))
(declare-function sprig--review-reject-plan "sprig" (id feedback))
(declare-function sprig--review-allow-tool "sprig" (id))
(declare-function sprig--review-deny-tool "sprig" (id))
(declare-function sprig--review-interrupt-owned "sprig" ())
(declare-function sprig--status-refresh "sprig" ())
(declare-function sprig--mode-line-permission "sprig" ())
(declare-function sprig--session-log-lines "sprig" ())
(declare-function sprig--session-log-lines-async "sprig" (callback))
(declare-function sprig--remote "sprig" ())
(declare-function sprig--session-log-file "sprig" ())
(declare-function sprig--set-permission-mode "sprig" (mode))
(declare-function sprig--notable-mode "sprig" (mode))
(declare-function sprig--state-parts "sprig" (state))
;; Transport state, defined in sprig.el; a session-owning session buffer
;; carries these buffer-locally, so silence the byte-compiler here.
(defvar sprig--process)
(defvar sprig--sink)
(defvar sprig--busy)
(defvar sprig--compacting)
(defvar sprig--queued)
(defvar sprig--session-id)
(defvar sprig--working-dir)
(defvar sprig--remote-override)
(defvar sprig--permission-mode)
(defvar sprig--btw-process)

;;;; Renamed options
;;
;; The transcript buffer was `sprig-review-mode' until 0.51.0, when `review'
;; moved to the changeset-review surface and the transcript became
;; `sprig-session-mode'.  A `setq' on a renamed option would otherwise fail
;; silently, so every user-facing option keeps its old name as an alias.

(define-obsolete-variable-alias 'sprig-review-heading-max-width
  'sprig-session-heading-max-width "0.51.0")
(define-obsolete-variable-alias 'sprig-review-expand-diffs
  'sprig-session-expand-diffs "0.51.0")
(define-obsolete-variable-alias 'sprig-review-timestamp-format
  'sprig-session-timestamp-format "0.51.0")
(define-obsolete-variable-alias 'sprig-review-fontify-markdown
  'sprig-session-fontify-markdown "0.51.0")
(define-obsolete-variable-alias 'sprig-review-defer-live-prose
  'sprig-session-defer-live-prose "0.51.0")
(define-obsolete-variable-alias 'sprig-review-fontify-async
  'sprig-session-fontify-async "0.51.0")
(define-obsolete-variable-alias 'sprig-review-fontify-idle-delay
  'sprig-session-fontify-idle-delay "0.51.0")
(define-obsolete-variable-alias 'sprig-review-incremental-render
  'sprig-session-incremental-render "0.51.0")
(define-obsolete-variable-alias 'sprig-review-refresh-delay
  'sprig-session-refresh-delay "0.51.0")
(define-obsolete-variable-alias 'sprig-review-refresh-delay-max
  'sprig-session-refresh-delay-max "0.51.0")
(define-obsolete-variable-alias 'sprig-review-debug-render
  'sprig-session-debug-render "0.51.0")
(define-obsolete-variable-alias 'sprig-review-commit-instruction
  'sprig-session-commit-instruction "0.51.0")
(define-obsolete-variable-alias 'sprig-review-accept-instruction
  'sprig-session-accept-instruction "0.51.0")
(define-obsolete-variable-alias 'sprig-review-decline-instruction
  'sprig-session-decline-instruction "0.51.0")

;;;; Faces

(defface sprig-session-tool '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a tool-call heading in the session buffer."
  :group 'sprig)


(defface sprig-session-todo-done '((t :inherit shadow :strike-through t))
  "Face for a completed item in a `TodoWrite' checklist."
  :group 'sprig)

(defface sprig-session-todo-active '((t :inherit warning :weight bold))
  "Face for the in-progress item in a `TodoWrite' checklist."
  :group 'sprig)

(defface sprig-session-todo-pending '((t :inherit default))
  "Face for a still-pending item in a `TodoWrite' checklist."
  :group 'sprig)

(defface sprig-session-user
  '((((class color) (background light)) :background "#eaeef8" :extend t)
    (((class color) (background dark))  :background "#2b3040" :extend t)
    (t :inherit region :extend t))
  "Face for a user turn's prose: the tint that marks it as yours.
This is the only thing telling a user turn from the agent's output, so it
carries no label; tinted is you, untinted is the agent.  Applied beneath
any markdown faces, so the prose keeps its own styling on top.  `:extend'
runs the tint to the window edge."
  :group 'sprig)

(defface sprig-session-user-highlight
  '((((class color) (background light)) :background "#ccd8f0" :extend t)
    (((class color) (background dark))  :background "#3c465e" :extend t)
    (t :inherit magit-section-highlight :extend t))
  "Face for the user turn under point.
A stronger take on `sprig-session-user', rather than the shared
`magit-section-highlight' every other section gets, so the turn under
point still reads as yours instead of losing its tint to the cursor."
  :group 'sprig)

(defface sprig-session-thinking '((t :inherit shadow :slant italic))
  "Face for a thinking-block label."
  :group 'sprig)

(defface sprig-session-meta-key '((t :inherit font-lock-comment-face))
  "Face for a metadata key in the header."
  :group 'sprig)

(defface sprig-session-time '((t :inherit font-lock-comment-face))
  "Face for a block's timestamp in the left margin."
  :group 'sprig)

(defface sprig-session-working
  '((t :inherit warning :weight bold))
  "Face for the state line while a turn is in flight.
Coloured text, not an inverse-video block, so it sits evenly beside the
context readout at the end of the line."
  :group 'sprig)

(defface sprig-session-pending
  '((t :inherit warning))
  "Face for the state line after a message is sent, before the agent replies.
Softer than `sprig-session-working' (not bold): the turn is on its way but
nothing has come back yet."
  :group 'sprig)

(defface sprig-session-queued
  '((t :inherit shadow))
  "Face for the marker on a queued message floating above the state line.
Dimmer than `sprig-session-pending' (which marks a steer already on the
wire): a queued message is only parked, waiting for the running turn to end
before it sends, so it should read as held rather than in flight."
  :group 'sprig)

(defface sprig-session-plan
  '((t :inherit shadow))
  "Face for the state line's plan-progress count.
Its own face rather than the state's, like the context readout beside it: a
plan is not the turn, so it should not turn amber merely because a turn is
running."
  :group 'sprig)

(defface sprig-session-context
  '((t :inherit shadow))
  "State-line face for a context that has not grown large.
The readout is ambient rather than a signal at this size, so it is dimmed
and, above all, coloured independently of the turn: it must not inherit
the state's own face, or a normal context would read as a warning merely
because a turn was in flight (the busy state and `sprig-session-context-large'
are both yellow)."
  :group 'sprig)

(defface sprig-session-context-large
  '((t :inherit warning :weight bold))
  "State-line face for a context that has grown large.
Applied to the token readout once it crosses `sprig-context-large-tokens'."
  :group 'sprig)

(defface sprig-session-context-huge
  '((t :inherit error :weight bold))
  "State-line face for a very large context.
Applied to the token readout once it crosses `sprig-context-huge-tokens'."
  :group 'sprig)

(defface sprig-session-done
  '((t :inherit success :weight bold))
  "Face for the state line once a turn has landed."
  :group 'sprig)

(defface sprig-session-failed
  '((t :inherit error :weight bold))
  "Face for the state line when a turn ended badly."
  :group 'sprig)

(defface sprig-session-idle '((t :inherit shadow :extend t))
  "Face for the state line of a conversation with nothing running."
  :group 'sprig)

(defface sprig-session-waiting
  '((((class color) (min-colors 88) (background light))
     :foreground "#6f42c1" :weight bold)
    (((class color) (min-colors 88) (background dark))
     :foreground "#c792ea" :weight bold)
    (((class color)) :foreground "magenta" :weight bold)
    (t :weight bold))
  "Face for the state line, and the navigator glyph, while a session is on you.
Purple, deliberately not the working state's amber: a turn that has stopped
for you (an `AskUserQuestion', a plan to approve, a permission prompt) is not
working, it is waiting, and amber reads as busy.  The purple makes the `?'
stand out as needing you rather than blending in with the running rows."
  :group 'sprig)

(defface sprig-session-dialog '((t :inherit font-lock-builtin-face :weight bold))
  "Face for a question the agent is waiting on."
  :group 'sprig)

(defface sprig-session-dialog-picked '((t :inherit success :weight bold))
  "Face for an option picked in a question."
  :group 'sprig)


;;;; Buffer-local state

;; `sprig-session--events', `sprig-session--model', `sprig-session--model-head',
;; and `sprig-session--current-model' live in sprig-session.el (the data layer),
;; so the navigator can share the memoised model without loading this file.
(defvar-local sprig-session--meta nil
  "Display-metadata plist feeding this session buffer's header.")
(defvar-local sprig-session--dirty nil
  "Non-nil when events have arrived since the last render.")
(defvar-local sprig-session--timer nil
  "Pending coalescing-refresh timer for this buffer, or nil.")
(defvar-local sprig-session--tail nil
  "Marker where streamed text is appended in place, or nil.
`sprig-session-render' sets it to the end of the last text section when a
turn is streaming into this buffer, so consecutive `text' events extend
that section without a full re-render.  Any structural event clears it.")

(defvar-local sprig-session--stream-nl nil
  "Non-nil when the deferred live stream so far ends on a newline.
Lets `sprig-session-consume' spot a completed paragraph (a blank line) as it
arrives split across `text' deltas, without rescanning the block, so it can
schedule a render only when a paragraph lands (see
`sprig-session-defer-live-prose').  Reset when the block settles.")

(defvar-local sprig-session--streaming nil
  "Non-nil while a turn is streaming into this buffer.
Two things hang off it.  The last text block opens as the live tail only
while it is set, which costs that block its markdown fontification (see
`sprig-session--insert-text'); and the header line says the buffer is
working only while it is set (see `sprig-session--state').  A settled
or replayed conversation is not streaming, so it renders fontified, and
says so.

Liveness cannot be read off the model instead: a replayed session log
carries no `done' event, so its last block would pass for a live tail
forever, and a conversation read from disk would claim to be working.")
(defvar-local sprig-session--pending-seed nil
  "A staging seed waiting on a `Read', a plist, or nil.
Set when `e' targets a region not already in the model: the agent is asked
to `Read' it, and the next turn's `done' seeds a staging buffer from that
read (see `sprig-session--seed-from-read').  The plist is (:file PATH) when
you named the file (`e f'), or (:any t) when the agent chose it (`e s'), in
which case the file is learnt from the read itself.  Live state, consumed on
use, so a later replay never re-opens the buffer.")
(defvar-local sprig-session--pending-steer nil
  "Steer messages written to stdin mid-turn but not yet taken, oldest first.
A `c c' sent into a running turn is handed to the agent at its next
tool-call boundary, so until then the message is not part of the transcript:
it floats pinned above the state line (see `sprig-session--insert-pending-steer')
rather than splitting the streaming message in two.  When the agent reaches
that boundary, `sprig-session--commit-pending-steer' folds it into the events
at the point the agent actually received it.")
(defvar-local sprig-session--remote nil
  "SSH destination of the session host, or nil for local.
Set by `sprig-session-set-remote' so visiting a file reaches it over TRAMP.")
(defvar-local sprig-session--file nil
  "Session-log file this buffer was opened from, or nil.
Set by `sprig-session-open-file', so a refresh re-reads that file; a buffer
that owns a session leaves this nil and finds its log by session id.")

;;;; Options

(defcustom sprig-session-heading-max-width 80
  "Maximum width of a tool-call heading before it is truncated with an ellipsis.
Keeps a long `Bash' command or file path on a single line; the full text
is one TAB away, since the tool section folds to its heading."
  :type 'integer
  :group 'sprig)

(defcustom sprig-session-expand-diffs nil
  "When non-nil, a tool call that reconstructs a diff renders expanded.
By default every tool section folds to its one-line heading, so a long
turn reads as a list of what the agent did rather than as pages of diff;
TAB opens the one you want to review."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-session-timestamp-format "%H:%M"
  "Time format for the left-margin timestamp against each block.
A `format-time-string' format, rendered in local time.  nil shows no
timestamps, narrowing the margin to the running bar alone.  Widen it (say
\"%m-%d %H:%M\") to date a conversation spanning days; the margin sizes
itself to fit.

Replayed history is dated from the session log's own record timestamps;
a live turn is dated when its first event reaches the buffer."
  :type '(choice (const :tag "No timestamps" nil) string)
  :group 'sprig)

(defcustom sprig-session-fontify-markdown t
  "When non-nil, render user and assistant prose with `markdown-mode' faces.
Markup characters (`*', `#', ...) are hidden.  Has no effect when
`markdown-mode' is not installed."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-session-defer-live-prose t
  "When non-nil, reveal a streaming reply a whole paragraph at a time.
A live text block otherwise shows its half-typed last paragraph raw, which
is markdown noise no one reads.  With this on, only the paragraphs that have
completed are shown, fontified, and the one still being typed is withheld
until it ends (a blank line) or the turn settles.  The paragraphs a live
render draws fontify synchronously so none flash raw; opening a long buffer
still fontifies off the critical path (see `sprig-session-fontify-async').
Has no effect on the fast raw tail append, which it replaces."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-context-large-tokens 150000
  "Context size, in tokens, at which the state line flags the context large.
The token count in use is always shown; crossing this flags it, since the
true window is not reported and a percentage against a guessed one is
misleading.  Anthropic itself marks 150k as the large-context point (the
`/status' \"…of your usage was at >150k context\" line): attention softens
and cost climbs past it, and it is where compacting starts to pay.  nil
disables the flag."
  :type '(choice integer (const nil))
  :group 'sprig)

(defcustom sprig-context-huge-tokens 200000
  "Context size, in tokens, at which the state line flags the context very large.
Past the standard 200000 window a session is in long-context territory and
paying its rates, so it earns a stronger flag than
`sprig-context-large-tokens'.  nil disables the stronger flag."
  :type '(choice integer (const nil))
  :group 'sprig)

;;;; Timestamp margin
;;
;; A block's time shows in the left margin, the way magit-log shows a
;; commit's date: it dates every row without spending a column of the
;; prose itself, and it cannot be confused for something the agent said.
;; The stamp rides on an overlay's `before-string', so it stays out of the
;; buffer text, and out of the way of the verbs that read that text.

(defun sprig-session--time-string (iso)
  "Return ISO, an ISO 8601 stamp, formatted per `sprig-session-timestamp-format'.
Returns nil when timestamps are off, or when ISO is missing or unparsable
\(a hand-edited log, or a record shape we have not seen), since a block
with no time is worth more than a render that dies over one."
  (when (and sprig-session-timestamp-format (stringp iso))
    (ignore-errors
      (format-time-string sprig-session-timestamp-format
                          (encode-time (iso8601-parse iso))))))

(defun sprig-session--stamp-width ()
  "Return the columns a timestamp needs, or 0 when they are off."
  (if sprig-session-timestamp-format
      ;; Formatted now, purely to measure the format; every stamp it makes
      ;; is the same width, bar a format holding a variable-width field.
      (string-width (format-time-string sprig-session-timestamp-format))
    0))

(defun sprig-session--margin-width ()
  "Return the columns the timestamp margin needs, or 0 when it is off.
The extra column is the gap holding the stamp off the text."
  (let ((width (sprig-session--stamp-width)))
    (if (> width 0) (1+ width) 0)))

(defun sprig-session--update-margin ()
  "Size the left margin of every window showing this buffer to fit a stamp.
`left-margin-width' alone only reaches a window on the next
`set-window-buffer', so the live windows are set too, and a change to
`sprig-session-timestamp-format' shows on the next render."
  (setq left-margin-width (sprig-session--margin-width))
  (dolist (win (get-buffer-window-list nil nil t))
    (set-window-margins win left-margin-width right-margin-width)))

(defun sprig-session--insert-margin (pos iso)
  "Show ISO's time in the left margin, against the line holding POS."
  (when-let ((stamp (sprig-session--time-string iso)))
    (let ((ov (make-overlay pos (min (1+ pos) (point-max)))))
      (overlay-put ov 'sprig-session-margin t)
      (overlay-put ov 'before-string
                   (propertize " " 'display
                               ;; `face', not `font-lock-face': an overlay
                               ;; string is not buffer text, so font-lock
                               ;; never sees it to strip it.
                               `((margin left-margin)
                                 ,(propertize stamp 'face 'sprig-session-time)))))))

;;;; Heading helpers


(defun sprig-session--truncate (s width)
  "Return S truncated to WIDTH columns, ending in an ellipsis when shortened."
  (if (> (string-width s) width)
      (truncate-string-to-width s width nil nil "…")
    s))

(defun sprig-session--input-summary (name input)
  "Return a one-line summary of tool NAME's INPUT, or nil.
Shows the command for `Bash'; other non-diff tools fall back to a salient
input field (path, pattern, query, ...).  File tools that render a diff
header instead pass their changes in, so this is only reached without one."
  (let* ((obj (sprig--parse-input input))
         (val (if (equal name "Bash")
                  (alist-get 'command obj)
                (seq-some (lambda (k) (alist-get k obj))
                          '(file_path path pattern query url description prompt)))))
    (when (stringp val)
      (car (split-string val "\n")))))

(defun sprig-session--todos (block)
  "Return the todo list a `TodoWrite' BLOCK carries, or nil for another tool.
Each element is the tool's own todo alist (`content', `status', and an
`activeForm'); their order is the agent's, which is the reading order.
Reads both input spellings, wire (a JSON string) and stored (an alist),
through `sprig--parse-input'."
  (when (equal (plist-get block :name) "TodoWrite")
    (let ((obj (sprig--parse-input (plist-get block :input))))
      (alist-get 'todos obj))))

(defun sprig-session--todo-progress (todos)
  "Return a \"N/M done\" count string for TODOS, or nil when there are none.
This is the one thing a folded `TodoWrite' tells you, so it rides in the
heading the way a diff's line counts do."
  (when todos
    (format "%d/%d done"
            (seq-count (lambda (td) (equal (alist-get 'status td) "completed"))
                       todos)
            (length todos))))

(defun sprig-session--plan-items (model)
  "Return the items of the freshest plan in MODEL, or nil if it has none.
A plan reaches the buffer by either of two routes, a whole-list `TodoWrite'
or the granular task tools folded into a `tasks' block, and both land on the
same content/status alist.  Newest wins: the blocks are oldest-first, so
this reads them backwards and stops at the first plan it meets, which is
the one still being worked."
  (seq-some (lambda (block)
              (or (and (eq (plist-get block :type) 'tasks)
                       (plist-get block :items))
                  (sprig-session--todos block)))
            (reverse (plist-get model :blocks))))

(defun sprig-session--plan-indicator (model)
  "Return a \"4/5\" count of the freshest plan's progress, or nil for no plan.
For the state line: the checklist itself is back up the buffer, and scrolling
to it to learn how far in the agent is defeats a line whose whole job is to
say what is going on.  Deliberately one dim face and no escalation, the way
the context readout stays dim until it is genuinely worth alarm: the line
already carries the state's colour and the context's, and a third would make
a plain running turn read as three warnings.  The checklist is where a task's
own state is coloured; this only says how far in."
  (let ((items (sprig-session--plan-items model)))
    (when items
      (format "%d/%d"
              (seq-count (lambda (td) (equal (alist-get 'status td) "completed"))
                         items)
              (length items)))))

(defun sprig-session--agent-activity (block)
  "Return what BLOCK's subagent is doing right now, or nil when none is.
Only while it runs: once it is done the row carries the subagent's report,
which says more than any summary of the work behind it could.  A subagent
can run for minutes, and the `Agent' row is otherwise still, so this is the
whole of what says the thing is alive rather than wedged.

Shows what it is doing over how much it has done: `Reading note.txt' is the
CLI's own account of the current step, and it moves, which is what the reader
is really checking for.  The token and tool counts are dropped as noise next
to that."
  (when-let ((agent (plist-get block :agent)))
    (when (equal (plist-get agent :status) "running")
      (let ((type (plist-get agent :agent-type))
            (desc (plist-get agent :description)))
        (if (and type desc) (format "%s: %s" type desc) (or type desc))))))

(defun sprig-session--tool-heading (block)
  "Return the single-line heading string for tool BLOCK."
  (let* ((name (or (plist-get block :name) "tool"))
         (changes (plist-get block :changes))
         (todos (sprig-session--todos block))
         (summary (sprig-session--input-summary name (plist-get block :input)))
         (activity (sprig-session--agent-activity block))
         (err (plist-get (plist-get block :result) :error)))
    (concat
     (sprig--face name 'sprig-session-tool)
     (cond
      (changes
       (let ((c (car changes)))
         (concat "  " (plist-get c :file) "  " (sprig--stat-string c))))
      (todos (concat "  " (sprig-session--todo-progress todos)))
      (summary (concat "  " (sprig-session--truncate
                             summary sprig-session-heading-max-width)))
      (t ""))
     ;; After the job it was given, not instead of it: the two say different
     ;; things, what the subagent was asked for and where it has got to.
     (if activity
         (sprig--face
          (concat "  ▸ " (sprig-session--truncate
                          activity sprig-session-heading-max-width))
          'sprig-session-working)
       "")
     (if err (sprig--face "  [error]" 'error) ""))))

;;;; Section insertion


(defun sprig-session--insert-result (result)
  "Insert RESULT as a section, folded by default since results can be large."
  (magit-insert-section (sprig-result result t)
    (magit-insert-heading
      (format "↳ result%s" (if (plist-get result :error) " (error)" "")))
    ;; Deferred so a folded result keeps its body out of the buffer; magit
    ;; only draws the fold when the body goes through `magit-insert-section-body'.
    (magit-insert-section-body
      (let ((text (string-trim-right (or (plist-get result :text) ""))))
        (unless (string-empty-p text)
          (insert text "\n"))))))

(defun sprig-session--todo-line (todo)
  "Return the rendered line for one TODO alist: a status marker and its text.
A completed item reads struck-through, the in-progress one stands out, and
a pending one is plain, so the checklist's state is legible at a glance."
  (let* ((status (alist-get 'status todo))
         (content (or (alist-get 'content todo) ""))
         (glyph (pcase status ("completed" "☑") ("in_progress" "▶") (_ "☐")))
         (face (pcase status
                 ("completed" 'sprig-session-todo-done)
                 ("in_progress" 'sprig-session-todo-active)
                 (_ 'sprig-session-todo-pending))))
    (sprig--face (concat glyph " " content) face)))

(defun sprig-session--insert-todos (todos)
  "Insert TODOS as a checklist, one status-marked line each."
  (dolist (td todos)
    (insert (sprig-session--todo-line td) "\n")))

(defun sprig-session--insert-tool (block)
  "Insert tool BLOCK: heading, then its body (file diffs, todos, or result).
Every tool folds to its one-line heading, so a turn reads as a list of
what the agent did; TAB opens the one you want.  A `TodoWrite' renders its
checklist in place of a result, so the plan-of-work reads as a list rather
than as a tool call.  Set `sprig-session-expand-diffs' to render
diff-bearing tools open instead."
  (magit-insert-section (sprig-tool block
                                    (not (and sprig-session-expand-diffs
                                              (plist-get block :changes))))
    (magit-insert-heading (sprig-session--tool-heading block))
    ;; Deferred so a folded tool keeps its body out of the buffer; magit only
    ;; draws the fold when the body goes through `magit-insert-section-body'.
    (magit-insert-section-body
      (let ((todos (sprig-session--todos block))
            (steps (plist-get (plist-get block :agent) :steps)))
        (cond
         ;; A TodoWrite's own result is a bookkeeping reminder; the checklist
         ;; is the content worth reading, so show it and drop the result.
         (todos (sprig-session--insert-todos todos))
         (t
          ;; A subagent's steps nest inside the `Agent' row that spawned them,
          ;; each an ordinary tool section: folded to a line, TAB to open, a
          ;; diff where it edited.  Before the result, since they are what led
          ;; to it, and the reader arrives at the report having seen the work.
          (dolist (step steps)
            (sprig-session--insert-tool step))
          (dolist (change (plist-get block :changes))
            (sprig--insert-change change))
          (when-let ((result (plist-get block :result)))
            (sprig-session--insert-result result))))))))

(defun sprig-session--insert-tasks (block)
  "Insert a folded task-list BLOCK as a checklist, progress in its heading.
This CLI emits one `TaskCreate'/`TaskUpdate' per task rather than a whole
`TodoWrite' list; the model folds those into a running checklist, and this
renders it the same way a `TodoWrite' renders, so the plan-of-work reads as
a list either way.  Folds to its heading; TAB opens the checklist."
  (let ((items (plist-get block :items)))
    (magit-insert-section (sprig-tasks block t)
      (magit-insert-heading
        (concat (sprig--face "Tasks" 'sprig-session-tool)
                (when items
                  (concat "  " (sprig-session--todo-progress items)))))
      (magit-insert-section-body
        (sprig-session--insert-todos items)))))

(defvar markdown-hide-markup)
(defvar markdown-mode-font-lock-keywords)
(defvar markdown-regex-italic)
(defvar markdown-regex-bold)
(declare-function markdown-mode "markdown-mode" ())
(declare-function markdown-toggle-markup-hiding "markdown-mode" (&optional arg))

(defun sprig-session--tame-markdown-faces ()
  "Trim `markdown-mode' fontification down to what Claude's prose uses.
Runs in the hidden fontify buffer (see `sprig-session--fontify-uncached')
after the mode is on but before font-lock compiles its keywords.

Two of the mode's defaults misfire on chat prose.  Declarative metadata
fontification paints any leading `Key: value' lines as MultiMarkdown
front matter, in `font-lock-string-face'; it normally only fires at a
file's very top, but each prose block is fontified from position 1, so
it fires on every message.  And the emphasis delimiters admit `_', so an
underscore in an identifier like `some_var' or `__init__' turns the run
italic or bold.  Claude emits `*italics*' and `**bold**' and never
underscore emphasis, so drop the metadata keywords and pin the emphasis
delimiters to `*'."
  (setq-local markdown-mode-font-lock-keywords
              (seq-remove
               (lambda (kw)
                 (memq (car-safe kw) '(markdown-match-declarative-metadata
                                       markdown-match-pandoc-metadata)))
               markdown-mode-font-lock-keywords))
  (setq-local markdown-regex-italic
              (replace-regexp-in-string
               (regexp-quote "[*_]") "\\*" markdown-regex-italic nil t))
  (setq-local markdown-regex-bold
              (replace-regexp-in-string
               (regexp-quote "\\*\\*\\|__") "\\*\\*" markdown-regex-bold nil t)))

(defvar sprig-session--fontify-cache (make-hash-table :test 'equal :size 200)
  "Memo of `sprig-session--fontify-markdown' results, keyed on raw TEXT.
A settled prose block's text never changes, yet a full re-render rebuilds
its fontified form identically every time; on a long conversation that
markdown font-lock pass is over half the render cost.  Caching it turns
the work from once-per-render-per-block into once-per-block.  The result
strings carry text properties, but `insert' copies them into the buffer,
so handing back the same object on a later render is safe.")

(defvar sprig-session--fontify-cache-flag 'unset
  "Value of `sprig-session-fontify-markdown' the cache was built under.
Fontification output depends on the flag, so a change to it stales every
entry; the cache is cleared when the flag no longer matches this.")

(defun sprig-session--fontify-uncached (text)
  "Fontify TEXT with `markdown-mode', its markup characters hidden.
See `sprig-session--fontify-markdown' for the whys; this is the raw pass,
without the memo."
  (if (and sprig-session-fontify-markdown
           (require 'markdown-mode nil t))
      (with-current-buffer (get-buffer-create " *sprig-markdown*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (delay-mode-hooks (markdown-mode))
          (setq-local markdown-hide-markup t)
          (sprig-session--tame-markdown-faces)
          ;; The toggle wires markup hiding fully (invisibility spec plus the
          ;; refontify hooks) where merely setting the flag may not.
          (when (fboundp 'markdown-toggle-markup-hiding)
            (ignore-errors (markdown-toggle-markup-hiding 1)))
          (insert text)
          (font-lock-ensure)
          (sprig--adopt-faces (buffer-string))))
    text))

(defun sprig-session--fontify-cache-refresh ()
  "Empty the fontify memo when `sprig-session-fontify-markdown' has changed.
Fontification output depends on the flag, so a change to it stales every
cached entry.  Shared by the synchronous and the deferred fontify paths."
  (unless (eq sprig-session--fontify-cache-flag sprig-session-fontify-markdown)
    (clrhash sprig-session--fontify-cache)
    (setq sprig-session--fontify-cache-flag sprig-session-fontify-markdown)))

(defun sprig-session--fontify-markdown (text)
  "Return TEXT fontified with `markdown-mode', its markup characters hidden.
Fontifies in a reusable hidden buffer and copies the propertized string,
so the `*'/`#' markup carries an `invisible' property the session buffer's
invisibility spec then hides (see `sprig-session-mode').  The copy's faces
are adopted onto `font-lock-face', without which this buffer's font-lock
would strip them (see `sprig--adopt-faces').  Returns TEXT
unchanged when `sprig-session-fontify-markdown' is nil or markdown-mode is
not installed.  Memoised on TEXT (see `sprig-session--fontify-cache'),
since a full re-render fontifies every settled block afresh though only
the streaming block's text has moved.  This is the synchronous pass; the
render can defer it to idle instead (see `sprig-session--prose')."
  (sprig-session--fontify-cache-refresh)
  (let ((hit (gethash text sprig-session--fontify-cache)))
    (or hit
        (puthash text (sprig-session--fontify-uncached text)
                 sprig-session--fontify-cache))))

;;;; Deferred (idle) fontification
;;
;; Fontifying a settled block is the heavier half of a render, and it runs
;; on the main thread the moment the block settles: a large markdown reply,
;; or the first paint of a long conversation (every block uncached at once),
;; stutters the UI just as a turn lands.  The work cannot leave the main
;; thread (markdown-mode font-lock has no async form), but it can leave the
;; critical path: `sprig-session--prose' inserts the block raw and queues its
;; text, and an idle timer fontifies the backlog in small batches, repainting
;; each buffer once its faces are ready.  The block reads as plain prose for
;; the blink before the repaint, exactly as the live streaming block already
;; does until it settles.  The model, and so the navigator, never wait on any
;; of this (see `sprig-session--current-model').

(defcustom sprig-session-fontify-async t
  "When non-nil, fontify settled markdown off the render's critical path.
An uncached prose block renders raw and is fontified by an idle worker (see
`sprig-session--fontify-drain'), which repaints the buffer once its faces are
ready, so a heavy font-lock pass no longer blocks the render that a landing
turn triggers.  Has no effect when `sprig-session-fontify-markdown' is nil."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-session-fontify-idle-delay 0.15
  "Idle seconds before the deferred markdown fontifier runs (see
`sprig-session-fontify-async')."
  :type 'number
  :group 'sprig)

(defvar sprig-session-fontify-batch 12
  "How many blocks the deferred fontifier fontifies per idle slice.
Bounded so a long backlog yields to input between slices rather than
fontifying the whole conversation in one uninterruptible burst.")

(defvar sprig-session--fontify-queue nil
  "Raw block texts awaiting deferred fontification, most recent first.")
(defvar sprig-session--fontify-queued (make-hash-table :test 'equal)
  "Set of texts already on `sprig-session--fontify-queue', to skip duplicates.")
(defvar sprig-session--fontify-buffers nil
  "Session buffers to repaint once the current deferred-fontify batch lands.")
(defvar sprig-session--fontify-timer nil
  "Pending idle timer draining `sprig-session--fontify-queue', or nil.")
(defvar-local sprig-session--fontify-fresh nil
  "A set of block texts the idle fontifier just cached, for one repaint.
Deferred fontification changes how a settled prose block looks without
changing the model, so the `equal' block diff cannot see it and would keep
the block in the untouched prefix, leaving it painted raw.  The drain
\(`sprig-session--fontify-drain') sets this before its repaint and
`sprig-session--render-incremental' reads and clears it, redrawing from the
earliest block it names so the block gains its faces.")

(defun sprig-session--fontify-arm ()
  "Arm the idle timer that drains the deferred-fontify queue, once."
  (unless sprig-session--fontify-timer
    (setq sprig-session--fontify-timer
          (run-with-idle-timer sprig-session-fontify-idle-delay nil
                               #'sprig-session--fontify-drain))))

(defun sprig-session--fontify-enqueue (text buffer)
  "Queue TEXT for deferred fontification and mark BUFFER for repaint.
A no-op for the text once it is cached or already queued; BUFFER is recorded
each time, so the block that finally fontifies it repaints the right buffers."
  (unless (or (gethash text sprig-session--fontify-cache)
              (gethash text sprig-session--fontify-queued))
    (puthash text t sprig-session--fontify-queued)
    (push text sprig-session--fontify-queue))
  (unless (memq buffer sprig-session--fontify-buffers)
    (push buffer sprig-session--fontify-buffers))
  (sprig-session--fontify-arm))

(defun sprig-session--fontify-drain ()
  "Fontify a batch of queued blocks into the cache, then repaint their buffers.
Runs on the idle timer.  Fontifies up to `sprig-session-fontify-batch' blocks,
repaints the shown session buffers that were waiting (a repaint re-queues any
block still un-fontified, and re-arms), and re-arms while the queue holds more."
  (setq sprig-session--fontify-timer nil)
  (let ((budget sprig-session-fontify-batch)
        (fresh (make-hash-table :test 'equal))
        (any nil))
    (while (and sprig-session--fontify-queue (> budget 0))
      (let ((text (pop sprig-session--fontify-queue)))
        (remhash text sprig-session--fontify-queued)
        (unless (gethash text sprig-session--fontify-cache)
          (puthash text (sprig-session--fontify-uncached text)
                   sprig-session--fontify-cache)
          (puthash text t fresh)
          (setq any t))
        (setq budget (1- budget))))
    (let ((buffers (prog1 sprig-session--fontify-buffers
                     (setq sprig-session--fontify-buffers nil))))
      (when any
        (dolist (buf buffers)
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (when (derived-mode-p 'sprig-session-mode)
                ;; Name the blocks that just gained faces so the incremental
                ;; render redraws from the earliest of them, rather than
                ;; keeping them all in the prefix and leaving them raw.
                ;; Merged, not replaced: an earlier drain's set can still be
                ;; waiting on a buffer that has not been shown in between.
                (if sprig-session--fontify-fresh
                    (maphash (lambda (k _)
                               (puthash k t sprig-session--fontify-fresh))
                             fresh)
                  (setq sprig-session--fontify-fresh (copy-hash-table fresh)))
                (if (get-buffer-window buf t)
                    (sprig-session--refresh)
                  ;; Off-screen (a reattached session seeded in the
                  ;; background, say): skipping it outright would strand the
                  ;; buffer raw for good, since its texts are now cached and
                  ;; nothing later re-queues them.  Leave it dirty instead,
                  ;; so `sprig-session--flush-when-shown' redraws it the
                  ;; moment it is displayed and the blocks gain their faces.
                  (setq sprig-session--dirty t))))))))
    (when sprig-session--fontify-queue
      (sprig-session--fontify-arm))))

(defun sprig-session--prose (text)
  "Return TEXT ready to insert as prose, fontified now or deferred to idle.
With `sprig-session-fontify-async', an uncached block is returned raw and its
markdown fontification is queued for the idle worker (see
`sprig-session--fontify-drain'); a cached block returns fontified at once.
Without async, fontifies synchronously (`sprig-session--fontify-markdown')."
  (if (not sprig-session-fontify-async)
      (sprig-session--fontify-markdown text)
    (sprig-session--fontify-cache-refresh)
    (or (gethash text sprig-session--fontify-cache)
        (progn (sprig-session--fontify-enqueue text (current-buffer))
               text))))

(defvar sprig-session--live-render nil
  "Bound non-nil while the incremental tail splice draws a live turn.
A live render fontifies prose synchronously so nothing shows raw (see
`sprig-session--prose-for'); a cold full render of a long buffer leaves it
nil, keeping the async path so opening one never blocks.  Dynamic, not
buffer-local: it scopes a single `sprig-session--splice-tail' call.")

(defun sprig-session--prose-for (text open)
  "Return TEXT fontified for a prose section, sync or deferred by context.
With `sprig-session-defer-live-prose', a live render (OPEN, the streaming
block, or `sprig-session--live-render', the tail splice a settling turn
drives) fontifies now, so no paragraph is shown raw; a cold full render
keeps the async path (`sprig-session--prose').  Without it, always
`sprig-session--prose'."
  (if (and sprig-session-defer-live-prose (or open sprig-session--live-render))
      (sprig-session--fontify-markdown text)
    (sprig-session--prose text)))

(defun sprig-session--completed-prose (text)
  "Return the leading run of whole paragraphs in TEXT, or nil for none.
A paragraph ends at a blank line outside a fenced code block; whatever
follows the last such blank line is still being typed, so it is withheld.
An open (unclosed) ``` fence withholds everything from its opening line,
since where it ends is not yet known.  This is what the deferred live
render shows (`sprig-session--insert-text'), so a half-typed paragraph or a
half-written code block never appears."
  (let ((lines (split-string text "\n" nil))
        (pos 0) (cut 0) (in-fence nil) (fence-start 0))
    (dolist (line lines)
      (cond
       ((string-match-p "\\`[ \t]*```" line)
        (if in-fence
            (setq in-fence nil)
          (setq in-fence t fence-start pos)))
       ((and (not in-fence) (string-match-p "\\`[ \t]*\\'" line))
        (setq cut (min (length text) (+ pos (length line) 1)))))
      (setq pos (+ pos (length line) 1)))
    ;; A fence still open caps the cut at its opening line.
    (when (and in-fence (< fence-start cut))
      (setq cut fence-start))
    (and (> cut 0) (substring text 0 cut))))

(defun sprig-session--paragraph-landed-p (delta)
  "Return non-nil when DELTA completes a paragraph in the deferred stream.
A paragraph ends at a blank line, which a delta may split across two
arrivals, so this threads the trailing-newline state in
`sprig-session--stream-nl'.  It errs towards yes: fence-correctness is the
render's job (`sprig-session--completed-prose'), and a false yes only costs a
cheap tail redraw that draws nothing new.  A single newline (a soft wrap)
does not count."
  (prog1
      (or (string-match-p "\n[ \t]*\n" delta)
          (and sprig-session--stream-nl (string-match-p "\\`[ \t]*\n" delta)))
    (when (> (length delta) 0)
      (setq sprig-session--stream-nl
            (and (string-match-p "\n[ \t]*\\'" delta) t)))))

(defun sprig-session--text-body (text)
  "Return TEXT with trailing newlines normalised to exactly one.
Trailing spaces are kept (a streamed delta may legitimately end in one),
so this matches what the in-place append path produces."
  (concat (string-trim-right text "[\n]+") "\n"))

(defun sprig-session--text-shown (block open)
  "Return the prose string a text or user BLOCK draws this render, or nil.
OPEN marks the live streaming block.  Deferring live prose, an open block
shows only its completed paragraphs (nil until one lands); any other prose
shows its whole text.  A whitespace-only block shows nil, so an empty block
\(a `text-block' with nothing after it, a withheld live one) draws no body
and, via `sprig-session--block-shown-p', pulls no separator blank around it."
  (let ((text (or (plist-get block :text) "")))
    (if (and open sprig-session-defer-live-prose
             (eq (plist-get block :type) 'text))
        (let ((done (sprig-session--completed-prose text)))
          (and done (sprig-session--text-body done)))
      (and (not (string-empty-p (string-trim text)))
           (sprig-session--text-body text)))))

(defun sprig-session--block-shown-p (block open)
  "Non-nil when BLOCK puts visible text on screen this render.
Only prose can come up empty (see `sprig-session--text-shown'); every other
block always draws.  An empty block still draws its (zero-length) section,
for block/section alignment, but is skipped by the separator rules."
  (if (memq (plist-get block :type) '(text user))
      (and (sprig-session--text-shown block open) t)
    t))

(defun sprig-session--insert-text (block &optional open)
  "Insert an assistant text BLOCK as bare prose.
It carries no label: a user turn is the tinted one, so the agent's output
is simply what is not tinted.  The section has no heading either, which
costs it nothing but the ability to fold, and prose is what you came to
read.  When OPEN, this is the live streaming block.  Normally it renders
raw (plus a trailing newline) and records the tail (`sprig-session--tail')
just before it, so `sprig-session--append-streamed' and a later full refresh
produce identical text; it gains markdown faces once it settles.  With
`sprig-session-defer-live-prose' it instead shows only its completed
paragraphs, fontified, and sets no tail (see
`sprig-session--completed-prose').  A settled block is normalised for tidy
display."
  (magit-insert-section (sprig-text block)
    (if (and open (not sprig-session-defer-live-prose))
        ;; The live block renders raw so the fast in-place append path and a
        ;; later full rebuild agree; it gains markdown faces once it settles.
        (progn
          (insert (plist-get block :text) "\n")
          (setq sprig-session--tail (copy-marker (1- (point)) t)))
      ;; Deferred (or settled): draw only what is shown, fontified.  An open
      ;; block shows its completed paragraphs and withholds the typing one; a
      ;; whitespace-only block shows nothing.  Nothing shown means no tail and
      ;; an empty section, which the separator rules then step over.
      (let ((shown (sprig-session--text-shown block open)))
        (when shown
          (insert (sprig-session--prose-for shown open)))))))

(defun sprig-session--insert-user (block)
  "Insert a user-turn BLOCK as prose carrying the `sprig-session-user' tint.
The tint is what tells your turn from the agent's output, so the block
needs no label, and no heading beyond its own first line.
`heading-highlight-face' is what magit paints over the section under
point; naming our own keeps the turn tinted there too.  With no heading
to confine it to, magit paints it over the whole section, which is what
we want."
  (magit-insert-section (sprig-user block nil
                         :heading-highlight-face 'sprig-session-user-highlight)
    (let ((beg (point))
          (shown (sprig-session--text-shown block nil)))
      (when shown
        (insert (sprig-session--prose-for shown nil))
        (sprig--add-face beg (point) 'sprig-session-user)))))

(defun sprig-session--insert-thinking (block)
  "Insert a thinking BLOCK, folded by default since it is verbose."
  (magit-insert-section (sprig-thinking block t)
    (magit-insert-heading (sprig--face "thinking" 'sprig-session-thinking))
    (magit-insert-section-body
      (insert (string-trim-right (plist-get block :text)) "\n"))))

(defun sprig-session--insert-error (block)
  "Insert an error BLOCK."
  (magit-insert-section (sprig-error block)
    (magit-insert-heading (sprig--face "error" 'error))
    (insert (string-trim-right (or (plist-get block :text) "")) "\n")))

;;;; Dialogs
;;
;; A question the agent asked mid-turn renders here, in the buffer, rather
;; than in the minibuffer: the turn it is about is on screen, and a
;; minibuffer prompt would hold the process filter (and Emacs with it) for
;; as long as the question went unanswered.  So the block stands pending,
;; you answer it with the same keys you review with, and the turn goes on.

(defun sprig-session--question-list (input)
  "Return INPUT's questions as a list.
The control request is re-read with JSON-faithful arrays, so `questions'
and `options' arrive as vectors and `multiSelect' as `:false'."
  (append (alist-get 'questions input) nil))

(defun sprig-session--multi-select-p (question)
  "Return non-nil when QUESTION takes more than one answer."
  (eq (alist-get 'multiSelect question) t))

(defconst sprig-session--plan-question
  '((question . "Approve this plan?")
    (multiSelect . :false)
    (options . [((label . "Approve")
                 (description . "the agent leaves plan mode and starts work"))
                ((label . "Reject")
                 (description . "say what is wrong; the agent plans again"))]))
  "The one thing a plan asks.
ExitPlanMode does not put it as a question, so it is put as one here, and
a plan is then answered by everything that answers a question.")

(defconst sprig-session--permission-question
  '((question . "Allow this call?")
    (multiSelect . :false)
    (options . [((label . "Allow")
                 (description . "run it, this once"))
                ((label . "Deny")
                 (description . "the agent is told no, and goes on"))]))
  "The one thing a tool wanting permission asks.
Put as a question here, as a plan's is, so a permission is answered by
everything that answers a question.")

(defun sprig-session--dialog-questions (block)
  "Return the questions dialog BLOCK asks."
  (pcase (plist-get block :kind)
    ("exit_plan_mode" (list sprig-session--plan-question))
    ("can_use_tool" (list sprig-session--permission-question))
    (_ (sprig-session--question-list (plist-get block :input)))))

(defun sprig-session--option-label (option)
  "Return OPTION's label."
  (alist-get 'label option))

(defun sprig-session--recommended-option (question)
  "Return the label QUESTION recommends, or its first option's.
The tool's own convention is to mark the recommended option in its label
and to put it first, so the first option is the fallback rather than a
guess."
  (let* ((options (append (alist-get 'options question) nil))
         (recommended
          (seq-find (lambda (option)
                      (string-match-p "recommend"
                                      (downcase (or (sprig-session--option-label
                                                     option)
                                                    ""))))
                    options)))
    (sprig-session--option-label (or recommended (car options)))))

(defun sprig-session--insert-question (block question index)
  "Insert QUESTION, the INDEX'th of dialog BLOCK, and what it offers.
The options are shown but not pickable: this buffer is for reading, and
the answering has a buffer of its own (see `sprig-session-answer')."
  (let ((answered (plist-get block :answered))
        (multi (sprig-session--multi-select-p question))
        (text (alist-get 'question question)))
    (magit-insert-section (sprig-question (list :dialog (plist-get block :id)
                                                :index index))
      (magit-insert-heading
        (concat (sprig--face (concat "? " text) 'sprig-session-dialog)
                (if (and multi (not answered))
                    (sprig--face "  (any of)" 'sprig-session-meta-key)
                  "")))
      (if answered
          ;; Settled: what was said, not what might have been.
          (insert "    "
                  (sprig--face
                   (or (alist-get (intern text) (plist-get block :answers))
                       "skipped")
                   'sprig-session-dialog-picked)
                  "\n")
        (seq-do
         (lambda (option)
           (insert "    "
                   (sprig--face (sprig-session--option-label option)
                                       'default)
                   (let ((description (alist-get 'description option)))
                     (if (and description (not (string-empty-p description)))
                         (sprig--face
                          (concat "  " (sprig-session--truncate
                                        description
                                        sprig-session-heading-max-width))
                          'sprig-session-meta-key)
                       ""))
                   "\n"))
         (alist-get 'options question))))))

(defun sprig-session--insert-plan (block)
  "Insert the plan dialog BLOCK holds, and what it says of it.
The plan itself, not a summary of it: approving is the point, and the
whole of what you are approving is here to read."
  (let ((plan (alist-get 'plan (plist-get block :input)))
        (answered (plist-get block :answered)))
    (magit-insert-section (sprig-plan block)
      (magit-insert-heading
        (sprig--face "? The agent has a plan" 'sprig-session-dialog))
      (insert (sprig-session--fontify-markdown
               (sprig-session--text-body (or plan ""))))
      (when answered
        (insert "    "
                (sprig--face (format "%s" (plist-get block :answers))
                                    'sprig-session-dialog-picked)
                "\n")))))

(defun sprig-session--insert-permission (block)
  "Insert the tool call BLOCK wants permission for, and what was said of it."
  (let* ((request (plist-get block :input))
         (tool (or (alist-get 'tool_name request) "a tool"))
         (summary (sprig-session--input-summary tool (alist-get 'input request))))
    (magit-insert-section (sprig-permission block)
      (magit-insert-heading
        (sprig--face (format "? Allow %s?" tool) 'sprig-session-dialog))
      (when summary
        (insert "    "
                (sprig--face
                 (sprig-session--truncate summary sprig-session-heading-max-width)
                 'default)
                "\n"))
      (when (plist-get block :answered)
        (insert "    "
                (sprig--face (format "%s" (plist-get block :answers))
                                    'sprig-session-dialog-picked)
                "\n")))))

(defun sprig-session--dialog-hint (kind)
  "Return the line saying how to answer a dialog of KIND."
  (pcase kind
    ("exit_plan_mode" "    a a to approve or reject · a r to approve")
    ("can_use_tool" "    a a to allow or deny · a s to deny")
    (_ "    a a to answer · a r to take the recommended")))

(defun sprig-session--insert-dialog (block)
  "Insert dialog BLOCK: what the agent asked, and what there is to answer.
The questions are the sections; no section of its own wraps them.  A
section that starts where its first child starts traps
`magit-section-backward': at that position it is the child that is
current, so `p' walks up to the parent and goes to the parent's start,
which is the very position it came from, and point never moves again.
Magit's own sections never meet this, always heading a section before
opening a child, and a wrapper here earns nothing to pay for it."
  (pcase (plist-get block :kind)
    ("exit_plan_mode" (sprig-session--insert-plan block))
    ("can_use_tool" (sprig-session--insert-permission block))
    (_ (seq-do-indexed
        (lambda (question index)
          (sprig-session--insert-question block question index))
        (sprig-session--question-list (plist-get block :input)))))
  (unless (plist-get block :answered)
    (insert (sprig--face (sprig-session--dialog-hint
                                 (plist-get block :kind))
                                'sprig-session-meta-key)
            "\n")))

(defun sprig-session--format-tokens (n)
  "Format N tokens compactly, in thousands or millions."
  (if (>= n 1000000) (format "%.1fM" (/ n 1000000.0))
    (format "%.1fk" (/ n 1000.0))))

(defun sprig-session--context-indicator (tokens)
  "Return (LABEL . FACE) for TOKENS of context in use, or nil.
The count is always shown; crossing `sprig-context-large-tokens' or
`sprig-context-huge-tokens' escalates the face and adds a word, so the
readout is a signal the context has grown large rather than a percentage
against a window the CLI never reports.  FACE is always one of the context
faces, never nil: the readout says how big the context is and nothing about
the turn, so it is coloured on its own terms rather than inheriting the
state line's face (see `sprig-session-context')."
  (when (and (numberp tokens) (> tokens 0))
    (let ((count (sprig-session--format-tokens tokens)))
      (cond
       ((and sprig-context-huge-tokens (>= tokens sprig-context-huge-tokens))
        (cons (concat count " (very large)") 'sprig-session-context-huge))
       ((and sprig-context-large-tokens (>= tokens sprig-context-large-tokens))
        (cons (concat count " (large)") 'sprig-session-context-large))
       (t (cons count 'sprig-session-context))))))

(defun sprig-session--meta-line (key value)
  "Return a header line pairing KEY with VALUE, or nil when VALUE is blank."
  (when (and value (not (string-empty-p (format "%s" value))))
    (concat (sprig--face (format "%-9s" (concat key ":"))
                                'sprig-session-meta-key)
            (format "%s" value) "\n")))

(defun sprig-session--insert-headers (model meta)
  "Insert the metadata header from MODEL and the META plist.
META may carry :title, :project, :model, and :status."
  (magit-insert-section (sprig-headers)
    (dolist (line (list
                   (sprig-session--meta-line
                    "Title" (or (plist-get meta :title) (plist-get model :title)))
                   (sprig-session--meta-line "Project" (plist-get meta :project))
                   (sprig-session--meta-line "Model"   (plist-get meta :model))
                   (sprig-session--meta-line "Status"  (plist-get meta :status))
                   (sprig-session--meta-line
                    "Mode" (sprig--notable-mode (plist-get model :mode)))
                   (sprig-session--meta-line "Session" (plist-get model :session))
                   (sprig-session--meta-line
                    "Cost" (when (plist-get model :cost)
                             (format "$%.4f" (plist-get model :cost))))))
      (when line (insert line)))
    (insert "\n")))

(defun sprig-session--prose-block-p (block)
  "Return non-nil when BLOCK reads as prose rather than as a one-line row.
A tool call or a thinking block folds to a single line, and a run of them
reads as one list of what the agent did.  Prose is what you actually
read, and a dialog is a question put to you, which wants the same air."
  (memq (plist-get block :type) '(user text error dialog)))

;;;; The state line
;;
;; The one question the buffer has to answer without being read is whether
;; anything is still going on in it.  It goes below the last message,
;; where you are already reading when a turn is coming in, and it is
;; stated rather than implied: the turn being over is the thing you are
;; waiting on, so the buffer says so, instead of leaving you to notice
;; that nothing has moved for a while.

(defun sprig-session--state (model)
  "Return (GLYPH TEXT FACE) for what is going on in MODEL, or has just ended.
The glyph, word, and face are `sprig--state-parts', shared with the
navigator so the two state lines never drift; only which state applies is
decided here, from this buffer's own live flags and MODEL.  The one thing
the navigator has no room for, the `a a to answer' hint on a waiting turn,
is added here."
  (let ((state
         (cond
          ;; Before anything else: the turn is not working, it is stopped, and
          ;; it is stopped on you.
          ((sprig-session-pending-dialog model) 'waiting)
          ;; Ahead of the turn's own state: a compaction stops the turn dead
          ;; for a minute or more, so `working…' would be the least of what is
          ;; going on.  An automatic one lands mid-turn, uninvited, which is
          ;; exactly when the reader wonders why nothing is moving.
          ((and (boundp 'sprig--compacting) sprig--compacting) 'compacting)
          (sprig-session--streaming 'streaming)
          ;; Sent, but nothing back yet: the transport is busy while it waits
          ;; on the agent's first token, so this window would otherwise read as
          ;; the previous turn's stale `✓ turn over'.
          ((and (boundp 'sprig--busy) sprig--busy) 'pending)
          ((plist-get model :error) 'failed)
          ;; The turn can end while a background agent (Task, Explore, ...) it
          ;; launched is still working; say so ahead of `done' so the buffer
          ;; does not go quiet on you while an agent churns.
          ((sprig-session-agent-running model) 'agent)
          ((plist-get model :done) 'done)
          ;; Replayed history, or a session not yet sent to: nothing is
          ;; running, but no turn of ours ended either, so claim neither.
          (t 'idle))))
    (pcase-let ((`(,glyph ,text ,face) (sprig--state-parts state)))
      (when (eq state 'waiting)
        (setq text (concat text "  ·  a a to answer")))
      (list glyph text face))))

(defun sprig-session--insert-state (model)
  "Insert the state line, below the last message: what is going on, or ended.
The context in use rides at the end of the line, where the reader is
already watching the turn; its face escalates once it grows large, and is
its own rather than the line's, so it says nothing about the turn.  The
side bar carries a rule in the state colour, so the gutter marks the end of
the turn as plainly as the line does."
  (pcase-let ((`(,glyph ,text ,face) (sprig-session--state model))
              (ctx (sprig-session--context-indicator (plist-get model :context)))
              (plan (sprig-session--plan-indicator model))
              (queued (and (boundp 'sprig--queued) (length sprig--queued)))
              (start (point)))
    (magit-insert-section (sprig-state)
      (insert (sprig--face (format "%s  %s" glyph text) face))
      ;; Nearest the state, since it qualifies it: `working…' says something is
      ;; happening, `☑ 4/5' says how much of it is left to happen.
      (when plan
        (insert (sprig--face "  ·  " face)
                (sprig--face (format "☑ %s" plan) 'sprig-session-plan)))
      ;; A queued message is invisible otherwise: it is not in the transcript
      ;; (nothing was sent), and it fires on its own, so without this the turn
      ;; ending would spawn a message the reader never asked for twice.  In
      ;; its own face, like the context: it is not the turn's state, it is
      ;; what happens next.
      (when (and queued (> queued 0))
        (insert (sprig--face "  ·  " face)
                (sprig--face (format "%d queued" queued)
                                    'sprig-session-pending)))
      ;; The permission mode rides its own tag, coloured on its own terms
      ;; rather than the turn's, exactly as the navigator's state line carries
      ;; it (same `sprig--notable-mode' filter, same `sprig-mode-tag' face).
      ;; Only the notable modes show; the everyday ones say nothing worth it.
      (when-let ((mode (sprig--notable-mode (plist-get model :mode))))
        (insert (sprig--face "  ·  " face)
                (sprig--face mode 'sprig-mode-tag)))
      (when ctx
        ;; The separator belongs to the line, the readout does not: the
        ;; context is coloured on its own terms, so a normal one does not
        ;; read as a warning just because the turn is busy (both yellow).
        (insert (sprig--face "  ·  " face)
                (sprig--face (car ctx) (cdr ctx))))
      (insert "\n"))
    (when (> (sprig-session--margin-width) 0)
      (let ((ov (make-overlay start (min (1+ start) (point-max)))))
        (overlay-put ov 'sprig-session-margin t)
        (overlay-put ov 'before-string
                     (propertize " " 'display
                                 `((margin left-margin)
                                   ,(propertize
                                     (make-string (sprig-session--margin-width) ?━)
                                     'face face))))))))

(defun sprig-session--insert-pending-steer ()
  "Draw any floated steer messages, pinned just above the state line.
A `c c' sent into a running turn shows here, tinted as yours the way a
committed turn is but marked with a leading arrow as not yet taken, until
the agent reaches the boundary that folds it into the transcript (see
`sprig-session--commit-pending-steer').  So your input waits at the bottom
instead of splitting the streaming message, and it sits where the committed
turn will land.  Each message is collapsed to one line and ellipsised: a
teaser, since its full text is about to become a real user turn."
  (dolist (text sprig-session--pending-steer)
    ;; The text is the section value, so `sprig-session-unfloat' knows which
    ;; message the point sits on.
    (magit-insert-section (sprig-pending-steer text)
      (let ((beg (point))
            (line (sprig-session--truncate
                   (replace-regexp-in-string "[ \t\n]+" " " (string-trim text))
                   sprig-session-heading-max-width)))
        (insert (sprig--face "⤷ " 'sprig-session-pending) line "\n")
        ;; The user tint beneath, so the arrow keeps its own colour on top and
        ;; the line reads as yours (see `sprig-session--insert-user').
        (sprig--add-face beg (point) 'sprig-session-user)))))

(defun sprig-session--insert-pending-queue ()
  "Draw any queued messages, pinned below the steers and above the state line.
A `c q' message waits here, tinted as yours and marked with an hourglass, so
a queued follow-up is visible while it waits for the running turn to end (a
steer, by contrast, is on the wire already and shows a `⤷').  Point on one of
these and `k' (`sprig-session-reject') takes it back.  Drawn straight from
`sprig--queued', the list that actually sends, so the float never promises a
message the queue will not deliver.  Each is collapsed to one ellipsised
line, since its full text becomes a real user turn once the queue flushes."
  (dolist (text (and (boundp 'sprig--queued) sprig--queued))
    ;; The text is the section value, so `k' (`sprig-session-reject') knows
    ;; which message the point sits on.
    (magit-insert-section (sprig-pending-queue text)
      (let ((beg (point))
            (line (sprig-session--truncate
                   (replace-regexp-in-string "[ \t\n]+" " " (string-trim text))
                   sprig-session-heading-max-width)))
        (insert (sprig--face "⧖ " 'sprig-session-queued) line "\n")
        (sprig--add-face beg (point) 'sprig-session-user)))))

;;;; Rendering entry points

(defcustom sprig-session-incremental-render t
  "When non-nil, redraw only the changed tail of a session buffer.
A full re-render is O(conversation): on a long session every structural
event repaints the whole buffer, which is the main source of navigator
lag while a turn streams in.  Since events almost always append at the
end, `sprig-session--render-incremental' keeps the unchanged block prefix
and re-inserts only the new tail and the state line, turning that into
O(new events).  It falls back to a full render whenever the prefix
diverges or a header field changed, so the buffer stays a faithful
projection of the model either way.  Set to nil to force full renders."
  :type 'boolean
  :group 'sprig)

(defvar-local sprig-session--rendered-blocks nil
  "The model's `:blocks' at the last render.
The baseline `sprig-session--render-incremental' diffs the new model
against to find the unchanged prefix it can keep.")

(defvar-local sprig-session--rendered-header nil
  "Header-field signature at the last render (see
`sprig-session--header-signature').  A change forces a full redraw, so the
kept header section cannot go stale behind the incremental path.")

(defvar-local sprig-session--rendered-sections nil
  "The last top-level section each block drew at the last render, aligned
with `sprig-session--rendered-blocks'.  The incremental splice takes its
boundary from a section's magit-maintained `end' marker, which stays at the
block's true end across a later fold or unfold (a raw position marker would
be left mid-section when a folded tool's body is later drawn).  Recording
the block's *last* section, rather than mapping blocks to sections by
position, also handles a block that draws several top-level sections, as a
multi-question dialog does.")

(defvar-local sprig-session--rendered-streaming nil
  "`sprig-session--streaming' as it stood at the last render.
The last block renders differently open (streaming) than settled, most
visibly under `sprig-session-defer-live-prose', yet the model is equal
across the settling `done'.  So a change here forces the last block to
redraw, without which its withheld final paragraph would never appear.")

(defvar-local sprig-session--incremental-reason nil
  "Why the last refresh fell back to a full render, or nil if it did not.
Set by `sprig-session--render-incremental' and logged when
`sprig-session-debug-render' is on, to make a fallback storm diagnosable.")

(defun sprig-session--insert-block (block prev first last)
  "Insert one BLOCK at point, with its boundary blank line and its margin.
PREV is the block before it (nil at the head), FIRST is non-nil for the
first block of the render, and LAST is the model's final block, which when
it is streaming text opens the live tail.  Factored out so the full render
and the incremental tail render (`sprig-session--splice-tail') draw a block
identically."
  ;; A blank line at every boundary prose is on either side of, which is to
  ;; say: around prose, and so above the first row of a run of tool calls, but
  ;; never between two of those rows.  A turn's tool calls then sit as one
  ;; block with air around it, rather than as a ladder down the buffer.  The
  ;; line goes before the block rather than after, which would sit between the
  ;; live text section's end and `sprig-session--tail'.  A block that shows
  ;; nothing (a withheld live paragraph, an empty one) is stepped over: no
  ;; blank to it, and PREV is the last block that actually drew (see
  ;; `sprig-session--insert-blocks'), so it pulls no doubled air either.
  (let ((open (and sprig-session--streaming (eq block last))))
    (when (and (not first)
               (sprig-session--block-shown-p block open)
               (or (sprig-session--prose-block-p block)
                   (and prev (sprig-session--prose-block-p prev))))
      (insert "\n"))
    ;; Held from before the block is drawn, so the stamp lands against its
    ;; first line rather than against whatever follows it.
    (let ((start (point)))
      (pcase (plist-get block :type)
        ('user     (sprig-session--insert-user block))
        ;; The live tail is the last block, when it is text, and only while a
        ;; turn is actually streaming in.
        ('text     (sprig-session--insert-text block open))
        ('thinking (sprig-session--insert-thinking block))
        ('tool     (sprig-session--insert-tool block))
        ('tasks    (sprig-session--insert-tasks block))
        ('dialog   (sprig-session--insert-dialog block))
        ('error    (sprig-session--insert-error block)))
      (sprig-session--insert-margin start (plist-get block :time)))))

(defun sprig-session-render (model &optional meta)
  "Render review MODEL into the current buffer as magit-sections.
META is an optional plist of display metadata (see
`sprig-session--insert-headers').  The buffer should already be in
`sprig-session-mode'."
  (let* ((inhibit-read-only t)
         (blocks (plist-get model :blocks))
         (last (car (last blocks)))
         (prev nil)
         (first t))
    (setq sprig-session--tail nil)
    ;; Before the erase: these hang off buffer text that is about to go.
    (remove-overlays (point-min) (point-max) 'sprig-session-margin t)
    (erase-buffer)
    (let (sections)
      (magit-insert-section (sprig-session)
        (sprig-session--insert-headers model meta)
        (setq sections
              (sprig-session--insert-blocks magit-root-section blocks prev first last))
        ;; Below the last message, and last of all, so it is what the buffer
        ;; ends on.  The live tail sits inside the block above and is not
        ;; disturbed by an insertion after it, so streamed text still lands
        ;; above this line rather than through it.  A floated steer sits just
        ;; above the state line, where its committed turn will land.
        (when blocks (insert "\n"))
        (sprig-session--insert-pending-steer)
        (sprig-session--insert-pending-queue)
        (sprig-session--insert-state model))
      (sprig-session--update-margin)
      (sprig-session--record-baseline model meta sections))
    (goto-char (point-min))))

(defun sprig-session--insert-blocks (root blocks prev first last)
  "Insert BLOCKS under ROOT in order, returning the last top-level section
each block drew.  A block may draw several top-level sections (a
multi-question dialog does); its last is what bounds it.  PREV and FIRST
seed the boundary blank line for the first of BLOCKS (see
`sprig-session--insert-block'); LAST is the model's final block."
  (let (sections)
    (dolist (block blocks)
      (sprig-session--insert-block block prev first last)
      ;; A block that showed nothing does not become the separator anchor:
      ;; PREV stays the last block that drew, and FIRST is not yet spent, so
      ;; the next real block sits against a real neighbour, not an empty one.
      (when (sprig-session--block-shown-p
             block (and sprig-session--streaming (eq block last)))
        (setq first nil prev block))
      ;; The block's sections have just been appended to ROOT; its last is
      ;; the freshest child.
      (push (car (last (oref root children))) sections))
    (nreverse sections)))

(defun sprig-session--header-signature (model meta)
  "Return the header fields of MODEL and META as a comparable value.
The incremental render keeps the header section untouched, so a change to
a field it draws (see `sprig-session--insert-headers') must force a full
redraw; comparing this signature across renders is how that is caught.

Cost is deliberately left out: it ticks up throughout a turn, so keying on
it would force a full O(conversation) redraw on nearly every structural
event, which is the very cost this path exists to avoid.  So the Cost line
is allowed to lag, refreshing on the next full render (a title, mode, or
session change, or a reset)."
  (list (or (plist-get meta :title) (plist-get model :title))
        (plist-get meta :project) (plist-get meta :model)
        (plist-get meta :status)  (plist-get model :mode)
        (plist-get model :session)))

(defun sprig-session--record-baseline (model meta sections)
  "Store MODEL's blocks, header signature, and per-block SECTIONS as baseline."
  (setq sprig-session--rendered-blocks (plist-get model :blocks)
        sprig-session--rendered-header (sprig-session--header-signature model meta)
        sprig-session--rendered-sections sections
        sprig-session--rendered-streaming sprig-session--streaming))

(defun sprig-session--common-prefix (a b)
  "Return the count of leading elements `equal' in lists A and B."
  (let ((n 0))
    (while (and a b (equal (car a) (car b)))
      (setq n (1+ n) a (cdr a) b (cdr b)))
    n))

(defun sprig-session--splice-tail (root k model meta)
  "Redraw the buffer from block K on, keeping the first K blocks in place.
ROOT is the review root section.  BOUNDARY is the recorded end of block
K-1 (`sprig-session--rendered-ends'); everything past it (blocks from K, the
trailing blank line, and the state line) is deleted and re-inserted as
fresh children of ROOT, so only O(new events) is drawn.  Sections are kept
by buffer position, not by block index, so a block that drew several
sections is handled correctly.  Returns t."
  (let* ((inhibit-read-only t)
         (new-blocks (plist-get model :blocks))
         ;; A shallow copy carrying the full old child list, so re-inserted
         ;; sections still inherit a predecessor's fold state by ident.  It
         ;; must be taken before ROOT's children are truncated below; `oset'
         ;; replaces the slot rather than mutating the list, so the copy keeps
         ;; the original.
         (oldroot (clone root))
         ;; End of block K-1's last section: the true end of the kept prefix,
         ;; magit-maintained across a fold or unfold, and before the blank
         ;; line to block K so that separator is redrawn with the tail.
         (boundary (oref (nth (1- k) sprig-session--rendered-sections) end))
         ;; Keep the header and every section starting before the boundary;
         ;; those are exactly the sections of blocks 0..K-1, however many each
         ;; drew.  A fresh list, since the inserts below `nconc' onto it.
         (keep (seq-filter (lambda (c) (< (oref c start) boundary))
                           (oref root children)))
         (kept-sections (seq-take sprig-session--rendered-sections k))
         (prev (nth (1- k) new-blocks))
         (last (car (last new-blocks)))
         new-sections)
    (oset root children keep)
    (remove-overlays boundary (point-max) 'sprig-session-margin t)
    (delete-region boundary (point-max))
    (goto-char boundary)
    ;; Clear the live tail only when the block holding it is being redrawn.
    ;; A state-only splice (no new blocks) keeps the last block, so its tail
    ;; marker stays valid and streaming keeps appending in place; clearing it
    ;; would send every following delta through a needless refresh.
    (when (nthcdr k new-blocks)
      (setq sprig-session--tail nil))
    ;; Append the new tail as children of the existing root: binding the
    ;; parent (non-nil) keeps `magit-insert-section' from starting a new root,
    ;; and the old root feeds fold inheritance.
    (let ((magit-insert-section--parent root)
          (magit-insert-section--oldroot oldroot)
          ;; A tail splice is the live path: fontify its prose now, so a
          ;; landing paragraph or a settling turn never shows raw (see
          ;; `sprig-session--prose-for').
          (sprig-session--live-render t))
      (setq new-sections
            (sprig-session--insert-blocks root (nthcdr k new-blocks) prev nil last))
      (when new-blocks (insert "\n"))
      (sprig-session--insert-pending-steer)
      (sprig-session--insert-pending-queue)
      (sprig-session--insert-state model))
    ;; The root's end marker sat at the old point-max; carry it to the new one.
    (oset root end (point-marker))
    (sprig-session--update-margin)
    (sprig-session--record-baseline model meta (append kept-sections new-sections)))
  t)

(defun sprig-session--fontify-floor (blocks fresh)
  "Return the index of the first prose BLOCK whose text is in FRESH, or nil.
FRESH is the set of texts the idle fontifier just cached
\(`sprig-session--fontify-fresh').  A rendered `text' or `user' block whose
key is in it is currently painted raw, so the tail redraw must start no
later than there for it to gain its faces.  Only those two types reach the
fontify cache (`sprig-session--prose'), so only they can match."
  (let ((i 0) (floor nil))
    (while (and blocks (not floor))
      (let ((block (car blocks)))
        (when (and (memq (plist-get block :type) '(text user))
                   (gethash (sprig-session--text-body (plist-get block :text))
                            fresh))
          (setq floor i)))
      (setq i (1+ i) blocks (cdr blocks)))
    floor))

(defun sprig-session--render-incremental (model meta)
  "Redraw only the changed tail of the buffer, or return nil to fall back.
Diffs MODEL's blocks against the last render's (`sprig-session--rendered-blocks')
for the unchanged leading prefix, and as long as the first block is kept
hands off to `sprig-session--splice-tail' (which redraws the new blocks and
the state line, or the state line alone when only it changed).  Returns
non-nil when it rendered, nil for the caller to run a full
`sprig-session-render'; it declines when disabled, on the first render, when
a header field changed, when the recorded per-block boundaries are missing,
or when even the first block diverged.  The reason is recorded in
`sprig-session--incremental-reason' for the debug log."
  (let* ((root magit-root-section)
         (old-blocks sprig-session--rendered-blocks)
         (new-blocks (plist-get model :blocks))
         (k (sprig-session--common-prefix old-blocks new-blocks))
         ;; Read-and-clear: a fontify repaint gets exactly one shot at the
         ;; boundary, and a later ordinary refresh must not re-apply it.
         (fresh (prog1 sprig-session--fontify-fresh
                  (setq sprig-session--fontify-fresh nil)))
         ;; A just-cached prose block in the kept prefix is still painted raw;
         ;; pull the redraw boundary back to it so the tail draws it fontified.
         ;; The model did not change, so the block diff alone would keep it.
         (floor (and fresh (sprig-session--fontify-floor new-blocks fresh)))
         (k (if floor (min k floor) k))
         ;; The last block renders differently open than settled (see
         ;; `sprig-session--rendered-streaming'), and the model is equal across
         ;; the settling `done', so force the last block to redraw when the
         ;; streaming state changed, or its withheld tail would never show.
         (k (if (and new-blocks
                     (not (eq sprig-session--streaming
                              sprig-session--rendered-streaming)))
                (min k (1- (length new-blocks)))
              k))
         (reason
          (cond
           ((not sprig-session-incremental-render) 'disabled)
           ((not (and root old-blocks
                      (eq (oref root type) 'sprig-session))) 'no-baseline)
           ;; The recorded sections must line up with the recorded blocks, or
           ;; a full render is safer than trusting stale boundaries.  They are
           ;; written together (`sprig-session--record-baseline'), so this can
           ;; only disagree after a reload swapped the render code under a
           ;; buffer whose baseline the old code built; the full render heals it.
           ((not (= (length sprig-session--rendered-sections) (length old-blocks)))
            'sections-mismatch)
           ((not (equal sprig-session--rendered-header
                        (sprig-session--header-signature model meta)))
            'header)
           ;; k == 0 means even the first block changed, so nothing is worth
           ;; keeping.  k up to the full block count is fine: with no new
           ;; blocks the splice redraws only the trailing state line, which is
           ;; the common state-only refresh (streaming -> done, busy toggling).
           ((not (> k 0)) 'prefix-diverged))))
    (setq sprig-session--incremental-reason reason)
    (unless reason
      (sprig-session--splice-tail root k model meta))))

;;;; Live sink: accumulate events, refresh the buffer
;;
;; The transport (sprig.el) emits a backend-neutral event vocabulary; a
;; session buffer folds those events into its model and re-renders.
;; `sprig-session-consume' is the buffer's sink: the transport calls it once
;; per event (see `sprig--review-sink', which wraps it with the owning
;; buffer's transport bookkeeping).
;;
;; Refresh rebuilds from the whole event list rather than mutating the
;; buffer in place.  That reuses the tested renderer verbatim and keeps
;; the buffer a pure projection of the model.  magit-section makes the
;; re-render cheap where it matters: user folds survive it (the
;; visibility cache is keyed by a section's stable ident), and point is
;; carried to the same section when it still exists.
;;
;; A full re-render is O(conversation), too costly to run per streamed
;; token in a long session, so `sprig-session-consume' avoids it two ways:
;;
;; - Streamed `text' deltas, the high-frequency case, extend the last text
;;   section in place at `sprig-session--tail', with no re-render at all.
;; - Structural events (a new tool call, a result, the user turn, done)
;;   mark the buffer dirty and arm a short timer that coalesces a burst
;;   into one render (`sprig-session-flush').  That render re-establishes
;;   the tail, so the following text deltas take the fast path again.
;;
;; So the re-render count is bounded by the number of structural events in
;; a turn, not the number of tokens.  `seed'/`reset' render synchronously,
;; being one-shot.

(defcustom sprig-session-refresh-delay 0.1
  "Floor, in seconds, for coalescing structural events before a re-render.
Batching them into one render at this cadence keeps a long conversation
from re-rendering repeatedly.  Lower is more responsive but renders more
often.  Streamed text does not wait on this; it appends in place.  This is
a floor: on a large buffer the wait widens toward the last render's own
cost (see `sprig-session-refresh-delay-max'), so a heavy render does not
fire again before the previous one has drawn."
  :type 'number
  :group 'sprig)

(defcustom sprig-session-refresh-delay-max 0.5
  "Ceiling, in seconds, on the adaptive coalescing delay.
A full re-render is O(conversation), so on a long history the flat
`sprig-session-refresh-delay' would arm the next render a tenth of a second
after the last one finished, spending most of a busy turn rendering and
leaving the buffer janky between draws.  Instead the wait widens to about
the last render's measured cost, so at most half a turn goes on rendering
and the rest stays responsive.  This bounds how late a structural update
can appear, and thus how far the wait may widen."
  :type 'number
  :group 'sprig)

(defvar-local sprig-session--last-render-cost 0.0
  "Seconds the last full re-render took, driving the adaptive coalescing.
Measured in `sprig-session--refresh' and read by `sprig-session--schedule',
so a cheap buffer keeps the snappy floor while a costly one widens toward
its own render time.  Nil-safe start of zero means the first render waits
only the floor.")

(defcustom sprig-session-debug-render nil
  "When non-nil, log each re-render's cost to `*Messages*'.
A diagnostic for redraw lag: with it on, every `sprig-session--refresh'
reports the milliseconds it took (and whether it was a full or an
incremental tail draw) alongside the buffer's accumulated event count, so
a slow draw and its conversation size show up together.  Off by default."
  :type 'boolean
  :group 'sprig)

(defun sprig-session--refresh-delay ()
  "Return the coalescing delay, widened toward the last render's cost.
`sprig-session-refresh-delay' is the floor and `sprig-session-refresh-delay-max'
the ceiling; between them the delay tracks `sprig-session--last-render-cost',
so renders never stack up faster than they draw."
  (min sprig-session-refresh-delay-max
       (max sprig-session-refresh-delay sprig-session--last-render-cost)))

(defun sprig-session--locate (pos)
  "Return a locator for POS that survives a re-render, or nil.
A section's ident and an offset into it, rather than a raw position: the
render erases the buffer, so a position means nothing across it, while a
section can be found again."
  (save-excursion
    (goto-char pos)
    (when-let ((section (magit-current-section)))
      (cons (magit-section-ident section) (- pos (oref section start))))))

(defun sprig-session--relocate (locator fallback)
  "Return where LOCATOR points now, or FALLBACK when its section is gone."
  (or (and locator
           (when-let ((section (magit-get-section (car locator))))
             (min (+ (oref section start) (max 0 (cdr locator)))
                  (or (oref section end) (point-max)))))
      (min fallback (point-max))))

;; `sprig-session--current-model' now lives in sprig-session.el (the data layer).

(defun sprig-session--refresh ()
  "Rebuild the model from accumulated events and re-render in place.
Keeps folds (via magit-section's visibility cache), and puts point and the
scroll back where they were, in every window showing the buffer.

The windows have to be done one by one, and by more than point: a window
keeps its own point and its own start, `erase-buffer' collapses both, and
a refresh driven by the coalescing timer runs in whatever buffer happens
to be current, so the buffer's own point is not the point you are looking
at.  Restoring only that is what threw a window to the top of the buffer
while a turn came in."
  ;; Do not bind `magit-insert-section--oldroot' here: the
  ;; `magit-insert-section' macro captures it from `magit-root-section'
  ;; itself, and only then advances `magit-root-section' to the new root.
  ;; Pre-binding it leaves the root stale and breaks section finishing.
  (let* ((mt0 (and sprig-session-debug-render (current-time)))
         (model (sprig-session--current-model))
         (model-ms (and mt0 (* 1000 (float-time (time-subtract (current-time) mt0)))))
         (pos (point))
         (locator (sprig-session--locate pos))
         (windows (mapcar (lambda (win)
                            (list win
                                  (sprig-session--locate (window-point win))
                                  (window-point win)
                                  (sprig-session--locate (window-start win))
                                  (window-start win)))
                          (get-buffer-window-list nil nil t))))
    (let ((t0 (current-time))
          (incremental (sprig-session--render-incremental model sprig-session--meta)))
      ;; The tail path handles the common append; only on its own terms does a
      ;; full O(conversation) render run.
      (unless incremental
        (sprig-session-render model sprig-session--meta))
      ;; Time the draw so the coalescing timer can widen toward it: a heavy
      ;; render must not be re-armed before it has finished drawing.
      (setq sprig-session--last-render-cost
            (float-time (time-subtract (current-time) t0)))
      (when sprig-session-debug-render
        (message "sprig-session model %.1fms[%s] + %s %.1fms  %d events  %s"
                 model-ms sprig-session--last-fold
                 (if incremental "tail"
                   (format "render[%s]" sprig-session--incremental-reason))
                 (* 1000 sprig-session--last-render-cost)
                 (length sprig-session--events)
                 (buffer-name))))
    (goto-char (sprig-session--relocate locator pos))
    (pcase-dolist (`(,win ,point-loc ,point-pos ,start-loc ,start-pos) windows)
      (when (window-live-p win)
        (set-window-point win (sprig-session--relocate point-loc point-pos))
        ;; NOFORCE, so a start that would now put point off screen is
        ;; recomputed rather than obeyed.
        (set-window-start win (sprig-session--relocate start-loc start-pos) t)))
    (sprig--apply-marks)))

(defun sprig-session--cancel-timer ()
  "Cancel this buffer's pending coalescing-refresh timer, if any."
  (when sprig-session--timer
    (cancel-timer sprig-session--timer)
    (setq sprig-session--timer nil)))

(defun sprig-session-flush (&optional buffer)
  "Render events pending in BUFFER since the last refresh, now.
Called by the coalescing timer, and usable to force a render immediately."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (sprig-session--cancel-timer)
        (when sprig-session--dirty
          (setq sprig-session--dirty nil)
          (sprig-session--refresh))))))

(defun sprig-session--append-streamed (s)
  "Append streamed text S at the live text tail, without a re-render."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char sprig-session--tail)
      (insert s))))          ; the type-t tail marker advances past S

(defun sprig-session--flush-if-shown (buffer)
  "Coalesced-timer render: draw BUFFER now if it is on screen, else defer.
The per-event redraw is O(conversation); a session buffer nobody is looking at
should not pay it on every stream tick, and with several sessions running at
once those off-screen redraws are what stutter the rest of Emacs (the navigator
included).  So when BUFFER is displayed in no window this leaves it dirty and
does nothing; `sprig-session--flush-when-shown' draws it the moment it next
appears.  Its model still rebuilds on demand for the navigator's status and
preview (see `sprig-session--current-model'), independent of this render, so
nothing on screen goes stale while it waits."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (sprig-session--cancel-timer)
      (when (and sprig-session--dirty (get-buffer-window buffer t))
        (sprig-session-flush buffer)))))

(defun sprig-session--flush-when-shown (&optional frame)
  "Draw any dirty session buffer newly shown in a window of FRAME.
On `window-buffer-change-functions': an off-screen session buffer skips its
coalesced render (see `sprig-session--flush-if-shown'), so when it comes back on
screen its pending events must be drawn to catch it up."
  (dolist (win (window-list frame 'no-minibuf))
    (let ((buf (window-buffer win)))
      (when (and (buffer-live-p buf)
                 (buffer-local-value 'sprig-session--dirty buf)
                 (with-current-buffer buf (derived-mode-p 'sprig-session-mode)))
        (sprig-session-flush buf)))))

(add-hook 'window-buffer-change-functions #'sprig-session--flush-when-shown)

(defun sprig-session--schedule ()
  "Mark the buffer dirty and arm the coalescing refresh timer.
The timer draws the buffer only if it is on screen (see
`sprig-session--flush-if-shown'); off-screen it stays dirty until shown."
  (setq sprig-session--dirty t)
  (unless sprig-session--timer
    (setq sprig-session--timer
          (run-with-timer (sprig-session--refresh-delay) nil
                          #'sprig-session--flush-if-shown (current-buffer)))))

(defun sprig-session--stamp-arrival (event)
  "Push a `time' event dating EVENT's arrival, unless it inherits one.
The wire carries no times, so a live turn is dated when it reaches the
buffer, and dated here rather than at render, since the model is rebuilt
from this event list every render and a time read off the clock there
would tick forward under a finished conversation.  One stamp per block is
enough: only the first `text' of a run opens a block, and the deltas
extending it are contiguous, so a `text' behind a `text' takes the stamp
already in the list rather than adding thousands of its own."
  (unless (and (eq (car event) 'text)
               (eq (car-safe (car sprig-session--events)) 'text))
    (push (list 'time (format-time-string "%FT%T.%3NZ" nil t))
          sprig-session--events)))

(defconst sprig-session--steer-boundary-events '(tool-call done error dialog)
  "Events that mark the agent taking a floated steer.
A mid-turn `c c' reaches the agent at its next tool-call boundary, so its
message stays floated (see `sprig-session--pending-steer') until one of these
lands, and commits just before it: a `tool-call' is the boundary itself, and
`done'/`error'/`dialog' are the turn ending or pausing without one.")

(defun sprig-session-stage-steer (text)
  "Float TEXT as a steer awaiting the agent's pickup, and redraw.
Called by the transport once TEXT has been written to the CLI's stdin
mid-turn: the message is not in the transcript yet (the agent has not taken
it), so it shows pinned above the state line until it does.  The counterpart
to `sprig-session--commit-pending-steer', which lands it once the agent
reaches the boundary that takes it."
  (setq sprig-session--pending-steer
        (append sprig-session--pending-steer (list text)))
  (sprig-session--schedule))

(defun sprig-session--commit-pending-steer ()
  "Fold any floated steer messages into the events, oldest first.
Turns each pending `c c' into a real `user' event, so it lands in the
transcript at the point the agent received it (the next tool-call boundary,
or the turn's end) rather than where the stream happened to be when it was
sent.  Each carries its own arrival stamp, pushed before it so the fold
reads the pair in order.  A no-op when nothing is floated."
  (when sprig-session--pending-steer
    (dolist (text sprig-session--pending-steer)
      (push (list 'time (format-time-string "%FT%T.%3NZ" nil t))
            sprig-session--events)
      (push (list 'user text) sprig-session--events))
    (setq sprig-session--pending-steer nil)
    (sprig-session--schedule)))

(defun sprig-session-consume (event)
  "Fold transport EVENT into the current session buffer.
A streamed `text' delta extends the live text section in place, with no
re-render, whenever a tail is established.  Every other event, and the
first `text' of a run, clears the tail and schedules a coalesced render
\(see `sprig-session-refresh-delay'), which re-establishes the tail."
  ;; A floated steer commits just before the boundary that takes it, so its
  ;; `user' event is pushed ahead of this one and the fold reads it first.
  (when (memq (car event) sprig-session--steer-boundary-events)
    (sprig-session--commit-pending-steer))
  (sprig-session--stamp-arrival event)
  (push event sprig-session--events)
  ;; Track whether a turn is in flight, which decides both the live tail and
  ;; the running bar (see `sprig-session--streaming').  Any event the agent
  ;; produces means it is working; a `user' event is you, mid-turn or not, and
  ;; says nothing either way.  The prior value tells the first `text' of a run
  ;; from a later one, so a deferred stream still paints `working…' at once.
  (let ((was-streaming sprig-session--streaming))
    (pcase (car event)
      ((or 'text 'thinking 'tool-call) (setq sprig-session--streaming t))
      ((or 'done 'error)
       (setq sprig-session--streaming nil)
       ;; A staging seed waiting on a read is served now the turn (and so the
       ;; `Read' result) has landed.  Deferred a tick so the model folds this
       ;; `done' in first, and only for `done': an errored turn read nothing.
       (when (and sprig-session--pending-seed (eq (car event) 'done))
         (run-at-time 0 nil
                      (let ((buf (current-buffer)))
                        (lambda ()
                          (when (buffer-live-p buf)
                            (with-current-buffer buf
                              (sprig-session--seed-from-read))))))))
      ;; A dialog opening or settling flips the session's `waiting' status, so
      ;; the navigator's `?' glyph appears and clears in step with it.
      ((or 'dialog 'dialog-answer) (sprig--status-refresh))
      (_ nil))
    (cond
     ;; Fast path: extend the live raw tail in place (never set while deferring).
     ((and (eq (car event) 'text)
           sprig-session--tail (marker-position sprig-session--tail))
      (sprig-session--append-streamed (cadr event)))
     ;; Deferring live prose: a `text' delta is withheld until its paragraph
     ;; ends, so redraw only when one lands, not once per delta.  The first
     ;; `text' of a run redraws regardless, to open the block and say `working'.
     ((and sprig-session-defer-live-prose (eq (car event) 'text))
      (let ((landed (sprig-session--paragraph-landed-p (cadr event))))
        (when (or (not was-streaming) landed)
          (sprig-session--schedule))))
     (t
      (unless (eq (car event) 'text)
        (setq sprig-session--tail nil sprig-session--stream-nl nil))
      (sprig-session--schedule)))))

(defun sprig-session-reset (&optional meta)
  "Drop this session buffer's accumulated events and render empty.
With META, replace the header metadata plist."
  (sprig-session--cancel-timer)
  (setq sprig-session--events nil sprig-session--dirty nil
        sprig-session--streaming nil sprig-session--stream-nl nil
        sprig-session--pending-steer nil)
  (when meta (setq sprig-session--meta meta))
  (sprig-session--refresh))

(defun sprig-session-seed (events &optional meta)
  "Seed this session buffer with EVENTS (in order) and refresh synchronously.
Use this to replay history before the live sink appends more, so a later
`sprig-session-consume' rebuilds from history plus the new event.  Replayed
history is settled, so it renders with no live tail."
  (sprig-session--cancel-timer)
  (setq sprig-session--events (reverse events) sprig-session--dirty nil
        sprig-session--streaming nil sprig-session--stream-nl nil
        sprig-session--pending-steer nil)
  (when meta (setq sprig-session--meta meta))
  (sprig-session--refresh))

(defun sprig-session-refresh (&rest _)
  "Re-read this review's history from its log, and re-render it.
A buffer's events are seeded once, when it is opened, and are never read
again: a render rebuilds the model from the events the buffer has already
accumulated, not from disk.  So this is what picks up a log that has
grown since, or a parser that has since learned to read more out of it,
`sprig-reload' being a reload of the code and not of a buffer's events.

Bound to \\`g', through `revert-buffer'.  Refuses while a turn is in
flight, since that turn is not in the log yet and re-seeding would drop it
from the buffer."
  (interactive)
  (when (and (boundp 'sprig--busy) sprig--busy)
    (user-error "A turn is in flight; refresh once it lands"))
  (if (and (not sprig-session--file) (sprig--remote))
      ;; A remote re-read fetches the log over SSH: run it in the background so
      ;; `g' never blocks Emacs, and re-seed when it lands.  A remote log has no
      ;; local path, so it replays without its subagents' steps either way.
      (progn
        (message "sprig: re-reading the log…")
        (sprig--session-log-lines-async
         (lambda (lines)
           (let ((events (sprig-session--replayed-events lines nil)))
             (sprig-session-seed events sprig-session--meta)
             (message "sprig: re-read %d event%s from the log"
                      (length events) (if (= (length events) 1) "" "s"))))))
    (let* ((lines (if sprig-session--file
                      (sprig-session-read-session-lines sprig-session--file)
                    (sprig--session-log-lines)))
           ;; A live session finds its own log; a local stored one is read by
           ;; path.  Its subagent steps ride along when the log has a path.
           (file (or sprig-session--file
                     (and (fboundp 'sprig--session-log-file)
                          (sprig--session-log-file))))
           (events (sprig-session--replayed-events lines file)))
      (sprig-session-seed events sprig-session--meta)
      (message "sprig: re-read %d event%s from the log"
               (length events) (if (= (length events) 1) "" "s")))))

(defun sprig-session-buffer (name)
  "Return a buffer named NAME, put into `sprig-session-mode'."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sprig-session-mode) (sprig-session-mode)))
    buffer))

;;;; Major mode

(defvar sprig-session-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `sprig-session-mode'.
Inherits magit-section's navigation and folding; the sprig verbs are
added on top as they land.")


(define-derived-mode sprig-session-mode magit-section-mode "Sprig-Review"
  "Major mode for reviewing an agent conversation as read-only sections.
Built on `magit-section-mode': move with \\`n' / \\`p', fold with TAB."
  :group 'sprig
  ;; `g' is bound to `revert-buffer' by the parent mode; point it at a re-read
  ;; of the log, rather than leaving the one key that means refresh a no-op.
  (setq-local revert-buffer-function #'sprig-session-refresh)
  ;; Surface the session's Claude permission mode (plan, auto, ...) in the
  ;; mode line; nil for an offline file review, which owns no session.
  (setq-local mode-line-process '(:eval (sprig--mode-line-permission)))
  ;; Prose wraps on word boundaries; tool headings are pre-truncated to one
  ;; line (see `sprig-session-heading-max-width'), so wrapping suits the body.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Markdown markup (`*', `#', ...) carries `invisible markdown-markup' from
  ;; `sprig-session--fontify-markdown'; hide it here so only the styling shows.
  (add-to-invisibility-spec 'markdown-markup)
  (sprig--suppress-section-highlight)
  ;; Claim the margin the timestamps hang in before the buffer is displayed,
  ;; so its first window comes up with the right width.
  (setq-local left-margin-width (sprig-session--margin-width)))

(defun sprig-session-show (model &optional meta name)
  "Show review MODEL in a session buffer named NAME and select it.
META is passed to `sprig-session-render'."
  (let ((buffer (get-buffer-create (or name "*sprig-session*"))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sprig-session-mode)
        (sprig-session-mode))
      (sprig-session-render model meta))
    (pop-to-buffer buffer)))

(defun sprig-session-read-session-lines (file)
  "Return the non-empty JSONL lines of session-log FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" t)))

(defun sprig-session--subagent-events-for-file (file)
  "Return replayed subagent step events for session-log FILE, or nil.
The CLI writes each subagent's transcript beside the log it belongs to, in
`<session-id>/subagents/', and mentions none of it in the log itself, so
this is the only way a replayed `Agent' call gets its work back rather than
just its report.  A `.meta.json' sidecar names the `Agent' call each
transcript ran under, which is what lets a step find its row.

Reads by path, so a log opened over TRAMP brings its subagents with it.
Missing or unreadable files are simply no steps: the transcript is an
extra, and the `Agent' row still carries the report without it."
  (let ((dir (expand-file-name (concat (file-name-base file) "/subagents")
                               (file-name-directory file))))
    (when (file-directory-p dir)
      (apply #'append
             (mapcar
              (lambda (meta)
                (ignore-errors
                  (let* ((obj (sprig-session--parse-session-json
                               (with-temp-buffer
                                 (insert-file-contents meta)
                                 (buffer-string))))
                         (parent (alist-get 'toolUseId obj))
                         (log (concat (string-remove-suffix ".meta.json" meta)
                                      ".jsonl")))
                    (when (and parent (file-readable-p log))
                      (sprig-session-subagent-events
                       parent (sprig-session-read-session-lines log))))))
              (directory-files dir t "\\.meta\\.json\\'"))))))

(defun sprig-session--replayed-events (lines file)
  "Return the events of LINES, with FILE's subagent steps folded in.
The steps go last, after the whole transcript: they are read from files of
their own, so there is no interleaving them by time, and the fold finds an
`Agent' call by id whether or not its result has landed."
  (append (sprig-session-log-events lines)
          (and file (sprig-session--subagent-events-for-file file))))

;;;###autoload
(defun sprig-session-open-file (file)
  "Open a read-only review of a stored `claude' session-log FILE.
Replays the whole transcript from the log; see `sprig-session-log-events'.
This is the local-read path.  A remote session's log lives on the SSH host
and is fetched by the integration layer, not here."
  (interactive "fSession log (.jsonl): ")
  (let ((buffer (sprig-session-buffer
                 (format "*sprig-session: %s*" (file-name-base file)))))
    (with-current-buffer buffer
      (setq sprig-session--file file)     ; so `g' re-reads this same file
      (sprig-session-seed (sprig-session--replayed-events
                          (sprig-session-read-session-lines file) file)))
    (pop-to-buffer buffer)))

;;;; Instruction builders
;;
;; Every change-touching verb is sugar over a message to the agent (see
;; DESIGN.md, "Verbs are canned instructions").  These builders are pure:
;; they turn the object(s) under point or marked into the instruction text.

(defcustom sprig-session-commit-instruction
  "Please commit the current changes with a suitable commit message."
  "Instruction the commit verb sends to the agent."
  :type 'string
  :group 'sprig)

(defcustom sprig-session-accept-instruction
  "Yes, go ahead; use your judgement on any open choice."
  "Affirmative the yes/accept verb sends to answer the agent's last question.
The agent has the whole conversation in context, so a short yes resolves
against whatever it just proposed (\"Want me to push?\" -> \"Yes\"); the
trailing clause nudges it to pick when the question was an either/or.  For
a genuinely open choice, compose a reply with `c c' instead."
  :type 'string
  :group 'sprig)

(defcustom sprig-session-decline-instruction
  "No, please don't; hold off and wait for my next instruction."
  "Negative the no/decline verb sends to answer the agent's last question.
The mirror of `sprig-session-accept-instruction': a short no, resolved by
the agent against what it just proposed, telling it to stop rather than
proceed.  For a reason or an alternative, compose a reply with `c c'."
  :type 'string
  :group 'sprig)

(defun sprig-session-reject-instruction (changes)
  "Return an instruction asking the agent to undo CHANGES.
CHANGES is a list of (FILE . HUNK-PLIST)."
  (concat
   (if (cdr changes) "Please undo these changes:\n\n"
     "Please undo this change:\n\n")
   (mapconcat
    (lambda (fc)
      (format "In `%s`:\n```diff\n%s\n```"
              (car fc) (sprig--format-hunk (cdr fc))))
    changes "\n\n")))

(defun sprig-session-run-instruction (command)
  "Return an instruction asking the agent to run COMMAND."
  (format "Please run:\n```\n%s\n```" command))

(defconst sprig-session--non-shell-langs
  '("diff" "elisp" "emacs-lisp" "lisp" "json" "python" "py" "js" "jsx"
    "javascript" "ts" "tsx" "typescript" "c" "cpp" "c++" "rust" "rs" "go"
    "java" "ruby" "rb" "php" "html" "css" "scss" "xml" "yaml" "yml" "toml"
    "ini" "sql" "markdown" "md" "text" "org")
  "Fence info-string languages the run verb treats as non-commands.
A fenced block tagged with one of these is code or data, not a shell
command, so `sprig-session-run' skips it; an untagged block or a shell tag
\(sh, bash, ...) is runnable.")

(defun sprig-session--fenced-blocks (text)
  "Return the triple-backtick fenced code blocks in TEXT.
Each element is a plist (:lang LANG :body BODY :beg BEG :end END): LANG is
the first word of the opening fence's info string (nil when absent), BODY
the block's contents, and BEG/END the character offsets in TEXT spanning
the whole block, fences included.  Only fences that open at column zero are
recognised."
  (let ((blocks '())
        (pos 0))
    (while (string-match
            "^\\(```+\\)[ \t]*\\([^\n]*\\)\n\\(\\(?:.\\|\n\\)*?\\)\n\\1[ \t]*$"
            text pos)
      (let ((info (string-trim (match-string 2 text))))
        (push (list :lang (and (not (string-empty-p info))
                               (downcase (car (split-string info))))
                    :body (match-string 3 text)
                    :beg (match-beginning 0)
                    :end (match-end 0))
              blocks))
      (setq pos (match-end 0)))
    (nreverse blocks)))

(defun sprig-session--runnable-blocks (text)
  "Return the fenced blocks in TEXT that read as shell commands.
Filters `sprig-session--fenced-blocks' down to untagged or shell-tagged
fences, dropping code/data blocks named by `sprig-session--non-shell-langs'."
  (seq-remove (lambda (b)
                (member (plist-get b :lang) sprig-session--non-shell-langs))
              (sprig-session--fenced-blocks text)))

;;;; Steering: send through the owned session

(defun sprig-session-set-remote (remote)
  "Record REMOTE, the session host's SSH destination (nil when local).
Used to reach a changed file over TRAMP when visiting it."
  (setq sprig-session--remote remote))

(defun sprig-session--send (text &optional mode)
  "Send TEXT as a user instruction steering this review's session.
MODE, when given (e.g. \"plan\"), sets the permission mode for the turn.
Starts or resumes the session if it is not already live."
  (sprig--review-deliver text mode)
  (message "sprig: sent%s" (if mode (format " (%s mode)" mode) "")))

(defun sprig-session--steer (text)
  "Send TEXT into the turn already in flight (see `sprig--review-steer').
Falls back to a plain send when the turn has since finished, so a message
does not go down with the turn it was composed against."
  (sprig--review-steer text))

(defun sprig-session--queue (text)
  "Hold TEXT until the in-flight turn ends (see `sprig--review-queue').
Falls back to a plain send when no turn is running, for the same reason
`sprig-session--steer' does."
  (sprig--review-queue text))

;;;; Verbs

(defun sprig-session--reject-pairs (sections)
  "Return (FILE . HUNK) pairs for the hunk SECTIONS."
  (delq nil
        (mapcar (lambda (s)
                  (when (eq (oref s type) 'sprig-hunk)
                    (cons (plist-get (oref (oref s parent) value) :file)
                          (oref s value))))
                sections)))

(defun sprig-session-reject ()
  "Undo the diff hunks at point, or unstage the floated message at point (`k').
`k' is the take-it-back gesture, and what it takes back depends on what
point sits on.  On a floated `c q' queued message it drops just that one
from the queue, the way `c Q' drops them all.  On a floated `c c' steer it
cannot help: the steer is already on the wire, so it says so and points at
`c i' (interrupt), which is the only way to stop mid-turn input and stops
the whole turn.  Otherwise it asks the agent to undo the marked diff hunks,
or the hunk at point (on a mixed mark set, confirms and acts only on the
hunks; see DESIGN.md).

The hunk case steers rather than sends: a bad hunk is usually spotted while
the turn is still running, and waiting it out to say so lets the agent keep
building on it.  With no turn running that is an ordinary send."
  (interactive)
  (let ((section (magit-current-section)))
    (cond
     ((and section (eq (oref section type) 'sprig-pending-queue))
      (sprig--review-unqueue (oref section value)))
     ((and section (eq (oref section type) 'sprig-pending-steer))
      (user-error "A steer is already sent; interrupt with `c i' to stop it"))
     (t
      (let* ((sections (sprig--marked-sections))
             (pairs (sprig-session--reject-pairs sections)))
        (unless pairs (user-error "No diff hunk marked or at point"))
        (when (and sprig--marks (< (length pairs) (length sections))
                   (not (y-or-n-p
                         (format "Reject %d hunk(s), ignoring %d other mark(s)? "
                                 (length pairs) (- (length sections) (length pairs))))))
          (user-error "Cancelled"))
        (sprig-session--steer (sprig-session-reject-instruction pairs))
        (sprig--unmark-sections
         (sprig--sections-of-type sections 'sprig-hunk)))))))

(defun sprig-session-commit ()
  "Ask the agent to commit the current changes."
  (interactive)
  (sprig-session--send sprig-session-commit-instruction))

(defun sprig-session-compact (&optional instructions)
  "Compact this session's context, replacing its history with a summary.
Sends the CLI's `/compact' command as a turn of its own: the session id is
unchanged and the conversation continues from the summary, so a context
grown large (see the state line) is reclaimed without starting over.  With
a prefix argument, prompt for INSTRUCTIONS steering what the summary keeps.

A `/compact' cannot fold into a running turn, so when one is in flight this
queues it (as `c q' does) and compacts once the turn ends, rather than
refusing outright."
  (interactive
   (list (and current-prefix-arg
              (read-string "Compact instructions (blank = default): "))))
  (let ((inst (and instructions (string-trim instructions))))
    (sprig-session--queue
     (if (and inst (not (string-empty-p inst)))
         (concat "/compact " inst)
       "/compact"))))

(defun sprig-session--tool-command (section)
  "Return the shell command a `sprig-tool' SECTION ran, or nil."
  (alist-get 'command
             (sprig--parse-input
              (plist-get (oref section value) :input))))

(defun sprig-session--prose-command (section)
  "Return the fenced shell command to run from prose SECTION.
SECTION is a `sprig-text'/`sprig-user' block; the command is the runnable
fenced block point is in, or the sole runnable block when point sits
outside one.  This reaches a command the agent proposed but did not run.
Signals a `user-error' when there is no runnable block, or several and
point is in none."
  (let* ((text (plist-get (oref section value) :text))
         (blocks (sprig-session--runnable-blocks text)))
    (unless blocks
      (user-error "No runnable command block in this prose"))
    (let* ((base (or (oref section content) (oref section start)))
           (off (- (point) base))
           (here (seq-find (lambda (b) (and (>= off (plist-get b :beg))
                                            (<= off (plist-get b :end))))
                           blocks)))
      (cond (here (plist-get here :body))
            ((null (cdr blocks)) (plist-get (car blocks) :body))
            (t (user-error
                "Point is in no command block (%d in this prose); move onto one"
                (length blocks)))))))

(defun sprig-session-run ()
  "Ask the agent to run a command.
On a tool-call section, the command that tool ran; on a prose section, the
shell command in the fenced code block point is in (or its sole one), which
lets you run a command the agent proposed but did not execute.  Acts on the
marked section, or the one at point when nothing is marked.

Steers rather than sends: asking for a command while the agent is working
is the case that matters (it is usually a correction to what you are
watching), and waiting out the turn to ask would defeat it.  With no turn
running this is an ordinary send."
  (interactive)
  (let* ((sections (sprig--marked-sections))
         (tool (seq-find (lambda (s) (eq (oref s type) 'sprig-tool)) sections))
         (prose (seq-find (lambda (s) (memq (oref s type)
                                            '(sprig-text sprig-user)))
                          sections))
         (cmd (cond (tool (or (sprig-session--tool-command tool)
                              (user-error "That tool call has no command to run")))
                    (prose (sprig-session--prose-command prose))
                    (t (user-error
                        "No tool call or command block marked or at point")))))
    (sprig-session--steer (sprig-session-run-instruction cmd))))

(defun sprig-session-accept ()
  "Yes: affirm the agent's last question, the affirmative of what it asked.
Sends `sprig-session-accept-instruction' as the next turn (\"Want me to
push?\" -> \"Yes\").  The agent resolves the short yes against the
conversation it already holds; this only answers, it does not commit
(that is `C').  Its mirror is `sprig-session-decline'."
  (interactive)
  (sprig-session--send sprig-session-accept-instruction)
  (message "sprig: yes"))

(defun sprig-session-decline ()
  "No: decline the agent's last question, the mirror of `sprig-session-accept'.
Sends `sprig-session-decline-instruction' as the next turn, telling the
agent to hold off rather than proceed."
  (interactive)
  (sprig-session--send sprig-session-decline-instruction)
  (message "sprig: no"))

(defun sprig-session-set-title (title)
  "Set this review's display TITLE in the header.
The stored session's own ai-title (owned by the CLI) is left untouched, so
this affects only what the navigator and header show for the open buffer.
To persist a title to the log, see `sprig-session-retitle'."
  (interactive
   (list (read-string "Title: " (plist-get sprig-session--meta :title))))
  (setq sprig-session--meta (plist-put sprig-session--meta :title title))
  (sprig-session--refresh))

(declare-function sprig--title-ask "sprig" (id dir remote-host callback))
(declare-function sprig--title-apply "sprig" (id remote-host proposed))
(declare-function sprig--title-commit "sprig" (id remote-host title))

(defun sprig-session-retitle ()
  "Ask the agent for a short title for this session, then set it (`T a').
Forks the session the way `c b' does to propose a title, and once you
confirm or edit the suggestion writes it to the log as a user title (the
`custom-title' the CLI's own `/rename' writes) so it survives a reload and
is never regenerated away.  The header updates too."
  (interactive)
  (unless sprig--session-id
    (user-error "This review has no stored session yet"))
  (let ((id sprig--session-id)
        (dir sprig--working-dir)
        (host (sprig--remote)))
    (sprig--title-ask id dir host
                      (lambda (proposed)
                        (sprig--title-apply id host proposed)))))

(defun sprig-session-retitle-manually (title)
  "Set this session's TITLE by hand and write it to the log (`T m').
Like `sprig-session-set-title', but it writes a user title (the same
`custom-title' the CLI's `/rename' writes) so it survives a reload, the way
`sprig-session-retitle' persists the agent's suggestion.  The plain `t' key
relabels the header only."
  (interactive
   (list (read-string "Session title: " (plist-get sprig-session--meta :title))))
  (unless sprig--session-id
    (user-error "This review has no stored session yet"))
  (sprig--title-commit sprig--session-id (sprig--remote) title))

(transient-define-prefix sprig-session-title-dispatch ()
  "Retitle this session (`T').
`T a' / `T m' save the new title to the log so it survives a reload; `T t'
only relabels this buffer's header, as the plain `t' key does."
  [["Title"
    ("a" "ask the agent, then save" sprig-session-retitle)
    ("m" "set by hand, then save" sprig-session-retitle-manually)
    ("t" "relabel the header only (not saved)" sprig-session-set-title)]])

(declare-function sprig-session-open "sprig" (dir &optional session-id host fork))
(declare-function sprig--remote "sprig" ())

(defun sprig-session-new ()
  "Start a fresh conversation in this session's directory (`s n').
This session is left alone: the new one gets its own session buffer and its
own session, which is what you want when the next piece of work is
unrelated rather than a continuation of this one.  Call
`sprig-session-open' directly to be asked for a different directory."
  (interactive)
  ;; On this session's host, pinned: an unrelated piece of work still
  ;; belongs where the work is, and a session started off a local `C-u s'
  ;; must not quietly come back on the primary remote.
  (sprig-session-open sprig--working-dir nil (or (sprig--remote) t)))

(defun sprig-session-new-message ()
  "Start a fresh session and open a prompt for its first message (`s c').
Like `s n' followed by `c c': a new session in this one's directory,
dropped straight into the compose buffer instead of an empty review
buffer.  `sprig-session-new' selects the new buffer, so the compose targets
it."
  (interactive)
  (sprig-session-new)
  (sprig-session-message))

(defun sprig-session-new-message-plan ()
  "Start a fresh session and compose its first message in plan mode (`s p').
Like `s c', but the opening turn is composed in plan mode."
  (interactive)
  (sprig-session-new)
  (sprig-session-message t))

(defun sprig-session-fork ()
  "Fork this session into one of its own, leaving this one untouched (`s f').
The fork replays this session's history and carries it on under a session
id of its own, so the two diverge from here: this buffer's session is not
written to again by the fork.  The CLI forks from the end of a session, so
this branches from where the conversation now stands, not from point.

The fork is only made on its first send, which is when the CLI is asked to
resume this session `--fork-session'; until then the new buffer is just a
replay of this history."
  (interactive)
  (unless sprig--session-id
    (user-error "This session has no id yet; send something first, then fork"))
  ;; The fork resumes the parent's id, which only exists on the parent's
  ;; host, so it is pinned there rather than left to follow the primary remote.
  (sprig-session-open sprig--working-dir sprig--session-id
                        (or (sprig--remote) t) t)
  (message "sprig: forked; the branch starts at its first send"))

(defun sprig-session-retry ()
  "Re-send the most recent user turn (`c l')."
  (interactive)
  (let* ((model (sprig-session--current-model))
         (last-user (seq-find (lambda (b) (eq (plist-get b :type) 'user))
                              (reverse (plist-get model :blocks)))))
    (unless last-user (user-error "No previous user turn to resend"))
    (sprig-session--send (plist-get last-user :text))))

(defun sprig-session-independent-review ()
  "Run an independent review of the latest changes, then act on it (`c r').
Asks the agent to spawn a subagent (the Task tool) that looks at the
uncommitted changes with fresh eyes and critiques them, then to address the
subagent's valid findings.  A subagent has its own context, so the review is
not the same agent marking its own work; Sprig renders its run inline as a
nested `Agent' row.  Any marked sections narrow what to review, the way `c c'
attaches them."
  (interactive)
  (let ((context (sprig--marked-context)))
    (sprig-session--send
     (concat
      "Launch a subagent with the Task tool to independently review the "
      "uncommitted changes here"
      (if context " (the parts quoted below)" "")
      ".  Brief it neutrally: run `git diff' and `git diff --staged', read "
      "enough surrounding code to judge the changes, then give a focused, "
      "critical review of correctness bugs, edge cases, unclear names, missing "
      "or wrong tests, and anything risky.  It reviews only and edits nothing, "
      "and it should judge cold, so do not tell it your intent or defend the "
      "changes.  When it reports back, address its valid findings and say which "
      "you disagree with and why."
      (if context (format "\n\nThe parts to review:\n\n%s" context) "")))))

(defun sprig-session-interrupt ()
  "Interrupt the in-flight turn on this review's session.
Asks the CLI to end the turn cleanly and keeps the session live, so the
next send continues it rather than resuming; falls back to killing the
turn if the CLI does not honour the request (see `sprig-interrupt-timeout')."
  (interactive)
  (sprig--review-interrupt-owned))


(defun sprig-session--file-location (path)
  "Return PATH, as a TRAMP name on the session host when the session is remote."
  (if sprig-session--remote (format "/ssh:%s:%s" sprig-session--remote path) path))

(defun sprig-session--question-section-p (section)
  "Return non-nil when SECTION is, or sits within, a question section."
  (let ((s section))
    (while (and s (not (eq (oref s type) 'sprig-question)))
      (setq s (oref s parent)))
    s))

(defun sprig-session-visit ()
  "Visit the file the section at point refers to, or answer a question.
On a question the agent is waiting on, open the answer dialog, the way
`a a' does.  On a diff hunk, best-effort move point to the first changed
line."
  (interactive)
  (let ((section (magit-current-section)))
    (if (sprig-session--question-section-p section)
        (sprig-session-answer)
      (let ((file (sprig--section-file section)))
        (unless file (user-error "No file to visit here"))
        (find-file (sprig-session--file-location file))
        (when (eq (oref section type) 'sprig-hunk)
          (when-let* ((hunk (oref section value))
                      (anchor (car (or (plist-get hunk :new) (plist-get hunk :old))))
                      (needle (string-trim-left anchor)))
            (unless (string-empty-p needle)
              (goto-char (point-min))
              (when (search-forward needle nil t)
                (beginning-of-line)))))))))

;;;; Compose buffer (the c c message)

(defvar-local sprig-session--compose-target nil
  "Session buffer a compose buffer sends to.")
(defvar-local sprig-session--compose-context nil
  "Marked-section context prepended to the composed message, or nil.")
(defvar-local sprig-session--compose-mode nil
  "Permission mode for the composed message (e.g. \"plan\"), or nil.")
(defvar-local sprig-session--compose-queue nil
  "Non-nil when the composed message waits for the in-flight turn to end.
Nil is the ordinary `c c', which speaks now: it steers a running turn, and
sends outright when none is running.")
(defvar-local sprig-session--compose-format nil
  "Function framing the composed message, or nil for the default framing.
Called with the composed TEXT and the attached CONTEXT, and returns the
message actually sent.  A published changeset review frames its comments
its own way (see `sprig-review-publish'); the default puts the context
first under a `Regarding:' heading.")
(defvar-local sprig-session--compose-btw nil
  "Non-nil when the composed text is a side question (`c b'), not a message.
Sent as a throwaway one-shot that leaves the turn and the log alone, rather
than as a turn in the conversation.")

(defvar sprig-session-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'sprig-session-compose-send)
    (define-key map (kbd "C-c C-k") #'sprig-session-compose-abort)
    map)
  "Keymap for `sprig-session-compose-mode'.")

(define-derived-mode sprig-session-compose-mode text-mode "Sprig-Msg"
  "Compose a message to send to a sprig conversation.
\\<sprig-session-compose-mode-map>\\[sprig-session-compose-send] sends, \
\\[sprig-session-compose-abort] cancels.")


(defun sprig-session-message (&optional plan queue)
  "Compose a message and send it to this review's session (`c c').
Any marked sections are attached as context (see DESIGN.md's `c c').

Says it now: with a turn running the message steers it (the agent takes it
at its next tool-call boundary and carries on in the same turn), and with
none it opens a turn of its own.  Which of the two is settled when you
send, not when you start composing, so a turn that ends while you are
still typing changes nothing you have to think about.

With PLAN non-nil, send the turn in plan mode (`c p'), which needs a turn
of its own and so refuses to fold into a running one.  With QUEUE non-nil,
hold it until the running turn ends (`c q')."
  (interactive)
  (sprig-session--compose (current-buffer) (sprig--marked-context)
                         plan queue))

(defun sprig-session--compose (target context &optional plan queue format label)
  "Pop a compose buffer whose send targets session buffer TARGET.
CONTEXT is the attached-context string (or nil), PLAN sends in plan mode
\(`c p'), and QUEUE holds the message until the running turn ends (`c q').
FORMAT, when given, frames the sent message from the composed text and
CONTEXT (see `sprig-session--compose-format'); LABEL names what is
attached, for the echo-area line, and defaults to counting the marks.
Shared by `sprig-session-message' and `sprig-review-publish'; call it from
the buffer whose marks CONTEXT was collected in, so that count reads right
before the compose buffer takes over."
  (let ((what (and context
                   (or label (format "%d section(s)" (length sprig--marks)))))
        (buf (get-buffer-create "*sprig-message*")))
    (with-current-buffer buf
      (sprig-session-compose-mode)
      (erase-buffer)
      (setq sprig-session--compose-target target
            sprig-session--compose-context context
            sprig-session--compose-mode (and plan "plan")
            sprig-session--compose-queue queue
            sprig-session--compose-format format
            sprig-session--compose-btw nil))
    (pop-to-buffer buf)
    (message "%s%s%sC-c C-c to send, C-c C-k to cancel"
             (if plan "PLAN mode.  " "")
             (if queue "QUEUED: waits for the running turn to end.  " "")
             (if what (format "%s attached.  " what) ""))))

(defun sprig-session-message-plan ()
  "Compose a message and send it in plan mode (`c p')."
  (interactive)
  (sprig-session-message t))

(defun sprig-session-queue ()
  "Compose a message and send it once the running turn ends (`c q').
The counterpart to a plain `c c', which speaks into the turn straight
away: this leaves the turn alone to finish and speaks after, so a
follow-up that is not a correction does not derail work that is going
fine.  With no turn running there is nothing to wait for, so it just
sends.  An interrupt drops the queue."
  (interactive)
  (sprig-session-message nil t))

(defun sprig-session-drop-queue ()
  "Forget the messages queued with `c q', leaving the turn to run (`c Q').
The only way to take a queued message back: nothing has been sent, so
there is nothing to steer or interrupt.  `c i' does not do this, on
purpose (see `sprig--review-drop-queue')."
  (interactive)
  (sprig--review-drop-queue))

(declare-function sprig--btw-ask "sprig"
                  (id dir remote-host question context tail))
(declare-function sprig--events-preview "sprig" (events))
(declare-function sprig--directory "sprig" ())
(declare-function sprig--remote "sprig" ())

(defun sprig-session--btw-tail ()
  "Return a note about the in-flight turn for a side question, or nil.
A `--resume' fork sees the conversation only up to the last saved turn, so
when a turn is still streaming its text is added here from the live model.
This is what lets a side question asked mid-turn see what the agent is doing
now, the way the CLI's in-process `/btw' does."
  (when (and sprig-session--streaming sprig-session--events)
    (let* ((preview (sprig--events-preview (reverse sprig-session--events)))
           (reply (and preview (plist-get preview :reply))))
      (if (and reply (not (string-empty-p (string-trim reply))))
          (format "The agent is mid-turn right now, and this is not yet in the \
saved transcript.  Its latest output so far is:\n\n%s" reply)
        "The agent is mid-turn right now (nothing not yet saved has any prose \
to show)."))))

(defun sprig-session-btw ()
  "Compose a side question about this session, disturbing nothing (`c b').
Opens a compose buffer the way `c c' does; `C-c C-c' asks it.  A throwaway
one-shot then forks the session (so the question sees the whole
conversation), answers into `*sprig-btw*', and vanishes without writing a
log or touching the running turn.  Any marked sections ride along as
context, and a turn in flight adds its live text, so a mid-turn question
sees what the agent is doing now.  It is the session buffer's stand-in for
the CLI's own `/btw'."
  (interactive)
  (unless sprig--session-id
    (user-error "No session yet to ask about; send a message first"))
  (let ((review (current-buffer))
        (context (sprig--marked-context))
        (buf (get-buffer-create "*sprig-message*")))
    (with-current-buffer buf
      (sprig-session-compose-mode)
      (erase-buffer)
      (setq sprig-session--compose-target review
            sprig-session--compose-context context
            sprig-session--compose-mode nil
            sprig-session--compose-queue nil
            sprig-session--compose-btw t))
    (pop-to-buffer buf)
    (message "%sby the way: C-c C-c to ask, C-c C-k to cancel"
             (if context (format "%d section(s) attached.  "
                                 (length (sprig--marked-sections)))
               ""))))

(defun sprig-session-compose-send ()
  "Send the composed message (with any attached context) to the conversation."
  (interactive)
  (let* ((text (string-trim (buffer-substring-no-properties
                             (point-min) (point-max))))
         (review sprig-session--compose-target)
         (context sprig-session--compose-context)
         (mode sprig-session--compose-mode)
         (fmt sprig-session--compose-format)
         (queue sprig-session--compose-queue)
         (btw sprig-session--compose-btw))
    (when (string-empty-p text) (user-error "Empty message"))
    (unless (buffer-live-p review) (user-error "The session buffer is gone"))
    (if btw
        ;; A side question is its own throwaway process, so it never folds
        ;; into a turn: the whole composed text is the question, marked
        ;; sections ride as context, and a turn in flight adds its live tail.
        ;; The one-at-a-time guard is checked here, before `quit-window' kills
        ;; this buffer, so a refusal leaves the text to try again.
        (let (id dir remote tail)
          (when (process-live-p sprig--btw-process)
            (user-error
             "A side question is already running; wait for it to finish"))
          (with-current-buffer review
            (setq id sprig--session-id
                  dir (sprig--directory)
                  remote (sprig--remote)
                  tail (sprig-session--btw-tail)))
          (quit-window t)
          (sprig--btw-ask id dir remote text context tail))
      (let ((message (cond (fmt (funcall fmt text context))
                           (context (format "Regarding:\n\n%s\n\n%s" context text))
                           (t text))))
        ;; Send before quitting, never after: `quit-window' kills this buffer,
        ;; so a send that signals (a plan turn refused because one is already in
        ;; flight) would take the composed prose down with it, leaving an error
        ;; where the message used to be.  Signal first and the buffer survives,
        ;; still holding the text, to send again or save.
        (with-current-buffer review
          (cond (queue (sprig-session--queue message))
                (mode (sprig-session--send message mode))
                (t (sprig-session--steer message))))
        (quit-window t)))))

(defun sprig-session-compose-abort ()
  "Cancel the message compose."
  (interactive)
  (quit-window t)
  (message "sprig: message cancelled"))

;;;; Staging buffer (author an edit by hand, then apply)

(declare-function sprig--courier "sprig")
(defvar sprig--courier)

(defcustom sprig-courier-edits nil
  "How a hand-authored staging edit (`C-c C-c') reaches disk.
When nil (the default), the edit is sent to the agent directly: your
bytes ride in the instruction and the agent writes them with one Edit.
Simple and works in every permission mode, but the agent, generating the
write, could in principle alter a character, so eyeball the resulting
diff.

When non-nil, the edit is couriered instead: your bytes stay in Emacs and
are substituted into the agent's Edit at the permission prompt, so the
agent cannot change them (see `sprig--maybe-courier').  Stronger, but it
needs the edit to prompt, so it refuses the auto-approve modes
\(`acceptEdits', `bypassPermissions')."
  :type 'boolean
  :group 'sprig)

(defvar-local sprig-session--stage-target nil
  "Session buffer a staging buffer couriers its edit to.")
(defvar-local sprig-session--stage-file nil
  "Path of the file a staging buffer edits, as the change model records it.")
(defvar-local sprig-session--stage-anchor nil
  "The staged region's original text: the `old_string' the courier edit matches.")

(defun sprig-session--stage-hunk (section)
  "Return the hunk plist to stage from SECTION, or nil when there is none.
Point on a hunk gives that hunk; on a file change with a single hunk, that
hunk; a multi-hunk change is ambiguous, so it asks for a hunk.  Anywhere
else returns nil, the caller's cue to seed from a fresh `Read' instead."
  (pcase (and section (oref section type))
    ('sprig-hunk (oref section value))
    ('sprig-change
     (let ((hunks (plist-get (oref section value) :hunks)))
       (cond ((null hunks) (user-error "This change has no hunk to stage"))
             ((cdr hunks) (user-error "Point on a single hunk to stage it"))
             (t (car hunks)))))
    (_ nil)))

(defun sprig-session--open-stage-buffer (review file anchor)
  "Open the staging buffer for FILE, seeded with ANCHOR, couriering to REVIEW.
ANCHOR is the region's current text and the `old_string' the courier edit
will match; the buffer opens in FILE's own major mode but visits nothing,
so a stray save writes no file."
  (let ((buf (get-buffer-create "*sprig-stage*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert anchor)
      (let ((buffer-file-name file)) (set-auto-mode t))
      (setq buffer-file-name nil)
      (setq-local sprig-session--stage-target review
                  sprig-session--stage-file file
                  sprig-session--stage-anchor anchor)
      (use-local-map (copy-keymap (or (current-local-map) (make-sparse-keymap))))
      (local-set-key (kbd "C-c C-c") #'sprig-session-stage-apply)
      (local-set-key (kbd "C-c C-k") #'sprig-session-stage-abort)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "Edit %s, then C-c C-c to stage, C-c C-k to cancel"
             (file-name-nondirectory file))))

(defun sprig-session--stage-guard ()
  "Signal a `user-error' unless there is a live session to stage on.
Staging reads and applies over the session, so a dead one cannot serve it.
No mode switch is needed: the edit rides the ordinary channel, so `e' works
whatever posture you are in."
  (unless (and (boundp 'sprig--process) (process-live-p sprig--process))
    (user-error "No live session to stage on; send a message first")))

(defun sprig-session--request-seed (pending instruction reading)
  "Arrange to seed a staging buffer from a read the agent is about to run.
Records PENDING (see `sprig-session--pending-seed') as the seed to serve,
sends INSTRUCTION as a turn, and says READING; the next turn's `done' opens
the staging buffer from the `Read' result (see `sprig-session--seed-from-read')."
  (setq sprig-session--pending-seed pending)
  (sprig-session--send instruction)
  (message "sprig: %s to seed a staging buffer…" reading))

(defun sprig-session-stage-at-point ()
  "Stage the diff hunk at point, seeded straight from the model (`e e').
The region's current text is the post-image where the model has one, else
the pre-image: the best guess at what is on disk, and so the `old_string'
the couriered Edit must match."
  (interactive)
  (sprig-session--stage-guard)
  (let* ((section (magit-current-section))
         (hunk (or (sprig-session--stage-hunk section)
                   (user-error "Point is not on a hunk; try `e f' or `e s'")))
         (file (or (sprig--section-file section)
                   (user-error "No file at point to stage")))
         (lines (or (plist-get hunk :new) (plist-get hunk :old))))
    (sprig-session--open-stage-buffer
     (current-buffer) file (mapconcat #'identity lines "\n"))))

(defun sprig-session-stage-file (file &optional region)
  "Name a FILE (and optional REGION hint) for the agent to read, then stage it.
Asks the agent to `Read' the region and seeds the staging buffer from that
read when the turn ends, so you can edit a region the diff does not already
show.  REGION is free text (\"function foo\", \"lines 10-40\"); blank reads
the whole file (`e f')."
  (interactive
   (progn
     (sprig-session--stage-guard)
     (list (read-string "Stage which file: "
                        (sprig--section-file (magit-current-section)))
           (read-string "Region (blank = whole file): "))))
  (sprig-session--stage-guard)
  (let ((path (string-trim (or file "")))
        (hint (string-trim (or region ""))))
    (when (string-empty-p path) (user-error "No file to stage"))
    (sprig-session--request-seed
     (list :file path)
     (format "Read the file `%s'%s and return only that one Read, nothing else: \
no edits, no summary, no other tools. I am about to edit it by hand and Sprig \
seeds my staging buffer from your read."
             path (if (string-empty-p hint) "" (format " (just %s)" hint)))
     (format "reading %s" (file-name-nondirectory path)))))

(defun sprig-session-stage-suggested (&optional note)
  "Let the agent suggest what to put in the staging buffer, from context (`e s').
The agent already knows the task from the conversation, so it decides the
single most relevant file and region to edit next, reads exactly that, and
Sprig seeds the staging buffer from its read when the turn ends: the agent
scopes, you author.  NOTE, if you give one, nudges the choice; blank leans
wholly on the conversation so far.  This is the scoping front-end to staging,
for when you know the change but not yet where it lands."
  (interactive
   (progn (sprig-session--stage-guard)
          (list (read-string "Nudge (blank = use our conversation): "))))
  (sprig-session--stage-guard)
  (let ((note (string-trim (or note ""))))
    (sprig-session--request-seed
     (list :any t)
     (concat
      "Based on what we have been working on, decide the single most relevant \
file and the specific region within it for me to edit next by hand"
      (if (string-empty-p note) "" (format ", keeping in mind: %s" note))
      ". Then `Read' exactly that region and return only that one Read: no \
edits, no summary, no other tools. Sprig seeds my staging buffer from your \
read, so read the slice you would want me to be editing.")
     "asking the agent what to stage")))

(defun sprig-session--strip-read-numbers (text)
  "Reconstruct file content from a `Read' TEXT in cat -n form.
Each content line is `<spaces><n>\\t<content>'; keep the content after the
tab, drop any line without that shape (a wrapper note), and join with
newlines.  The result is the file's bytes as read, the courier anchor."
  (let (out)
    (dolist (line (split-string (or text "") "\n"))
      (when (string-match "\\`[ \t]*[0-9]+\t" line)
        (push (substring line (match-end 0)) out)))
    (mapconcat #'identity (nreverse out) "\n")))

(defun sprig-session--latest-read (model &optional file)
  "Return (FILE-PATH . TEXT) for the latest non-error `Read' in MODEL, or nil.
With FILE, restrict to reads whose basename matches it, so a repo-relative
request lines up with the agent's absolute path.  Without, take the most
recent read of any file, which is how an agent-suggested seed learns the
file the agent chose."
  (let ((base (and file (file-name-nondirectory file))) hit)
    (dolist (b (plist-get model :blocks))
      (let ((path (and (eq (plist-get b :type) 'tool)
                       (equal (plist-get b :name) "Read")
                       (not (plist-get (plist-get b :result) :error))
                       (alist-get 'file_path
                                  (sprig--parse-input
                                   (plist-get b :input))))))
        (when (and path (or (null base)
                            (equal base (file-name-nondirectory path))))
          (setq hit (cons path (plist-get (plist-get b :result) :text))))))
    hit))

(defun sprig-session--seed-from-read ()
  "Seed a staging buffer from the read a `sprig-session--pending-seed' asked for.
Called on a turn's `done': finds the relevant `Read' in the model (the named
file, or the latest read for an agent-suggested seed), reconstructs its bytes
as the anchor, and opens the staging buffer at the file the agent read.
Clears the pending seed either way, and reports when no usable read came back."
  (let* ((seed sprig-session--pending-seed)
         (hit (and seed (sprig-session--latest-read
                         (sprig-session--current-model) (plist-get seed :file)))))
    (setq sprig-session--pending-seed nil)
    (if (not hit)
        (message "sprig: no read came back; staging cancelled")
      (sprig-session--open-stage-buffer
       (current-buffer) (car hit)
       (sprig-session--strip-read-numbers (cdr hit))))))

(defun sprig-session-stage-apply ()
  "Send this buffer's hand-authored edit to the session to apply.
Sent to the agent directly, or couriered when `sprig-courier-edits' is
set (see that variable for the trade-off)."
  (interactive)
  (let ((review sprig-session--stage-target)
        (file sprig-session--stage-file)
        (anchor sprig-session--stage-anchor)
        (new (buffer-substring-no-properties (point-min) (point-max))))
    (unless (buffer-live-p review) (user-error "The session buffer is gone"))
    (when (equal new anchor) (user-error "Nothing changed; edit before staging"))
    (with-current-buffer review
      (unless (and (boundp 'sprig--process) (process-live-p sprig--process))
        (user-error "No live session to send to; send a message first"))
      (if sprig-courier-edits
          (sprig-session--stage-courier file anchor new)
        (sprig-session--stage-direct file anchor new)))
    (quit-window t)
    (message "sprig: sent your edit to %s to apply" (file-name-nondirectory file))))

(defun sprig-session--stage-direct (file anchor new)
  "Ask the agent to apply a hand-authored edit of FILE directly.
ANCHOR is the region's original text and NEW your edited version; both
ride in the instruction so the agent writes them with one Edit, in any
permission mode.  The agent generates the write, so it could drift from
NEW: the resulting diff is the check.  Run in the session buffer."
  (sprig-session--send
   (format "I have hand-authored an edit to `%s' and want it applied exactly \
as written.  With a single Edit on that file, replace this block verbatim:

```
%s
```

with this block verbatim:

```
%s
```

Reproduce my text character for character: do not reformat, re-indent, \
correct, or improve any of it.  Make only this one edit and nothing else."
           file anchor new)))

(defun sprig-session--stage-courier (file anchor new)
  "Stage a hand-authored edit of FILE for the tamper-proof courier apply.
Records NEW (over ANCHOR) in `sprig--courier' so the permission gate can
substitute your exact bytes into the agent's Edit (see
`sprig--maybe-courier'), and asks the agent to make that one write.  Needs
the edit to prompt, so it refuses the auto-approve modes.  Run in the
session buffer."
  (when (member sprig--permission-mode '("acceptEdits" "bypassPermissions"))
    (user-error
     "This session auto-approves edits (%s); the courier needs them to \
prompt, so change the mode with `P' first, or unset `sprig-courier-edits'"
     sprig--permission-mode))
  (push (list :file file :old anchor :new new) sprig--courier)
  (sprig-session--send
   (format "I have authored an edit to `%s' by hand and staged it in Sprig. \
Call the Edit tool on that file once now to apply it: your `old_string' and \
`new_string' arguments are placeholders, because Sprig replaces them with the \
exact staged bytes through the permission channel. This one write is \
authorised; make only this single Edit and nothing else." file)))

(defun sprig-session-stage-abort ()
  "Discard the staging buffer without sending the edit."
  (interactive)
  (quit-window t)
  (message "sprig: staging cancelled"))

;;;; Answering: the verbs, and the buffer they open

(defvar-local sprig-answer--review nil
  "Session buffer whose question this answer buffer is answering.")
(defvar-local sprig-answer--dialog nil
  "The dialog block being answered.")
(defvar-local sprig-answer--index 0
  "Which of the dialog's questions is on screen.")
(defvar-local sprig-answer--answers nil
  "Answers settled so far, an alist of question symbol to label string.")
(defvar-local sprig-answer--picked nil
  "Labels picked so far for the question on screen (multi-select).")

(defun sprig-session--pending-dialog ()
  "Return this buffer's question waiting on an answer, or signal there is none."
  (or (sprig-session-pending-dialog (sprig-session--current-model))
      (user-error "No question is waiting")))

(defun sprig-session--answer-plan (dialog answers)
  "Approve or reject DIALOG's plan, per ANSWERS.
Rejecting outright reads the feedback the agent plans again against;
reading it here is safe where reading it in the filter was not, this
being a command of yours rather than the middle of the CLI's output.
Skipping (no ANSWERS at all) rejects without asking for any."
  (let ((id (plist-get dialog :id)))
    (cond
     ((equal (cdar answers) "Approve")
      (sprig--review-approve-plan id)
      (message "sprig: plan approved; the agent starts work"))
     (answers
      (let ((feedback (read-string "Reject plan; what should change? ")))
        (sprig--review-reject-plan id feedback)
        (message "sprig: plan rejected; the agent plans again")))
     (t (sprig--review-reject-plan id "")
        (message "sprig: plan rejected")))))

(defun sprig-session--answer-permission (dialog answers)
  "Allow or deny DIALOG's tool call, per ANSWERS.
Anything but an outright allow denies, skipping included: the call has to
be answered, and no is the answer that cannot do damage."
  (let ((id (plist-get dialog :id)))
    (if (equal (cdar answers) "Allow")
        (progn (sprig--review-allow-tool id)
               (message "sprig: allowed"))
      (sprig--review-deny-tool id)
      (message "sprig: denied; the agent is told no and goes on"))))

(defun sprig-session--answer-dialog (dialog answers)
  "Answer DIALOG with ANSWERS, and say so.
A plan and a permission are not answered with a map of answers, but by
approving or allowing, so each goes its own way from here."
  (pcase (plist-get dialog :kind)
    ("exit_plan_mode" (sprig-session--answer-plan dialog answers))
    ("can_use_tool" (sprig-session--answer-permission dialog answers))
    (_ (sprig--review-answer-dialog (plist-get dialog :id)
                                    (plist-get dialog :input)
                                    answers)
       (message "sprig: %s" (if answers
                                (format "answered (%d)" (length answers))
                              "skipped; the agent goes on unanswered")))))

;;;###autoload
(defun sprig-session-answer ()
  "Answer the waiting question, one question at a time, in its own buffer."
  (interactive)
  (let ((dialog (sprig-session--pending-dialog))
        (review (current-buffer))
        (buffer (get-buffer-create "*sprig-answer*")))
    (with-current-buffer buffer
      (sprig-answer-mode)
      (setq sprig-answer--review review
            sprig-answer--dialog dialog
            sprig-answer--index 0
            sprig-answer--answers nil
            sprig-answer--picked nil)
      (sprig-answer--render))
    (pop-to-buffer buffer)))

(defun sprig-session-answer-recommended ()
  "Answer every waiting question with the option it recommends.
The tool marks its recommended option and puts it first, so a question
recommending nothing takes its first option (see
`sprig-session--recommended-option').  A permission recommends nothing, and
will not be talked into it: one keypress allowing an unread call is the
wrong thing to make easy."
  (interactive)
  (let* ((dialog (sprig-session--pending-dialog))
         (_ (when (equal (plist-get dialog :kind) "can_use_tool")
              (user-error "Nothing is recommended here: a permission is yours to give")))
         (answers (mapcar (lambda (question)
                            (cons (intern (alist-get 'question question))
                                  (sprig-session--recommended-option question)))
                          (sprig-session--dialog-questions dialog))))
    (sprig-session--answer-dialog dialog (delq nil answers))))

(defun sprig-session-answer-skip ()
  "Skip the waiting question; the agent goes on without an answer."
  (interactive)
  (sprig-session--answer-dialog (sprig-session--pending-dialog) nil))

(transient-define-prefix sprig-session-answer-dispatch ()
  "Answer the question the agent is waiting on."
  [["Answer"
    ("a" "answer, one question at a time" sprig-session-answer)
    ("r" "take every recommended option" sprig-session-answer-recommended)
    ("s" "skip; go on unanswered" sprig-session-answer-skip)]])

;;;; Answering: the a transient, and its buffer
;;
;; The session buffer shows the question and stays a session buffer; the
;; answering happens in a buffer of its own, the way `c c' composes in one,
;; one question at a time so a four-question dialog is four small choices
;; rather than one wall.  `a r' skips the buffer entirely for the common
;; case of going with what was recommended.

(defvar sprig-answer-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'sprig-answer-pick)
    (define-key map (kbd "SPC") #'sprig-answer-pick)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    (define-key map (kbd "o")   #'sprig-answer-other)
    (define-key map (kbd "C-c C-c") #'sprig-answer-confirm)
    (define-key map (kbd "C-c C-k") #'sprig-answer-cancel)
    (dotimes (i 9)
      (define-key map (kbd (number-to-string (1+ i))) #'sprig-answer-pick-number))
    map)
  "Keymap for `sprig-answer-mode'.")

(define-derived-mode sprig-answer-mode special-mode "Sprig-Answer"
  "Answer one of the agent's questions.
\\<sprig-answer-mode-map>\\[sprig-answer-pick] picks the option at point, \
1-9 picks by number.
\\[sprig-answer-other] types an answer of your own; \\[sprig-answer-cancel] \
cancels."
  (setq-local truncate-lines nil))

(defun sprig-answer--question ()
  "Return the question on screen."
  (nth sprig-answer--index (sprig-session--dialog-questions sprig-answer--dialog)))

(defun sprig-answer--options ()
  "Return the options of the question on screen, as a list."
  (append (alist-get 'options (sprig-answer--question)) nil))

(defun sprig-answer--render ()
  "Draw the question on screen, and what has been picked of it."
  (let* ((question (sprig-answer--question))
         (questions (sprig-session--dialog-questions sprig-answer--dialog))
         (multi (sprig-session--multi-select-p question))
         (inhibit-read-only t))
    (erase-buffer)
    (when (> (length questions) 1)
      (insert (propertize (format "Question %d of %d\n\n"
                                  (1+ sprig-answer--index) (length questions))
                          'face 'sprig-session-meta-key)))
    (insert (propertize (concat "? " (alist-get 'question question))
                        'face 'sprig-session-dialog)
            (if multi (propertize "  (pick any)" 'face 'sprig-session-meta-key) "")
            "\n\n")
    (seq-do-indexed
     (lambda (option index)
       (let* ((label (sprig-session--option-label option))
              (picked (member label sprig-answer--picked)))
         (insert (propertize (format "%s%d  " (if picked "▸" " ") (1+ index))
                            'face (if picked 'sprig-session-dialog-picked
                                    'sprig-session-meta-key))
                 (propertize label 'face (if picked 'sprig-session-dialog-picked
                                           'default))
                 "\n")
         (when-let ((description (alist-get 'description option)))
           (unless (string-empty-p description)
             (insert (propertize (concat "     " description "\n")
                                 'face 'sprig-session-meta-key))))))
     (sprig-answer--options))
    ;; A typed answer (o) that is not one of the offered labels is picked
    ;; too, so a multi-select shows it alongside the options it joins.
    (dolist (custom (sprig-answer--custom-picks))
      (insert (propertize "▸    " 'face 'sprig-session-dialog-picked)
              (propertize custom 'face 'sprig-session-dialog-picked)
              (propertize "  (your answer)" 'face 'sprig-session-meta-key)
              "\n"))
    (insert "\n"
            (propertize (if multi
                            "RET or 1-9 toggles · o adds your own · C-c C-c takes them · C-c C-k skips"
                          "RET or 1-9 picks · o types your own · C-c C-c skips this one · C-c C-k skips all")
                        'face 'sprig-session-meta-key)
            "\n")
    (goto-char (point-min))))

(defun sprig-answer--settle (label)
  "Settle the question on screen with LABEL, or with nothing when nil."
  (let ((text (alist-get 'question (sprig-answer--question))))
    (when label
      (push (cons (intern text) label) sprig-answer--answers)))
  (setq sprig-answer--picked nil)
  (if (< (1+ sprig-answer--index)
         (length (sprig-session--dialog-questions sprig-answer--dialog)))
      (progn (setq sprig-answer--index (1+ sprig-answer--index))
             (sprig-answer--render))
    (sprig-answer--send)))

(defun sprig-answer--send ()
  "Send what was answered back to the agent, and be done."
  (let ((review sprig-answer--review)
        (dialog sprig-answer--dialog)
        (answers (nreverse sprig-answer--answers)))
    (quit-window t)
    (if (buffer-live-p review)
        (with-current-buffer review
          (sprig-session--answer-dialog dialog answers))
      (message "sprig: the session buffer is gone; the question went unanswered"))))

(defun sprig-answer-pick ()
  "Pick the option at point."
  (interactive)
  (let* ((line (- (line-number-at-pos) 1))
         (options (sprig-answer--options))
         (label (seq-some (lambda (option)
                            (let ((l (sprig-session--option-label option)))
                              (and (save-excursion
                                     (beginning-of-line)
                                     (looking-at-p (format ".*%s"
                                                           (regexp-quote l))))
                                   l)))
                          options)))
    (ignore line)
    (unless label (user-error "No option on this line"))
    (sprig-answer--take label)))

(defun sprig-answer-pick-number ()
  "Pick the option whose number is the key just pressed."
  (interactive)
  (let* ((n (- last-command-event ?1))
         (option (nth n (sprig-answer--options))))
    (unless option (user-error "No option %d here" (1+ n)))
    (sprig-answer--take (sprig-session--option-label option))))

(defun sprig-answer--take (label)
  "Take LABEL for the question on screen: toggling it, or settling on it."
  (if (sprig-session--multi-select-p (sprig-answer--question))
      (progn
        (setq sprig-answer--picked
              (if (member label sprig-answer--picked)
                  (remove label sprig-answer--picked)
                (append sprig-answer--picked (list label))))
        (sprig-answer--render))
    (sprig-answer--settle label)))

(defun sprig-answer--custom-picks ()
  "Return the picked answers that are not one of the offered options."
  (let ((labels (mapcar #'sprig-session--option-label (sprig-answer--options))))
    (seq-remove (lambda (pick) (member pick labels)) sprig-answer--picked)))

(defun sprig-answer-other ()
  "Answer the question on screen with text of your own.
The tool always allows an answer outside the offered options; this types
one.  A single-select question settles on it at once; a multi-select adds
it to whatever is already picked, to take with \\<sprig-answer-mode-map>\
\\[sprig-answer-confirm]."
  (interactive)
  (let ((text (string-trim (read-string "Your answer: "))))
    (when (string-empty-p text)
      (user-error "No answer typed"))
    (sprig-answer--take text)))

(defun sprig-answer-confirm ()
  "Take what is picked for this question, or skip it when nothing is."
  (interactive)
  (sprig-answer--settle (and sprig-answer--picked
                             (string-join sprig-answer--picked ", "))))

(defun sprig-answer-cancel ()
  "Skip the rest of the questions; the agent goes on without an answer."
  (interactive)
  (setq sprig-answer--picked nil)
  (setq sprig-answer--index
        (length (sprig-session--dialog-questions sprig-answer--dialog)))
  (sprig-answer--send))

;;;; The c transient

(transient-define-prefix sprig-session-dispatch ()
  "Steer the conversation from the session buffer."
  [["Message"
    ("c" "compose & send (steers a running turn)" sprig-session-message)
    ("q" "compose & queue (after this turn)" sprig-session-queue)
    ("Q" "drop the queued messages" sprig-session-drop-queue)
    ("y" "yes / accept" sprig-session-accept)
    ("n" "no / decline" sprig-session-decline)
    ("p" "compose in plan mode" sprig-session-message-plan)
    ("r" "independent review of the changes (subagent)" sprig-session-independent-review)
    ("l" "resend last turn" sprig-session-retry)
    ("i" "interrupt turn (any queued message then goes)" sprig-session-interrupt)
    ("z" "compact context" sprig-session-compact)
    ("b" "by the way: side question (writes no log)" sprig-session-btw)]
   ["Changes (agent instructions)"
    ("k" "reject / undo (or unstage a floated message)" sprig-session-reject)
    ("C" "commit" sprig-session-commit)
    ("x" "run command / fenced block" sprig-session-run)]])

(defun sprig-session--set-mode (mode)
  "Switch this session's permission MODE, which must be live to be told.
The mode is a session-level setting the CLI tracks and reports back, so
there has to be a running session to set it on; it takes hold from the next
turn, and sent mid-turn, from the agent's next tool-call boundary."
  (unless (and (boundp 'sprig--process) (process-live-p sprig--process))
    (user-error "No live session to set the mode on; send a message first"))
  (sprig--set-permission-mode mode)
  (message "sprig: permission mode is now %s" mode))

(defun sprig-session-plan-mode ()
  "Put the session into plan mode (`P p'): the agent plans, makes no edits.
Sticky, like Claude Code's own: it stays until you leave it, whether by
approving a plan or with another `P', so a follow-up carries on planning
rather than dropping out."
  (interactive)
  (sprig-session--set-mode "plan"))

(defun sprig-session-auto-mode ()
  "Put the session into auto mode (`P a'): the CLI's normal working mode.
What the shift-tab cycle calls \"auto mode\": allowed tools run, the rest
prompt.  It is where a session sits when it is not in one of the others."
  (interactive)
  (sprig-session--set-mode "auto"))

(defun sprig-session-accept-edits-mode ()
  "Put the session into accept-edits mode (`P e'): file edits auto-approve."
  (interactive)
  (sprig-session--set-mode "acceptEdits"))

(defun sprig-session-manual-mode ()
  "Put the session into manual mode (`P m'): every tool call prompts."
  (interactive)
  (sprig-session--set-mode "manual"))

(defun sprig-session-bypass-mode ()
  "Put the session into bypass mode (`P b'): every tool call auto-approves.
The unguarded mode: file edits and shell commands run with no prompt at
all, so reach for it only where that is genuinely what you want."
  (interactive)
  (sprig-session--set-mode "bypassPermissions"))

(transient-define-prefix sprig-session-permission-mode ()
  "Set the session's permission mode (`P').
The mode is sticky: it holds until you change it here or the agent leaves
plan mode on an approved plan.  This is how you enter or leave plan mode by
hand, since a plain send no longer drops out of it on its own.  The keys
name the CLI's own modes, the ones the shift-tab cycle steps through."
  [["Permission mode"
    ("p" "plan (agent plans, makes no edits)" sprig-session-plan-mode)
    ("a" "auto (normal: allowed tools run, rest prompt)" sprig-session-auto-mode)
    ("e" "accept edits (auto-approve file edits)" sprig-session-accept-edits-mode)
    ("m" "manual (prompt for every tool call)" sprig-session-manual-mode)
    ("b" "bypass (auto-approve everything, incl. shell)" sprig-session-bypass-mode)]])

(transient-define-prefix sprig-session-stage-dispatch ()
  "Open a staging buffer to author an edit by hand (`e').
You edit the seeded buffer, then `C-c C-c' sends it to the agent to apply
\(or couriers it when `sprig-courier-edits' is set); `C-c C-k' cancels.  No
mode switch first.  The routes differ only in how the buffer is seeded: from
the hunk you are on, from a file you name, or from what the agent suggests."
  [["Stage an edit"
    ("e" "the hunk at point" sprig-session-stage-at-point)
    ("f" "a file / region you name (agent reads it)" sprig-session-stage-file)
    ("s" "let the agent suggest what to edit" sprig-session-stage-suggested)]])

(transient-define-prefix sprig-session-start-dispatch ()
  "Start or fork a session from the session buffer.
`c' steers the conversation this buffer already owns; `s' is where a
session of its own begins.  `s c' / `s p' start one and drop you straight
into its first-message prompt (plan mode for `s p')."
  [["Session"
    ("n" "new conversation" sprig-session-new)
    ("c" "new, then compose the first message" sprig-session-new-message)
    ("p" "new, then compose in plan mode" sprig-session-new-message-plan)
    ("f" "fork this session" sprig-session-fork)]])

;;;; Verb keybindings

(define-key sprig-session-mode-map (kbd "SPC") #'sprig-toggle-mark)
(define-key sprig-session-mode-map (kbd "m")   #'sprig-toggle-mark)
(define-key sprig-session-mode-map (kbd "U")   #'sprig-unmark-all)
(define-key sprig-session-mode-map (kbd "c")   #'sprig-session-dispatch)
(define-key sprig-session-mode-map (kbd "s")   #'sprig-session-start-dispatch)
(define-key sprig-session-mode-map (kbd "P")   #'sprig-session-permission-mode)
(define-key sprig-session-mode-map (kbd "e")   #'sprig-session-stage-dispatch)
(define-key sprig-session-mode-map (kbd "k")   #'sprig-session-reject)
;; `a' answers the agent's structured dialog; the yes/no reply to a plain
;; prose question is `c y' / `c n' (not top-level: `n' is section motion).
;; Commit is `C'.
(define-key sprig-session-mode-map (kbd "a")   #'sprig-session-answer-dispatch)
(define-key sprig-session-mode-map (kbd "C")   #'sprig-session-commit)
(define-key sprig-session-mode-map (kbd "x")   #'sprig-session-run)
(define-key sprig-session-mode-map (kbd "d")   #'sprig-session-review-dispatch)
(define-key sprig-session-mode-map (kbd "RET") #'sprig-session-visit)
(define-key sprig-session-mode-map (kbd "t")   #'sprig-session-set-title)
(define-key sprig-session-mode-map (kbd "T")   #'sprig-session-title-dispatch)

;;;; Renamed faces
;;
;; The transcript's own faces, renamed with the mode in 0.51.0.  Aliased for
;; the same reason the options above are: a theme naming a face that no
;; longer exists fails silently.

(define-obsolete-face-alias 'sprig-review-tool
  'sprig-session-tool "0.51.0")
(define-obsolete-face-alias 'sprig-review-todo-done
  'sprig-session-todo-done "0.51.0")
(define-obsolete-face-alias 'sprig-review-todo-active
  'sprig-session-todo-active "0.51.0")
(define-obsolete-face-alias 'sprig-review-todo-pending
  'sprig-session-todo-pending "0.51.0")
(define-obsolete-face-alias 'sprig-review-user
  'sprig-session-user "0.51.0")
(define-obsolete-face-alias 'sprig-review-user-highlight
  'sprig-session-user-highlight "0.51.0")
(define-obsolete-face-alias 'sprig-review-thinking
  'sprig-session-thinking "0.51.0")
(define-obsolete-face-alias 'sprig-review-meta-key
  'sprig-session-meta-key "0.51.0")
(define-obsolete-face-alias 'sprig-review-time
  'sprig-session-time "0.51.0")
(define-obsolete-face-alias 'sprig-review-working
  'sprig-session-working "0.51.0")
(define-obsolete-face-alias 'sprig-review-pending
  'sprig-session-pending "0.51.0")
(define-obsolete-face-alias 'sprig-review-queued
  'sprig-session-queued "0.51.0")
(define-obsolete-face-alias 'sprig-review-plan
  'sprig-session-plan "0.51.0")
(define-obsolete-face-alias 'sprig-review-context
  'sprig-session-context "0.51.0")
(define-obsolete-face-alias 'sprig-review-context-large
  'sprig-session-context-large "0.51.0")
(define-obsolete-face-alias 'sprig-review-context-huge
  'sprig-session-context-huge "0.51.0")
(define-obsolete-face-alias 'sprig-review-done
  'sprig-session-done "0.51.0")
(define-obsolete-face-alias 'sprig-review-failed
  'sprig-session-failed "0.51.0")
(define-obsolete-face-alias 'sprig-review-idle
  'sprig-session-idle "0.51.0")
(define-obsolete-face-alias 'sprig-review-waiting
  'sprig-session-waiting "0.51.0")
(define-obsolete-face-alias 'sprig-review-dialog
  'sprig-session-dialog "0.51.0")
(define-obsolete-face-alias 'sprig-review-dialog-picked
  'sprig-session-dialog-picked "0.51.0")


;;;; Renamed diff buffer
;;
;; The `d' buffer was `sprig-diff-mode', a read-only view of the working
;; tree.  In 0.51.0 it grew draft line comments and became the changeset
;; review (sprig-review.el); the old names still reach it.

(define-obsolete-function-alias 'sprig-session-diff
  'sprig-session-review "0.51.0")
;; `c r' was `sprig-review-review'; renaming the transcript would have
;; collided it with the changeset review's own entry point, so it is named
;; for what it does instead.
(define-obsolete-function-alias 'sprig-review-review
  'sprig-session-independent-review "0.51.0")
(define-obsolete-function-alias 'sprig-diff-mode
  'sprig-review-mode "0.51.0")
(define-obsolete-variable-alias 'sprig-diff-base
  'sprig-review-base "0.51.0")

(provide 'sprig-session-mode)
;;; sprig-session-mode.el ends here
