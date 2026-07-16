;;; sprig-review-mode.el --- Read-only review buffer for sprig -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.12.0
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The read-only, Magit-like review buffer (see DESIGN.md, "Current
;; direction: the review buffer").  It projects a review model built by
;; `sprig-review-build' into `magit-section' rows: a metadata header,
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
;; (sprig-review.el) needs no magit-section; the tests for this renderer
;; live in sprig-review-mode-tests.el and load magit-section, so they run
;; separately from the process-free suite.

;;; Code:

(require 'magit-section)
(require 'diff-mode)                     ; for the diff-* faces
(require 'iso8601)                       ; for the log's own timestamps
(require 'sprig-review)
(require 'subr-x)
(require 'eieio)
(require 'transient)
(require 'seq)

(declare-function sprig--review-deliver "sprig" (text &optional mode))
(declare-function sprig--review-steer "sprig" (text))
(declare-function sprig--review-answer-dialog "sprig" (id input answers))
(declare-function sprig--review-approve-plan "sprig" (id))
(declare-function sprig--review-reject-plan "sprig" (id feedback))
(declare-function sprig--review-allow-tool "sprig" (id))
(declare-function sprig--review-deny-tool "sprig" (id))
(declare-function sprig--review-interrupt-owned "sprig" ())
(declare-function sprig--mode-line-permission "sprig" ())
(declare-function sprig--session-log-lines "sprig" ())
;; Transport state, defined in sprig.el; a session-owning review buffer
;; carries these buffer-locally, so silence the byte-compiler here.
(defvar sprig--process)
(defvar sprig--sink)
(defvar sprig--busy)

;;;; Faces

(defface sprig-review-tool '((t :inherit font-lock-keyword-face :weight bold))
  "Face for a tool-call heading in the review buffer."
  :group 'sprig)

(defface sprig-review-file '((t :inherit diff-file-header))
  "Face for a changed file's path."
  :group 'sprig)

(defface sprig-review-added '((t :inherit diff-added))
  "Face for an added line in a reconstructed hunk."
  :group 'sprig)

(defface sprig-review-removed '((t :inherit diff-removed))
  "Face for a removed line in a reconstructed hunk."
  :group 'sprig)

(defface sprig-review-stat-added '((t :inherit success :weight normal))
  "Face for the added-line count in a tool heading.
Foreground only, unlike `sprig-review-added': a count sits in a heading,
where the diff faces' backgrounds would be a stripe across it."
  :group 'sprig)

(defface sprig-review-stat-removed '((t :inherit error :weight normal))
  "Face for the removed-line count in a tool heading."
  :group 'sprig)

(defface sprig-review-user
  '((((class color) (background light)) :background "#eaeef8" :extend t)
    (((class color) (background dark))  :background "#2b3040" :extend t)
    (t :inherit region :extend t))
  "Face for a user turn's prose: the tint that marks it as yours.
This is the only thing telling a user turn from the agent's output, so it
carries no label; tinted is you, untinted is the agent.  Applied beneath
any markdown faces, so the prose keeps its own styling on top.  `:extend'
runs the tint to the window edge."
  :group 'sprig)

(defface sprig-review-user-highlight
  '((((class color) (background light)) :background "#ccd8f0" :extend t)
    (((class color) (background dark))  :background "#3c465e" :extend t)
    (t :inherit magit-section-highlight :extend t))
  "Face for the user turn under point.
A stronger take on `sprig-review-user', rather than the shared
`magit-section-highlight' every other section gets, so the turn under
point still reads as yours instead of losing its tint to the cursor."
  :group 'sprig)

(defface sprig-review-thinking '((t :inherit shadow :slant italic))
  "Face for a thinking-block label."
  :group 'sprig)

(defface sprig-review-meta-key '((t :inherit font-lock-comment-face))
  "Face for a metadata key in the header."
  :group 'sprig)

(defface sprig-review-time '((t :inherit font-lock-comment-face))
  "Face for a block's timestamp in the left margin."
  :group 'sprig)

(defface sprig-review-working
  '((t :inherit warning :inverse-video t :weight bold :extend t))
  "Face for the state line while a turn is in flight."
  :group 'sprig)

(defface sprig-review-pending
  '((t :inherit warning :weight bold :extend t))
  "Face for the state line after a message is sent, before the agent replies.
Softer than `sprig-review-working' (no inverse video): the turn is on its
way but nothing has come back yet."
  :group 'sprig)

(defface sprig-review-done
  '((t :inherit success :inverse-video t :weight bold :extend t))
  "Face for the state line once a turn has landed."
  :group 'sprig)

(defface sprig-review-failed
  '((t :inherit error :inverse-video t :weight bold :extend t))
  "Face for the state line when a turn ended badly."
  :group 'sprig)

(defface sprig-review-idle '((t :inherit shadow :extend t))
  "Face for the state line of a conversation with nothing running."
  :group 'sprig)

(defface sprig-review-waiting
  '((t :inherit warning :inverse-video t :weight bold :extend t))
  "Face for the state line while a question waits on you."
  :group 'sprig)

(defface sprig-review-dialog '((t :inherit font-lock-builtin-face :weight bold))
  "Face for a question the agent is waiting on."
  :group 'sprig)

(defface sprig-review-dialog-picked '((t :inherit success :weight bold))
  "Face for an option picked in a question."
  :group 'sprig)

(defface sprig-review-marked '((t :inherit highlight))
  "Face for the heading of a marked section."
  :group 'sprig)

;;;; Buffer-local state

(defvar-local sprig-review--events nil
  "Transport events consumed by this review buffer, most recent first.")
(defvar-local sprig-review--meta nil
  "Display-metadata plist feeding this review buffer's header.")
(defvar-local sprig-review--dirty nil
  "Non-nil when events have arrived since the last render.")
(defvar-local sprig-review--timer nil
  "Pending coalescing-refresh timer for this buffer, or nil.")
(defvar-local sprig-review--tail nil
  "Marker where streamed text is appended in place, or nil.
`sprig-review-render' sets it to the end of the last text section when a
turn is streaming into this buffer, so consecutive `text' events extend
that section without a full re-render.  Any structural event clears it.")

(defvar-local sprig-review--streaming nil
  "Non-nil while a turn is streaming into this buffer.
Two things hang off it.  The last text block opens as the live tail only
while it is set, which costs that block its markdown fontification (see
`sprig-review--insert-text'); and the header line says the buffer is
working only while it is set (see `sprig-review--state').  A settled
or replayed conversation is not streaming, so it renders fontified, and
says so.

Liveness cannot be read off the model instead: a replayed session log
carries no `done' event, so its last block would pass for a live tail
forever, and a conversation read from disk would claim to be working.")
(defvar-local sprig-review--marks nil
  "Idents (per `magit-section-ident') of the marked sections.
Idents rather than section objects, so marks survive a re-render.")
(defvar-local sprig-review--remote nil
  "SSH destination of the session host, or nil for local.
Set by `sprig-review-set-remote' so visiting a file reaches it over TRAMP.")
(defvar-local sprig-review--file nil
  "Session-log file this buffer was opened from, or nil.
Set by `sprig-review-open-file', so a refresh re-reads that file; a buffer
that owns a session leaves this nil and finds its log by session id.")

;;;; Options

(defcustom sprig-review-heading-max-width 80
  "Maximum width of a tool-call heading before it is truncated with an ellipsis.
Keeps a long `Bash' command or file path on a single line; the full text
is one TAB away, since the tool section folds to its heading."
  :type 'integer
  :group 'sprig)

(defcustom sprig-review-expand-diffs nil
  "When non-nil, a tool call that reconstructs a diff renders expanded.
By default every tool section folds to its one-line heading, so a long
turn reads as a list of what the agent did rather than as pages of diff;
TAB opens the one you want to review."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-review-timestamp-format "%H:%M"
  "Time format for the left-margin timestamp against each block.
A `format-time-string' format, rendered in local time.  nil shows no
timestamps, narrowing the margin to the running bar alone.  Widen it (say
\"%m-%d %H:%M\") to date a conversation spanning days; the margin sizes
itself to fit.

Replayed history is dated from the session log's own record timestamps;
a live turn is dated when its first event reaches the buffer."
  :type '(choice (const :tag "No timestamps" nil) string)
  :group 'sprig)

(defcustom sprig-review-fontify-markdown t
  "When non-nil, render user and assistant prose with `markdown-mode' faces.
Markup characters (`*', `#', ...) are hidden.  Has no effect when
`markdown-mode' is not installed."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-context-window-tokens 200000
  "Baseline context-window size, in tokens, for the header's Context %.
The standard Claude window is 200000.  The CLI does not report the true
window, and a long-context (1M) session cannot be told from its model id,
so a turn that uses more than this baseline auto-widens the denominator to
the smallest tier in `sprig-context-window-tiers' that contains it: the
percentage never runs past 100.  Set this to the real window to pin it."
  :type 'integer
  :group 'sprig)

(defcustom sprig-context-window-tiers '(200000 1000000)
  "Known context-window sizes, ascending, that the header % auto-fits to.
When a turn's context exceeds `sprig-context-window-tokens', the smallest
tier here that still contains it becomes the denominator, so a 1M session
reads against 1M rather than overflowing a 200k baseline."
  :type '(repeat integer)
  :group 'sprig)

;;;; Face helpers
;;
;; Everything rendered here carries its colours as `font-lock-face', not
;; `face'.  `magit-section-mode' deliberately turns font-lock on (with no
;; keywords) so that `font-lock-face' is honoured, and font-lock's
;; unfontify pass strips the plain `face' property off every region it
;; redisplays (see `font-lock-default-unfontify-region').  Text propertized
;; with `face' therefore loses its colours the moment the window scrolls
;; over it; `font-lock-face' survives and displays identically.

(defun sprig-review--face (string face)
  "Return STRING carrying FACE, as a property the buffer's font-lock keeps."
  (propertize string 'font-lock-face face))

(defun sprig-review--add-face (beg end face)
  "Add FACE beneath the faces already on the buffer text between BEG and END.
Appending rather than replacing leaves a foreground set by, say, markdown
fontification in front of FACE's background."
  (let ((pos beg))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'font-lock-face nil end))
            (val (get-text-property pos 'font-lock-face)))
        (put-text-property pos next 'font-lock-face
                           (append (ensure-list val) (list face)))
        (setq pos next)))))

(defun sprig-review--adopt-faces (string)
  "Return STRING with each `face' property moved over to `font-lock-face'.
Font-lock fontifies with `face', so a string fontified elsewhere (see
`sprig-review--fontify-markdown') needs this before it is inserted here."
  (let ((pos 0) (end (length string)))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'face string end))
            (val (get-text-property pos 'face string)))
        (when val
          (put-text-property pos next 'font-lock-face val string)
          (remove-list-of-text-properties pos next '(face) string))
        (setq pos next)))
    string))

;;;; Timestamp margin
;;
;; A block's time shows in the left margin, the way magit-log shows a
;; commit's date: it dates every row without spending a column of the
;; prose itself, and it cannot be confused for something the agent said.
;; The stamp rides on an overlay's `before-string', so it stays out of the
;; buffer text, and out of the way of the verbs that read that text.

(defun sprig-review--time-string (iso)
  "Return ISO, an ISO 8601 stamp, formatted per `sprig-review-timestamp-format'.
Returns nil when timestamps are off, or when ISO is missing or unparsable
\(a hand-edited log, or a record shape we have not seen), since a block
with no time is worth more than a render that dies over one."
  (when (and sprig-review-timestamp-format (stringp iso))
    (ignore-errors
      (format-time-string sprig-review-timestamp-format
                          (encode-time (iso8601-parse iso))))))

(defun sprig-review--stamp-width ()
  "Return the columns a timestamp needs, or 0 when they are off."
  (if sprig-review-timestamp-format
      ;; Formatted now, purely to measure the format; every stamp it makes
      ;; is the same width, bar a format holding a variable-width field.
      (string-width (format-time-string sprig-review-timestamp-format))
    0))

(defun sprig-review--margin-width ()
  "Return the columns the timestamp margin needs, or 0 when it is off.
The extra column is the gap holding the stamp off the text."
  (let ((width (sprig-review--stamp-width)))
    (if (> width 0) (1+ width) 0)))

(defun sprig-review--update-margin ()
  "Size the left margin of every window showing this buffer to fit a stamp.
`left-margin-width' alone only reaches a window on the next
`set-window-buffer', so the live windows are set too, and a change to
`sprig-review-timestamp-format' shows on the next render."
  (setq left-margin-width (sprig-review--margin-width))
  (dolist (win (get-buffer-window-list nil nil t))
    (set-window-margins win left-margin-width right-margin-width)))

(defun sprig-review--insert-margin (pos iso)
  "Show ISO's time in the left margin, against the line holding POS."
  (when-let ((stamp (sprig-review--time-string iso)))
    (let ((ov (make-overlay pos (min (1+ pos) (point-max)))))
      (overlay-put ov 'sprig-review-margin t)
      (overlay-put ov 'before-string
                   (propertize " " 'display
                               ;; `face', not `font-lock-face': an overlay
                               ;; string is not buffer text, so font-lock
                               ;; never sees it to strip it.
                               `((margin left-margin)
                                 ,(propertize stamp 'face 'sprig-review-time)))))))

;;;; Heading helpers

(defun sprig-review--stat-string (change)
  "Return a \"(+A -B)\" line-count summary for CHANGE, added green, removed red.
The numbers are the whole of what a folded edit tells you about its size,
so they are worth reading at a glance rather than parsing."
  (let ((stat (sprig-review-change-stat change)))
    (concat "("
            (sprig-review--face (format "+%d" (car stat))
                                'sprig-review-stat-added)
            " "
            (sprig-review--face (format "-%d" (cdr stat))
                                'sprig-review-stat-removed)
            ")")))

(defun sprig-review--truncate (s width)
  "Return S truncated to WIDTH columns, ending in an ellipsis when shortened."
  (if (> (string-width s) width)
      (truncate-string-to-width s width nil nil "…")
    s))

(defun sprig-review--input-summary (name input)
  "Return a one-line summary of tool NAME's INPUT, or nil.
Shows the command for `Bash'; other non-diff tools fall back to a salient
input field (path, pattern, query, ...).  File tools that render a diff
header instead pass their changes in, so this is only reached without one."
  (let* ((obj (sprig-review--parse-input input))
         (val (if (equal name "Bash")
                  (alist-get 'command obj)
                (seq-some (lambda (k) (alist-get k obj))
                          '(file_path path pattern query url description prompt)))))
    (when (stringp val)
      (car (split-string val "\n")))))

(defun sprig-review--tool-heading (block)
  "Return the single-line heading string for tool BLOCK."
  (let* ((name (or (plist-get block :name) "tool"))
         (changes (plist-get block :changes))
         (summary (sprig-review--input-summary name (plist-get block :input)))
         (err (plist-get (plist-get block :result) :error)))
    (concat
     (sprig-review--face name 'sprig-review-tool)
     (cond
      (changes
       (let ((c (car changes)))
         (concat "  " (plist-get c :file) "  " (sprig-review--stat-string c))))
      (summary (concat "  " (sprig-review--truncate
                             summary sprig-review-heading-max-width)))
      (t ""))
     (if err (sprig-review--face "  [error]" 'error) ""))))

;;;; Section insertion

(defun sprig-review--insert-hunk (hunk)
  "Insert HUNK as removed lines then added lines, each a coloured section line."
  (magit-insert-section (sprig-hunk hunk)
    (dolist (l (plist-get hunk :old))
      (insert (sprig-review--face (concat "-" l) 'sprig-review-removed) "\n"))
    (dolist (l (plist-get hunk :new))
      (insert (sprig-review--face (concat "+" l) 'sprig-review-added) "\n"))))

(defun sprig-review--insert-change (change)
  "Insert CHANGE as a foldable file section holding its hunks."
  (magit-insert-section (sprig-change change)
    (magit-insert-heading
      (sprig-review--face (plist-get change :file) 'sprig-review-file))
    (dolist (hunk (plist-get change :hunks))
      (sprig-review--insert-hunk hunk))))

(defun sprig-review--insert-result (result)
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

(defun sprig-review--insert-tool (block)
  "Insert tool BLOCK: heading, its file-change diffs, then its result.
Every tool folds to its one-line heading, so a turn reads as a list of
what the agent did; TAB opens the change you want.  Set
`sprig-review-expand-diffs' to render diff-bearing tools open instead."
  (magit-insert-section (sprig-tool block
                                    (not (and sprig-review-expand-diffs
                                              (plist-get block :changes))))
    (magit-insert-heading (sprig-review--tool-heading block))
    ;; Deferred so a folded tool keeps its body out of the buffer; magit only
    ;; draws the fold when the body goes through `magit-insert-section-body'.
    (magit-insert-section-body
      (dolist (change (plist-get block :changes))
        (sprig-review--insert-change change))
      (when-let ((result (plist-get block :result)))
        (sprig-review--insert-result result)))))

(defvar markdown-hide-markup)
(declare-function markdown-mode "markdown-mode" ())
(declare-function markdown-toggle-markup-hiding "markdown-mode" (&optional arg))

(defun sprig-review--fontify-markdown (text)
  "Return TEXT fontified with `markdown-mode', its markup characters hidden.
Fontifies in a reusable hidden buffer and copies the propertized string,
so the `*'/`#' markup carries an `invisible' property the review buffer's
invisibility spec then hides (see `sprig-review-mode').  The copy's faces
are adopted onto `font-lock-face', without which this buffer's font-lock
would strip them (see `sprig-review--adopt-faces').  Returns TEXT
unchanged when `sprig-review-fontify-markdown' is nil or markdown-mode is
not installed."
  (if (and sprig-review-fontify-markdown
           (require 'markdown-mode nil t))
      (with-current-buffer (get-buffer-create " *sprig-review-markdown*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (delay-mode-hooks (markdown-mode))
          (setq-local markdown-hide-markup t)
          ;; The toggle wires markup hiding fully (invisibility spec plus the
          ;; refontify hooks) where merely setting the flag may not.
          (when (fboundp 'markdown-toggle-markup-hiding)
            (ignore-errors (markdown-toggle-markup-hiding 1)))
          (insert text)
          (font-lock-ensure)
          (sprig-review--adopt-faces (buffer-string))))
    text))

(defun sprig-review--text-body (text)
  "Return TEXT with trailing newlines normalised to exactly one.
Trailing spaces are kept (a streamed delta may legitimately end in one),
so this matches what the in-place append path produces."
  (concat (string-trim-right text "[\n]+") "\n"))

(defun sprig-review--insert-text (block &optional open)
  "Insert an assistant text BLOCK as bare prose.
It carries no label: a user turn is the tinted one, so the agent's output
is simply what is not tinted.  The section has no heading either, which
costs it nothing but the ability to fold, and prose is what you came to
read.  When OPEN, this is the live streaming block: render its text raw
\(plus a trailing newline) and record the tail (`sprig-review--tail') just
before that newline, so `sprig-review--append-streamed' and a later full
refresh produce identical text.  A settled block is normalised for tidy
display."
  (magit-insert-section (sprig-text block)
    (if open
        ;; The live block renders raw so the fast in-place append path and a
        ;; later full rebuild agree; it gains markdown faces once it settles.
        (progn
          (insert (plist-get block :text) "\n")
          (setq sprig-review--tail (copy-marker (1- (point)) t)))
      (insert (sprig-review--fontify-markdown
               (sprig-review--text-body (plist-get block :text)))))))

(defun sprig-review--insert-user (block)
  "Insert a user-turn BLOCK as prose carrying the `sprig-review-user' tint.
The tint is what tells your turn from the agent's output, so the block
needs no label, and no heading beyond its own first line.
`heading-highlight-face' is what magit paints over the section under
point; naming our own keeps the turn tinted there too.  With no heading
to confine it to, magit paints it over the whole section, which is what
we want."
  (magit-insert-section (sprig-user block nil
                         :heading-highlight-face 'sprig-review-user-highlight)
    (let ((beg (point)))
      (insert (sprig-review--fontify-markdown
               (sprig-review--text-body (plist-get block :text))))
      (sprig-review--add-face beg (point) 'sprig-review-user))))

(defun sprig-review--insert-thinking (block)
  "Insert a thinking BLOCK, folded by default since it is verbose."
  (magit-insert-section (sprig-thinking block t)
    (magit-insert-heading (sprig-review--face "thinking" 'sprig-review-thinking))
    (magit-insert-section-body
      (insert (string-trim-right (plist-get block :text)) "\n"))))

(defun sprig-review--insert-error (block)
  "Insert an error BLOCK."
  (magit-insert-section (sprig-error block)
    (magit-insert-heading (sprig-review--face "error" 'error))
    (insert (string-trim-right (or (plist-get block :text) "")) "\n")))

;;;; Dialogs
;;
;; A question the agent asked mid-turn renders here, in the buffer, rather
;; than in the minibuffer: the turn it is about is on screen, and a
;; minibuffer prompt would hold the process filter (and Emacs with it) for
;; as long as the question went unanswered.  So the block stands pending,
;; you answer it with the same keys you review with, and the turn goes on.

(defun sprig-review--question-list (input)
  "Return INPUT's questions as a list.
The control request is re-read with JSON-faithful arrays, so `questions'
and `options' arrive as vectors and `multiSelect' as `:false'."
  (append (alist-get 'questions input) nil))

(defun sprig-review--multi-select-p (question)
  "Return non-nil when QUESTION takes more than one answer."
  (eq (alist-get 'multiSelect question) t))

(defconst sprig-review--plan-question
  '((question . "Approve this plan?")
    (multiSelect . :false)
    (options . [((label . "Approve")
                 (description . "the agent leaves plan mode and starts work"))
                ((label . "Reject")
                 (description . "say what is wrong; the agent plans again"))]))
  "The one thing a plan asks.
ExitPlanMode does not put it as a question, so it is put as one here, and
a plan is then answered by everything that answers a question.")

(defconst sprig-review--permission-question
  '((question . "Allow this call?")
    (multiSelect . :false)
    (options . [((label . "Allow")
                 (description . "run it, this once"))
                ((label . "Deny")
                 (description . "the agent is told no, and goes on"))]))
  "The one thing a tool wanting permission asks.
Put as a question here, as a plan's is, so a permission is answered by
everything that answers a question.")

(defun sprig-review--dialog-questions (block)
  "Return the questions dialog BLOCK asks."
  (pcase (plist-get block :kind)
    ("exit_plan_mode" (list sprig-review--plan-question))
    ("can_use_tool" (list sprig-review--permission-question))
    (_ (sprig-review--question-list (plist-get block :input)))))

(defun sprig-review--option-label (option)
  "Return OPTION's label."
  (alist-get 'label option))

(defun sprig-review--recommended-option (question)
  "Return the label QUESTION recommends, or its first option's.
The tool's own convention is to mark the recommended option in its label
and to put it first, so the first option is the fallback rather than a
guess."
  (let* ((options (append (alist-get 'options question) nil))
         (recommended
          (seq-find (lambda (option)
                      (string-match-p "recommend"
                                      (downcase (or (sprig-review--option-label
                                                     option)
                                                    ""))))
                    options)))
    (sprig-review--option-label (or recommended (car options)))))

(defun sprig-review--insert-question (block question index)
  "Insert QUESTION, the INDEX'th of dialog BLOCK, and what it offers.
The options are shown but not pickable: this buffer is for reading, and
the answering has a buffer of its own (see `sprig-review-answer')."
  (let ((answered (plist-get block :answered))
        (multi (sprig-review--multi-select-p question))
        (text (alist-get 'question question)))
    (magit-insert-section (sprig-question (list :dialog (plist-get block :id)
                                                :index index))
      (magit-insert-heading
        (concat (sprig-review--face (concat "? " text) 'sprig-review-dialog)
                (if (and multi (not answered))
                    (sprig-review--face "  (any of)" 'sprig-review-meta-key)
                  "")))
      (if answered
          ;; Settled: what was said, not what might have been.
          (insert "    "
                  (sprig-review--face
                   (or (alist-get (intern text) (plist-get block :answers))
                       "skipped")
                   'sprig-review-dialog-picked)
                  "\n")
        (seq-do
         (lambda (option)
           (insert "    "
                   (sprig-review--face (sprig-review--option-label option)
                                       'default)
                   (let ((description (alist-get 'description option)))
                     (if (and description (not (string-empty-p description)))
                         (sprig-review--face
                          (concat "  " (sprig-review--truncate
                                        description
                                        sprig-review-heading-max-width))
                          'sprig-review-meta-key)
                       ""))
                   "\n"))
         (alist-get 'options question))))))

(defun sprig-review--insert-plan (block)
  "Insert the plan dialog BLOCK holds, and what it says of it.
The plan itself, not a summary of it: approving is the point, and the
whole of what you are approving is here to read."
  (let ((plan (alist-get 'plan (plist-get block :input)))
        (answered (plist-get block :answered)))
    (magit-insert-section (sprig-plan block)
      (magit-insert-heading
        (sprig-review--face "? The agent has a plan" 'sprig-review-dialog))
      (insert (sprig-review--fontify-markdown
               (sprig-review--text-body (or plan ""))))
      (when answered
        (insert "    "
                (sprig-review--face (format "%s" (plist-get block :answers))
                                    'sprig-review-dialog-picked)
                "\n")))))

(defun sprig-review--insert-permission (block)
  "Insert the tool call BLOCK wants permission for, and what was said of it."
  (let* ((request (plist-get block :input))
         (tool (or (alist-get 'tool_name request) "a tool"))
         (summary (sprig-review--input-summary tool (alist-get 'input request))))
    (magit-insert-section (sprig-permission block)
      (magit-insert-heading
        (sprig-review--face (format "? Allow %s?" tool) 'sprig-review-dialog))
      (when summary
        (insert "    "
                (sprig-review--face
                 (sprig-review--truncate summary sprig-review-heading-max-width)
                 'default)
                "\n"))
      (when (plist-get block :answered)
        (insert "    "
                (sprig-review--face (format "%s" (plist-get block :answers))
                                    'sprig-review-dialog-picked)
                "\n")))))

(defun sprig-review--dialog-hint (kind)
  "Return the line saying how to answer a dialog of KIND."
  (pcase kind
    ("exit_plan_mode" "    a a to approve or reject · a r to approve")
    ("can_use_tool" "    a a to allow or deny · a s to deny")
    (_ "    a a to answer · a r to take the recommended")))

(defun sprig-review--insert-dialog (block)
  "Insert dialog BLOCK: what the agent asked, and what there is to answer.
The questions are the sections; no section of its own wraps them.  A
section that starts where its first child starts traps
`magit-section-backward': at that position it is the child that is
current, so `p' walks up to the parent and goes to the parent's start,
which is the very position it came from, and point never moves again.
Magit's own sections never meet this, always heading a section before
opening a child, and a wrapper here earns nothing to pay for it."
  (pcase (plist-get block :kind)
    ("exit_plan_mode" (sprig-review--insert-plan block))
    ("can_use_tool" (sprig-review--insert-permission block))
    (_ (seq-do-indexed
        (lambda (question index)
          (sprig-review--insert-question block question index))
        (sprig-review--question-list (plist-get block :input)))))
  (unless (plist-get block :answered)
    (insert (sprig-review--face (sprig-review--dialog-hint
                                 (plist-get block :kind))
                                'sprig-review-meta-key)
            "\n")))

(defun sprig-review--context-window (tokens)
  "Return the window size to measure TOKENS of context against, or nil.
The smallest of `sprig-context-window-tokens' and the
`sprig-context-window-tiers' that is at least TOKENS, so the percentage
never runs past 100 (a long-context session the CLI does not flag widens
to the tier that fits); TOKENS itself when it exceeds them all, and nil
when neither is configured, so the header shows the bare count."
  (let ((cands (sort (seq-filter (lambda (n) (and (integerp n) (> n 0)))
                                 (cons sprig-context-window-tokens
                                       (copy-sequence sprig-context-window-tiers)))
                     #'<)))
    (when cands
      (or (seq-find (lambda (c) (>= c tokens)) cands) tokens))))

(defun sprig-review--format-tokens (n)
  "Format N tokens compactly, in thousands or millions."
  (if (>= n 1000000) (format "%.1fM" (/ n 1000000.0))
    (format "%.1fk" (/ n 1000.0))))

(defun sprig-review--format-context (tokens)
  "Return a compact \"USED / WINDOW (PCT%)\" string for TOKENS, or nil.
The window auto-fits TOKENS (see `sprig-review--context-window'), so the
percentage stays within 100."
  (when (and (numberp tokens) (> tokens 0))
    (let ((win (sprig-review--context-window tokens)))
      (if (and (numberp win) (> win 0))
          (format "%s / %s (%d%%)"
                  (sprig-review--format-tokens tokens)
                  (sprig-review--format-tokens win)
                  (round (* 100.0 (/ (float tokens) win))))
        (sprig-review--format-tokens tokens)))))

(defun sprig-review--meta-line (key value)
  "Return a header line pairing KEY with VALUE, or nil when VALUE is blank."
  (when (and value (not (string-empty-p (format "%s" value))))
    (concat (sprig-review--face (format "%-9s" (concat key ":"))
                                'sprig-review-meta-key)
            (format "%s" value) "\n")))

(defun sprig-review--insert-headers (model meta)
  "Insert the metadata header from MODEL and the META plist.
META may carry :title, :project, :model, and :status."
  (magit-insert-section (sprig-headers)
    (dolist (line (list
                   (sprig-review--meta-line
                    "Title" (or (plist-get meta :title) (plist-get model :title)))
                   (sprig-review--meta-line "Project" (plist-get meta :project))
                   (sprig-review--meta-line "Model"   (plist-get meta :model))
                   (sprig-review--meta-line "Status"  (plist-get meta :status))
                   (sprig-review--meta-line
                    "Mode" (let ((m (plist-get model :mode)))
                             (unless (member m '(nil "auto" "default" "manual")) m)))
                   (sprig-review--meta-line "Session" (plist-get model :session))
                   (sprig-review--meta-line
                    "Cost" (when (plist-get model :cost)
                             (format "$%.4f" (plist-get model :cost))))))
      (when line (insert line)))
    (insert "\n")))

(defun sprig-review--prose-block-p (block)
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

(defun sprig-review--state (model)
  "Return (GLYPH TEXT FACE) for what is going on in MODEL, or has just ended.
The context in use is appended to the text, since the state line sits where
you are reading and is the natural place to watch the window fill."
  (let ((base
         (cond
          ;; Before anything else: the turn is not working, it is stopped, and
          ;; it is stopped on you.
          ((sprig-review-pending-dialog model)
           (list "?" "waiting on you  ·  a a to answer" 'sprig-review-waiting))
          (sprig-review--streaming (list "▶" "working…" 'sprig-review-working))
          ;; Sent, but nothing back yet: the transport is busy while it waits on
          ;; the agent's first token, so this window would otherwise read as the
          ;; previous turn's stale `✓ turn over'.
          ((and (boundp 'sprig--busy) sprig--busy)
           (list "▷" "sent, awaiting reply" 'sprig-review-pending))
          ((plist-get model :error) (list "✗" "turn failed" 'sprig-review-failed))
          ;; What it cost is in the header; the line says the one thing it is for.
          ((plist-get model :done) (list "✓" "turn over" 'sprig-review-done))
          ;; Replayed history, or a session not yet sent to: nothing is running,
          ;; but no turn of ours ended either, so claim neither.
          (t (list "●" "idle" 'sprig-review-idle))))
        (ctx (sprig-review--format-context (plist-get model :context))))
    (if ctx
        (list (nth 0 base) (concat (nth 1 base) "  ·  " ctx) (nth 2 base))
      base)))

(defun sprig-review--insert-state (model)
  "Insert the state line, below the last message: what is going on, or ended.
The side bar carries a rule in the same colour, so the gutter marks the
end of the turn as plainly as the line does."
  (pcase-let ((`(,glyph ,text ,face) (sprig-review--state model))
              (start (point)))
    (magit-insert-section (sprig-state)
      (insert (sprig-review--face (format "%s  %s" glyph text) face) "\n"))
    (when (> (sprig-review--margin-width) 0)
      (let ((ov (make-overlay start (min (1+ start) (point-max)))))
        (overlay-put ov 'sprig-review-margin t)
        (overlay-put ov 'before-string
                     (propertize " " 'display
                                 `((margin left-margin)
                                   ,(propertize
                                     (make-string (sprig-review--margin-width) ?━)
                                     'face face))))))))

;;;; Rendering entry points

(defun sprig-review-render (model &optional meta)
  "Render review MODEL into the current buffer as magit-sections.
META is an optional plist of display metadata (see
`sprig-review--insert-headers').  The buffer should already be in
`sprig-review-mode'."
  (let* ((inhibit-read-only t)
         (blocks (plist-get model :blocks))
         (last (car (last blocks)))
         (prev nil)
         (first t))
    (setq sprig-review--tail nil)
    ;; Before the erase: these hang off buffer text that is about to go.
    (remove-overlays (point-min) (point-max) 'sprig-review-margin t)
    (erase-buffer)
    (magit-insert-section (sprig-review)
      (sprig-review--insert-headers model meta)
      (dolist (block blocks)
        ;; A blank line at every boundary prose is on either side of, which
        ;; is to say: around prose, and so above the first row of a run of
        ;; tool calls, but never between two of those rows.  A turn's tool
        ;; calls then sit as one block with air around it, rather than as a
        ;; ladder down the buffer.  The line goes before the block rather
        ;; than after, which would sit between the live text section's end
        ;; and `sprig-review--tail'.
        (when (and (not first)
                   (or (sprig-review--prose-block-p block)
                       (sprig-review--prose-block-p prev)))
          (insert "\n"))
        (setq first nil prev block)
        ;; Held from before the block is drawn, so the stamp lands against
        ;; its first line rather than against whatever follows it.
        (let ((start (point)))
          (pcase (plist-get block :type)
            ('user     (sprig-review--insert-user block))
            ;; The live tail is the last block, when it is text, and only
            ;; while a turn is actually streaming in.
            ('text     (sprig-review--insert-text
                        block (and sprig-review--streaming (eq block last))))
            ('thinking (sprig-review--insert-thinking block))
            ('tool     (sprig-review--insert-tool block))
            ('dialog   (sprig-review--insert-dialog block))
            ('error    (sprig-review--insert-error block)))
          (sprig-review--insert-margin start (plist-get block :time))))
      ;; Below the last message, and last of all, so it is what the buffer
      ;; ends on.  The live tail sits inside the block above and is not
      ;; disturbed by an insertion after it, so streamed text still lands
      ;; above this line rather than through it.
      (when blocks (insert "\n"))
      (sprig-review--insert-state model))
    (sprig-review--update-margin)
    (goto-char (point-min))))

;;;; Live sink: accumulate events, refresh the buffer
;;
;; The transport (sprig.el) emits a backend-neutral event vocabulary; a
;; review buffer folds those events into its model and re-renders.
;; `sprig-review-consume' is the buffer's sink: the transport calls it once
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
;; token in a long session, so `sprig-review-consume' avoids it two ways:
;;
;; - Streamed `text' deltas, the high-frequency case, extend the last text
;;   section in place at `sprig-review--tail', with no re-render at all.
;; - Structural events (a new tool call, a result, the user turn, done)
;;   mark the buffer dirty and arm a short timer that coalesces a burst
;;   into one render (`sprig-review-flush').  That render re-establishes
;;   the tail, so the following text deltas take the fast path again.
;;
;; So the re-render count is bounded by the number of structural events in
;; a turn, not the number of tokens.  `seed'/`reset' render synchronously,
;; being one-shot.

(defcustom sprig-review-refresh-delay 0.1
  "Seconds to coalesce structural events before re-rendering the review buffer.
Batching them into one render at this cadence keeps a long conversation
from re-rendering repeatedly.  Lower is more responsive but renders more
often.  Streamed text does not wait on this; it appends in place."
  :type 'number
  :group 'sprig)

(defun sprig-review--locate (pos)
  "Return a locator for POS that survives a re-render, or nil.
A section's ident and an offset into it, rather than a raw position: the
render erases the buffer, so a position means nothing across it, while a
section can be found again."
  (save-excursion
    (goto-char pos)
    (when-let ((section (magit-current-section)))
      (cons (magit-section-ident section) (- pos (oref section start))))))

(defun sprig-review--relocate (locator fallback)
  "Return where LOCATOR points now, or FALLBACK when its section is gone."
  (or (and locator
           (when-let ((section (magit-get-section (car locator))))
             (min (+ (oref section start) (max 0 (cdr locator)))
                  (or (oref section end) (point-max)))))
      (min fallback (point-max))))

(defun sprig-review--refresh ()
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
  (let* ((model (sprig-review-build (reverse sprig-review--events)))
         (pos (point))
         (locator (sprig-review--locate pos))
         (windows (mapcar (lambda (win)
                            (list win
                                  (sprig-review--locate (window-point win))
                                  (window-point win)
                                  (sprig-review--locate (window-start win))
                                  (window-start win)))
                          (get-buffer-window-list nil nil t))))
    (sprig-review-render model sprig-review--meta)
    (goto-char (sprig-review--relocate locator pos))
    (pcase-dolist (`(,win ,point-loc ,point-pos ,start-loc ,start-pos) windows)
      (when (window-live-p win)
        (set-window-point win (sprig-review--relocate point-loc point-pos))
        ;; NOFORCE, so a start that would now put point off screen is
        ;; recomputed rather than obeyed.
        (set-window-start win (sprig-review--relocate start-loc start-pos) t)))
    (sprig-review--apply-marks)))

(defun sprig-review--cancel-timer ()
  "Cancel this buffer's pending coalescing-refresh timer, if any."
  (when sprig-review--timer
    (cancel-timer sprig-review--timer)
    (setq sprig-review--timer nil)))

(defun sprig-review-flush (&optional buffer)
  "Render events pending in BUFFER since the last refresh, now.
Called by the coalescing timer, and usable to force a render immediately."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (sprig-review--cancel-timer)
        (when sprig-review--dirty
          (setq sprig-review--dirty nil)
          (sprig-review--refresh))))))

(defun sprig-review--append-streamed (s)
  "Append streamed text S at the live text tail, without a re-render."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char sprig-review--tail)
      (insert s))))          ; the type-t tail marker advances past S

(defun sprig-review--schedule ()
  "Mark the buffer dirty and arm the coalescing refresh timer."
  (setq sprig-review--dirty t)
  (unless sprig-review--timer
    (setq sprig-review--timer
          (run-with-timer sprig-review-refresh-delay nil
                          #'sprig-review-flush (current-buffer)))))

(defun sprig-review--stamp-arrival (event)
  "Push a `time' event dating EVENT's arrival, unless it inherits one.
The wire carries no times, so a live turn is dated when it reaches the
buffer, and dated here rather than at render, since the model is rebuilt
from this event list every render and a time read off the clock there
would tick forward under a finished conversation.  One stamp per block is
enough: only the first `text' of a run opens a block, and the deltas
extending it are contiguous, so a `text' behind a `text' takes the stamp
already in the list rather than adding thousands of its own."
  (unless (and (eq (car event) 'text)
               (eq (car-safe (car sprig-review--events)) 'text))
    (push (list 'time (format-time-string "%FT%T.%3NZ" nil t))
          sprig-review--events)))

(defun sprig-review-consume (event)
  "Fold transport EVENT into the current review buffer.
A streamed `text' delta extends the live text section in place, with no
re-render, whenever a tail is established.  Every other event, and the
first `text' of a run, clears the tail and schedules a coalesced render
\(see `sprig-review-refresh-delay'), which re-establishes the tail."
  (sprig-review--stamp-arrival event)
  (push event sprig-review--events)
  ;; Track whether a turn is in flight, which decides both the live tail and
  ;; the running bar (see `sprig-review--streaming').  Any event the agent
  ;; produces means it is working; a `user' event is you, mid-turn or not, and
  ;; says nothing either way.
  (pcase (car event)
    ((or 'text 'thinking 'tool-call) (setq sprig-review--streaming t))
    ((or 'done 'error) (setq sprig-review--streaming nil))
    (_ nil))
  (if (and (eq (car event) 'text)
           sprig-review--tail (marker-position sprig-review--tail))
      (sprig-review--append-streamed (cadr event))
    (unless (eq (car event) 'text)
      (setq sprig-review--tail nil))
    (sprig-review--schedule)))

(defun sprig-review-reset (&optional meta)
  "Drop this review buffer's accumulated events and render empty.
With META, replace the header metadata plist."
  (sprig-review--cancel-timer)
  (setq sprig-review--events nil sprig-review--dirty nil
        sprig-review--streaming nil)
  (when meta (setq sprig-review--meta meta))
  (sprig-review--refresh))

(defun sprig-review-seed (events &optional meta)
  "Seed this review buffer with EVENTS (in order) and refresh synchronously.
Use this to replay history before the live sink appends more, so a later
`sprig-review-consume' rebuilds from history plus the new event.  Replayed
history is settled, so it renders with no live tail."
  (sprig-review--cancel-timer)
  (setq sprig-review--events (reverse events) sprig-review--dirty nil
        sprig-review--streaming nil)
  (when meta (setq sprig-review--meta meta))
  (sprig-review--refresh))

(defun sprig-review-refresh (&rest _)
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
  (let ((events (sprig-review-session-events
                 (if sprig-review--file
                     (sprig-review-read-session-lines sprig-review--file)
                   (sprig--session-log-lines)))))
    (sprig-review-seed events sprig-review--meta)
    (message "sprig: re-read %d event%s from the log"
             (length events) (if (= (length events) 1) "" "s"))))

(defun sprig-review-buffer (name)
  "Return a buffer named NAME, put into `sprig-review-mode'."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sprig-review-mode) (sprig-review-mode)))
    buffer))

;;;; Major mode

(defvar sprig-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    map)
  "Keymap for `sprig-review-mode'.
Inherits magit-section's navigation and folding; the sprig verbs are
added on top as they land.")

(define-derived-mode sprig-review-mode magit-section-mode "Sprig-Review"
  "Major mode for reviewing an agent conversation as read-only sections.
Built on `magit-section-mode': move with \\`n' / \\`p', fold with TAB."
  :group 'sprig
  ;; `g' is bound to `revert-buffer' by the parent mode; point it at a re-read
  ;; of the log, rather than leaving the one key that means refresh a no-op.
  (setq-local revert-buffer-function #'sprig-review-refresh)
  ;; Surface the session's Claude permission mode (plan, auto, ...) in the
  ;; mode line; nil for an offline file review, which owns no session.
  (setq-local mode-line-process '(:eval (sprig--mode-line-permission)))
  ;; Prose wraps on word boundaries; tool headings are pre-truncated to one
  ;; line (see `sprig-review-heading-max-width'), so wrapping suits the body.
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Markdown markup (`*', `#', ...) carries `invisible markdown-markup' from
  ;; `sprig-review--fontify-markdown'; hide it here so only the styling shows.
  (add-to-invisibility-spec 'markdown-markup)
  ;; Claim the margin the timestamps hang in before the buffer is displayed,
  ;; so its first window comes up with the right width.
  (setq-local left-margin-width (sprig-review--margin-width)))

(defun sprig-review-show (model &optional meta name)
  "Show review MODEL in a review buffer named NAME and select it.
META is passed to `sprig-review-render'."
  (let ((buffer (get-buffer-create (or name "*sprig-review*"))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'sprig-review-mode)
        (sprig-review-mode))
      (sprig-review-render model meta))
    (pop-to-buffer buffer)))

(defun sprig-review-read-session-lines (file)
  "Return the non-empty JSONL lines of session-log FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (split-string (buffer-string) "\n" t)))

;;;###autoload
(defun sprig-review-open-file (file)
  "Open a read-only review of a stored `claude' session-log FILE.
Replays the whole transcript from the log; see `sprig-review-session-events'.
This is the local-read path.  A remote session's log lives on the SSH host
and is fetched by the integration layer, not here."
  (interactive "fSession log (.jsonl): ")
  (let ((buffer (sprig-review-buffer
                 (format "*sprig-review: %s*" (file-name-base file)))))
    (with-current-buffer buffer
      (setq sprig-review--file file)     ; so `g' re-reads this same file
      (sprig-review-seed (sprig-review-session-events
                          (sprig-review-read-session-lines file))))
    (pop-to-buffer buffer)))

;;;; Marks
;;
;; Marking is the review buffer's one selection primitive (see DESIGN.md):
;; a verb acts on the marked sections, or on the section at point when
;; nothing is marked.  Marks are stored as section idents so they survive
;; a re-render, and re-applied by `sprig-review--refresh'.

(defun sprig-review--apply-marks ()
  "Highlight the marked sections; drop marks whose section no longer exists."
  (remove-overlays (point-min) (point-max) 'sprig-review-mark t)
  (setq sprig-review--marks (seq-filter #'magit-get-section sprig-review--marks))
  (dolist (ident sprig-review--marks)
    (let* ((sec (magit-get-section ident))
           (beg (oref sec start))
           (end (save-excursion (goto-char beg)
                                (min (1+ (line-end-position)) (point-max))))
           (ov (make-overlay beg end)))
      (overlay-put ov 'sprig-review-mark t)
      (overlay-put ov 'face 'sprig-review-marked)
      (overlay-put ov 'before-string (propertize "▸" 'face 'sprig-review-marked)))))

(defun sprig-review-toggle-mark ()
  "Toggle the mark on the section at point, then move to the next section."
  (interactive)
  (when-let ((sec (magit-current-section)))
    (let ((ident (magit-section-ident sec)))
      (setq sprig-review--marks
            (if (member ident sprig-review--marks)
                (delete ident sprig-review--marks)
              (cons ident sprig-review--marks))))
    (sprig-review--apply-marks)
    (ignore-errors (magit-section-forward))))

(defun sprig-review-unmark-all ()
  "Clear all marks."
  (interactive)
  (setq sprig-review--marks nil)
  (sprig-review--apply-marks))

(defun sprig-review--marked-sections ()
  "Return the marked sections, or the section at point if none are marked."
  (or (let (secs)
        (dolist (ident (reverse sprig-review--marks))
          (when-let ((s (magit-get-section ident))) (push s secs)))
        (nreverse secs))
      (when-let ((s (magit-current-section))) (list s))))

(defun sprig-review--sections-of-type (sections type)
  "Return the members of SECTIONS whose section type is TYPE."
  (seq-filter (lambda (s) (eq (oref s type) type)) sections))

(defun sprig-review--unmark-sections (sections)
  "Drop the marks on SECTIONS and refresh the highlighting."
  (dolist (s sections)
    (setq sprig-review--marks
          (delete (magit-section-ident s) sprig-review--marks)))
  (sprig-review--apply-marks))

;;;; Instruction builders
;;
;; Every change-touching verb is sugar over a message to the agent (see
;; DESIGN.md, "Verbs are canned instructions").  These builders are pure:
;; they turn the object(s) under point or marked into the instruction text.

(defcustom sprig-review-commit-instruction
  "Please commit the current changes with a suitable commit message."
  "Instruction the commit verb sends to the agent."
  :type 'string
  :group 'sprig)

(defcustom sprig-review-accept-instruction
  "Yes, go ahead; use your judgement on any open choice."
  "Affirmative the yes/accept verb sends to answer the agent's last question.
The agent has the whole conversation in context, so a short yes resolves
against whatever it just proposed (\"Want me to push?\" -> \"Yes\"); the
trailing clause nudges it to pick when the question was an either/or.  For
a genuinely open choice, compose a reply with `c c' instead."
  :type 'string
  :group 'sprig)

(defcustom sprig-review-decline-instruction
  "No, please don't; hold off and wait for my next instruction."
  "Negative the no/decline verb sends to answer the agent's last question.
The mirror of `sprig-review-accept-instruction': a short no, resolved by
the agent against what it just proposed, telling it to stop rather than
proceed.  For a reason or an alternative, compose a reply with `c c'."
  :type 'string
  :group 'sprig)

(defun sprig-review-reject-instruction (changes)
  "Return an instruction asking the agent to undo CHANGES.
CHANGES is a list of (FILE . HUNK-PLIST)."
  (concat
   (if (cdr changes) "Please undo these changes:\n\n"
     "Please undo this change:\n\n")
   (mapconcat
    (lambda (fc)
      (format "In `%s`:\n```diff\n%s\n```"
              (car fc) (sprig-review--format-hunk (cdr fc))))
    changes "\n\n")))

(defun sprig-review-run-instruction (command)
  "Return an instruction asking the agent to run COMMAND."
  (format "Please run:\n```\n%s\n```" command))

(defconst sprig-review--non-shell-langs
  '("diff" "elisp" "emacs-lisp" "lisp" "json" "python" "py" "js" "jsx"
    "javascript" "ts" "tsx" "typescript" "c" "cpp" "c++" "rust" "rs" "go"
    "java" "ruby" "rb" "php" "html" "css" "scss" "xml" "yaml" "yml" "toml"
    "ini" "sql" "markdown" "md" "text" "org")
  "Fence info-string languages the run verb treats as non-commands.
A fenced block tagged with one of these is code or data, not a shell
command, so `sprig-review-run' skips it; an untagged block or a shell tag
\(sh, bash, ...) is runnable.")

(defun sprig-review--fenced-blocks (text)
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

(defun sprig-review--runnable-blocks (text)
  "Return the fenced blocks in TEXT that read as shell commands.
Filters `sprig-review--fenced-blocks' down to untagged or shell-tagged
fences, dropping code/data blocks named by `sprig-review--non-shell-langs'."
  (seq-remove (lambda (b)
                (member (plist-get b :lang) sprig-review--non-shell-langs))
              (sprig-review--fenced-blocks text)))

;;;; Steering: send through the owned session

(defun sprig-review-set-remote (remote)
  "Record REMOTE, the session host's SSH destination (nil when local).
Used to reach a changed file over TRAMP when visiting it."
  (setq sprig-review--remote remote))

(defun sprig-review--send (text &optional mode)
  "Send TEXT as a user instruction steering this review's session.
MODE, when given (e.g. \"plan\"), sets the permission mode for the turn.
Starts or resumes the session if it is not already live."
  (sprig--review-deliver text mode)
  (message "sprig: sent%s" (if mode (format " (%s mode)" mode) "")))

(defun sprig-review--steer (text)
  "Send TEXT into the turn already in flight (see `sprig--review-steer').
Falls back to a plain send when the turn has since finished, so a message
does not go down with the turn it was composed against."
  (sprig--review-steer text))

;;;; Verbs

(defun sprig-review--reject-pairs (sections)
  "Return (FILE . HUNK) pairs for the hunk SECTIONS."
  (delq nil
        (mapcar (lambda (s)
                  (when (eq (oref s type) 'sprig-hunk)
                    (cons (plist-get (oref (oref s parent) value) :file)
                          (oref s value))))
                sections)))

(defun sprig-review-reject ()
  "Ask the agent to undo the marked diff hunks, or the hunk at point.
On a mixed mark set, confirms and acts only on the hunks (see DESIGN.md)."
  (interactive)
  (let* ((sections (sprig-review--marked-sections))
         (pairs (sprig-review--reject-pairs sections)))
    (unless pairs (user-error "No diff hunk marked or at point"))
    (when (and sprig-review--marks (< (length pairs) (length sections))
               (not (y-or-n-p
                     (format "Reject %d hunk(s), ignoring %d other mark(s)? "
                             (length pairs) (- (length sections) (length pairs))))))
      (user-error "Cancelled"))
    (sprig-review--send (sprig-review-reject-instruction pairs))
    (sprig-review--unmark-sections
     (sprig-review--sections-of-type sections 'sprig-hunk))))

(defun sprig-review-commit ()
  "Ask the agent to commit the current changes."
  (interactive)
  (sprig-review--send sprig-review-commit-instruction))

(defun sprig-review--tool-command (section)
  "Return the shell command a `sprig-tool' SECTION ran, or nil."
  (alist-get 'command
             (sprig-review--parse-input
              (plist-get (oref section value) :input))))

(defun sprig-review--prose-command (section)
  "Return the fenced shell command to run from prose SECTION.
SECTION is a `sprig-text'/`sprig-user' block; the command is the runnable
fenced block point is in, or the sole runnable block when point sits
outside one.  This reaches a command the agent proposed but did not run.
Signals a `user-error' when there is no runnable block, or several and
point is in none."
  (let* ((text (plist-get (oref section value) :text))
         (blocks (sprig-review--runnable-blocks text)))
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

(defun sprig-review-run ()
  "Ask the agent to run a command.
On a tool-call section, the command that tool ran; on a prose section, the
shell command in the fenced code block point is in (or its sole one), which
lets you run a command the agent proposed but did not execute.  Acts on the
marked section, or the one at point when nothing is marked."
  (interactive)
  (let* ((sections (sprig-review--marked-sections))
         (tool (seq-find (lambda (s) (eq (oref s type) 'sprig-tool)) sections))
         (prose (seq-find (lambda (s) (memq (oref s type)
                                            '(sprig-text sprig-user)))
                          sections))
         (cmd (cond (tool (or (sprig-review--tool-command tool)
                              (user-error "That tool call has no command to run")))
                    (prose (sprig-review--prose-command prose))
                    (t (user-error
                        "No tool call or command block marked or at point")))))
    (sprig-review--send (sprig-review-run-instruction cmd))))

(defun sprig-review-accept ()
  "Yes: affirm the agent's last question, the affirmative of what it asked.
Sends `sprig-review-accept-instruction' as the next turn (\"Want me to
push?\" -> \"Yes\").  The agent resolves the short yes against the
conversation it already holds; this only answers, it does not commit
(that is `C').  Its mirror is `sprig-review-decline'."
  (interactive)
  (sprig-review--send sprig-review-accept-instruction)
  (message "sprig: yes"))

(defun sprig-review-decline ()
  "No: decline the agent's last question, the mirror of `sprig-review-accept'.
Sends `sprig-review-decline-instruction' as the next turn, telling the
agent to hold off rather than proceed."
  (interactive)
  (sprig-review--send sprig-review-decline-instruction)
  (message "sprig: no"))

(defun sprig-review-set-title (title)
  "Set this review's display TITLE in the header.
The stored session's own ai-title (owned by the CLI) is left untouched, so
this affects only what the navigator and header show for the open buffer."
  (interactive
   (list (read-string "Title: " (plist-get sprig-review--meta :title))))
  (setq sprig-review--meta (plist-put sprig-review--meta :title title))
  (sprig-review--refresh))

(defun sprig-review-retry ()
  "Re-send the most recent user turn."
  (interactive)
  (let* ((model (sprig-review-build (reverse sprig-review--events)))
         (last-user (seq-find (lambda (b) (eq (plist-get b :type) 'user))
                              (reverse (plist-get model :blocks)))))
    (unless last-user (user-error "No previous user turn to resend"))
    (sprig-review--send (plist-get last-user :text))))

(defun sprig-review-interrupt ()
  "Interrupt the in-flight turn on this review's session.
Asks the CLI to end the turn cleanly and keeps the session live, so the
next send continues it rather than resuming; falls back to killing the
turn if the CLI does not honour the request (see `sprig-interrupt-timeout')."
  (interactive)
  (sprig--review-interrupt-owned))

(defun sprig-review--section-file (section)
  "Return the file path SECTION refers to, or nil."
  (and section
       (pcase (oref section type)
         ('sprig-hunk (plist-get (oref (oref section parent) value) :file))
         ('sprig-change (plist-get (oref section value) :file))
         ('sprig-tool (plist-get (car (plist-get (oref section value) :changes))
                                 :file))
         (_ nil))))

(defun sprig-review--file-location (path)
  "Return PATH, as a TRAMP name on the session host when the session is remote."
  (if sprig-review--remote (format "/ssh:%s:%s" sprig-review--remote path) path))

(defun sprig-review-visit ()
  "Visit the file the section at point refers to.
On a diff hunk, best-effort move point to the first changed line."
  (interactive)
  (let* ((section (magit-current-section))
         (file (sprig-review--section-file section)))
    (unless file (user-error "No file to visit here"))
    (find-file (sprig-review--file-location file))
    (when (eq (oref section type) 'sprig-hunk)
      (when-let* ((hunk (oref section value))
                  (anchor (car (or (plist-get hunk :new) (plist-get hunk :old))))
                  (needle (string-trim-left anchor)))
        (unless (string-empty-p needle)
          (goto-char (point-min))
          (when (search-forward needle nil t)
            (beginning-of-line)))))))

;;;; Compose buffer (the c c message)

(defvar-local sprig-review--compose-target nil
  "Review buffer a compose buffer sends to.")
(defvar-local sprig-review--compose-context nil
  "Marked-section context prepended to the composed message, or nil.")
(defvar-local sprig-review--compose-mode nil
  "Permission mode for the composed message (e.g. \"plan\"), or nil.")
(defvar-local sprig-review--compose-steer nil
  "Non-nil when the composed message steers the turn already in flight.")

(defvar sprig-review-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'sprig-review-compose-send)
    (define-key map (kbd "C-c C-k") #'sprig-review-compose-abort)
    map)
  "Keymap for `sprig-review-compose-mode'.")

(define-derived-mode sprig-review-compose-mode text-mode "Sprig-Msg"
  "Compose a message to send to a sprig conversation.
\\<sprig-review-compose-mode-map>\\[sprig-review-compose-send] sends, \
\\[sprig-review-compose-abort] cancels.")

(defun sprig-review--marked-context ()
  "Return the text of the marked sections as a context string, or nil.
Uses only real marks, not the section-at-point fallback."
  (when sprig-review--marks
    (let ((secs (sprig-review--marked-sections)))
      (mapconcat (lambda (s)
                   (string-trim (buffer-substring-no-properties
                                 (oref s start) (oref s end))))
                 secs "\n\n"))))

(defun sprig-review-message (&optional plan steer)
  "Compose a message and send it to this review's session.
Any marked sections are attached as context (see DESIGN.md's `c c').
With PLAN non-nil, send the turn in plan mode (`c p').  With STEER
non-nil, send it into the turn already in flight (`c s')."
  (interactive)
  (let ((review (current-buffer))
        (context (sprig-review--marked-context))
        (buf (get-buffer-create "*sprig-message*")))
    (with-current-buffer buf
      (sprig-review-compose-mode)
      (erase-buffer)
      (setq sprig-review--compose-target review
            sprig-review--compose-context context
            sprig-review--compose-mode (and plan "plan")
            sprig-review--compose-steer steer))
    (pop-to-buffer buf)
    (message "%s%s%sC-c C-c to send, C-c C-k to cancel"
             (if plan "PLAN mode.  " "")
             (if steer "STEER: goes into the running turn at its next step.  " "")
             (if context (format "%d section(s) attached.  "
                                 (length (sprig-review--marked-sections)))
               ""))))

(defun sprig-review-message-plan ()
  "Compose a message and send it in plan mode (`c p')."
  (interactive)
  (sprig-review-message t))

(defun sprig-review-steer ()
  "Compose a message and send it into the turn already in flight (`c s').
The agent takes it at its next tool-call boundary and carries on in the
same turn, so a turn heading the wrong way can be corrected without being
interrupted and restarted.  With no turn running, this just sends."
  (interactive)
  (sprig-review-message nil t))

(defun sprig-review-compose-send ()
  "Send the composed message (with any attached context) to the conversation."
  (interactive)
  (let* ((text (string-trim (buffer-substring-no-properties
                             (point-min) (point-max))))
         (review sprig-review--compose-target)
         (context sprig-review--compose-context)
         (mode sprig-review--compose-mode)
         (steer sprig-review--compose-steer))
    (when (string-empty-p text) (user-error "Empty message"))
    (unless (buffer-live-p review) (user-error "The review buffer is gone"))
    (quit-window t)
    (with-current-buffer review
      (let ((message (if context (format "Regarding:\n\n%s\n\n%s" context text)
                       text)))
        (if steer
            (sprig-review--steer message)
          (sprig-review--send message mode))))))

(defun sprig-review-compose-abort ()
  "Cancel the message compose."
  (interactive)
  (quit-window t)
  (message "sprig: message cancelled"))

;;;; Answering: the verbs, and the buffer they open

(defvar-local sprig-answer--review nil
  "Review buffer whose question this answer buffer is answering.")
(defvar-local sprig-answer--dialog nil
  "The dialog block being answered.")
(defvar-local sprig-answer--index 0
  "Which of the dialog's questions is on screen.")
(defvar-local sprig-answer--answers nil
  "Answers settled so far, an alist of question symbol to label string.")
(defvar-local sprig-answer--picked nil
  "Labels picked so far for the question on screen (multi-select).")

(defun sprig-review--pending-dialog ()
  "Return this buffer's question waiting on an answer, or signal there is none."
  (or (sprig-review-pending-dialog
       (sprig-review-build (reverse sprig-review--events)))
      (user-error "No question is waiting")))

(defun sprig-review--answer-plan (dialog answers)
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

(defun sprig-review--answer-permission (dialog answers)
  "Allow or deny DIALOG's tool call, per ANSWERS.
Anything but an outright allow denies, skipping included: the call has to
be answered, and no is the answer that cannot do damage."
  (let ((id (plist-get dialog :id)))
    (if (equal (cdar answers) "Allow")
        (progn (sprig--review-allow-tool id)
               (message "sprig: allowed"))
      (sprig--review-deny-tool id)
      (message "sprig: denied; the agent is told no and goes on"))))

(defun sprig-review--answer-dialog (dialog answers)
  "Answer DIALOG with ANSWERS, and say so.
A plan and a permission are not answered with a map of answers, but by
approving or allowing, so each goes its own way from here."
  (pcase (plist-get dialog :kind)
    ("exit_plan_mode" (sprig-review--answer-plan dialog answers))
    ("can_use_tool" (sprig-review--answer-permission dialog answers))
    (_ (sprig--review-answer-dialog (plist-get dialog :id)
                                    (plist-get dialog :input)
                                    answers)
       (message "sprig: %s" (if answers
                                (format "answered (%d)" (length answers))
                              "skipped; the agent goes on unanswered")))))

;;;###autoload
(defun sprig-review-answer ()
  "Answer the waiting question, one question at a time, in its own buffer."
  (interactive)
  (let ((dialog (sprig-review--pending-dialog))
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

(defun sprig-review-answer-recommended ()
  "Answer every waiting question with the option it recommends.
The tool marks its recommended option and puts it first, so a question
recommending nothing takes its first option (see
`sprig-review--recommended-option').  A permission recommends nothing, and
will not be talked into it: one keypress allowing an unread call is the
wrong thing to make easy."
  (interactive)
  (let* ((dialog (sprig-review--pending-dialog))
         (_ (when (equal (plist-get dialog :kind) "can_use_tool")
              (user-error "Nothing is recommended here: a permission is yours to give")))
         (answers (mapcar (lambda (question)
                            (cons (intern (alist-get 'question question))
                                  (sprig-review--recommended-option question)))
                          (sprig-review--dialog-questions dialog))))
    (sprig-review--answer-dialog dialog (delq nil answers))))

(defun sprig-review-answer-skip ()
  "Skip the waiting question; the agent goes on without an answer."
  (interactive)
  (sprig-review--answer-dialog (sprig-review--pending-dialog) nil))

(transient-define-prefix sprig-review-answer-dispatch ()
  "Answer the question the agent is waiting on."
  [["Answer"
    ("a" "answer, one question at a time" sprig-review-answer)
    ("r" "take every recommended option" sprig-review-answer-recommended)
    ("s" "skip; go on unanswered" sprig-review-answer-skip)]])

;;;; Answering: the a transient, and its buffer
;;
;; The review buffer shows the question and stays a review buffer; the
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
    (define-key map (kbd "C-c C-c") #'sprig-answer-confirm)
    (define-key map (kbd "C-c C-k") #'sprig-answer-cancel)
    (dotimes (i 9)
      (define-key map (kbd (number-to-string (1+ i))) #'sprig-answer-pick-number))
    map)
  "Keymap for `sprig-answer-mode'.")

(define-derived-mode sprig-answer-mode special-mode "Sprig-Answer"
  "Answer one of the agent's questions.
\\<sprig-answer-mode-map>\\[sprig-answer-pick] picks the option at point, \
1-9 picks by number, \\[sprig-answer-cancel] cancels."
  (setq-local truncate-lines nil))

(defun sprig-answer--question ()
  "Return the question on screen."
  (nth sprig-answer--index (sprig-review--dialog-questions sprig-answer--dialog)))

(defun sprig-answer--options ()
  "Return the options of the question on screen, as a list."
  (append (alist-get 'options (sprig-answer--question)) nil))

(defun sprig-answer--render ()
  "Draw the question on screen, and what has been picked of it."
  (let* ((question (sprig-answer--question))
         (questions (sprig-review--dialog-questions sprig-answer--dialog))
         (multi (sprig-review--multi-select-p question))
         (inhibit-read-only t))
    (erase-buffer)
    (when (> (length questions) 1)
      (insert (propertize (format "Question %d of %d\n\n"
                                  (1+ sprig-answer--index) (length questions))
                          'face 'sprig-review-meta-key)))
    (insert (propertize (concat "? " (alist-get 'question question))
                        'face 'sprig-review-dialog)
            (if multi (propertize "  (pick any)" 'face 'sprig-review-meta-key) "")
            "\n\n")
    (seq-do-indexed
     (lambda (option index)
       (let* ((label (sprig-review--option-label option))
              (picked (member label sprig-answer--picked)))
         (insert (propertize (format "%s%d  " (if picked "▸" " ") (1+ index))
                            'face (if picked 'sprig-review-dialog-picked
                                    'sprig-review-meta-key))
                 (propertize label 'face (if picked 'sprig-review-dialog-picked
                                           'default))
                 "\n")
         (when-let ((description (alist-get 'description option)))
           (unless (string-empty-p description)
             (insert (propertize (concat "     " description "\n")
                                 'face 'sprig-review-meta-key))))))
     (sprig-answer--options))
    (insert "\n"
            (propertize (if multi
                            "RET or 1-9 toggles · C-c C-c takes them · C-c C-k skips"
                          "RET or 1-9 picks · C-c C-c skips this one · C-c C-k skips all")
                        'face 'sprig-review-meta-key)
            "\n")
    (goto-char (point-min))))

(defun sprig-answer--settle (label)
  "Settle the question on screen with LABEL, or with nothing when nil."
  (let ((text (alist-get 'question (sprig-answer--question))))
    (when label
      (push (cons (intern text) label) sprig-answer--answers)))
  (setq sprig-answer--picked nil)
  (if (< (1+ sprig-answer--index)
         (length (sprig-review--dialog-questions sprig-answer--dialog)))
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
          (sprig-review--answer-dialog dialog answers))
      (message "sprig: the review buffer is gone; the question went unanswered"))))

(defun sprig-answer-pick ()
  "Pick the option at point."
  (interactive)
  (let* ((line (- (line-number-at-pos) 1))
         (options (sprig-answer--options))
         (label (seq-some (lambda (option)
                            (let ((l (sprig-review--option-label option)))
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
    (sprig-answer--take (sprig-review--option-label option))))

(defun sprig-answer--take (label)
  "Take LABEL for the question on screen: toggling it, or settling on it."
  (if (sprig-review--multi-select-p (sprig-answer--question))
      (progn
        (setq sprig-answer--picked
              (if (member label sprig-answer--picked)
                  (remove label sprig-answer--picked)
                (append sprig-answer--picked (list label))))
        (sprig-answer--render))
    (sprig-answer--settle label)))

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
        (length (sprig-review--dialog-questions sprig-answer--dialog)))
  (sprig-answer--send))

;;;; The c transient

(transient-define-prefix sprig-review-dispatch ()
  "Steer the conversation from the review buffer."
  [["Message"
    ("c" "compose & send" sprig-review-message)
    ("y" "yes / accept" sprig-review-accept)
    ("n" "no / decline" sprig-review-decline)
    ("p" "compose in plan mode" sprig-review-message-plan)
    ("s" "steer the running turn" sprig-review-steer)
    ("r" "resend last turn" sprig-review-retry)
    ("i" "interrupt turn" sprig-review-interrupt)]
   ["Changes (agent instructions)"
    ("k" "reject / undo" sprig-review-reject)
    ("C" "commit" sprig-review-commit)
    ("x" "run command / fenced block" sprig-review-run)]])

;;;; Verb keybindings

(define-key sprig-review-mode-map (kbd "SPC") #'sprig-review-toggle-mark)
(define-key sprig-review-mode-map (kbd "m")   #'sprig-review-toggle-mark)
(define-key sprig-review-mode-map (kbd "U")   #'sprig-review-unmark-all)
(define-key sprig-review-mode-map (kbd "c")   #'sprig-review-dispatch)
(define-key sprig-review-mode-map (kbd "k")   #'sprig-review-reject)
;; `a' answers the agent's structured dialog; the yes/no reply to a plain
;; prose question is `c y' / `c n' (not top-level: `n' is section motion).
;; Commit is `C'.
(define-key sprig-review-mode-map (kbd "a")   #'sprig-review-answer-dispatch)
(define-key sprig-review-mode-map (kbd "C")   #'sprig-review-commit)
(define-key sprig-review-mode-map (kbd "x")   #'sprig-review-run)
(define-key sprig-review-mode-map (kbd "RET") #'sprig-review-visit)
(define-key sprig-review-mode-map (kbd "t")   #'sprig-review-set-title)

(provide 'sprig-review-mode)
;;; sprig-review-mode.el ends here
