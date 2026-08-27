;;; sprig-quiz.el --- Quiz yourself on the change you just accepted -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; `Q' in the changeset review: a short worksheet about the change you are
;; reviewing, which you answer from memory before anything answers back.
;;
;; The problem it exists for is the one DESIGN.md names under *Authoring by
;; hand*: rubber-stamping is how understanding erodes.  Hand-authoring
;; fights that at the moment of writing, and the review fights it at the
;; moment of reading, but neither catches the case where you reviewed
;; carefully at the time and the model has since quietly gone.  Only being
;; asked catches that, because retrieval is the one thing you cannot fake to
;; yourself.
;;
;; Three decisions carry the whole design.
;;
;; *The answer must be entailed by the code, not contained in it.*  A
;; question whose answer can be found by looking at any single location
;; tests whether you can read, which was never in doubt.  The generation
;; prompt is built almost entirely out of ruling those out, because trivia
;; is what a model reaches for by default and one bad quiz discredits the
;; practice for good.
;;
;; *You are compared against a cold reader, not against the author.*  A
;; `--resume' fork carries the conversation that wrote the code, so it is not
;; answering from the code but from having written it: it cannot be wrong in
;; the interesting way, and disagreeing with it is disagreeing with an
;; authority rather than a peer.  So the peer is a second one-shot with no
;; history at all, holding exactly what you hold.  The author answers too,
;; folded away, as the adjudicator you unfold when the two of you differ.
;; `c r' already spawns a cold subagent for the same reason.
;;
;; The four cases that falls into are the point of the feature:
;;
;;   you right, cold right   fine
;;   you wrong, cold right   your gap; the code says it and you did not read it
;;   you right, cold wrong   the code is misleading
;;   you wrong, cold wrong   the intent is not recoverable from the code
;;
;; The last one is a documentation gap, located precisely, found rather than
;; guessed at.
;;
;; *It aims at what is consequential, not at what you skipped.*  An earlier
;; cut weighted the questions towards the files `sprig-review--expanded' said
;; you never unfolded.  That was wrong three times over.  The signal is weaker
;; than it looks, since it only knows this buffer: you may have read the file
;; in your editor, in the transcript's inline diff, or written it yourself.
;; Skipping is often correct, so aiming there aims at the generated file and
;; the lockfile, which is the opposite of spending attention where it matters.
;; And it is Goodhart: once the quiz targets unopened files you unfold files to
;; avoid being asked about them, which corrupts the one attention signal the
;; review had.  It also bought nothing, because 300 lines you waved through
;; fail their questions whether or not the selector knew you waved them
;; through.
;;
;; *The count is a ceiling that scales with the change, not a quota.*  Three
;; questions is a thorough pass over forty lines and a spot check on two
;; thousand.  But line count is a poor proxy for how much there is to
;; understand: a thousand-line rename holds one idea and a forty-line change
;; to a lock ordering holds several.  So size sets the *cap* and the generator
;; is told outright to ask fewer where there is less to ask about.
;;
;; *It is never a score, and never unprompted.*  No grade, no history, no
;; streak, nothing on a timer.  An agent grading a human is the exact posture
;; that erodes ownership, dressed up as the cure for it.
;;
;; Everything rides the side-question transport (`sprig--btw-command'), so a
;; quiz writes no log, opens no turn, and leaves the session untouched.  Your
;; homework does not belong in the record the next agent reads.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'sprig-change)
(require 'sprig-review)

(declare-function sprig--btw-command "sprig" (id dir remote-host))
(declare-function sprig--btw-send "sprig" (proc text))
(declare-function sprig--fork-spawn "sprig"
                  (command dir remote-host buffer name sentinel))
(declare-function sprig--wrap-command "sprig" (args dir remote-host))
(declare-function sprig--directory "sprig" ())
(declare-function sprig-session--fontify-markdown "sprig-session-mode" (text))
(declare-function sprig-session--compose "sprig-session-mode"
                  (target context &optional plan queue format label))

(defvar sprig-program)
(defvar sprig-model)
(defvar sprig-system-prompt)
(defvar sprig-extra-args)
(defvar sprig--sink)
(defvar sprig--session-id)

;;;; Options

(defcustom sprig-quiz-questions '(3 . 10)
  "How many questions a quiz asks, as (FEWEST . MOST).
The ceiling scales with the size of the change (see
`sprig-quiz-lines-per-question'), because three questions is a thorough
pass over a forty-line change and a spot check on a two-thousand-line one,
and passing a spot check is worth knowing you have not done.

MOST binds only where a change genuinely holds that many distinct things
worth understanding, because the generator is told to ask fewer where there
is less to ask about and does (a 150-file rename is asked one question, not
its permitted three).  So a generous ceiling costs nothing on an ordinary
change and buys a real pass over a large one, and question count costs no
extra round trips either: each fork answers the whole set in one call.

A long worksheet is answered in the sittings you have.  `C-c C-c' hands in
only the questions you have actually written under, leaves the blanks
alone, and can be run again for them later, so nothing is spent unattempted."
  :type '(cons integer integer)
  :group 'sprig)

(defcustom sprig-quiz-lines-per-question 100
  "Changed diff lines that earn one more question, up to the ceiling.
A crude measure, and deliberately only ever a *ceiling*: line count is a
poor proxy for how much there is to understand, since a thousand-line
mechanical rename holds one idea and a forty-line change to a lock
ordering holds several.  Scaling the cap on size and letting the generator
ask fewer where there is less to ask about gets the useful half of scaling
without asking twelve questions about a rename.

The default is set against the sizes real changes come in, so that the
band is reached rather than admired: with `sprig-quiz-questions' at
\(3 . 10) a six-hundred-line change earns seven and a fourteen-hundred-line
one the lot.  Raise it and the floor swallows everything an ordinary review
contains, which is a constant wearing a formula\='s clothes."
  :type 'integer
  :group 'sprig)

(defcustom sprig-quiz-cold-read t
  "Whether a cold reader answers alongside you.
The cold reader is a one-shot with no conversation history, answering only
from the working tree, so it holds exactly what you hold and its answer is
a peer's rather than the author's.  It is what makes the comparison mean
anything; nil saves a process and leaves you with the author alone, which
reads much more like being marked."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-quiz-max-diff-lines 1500
  "Most diff lines handed to the quiz forks.
A large changeset would otherwise blow the prompt.  What is dropped is
reported rather than silently truncated, since a quiz drawn from half a
change should not read as a quiz on the whole of it."
  :type 'integer
  :group 'sprig)

;;;; Faces

(defface sprig-quiz-question '((t :inherit magit-section-heading))
  "Face for a quiz question."
  :group 'sprig)

(defface sprig-quiz-answer '((t :inherit sprig-session-user :extend t))
  "Face for your own answer: the same tint that marks your turns.
Tinted is you, untinted is an agent, exactly as in the session buffer."
  :group 'sprig)

(defface sprig-quiz-source '((t :inherit font-lock-comment-face))
  "Face for the label naming who an answer came from."
  :group 'sprig)

(defface sprig-quiz-finding '((t :inherit warning))
  "Face for the label on a question flagged as a finding."
  :group 'sprig)

(defface sprig-quiz-hint '((t :inherit shadow :slant italic))
  "Face for the worksheet's own instructions."
  :group 'sprig)

;;;; Buffer-local state

(defvar-local sprig-quiz--questions nil
  "The questions on the worksheet, as an alist of (N . TEXT).")

(defvar-local sprig-quiz--diff nil
  "The diff text the questions were drawn from, for the answering forks.")

(defvar-local sprig-quiz--id nil
  "Session id the change came from, or nil when the session never started.")

(defvar-local sprig-quiz--dir nil
  "Working directory the forks run in, on the session host.")

(defvar-local sprig-quiz--remote nil
  "SSH host the forks run on, or nil for local.")

(defvar-local sprig-quiz--slots nil
  "Reserved regions awaiting an answer.
Each is a plist (:n N :source cold|author :beg MARKER :end MARKER), filled
in as each fork lands.  Reserving them at submit time rather than appending
on arrival is what keeps the cold read above the author's answer however
the two races.")

(defvar-local sprig-quiz--pending 0
  "How many answering forks are still out.")

(defvar-local sprig-quiz--answers nil
  "What you wrote, as an alist of (N . TEXT), snapshotted on hand-in.
Kept rather than re-read, because once the answers land the question's body
holds them too and there is no longer a boundary to read your own back
from.  It is frozen at hand-in anyway, so a snapshot is the truth.")

(defvar-local sprig-quiz--findings nil
  "Questions flagged as findings, as plists (:n N :beg MARKER :end MARKER).
BEG and END bracket the editable note you wrote about what the exchange
showed.  A quiz that only tells you what you did not know is half of it:
often the answer is that the code does not say, and that is a defect in
the code rather than in the reader.")

(defvar-local sprig-quiz--submitted nil
  "Question numbers already handed in, so a resubmit only takes the rest.
A worksheet is a buffer, not a form: a long one is answered in the sittings
you have, and a question is spent the moment its answers appear, so
handing in what you have written must not spend what you have not.")

;;;; The fork transport
;;
;; Two shapes of one-shot.  The author is a side-question fork of the
;; session, so it carries the conversation that produced the change; the
;; cold reader is the same one-shot with no `--resume' at all, so it holds
;; only the working tree.  Neither persists a session.

(defvar-local sprig-quiz--raw ""
  "Assistant text collected from a quiz fork, assembled on `done'.")

(defvar-local sprig-quiz--callback nil
  "One-argument function run with the fork's whole answer, or nil on failure.")

(defun sprig-quiz--cold-args ()
  "The `claude' argument list for a cold read: a one-shot with no history.
No `--resume' and no `--fork-session', so nothing of the conversation
reaches it; `--no-session-persistence' keeps it out of the log the way a
side question is."
  (append
   (list "-p"
         "--input-format" "stream-json"
         "--output-format" "stream-json"
         "--include-partial-messages"
         "--verbose"
         "--no-session-persistence")
   (when sprig-model (list "--model" sprig-model))
   (when sprig-system-prompt
     (list "--append-system-prompt" sprig-system-prompt))
   sprig-extra-args))

(defun sprig-quiz--cold-command (dir remote-host)
  "Full command for a cold read in DIR on REMOTE-HOST."
  (sprig--wrap-command (cons sprig-program (sprig-quiz--cold-args))
                       dir remote-host))

(defun sprig-quiz--consume (event)
  "Sink for a quiz fork: collect its answer, then hand it to the callback.
Runs in the fork's hidden buffer.  The call is deferred with a zero timer so
the buffer edit it makes runs at top level rather than inside the process
filter."
  (pcase event
    (`(text ,s) (setq sprig-quiz--raw (concat sprig-quiz--raw s)))
    (`(done ,_ ,err)
     (let ((cb sprig-quiz--callback)
           (text (and (not err) sprig-quiz--raw)))
       (setq sprig-quiz--callback nil)
       (when cb (run-at-time 0 nil cb text))))
    (`(error ,_)
     (let ((cb sprig-quiz--callback))
       (setq sprig-quiz--callback nil)
       (when cb (run-at-time 0 nil cb nil))))
    (_ nil)))

(defun sprig-quiz--sentinel (proc _event)
  "Tear down quiz fork PROC and its stderr when it ends."
  (when (memq (process-status proc) '(exit signal))
    (let ((stderr (process-get proc :stderr-proc)))
      (when (process-live-p stderr) (delete-process stderr)))
    (let ((buf (process-get proc :conv-buffer)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(defun sprig-quiz--ask (command dir remote name prompt callback)
  "Run a quiz one-shot NAME with COMMAND in DIR on REMOTE, asking PROMPT.
CALLBACK gets the fork's whole answer text, or nil when it failed.  Unlike
the retitle fork there is no one-at-a-time guard: a quiz fires two of these
at once on purpose, and each owns its own buffer and callback."
  (let ((buffer (generate-new-buffer (format " *%s*" name))))
    (with-current-buffer buffer
      (setq-local sprig--sink #'sprig-quiz--consume)
      (setq-local sprig-quiz--raw "")
      (setq-local sprig-quiz--callback callback))
    (let ((proc (sprig--fork-spawn command dir remote buffer name
                                   #'sprig-quiz--sentinel)))
      (sprig--btw-send proc prompt)
      proc)))

;;;; The diff the questions are drawn from

(defun sprig-quiz--changed-lines (changes)
  "Count the added and removed lines across CHANGES.
Context lines do not count: they are what the change is written against,
not the change."
  (let ((n 0))
    (dolist (c changes n)
      (dolist (u (plist-get c :unified))
        (dolist (l (plist-get u :lines))
          (when (memq (plist-get l :kind) '(add del)) (cl-incf n)))))))

(defun sprig-quiz--count (changes)
  "How many questions to allow for CHANGES, within `sprig-quiz-questions'."
  (let ((fewest (car sprig-quiz-questions))
        (most (cdr sprig-quiz-questions))
        (lines (sprig-quiz--changed-lines changes)))
    (max fewest
         (min most (ceiling lines (max 1 sprig-quiz-lines-per-question))))))

(defun sprig-quiz--diff-text (changes)
  "Render CHANGES back to diff text for a prompt.
Capped at `sprig-quiz-max-diff-lines', with what was dropped stated in the
text rather than silently cut."
  (let ((lines nil) (count 0) (dropped 0))
    (cl-flet ((emit (s) (if (< count sprig-quiz-max-diff-lines)
                            (progn (push s lines) (cl-incf count))
                          (cl-incf dropped))))
      (dolist (c changes)
        (emit (format "--- %s" (plist-get c :file)))
        (dolist (u (plist-get c :unified))
          (emit (format "@@ -%d,%d +%d,%d @@%s"
                        (plist-get u :old-start) (plist-get u :old-count)
                        (plist-get u :new-start) (plist-get u :new-count)
                        (if (plist-get u :heading)
                            (concat " " (plist-get u :heading)) "")))
          (dolist (l (plist-get u :lines))
            (emit (concat (pcase (plist-get l :kind)
                            ('add "+") ('del "-") (_ " "))
                          (plist-get l :text)))))
        (emit "")))
    (concat (string-join (nreverse lines) "\n")
            (when (> dropped 0)
              (format "\n[%d further diff lines omitted; ask only about \
what is shown]" dropped)))))

;;;; Prompts

(defun sprig-quiz--generate-prompt (diff n)
  "Ask for at most N questions about DIFF."
  (concat
   (format "Set a short comprehension quiz for the person who just reviewed \
the changeset below. You are finding out whether they understand the change, \
not whether they can read.

Ask AT MOST %d questions. That is a ceiling, not a quota: ask one question per \
distinct thing in this change that is worth understanding, and stop. A large \
mechanical change (a rename, a reformat, generated output) may honestly \
deserve one question, and padding it out to %d with weaker ones is worse than \
asking one good one.

Aim at whatever is most consequential: the decisions someone will have to \
live with, the parts that are load-bearing, the places a later change is \
most likely to go wrong. Not the parts that are merely large.

Every question must satisfy all of:

- Its answer is ENTAILED by the code, not CONTAINED in it. If it can be \
answered by looking at any single location, it is worthless. Ask about \
consequences, invariants, blast radius, rejected alternatives, and where a \
described symptom would come from.
- It is answerable in two or three sentences by someone who understands the \
change, with the code in front of them and without running anything.
- It is independent of the others: no question may hint at another's answer.
- It is about THIS changeset, not general programming knowledge.

Shapes that work:
  \"What breaks if X were a Y instead?\"
  \"Callers are seeing Z. Where do you look first, and why?\"
  \"You now need to add W. Which files do you touch, and which is the hard one?\"
  \"If this line were deleted, what fails, and does it fail loudly or quietly?\"

Shapes to never ask:
  \"What does function F return?\"  \"Which file defines T?\"  \"How many \
arguments does F take?\"

Reply with the questions alone, as markdown headings numbered from 1, and \
nothing else. No preamble, no answers, no commentary.

## 1. <question>
## 2. <question>

The changeset:

" n n)
   diff))

(defun sprig-quiz--questions-text (questions)
  "Render QUESTIONS back to the numbered headings a fork is asked to mirror."
  (mapconcat (lambda (q) (format "## %d. %s" (car q) (cdr q)))
             questions "\n"))

(defun sprig-quiz--cold-prompt (questions diff)
  "Ask a cold reader QUESTIONS about the tree, with DIFF for orientation."
  (concat
   "Answer these questions about this repository.

You are reading the code cold. Answer only from the code as it stands, not \
from any account of why it was written; read whatever files you need. Two or \
three sentences each. If the code does not settle it, say so plainly rather \
than guessing: \"the code does not say\" is a real answer and a useful one.

Reply with the same numbered headings and nothing else. Put nothing after \
the number on the heading line, and do not restate the question.

"
   (sprig-quiz--questions-text questions)
   "\n\nFor orientation, the changeset under review:\n\n"
   diff))

(defun sprig-quiz--author-prompt (questions)
  "Ask the author fork QUESTIONS about the change it just made."
  (concat
   "Answer these questions about the change you just made.

Answer from what you actually intended: the reasons behind the design, the \
alternatives you rejected, and what would break. Two or three sentences each. \
Where the reason is not recoverable from the code itself, say so, because \
that is the most useful thing you can report.

Do not edit any files. Reply with the same numbered headings and nothing \
else. Put nothing after the number on the heading line, and do not restate \
the question.

"
   (sprig-quiz--questions-text questions)))

;;;; Parsing the numbered headings

(defun sprig-quiz--split (text)
  "Split TEXT into an alist of (N . BODY) on its `## N.' headings.
The one structured contract in either direction, and deliberately loose:
a stray preamble before the first heading is dropped, and any heading level
or trailing punctuation is accepted."
  (let ((out nil) (n nil) (beg nil))
    (with-temp-buffer
      (insert (or text ""))
      (goto-char (point-min))
      (while (re-search-forward
              "^[ \t]*#\\{1,4\\}[ \t]*\\([0-9]+\\)[.):]?[ \t]*" nil t)
        ;; Take everything out of the match data before anything else runs:
        ;; `string-trim' matches internally and would leave group 1 nil, so
        ;; reading the number after the push loses it.
        (let ((this (string-to-number (match-string 1)))
              (head (match-beginning 0))
              (body (point)))
          (when n
            (push (cons n (string-trim (buffer-substring beg head))) out))
          (setq n this beg body)))
      (when n
        (push (cons n (string-trim (buffer-substring beg (point-max)))) out)))
    (nreverse out)))

;;;; The worksheet buffer

(defvar sprig-quiz-mode-map (make-sparse-keymap)
  "Keymap for `sprig-quiz-mode'.
Bound below, for the reason `sprig-review-mode-map' gives.")

(define-key sprig-quiz-mode-map (kbd "C-c C-c") #'sprig-quiz-submit)
(define-key sprig-quiz-mode-map (kbd "C-c C-k") #'sprig-quiz-abort)
(define-key sprig-quiz-mode-map (kbd "TAB")     #'sprig-quiz-toggle)
(define-key sprig-quiz-mode-map (kbd "C-c C-f") #'sprig-quiz-flag)
(define-key sprig-quiz-mode-map (kbd "C-c C-p") #'sprig-quiz-publish)

(define-derived-mode sprig-quiz-mode text-mode "sprig-quiz"
  "Worksheet for a quiz about the changeset under review.
Questions are read-only; you type in the gap under each and hand in what
you have written with \\[sprig-quiz-submit], which leaves the blanks alone
and can be run again for them.  An answer freezes once handed in, and
\\[sprig-quiz-toggle] unfolds the author's.

Where the exchange says something about the *code* rather than about you,
\\[sprig-quiz-flag] flags it and \\[sprig-quiz-publish] hands the set back
to the agent in one turn."
  ;; Render the forks' markdown the way `*sprig-btw*' does: its markup
  ;; carries `invisible markdown-markup' and its colours ride `font-lock-face'.
  (add-to-invisibility-spec 'markdown-markup)
  (setq-local char-property-alias-alist '((face font-lock-face)))
  (setq-local word-wrap t)
  (setq-local truncate-lines nil))

(defun sprig-quiz--fontify (text)
  "Fontify TEXT as markdown when the session buffer's helper is loaded."
  (if (fboundp 'sprig-session--fontify-markdown)
      (sprig-session--fontify-markdown text)
    text))

(defun sprig-quiz--render (questions)
  "Draw the worksheet for QUESTIONS into the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize
             (concat "Answer from memory, in the gap under each question.\n"
                     "C-c C-c hands in what you have written and asks for "
                     "the other answers; blanks are\nleft alone, so you can "
                     "run it again for them later.  C-c C-k walks away.\n"
                     "Nothing is sent until you do, and nothing is written "
                     "to the session log.\n"
                     "C-c C-f flags a question the quiz found something out "
                     "through; C-c C-p sends\nthose findings back to the "
                     "agent in one turn.\n\n")
             'face 'sprig-quiz-hint 'read-only t))
    (dolist (q questions)
      (let ((beg (point)))
        (insert (format "## %d. %s" (car q) (cdr q)))
        (add-text-properties beg (point)
                             '(face sprig-quiz-question read-only t)))
      (insert "\n\n\n"))
    (goto-char (point-min))
    (when (re-search-forward "^## [0-9]+\\." nil t)
      (forward-line 1))))

;;;; Handing it in

(defun sprig-quiz--question-bounds (n)
  "Return (BEG . END) of the body under question N, or nil.
BEG is just past the heading line, END the start of the next heading or the
end of the buffer, so the body is everything you wrote for that question."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (format "^## %d\\." n) nil t)
      (forward-line 1)
      (let ((beg (point))
            (end (if (re-search-forward "^## [0-9]+\\." nil t)
                     (match-beginning 0)
                   (point-max))))
        (cons beg end)))))

(defun sprig-quiz--reserve (n source label)
  "Insert a waiting slot for SOURCE under question N, headed by LABEL.
Returns the slot plist.  Reserving before either fork lands is what fixes
the order on screen: the cold read sits above the author's answer whichever
of the two arrives first, because the cold slot was already there when the
author's was inserted after it."
  (when-let* ((bounds (sprig-quiz--question-bounds n)))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (cdr bounds))
        ;; The last question's body ends wherever you stopped typing, so this
        ;; can be mid-line; a slot label welded to the end of your own answer
        ;; reads as part of it.
        (unless (bolp) (insert "\n\n"))
        (let ((fold (eq source 'author))
              arrow)
          (insert (propertize "  " 'read-only t))
          (when fold
            (setq arrow (copy-marker (point) nil))
            (insert (propertize "\u25b8 " 'face 'sprig-quiz-source
                                'read-only t)))
          (insert (propertize (concat label "\n")
                              'face 'sprig-quiz-source 'read-only t))
          (let* ((beg (copy-marker (point) nil)))
            (insert "    \u2026\n\n")
            ;; Both markers hold their ground on an insertion at their own
            ;; position: the author's slot goes in at exactly where the cold
            ;; slot ends, and an advancing end marker would swallow it whole
            ;; the moment the cold read landed.
            (list :n n :source source :label label
                  :arrow arrow :beg beg
                  :end (copy-marker (point) nil))))))))

(defun sprig-quiz--answered-p (n)
  "Whether you have written anything under question N."
  (when-let* ((b (sprig-quiz--question-bounds n)))
    (not (string-blank-p (buffer-substring-no-properties (car b) (cdr b))))))

(defun sprig-quiz--outstanding ()
  "The questions answered but not yet handed in, in order."
  (seq-filter (lambda (q) (and (sprig-quiz--answered-p (car q))
                               (not (memq (car q) sprig-quiz--submitted))))
              sprig-quiz--questions))

(defun sprig-quiz--tint-answers (questions)
  "Tint what you wrote under each question as yours."
  (let ((inhibit-read-only t))
    (dolist (q questions)
      (when-let* ((b (sprig-quiz--question-bounds (car q))))
        (push (cons (car q) (string-trim (buffer-substring-no-properties
                                          (car b) (cdr b))))
              sprig-quiz--answers)
        (add-face-text-property (car b) (cdr b) 'sprig-quiz-answer)
        ;; Handed in is handed in: freeze this answer, but leave the rest of
        ;; the buffer editable so the blanks can still be filled.
        (put-text-property (car b) (cdr b) 'read-only t)))))

(defun sprig-quiz--fill (slot text)
  "Put TEXT into SLOT, folding it away when it is the author's."
  (when (and (markerp (plist-get slot :beg))
             (marker-buffer (plist-get slot :beg)))
    (let ((inhibit-read-only t)
          (beg (plist-get slot :beg))
          (end (plist-get slot :end)))
      (save-excursion
        (delete-region beg end)
        (goto-char beg)
        (let ((from (point)))
          (insert (replace-regexp-in-string
                   "^" "    " (sprig-quiz--fontify (string-trim text)))
                  "\n\n")
          ;; The buffer stays editable for the still-blank questions, so an
          ;; answer has to protect itself rather than lean on a global freeze.
          (put-text-property from (point) 'read-only t)
          ;; END does not advance on insertion (see `sprig-quiz--reserve'), so
          ;; the delete-and-insert above left it sitting on BEG.  Put it back
          ;; on the end of what was written, or the slot reads back empty when
          ;; a finding quotes it.
          (set-marker end (point)))
        (when (eq (plist-get slot :source) 'author)
          (let ((ov (make-overlay beg (point))))
            (overlay-put ov 'invisible t)
            (when-let* ((arrow (plist-get slot :arrow)))
              ;; The fold handle is the arrow itself, so the toggle finds its
              ;; overlay from the line and never has to search for it.
              (put-text-property arrow (1+ arrow) 'sprig-quiz-fold ov))))))))

(defun sprig-quiz--fold-at-point ()
  "The fold overlay handled by the line point is on, or nil.
The handle is the arrow itself rather than the line's first character, so
the line is scanned for it."
  (let ((pos (line-beginning-position))
        (end (line-end-position))
        (ov nil))
    (while (and (< pos end) (not ov))
      (setq ov (get-text-property pos 'sprig-quiz-fold)
            pos (1+ pos)))
    ov))

(defun sprig-quiz-toggle ()
  "Unfold or fold the author's answer on the line at point (TAB).
The arrow carries its own overlay, so the arrow is both the handle and the
lookup, and flipping it uses `subst-char-in-region\=' rather than a
delete-and-reinsert, which would drag the slot markers off their text."
  (interactive)
  (let ((ov (sprig-quiz--fold-at-point)))
    (unless (overlayp ov)
      (user-error "Nothing folded here"))
    (let* ((hidden (overlay-get ov 'invisible))
           (inhibit-read-only t)
           (pos (save-excursion
                  (goto-char (line-beginning-position))
                  (and (re-search-forward "[\u25b8\u25be]" (line-end-position) t)
                       (1- (point))))))
      (overlay-put ov 'invisible (not hidden))
      (when pos
        (subst-char-in-region pos (1+ pos)
                              (if hidden ?\u25b8 ?\u25be)
                              (if hidden ?\u25be ?\u25b8)
                              t)))))

(defun sprig-quiz--strip-echo (body question)
  "Drop QUESTION from the head of BODY when the answer opened by repeating it.
Asked for a numbered heading, a model will often restate the question on it
or just under it; left in, every answer is half quotation and the two sit
under a heading that already says it."
  (let* ((body (or body ""))
         (q (string-trim (or question "")))
         (lines (split-string body "\n"))
         (first (string-trim (or (car lines) ""))))
    (if (and (not (string-empty-p q)) (equal first q))
        (string-trim (string-join (cdr lines) "\n"))
      body)))

(defun sprig-quiz--landed (n source text)
  "Fill the slot for SOURCE under question N from the fork's whole TEXT."
  (let* ((split (sprig-quiz--split text))
         (body (or (alist-get n split)
                   (and (= 1 (length sprig-quiz--questions))
                        (string-trim (or text "")))))
         (body (and body (sprig-quiz--strip-echo
                          body (alist-get n sprig-quiz--questions))))
         (slot (seq-find (lambda (s) (and (= (plist-get s :n) n)
                                          (eq (plist-get s :source) source)))
                         sprig-quiz--slots)))
    (when slot
      (sprig-quiz--fill slot (or body "(no answer for this question)")))))

(defun sprig-quiz--receive (source text asked)
  "Spread a fork's whole answer TEXT from SOURCE over the ASKED questions."
  (dolist (q asked)
    (sprig-quiz--landed (car q) source (or text "(this one failed)")))
  (cl-decf sprig-quiz--pending)
  (when (<= sprig-quiz--pending 0)
    (message "sprig: answered.  TAB on a ▸ line for what the author says")))

(defun sprig-quiz-submit ()
  "Hand in the questions you have answered, and ask the other two (C-c C-c).
Fires both forks at once and reserves their slots first, so the cold read
sits above the author's answer however the two race.  Neither fork is shown
what you wrote: they answer independently, or the comparison is not one.

A question is spent the moment its answers appear, so only the questions
you have actually written under are handed in.  Blanks are left alone and
`C-c C-c' can be run again for them, which is what makes a long worksheet
answerable across two sittings rather than a form you fill or waste."
  (interactive)
  (unless (derived-mode-p 'sprig-quiz-mode)
    (user-error "Not in a quiz buffer"))
  (let ((asked (sprig-quiz--outstanding)))
    (unless asked
      (user-error (if sprig-quiz--submitted
                      "Nothing new answered; write under a blank question first"
                    "Nothing answered yet; write under a question first")))
    (setq sprig-quiz--submitted
          (append sprig-quiz--submitted (mapcar #'car asked)))
    (sprig-quiz--tint-answers asked)
    ;; Reserve every slot before anything can land in one.
    ;; Cold first, then the author: each is inserted at the end of the
    ;; question's body, so the one reserved first ends up above.
    (dolist (q asked)
      (when sprig-quiz-cold-read
        (push (sprig-quiz--reserve (car q) 'cold "cold read")
              sprig-quiz--slots))
      (when sprig-quiz--id
        (push (sprig-quiz--reserve (car q) 'author "what the author says")
              sprig-quiz--slots)))
    (setq sprig-quiz--slots (delq nil sprig-quiz--slots))
    (let ((buf (current-buffer))
          (dir sprig-quiz--dir)
          (remote sprig-quiz--remote)
          (id sprig-quiz--id)
          (diff sprig-quiz--diff))
      (cl-flet ((receive (source)
                  (lambda (text)
                    (when (buffer-live-p buf)
                      (with-current-buffer buf
                        ;; Only this batch's questions: a later batch's slots
                        ;; are not this fork's to fill, and it was never asked
                        ;; about them.
                        (sprig-quiz--receive source text asked))))))
        (when sprig-quiz-cold-read
          (cl-incf sprig-quiz--pending)
          (sprig-quiz--ask (sprig-quiz--cold-command dir remote)
                           dir remote "sprig-quiz-cold"
                           (sprig-quiz--cold-prompt asked diff)
                           (receive 'cold)))
        (when id
          (cl-incf sprig-quiz--pending)
          (sprig-quiz--ask (sprig--btw-command id dir remote)
                           dir remote "sprig-quiz-author"
                           (sprig-quiz--author-prompt asked)
                           (receive 'author)))))
    (message "sprig: %s"
             (let ((left (- (length sprig-quiz--questions)
                            (length sprig-quiz--submitted))))
               (concat
                (format "handed in %d" (length asked))
                (if (> left 0) (format ", %d still blank" left) "")
                (cond ((and sprig-quiz-cold-read sprig-quiz--id)
                       "; a cold reader and the author are answering…")
                      (sprig-quiz-cold-read "; a cold reader is answering…")
                      (sprig-quiz--id "; the author is answering…")
                      ;; No peer and no author: the retrieval still happened,
                      ;; which was most of the value, but nothing is coming
                      ;; back and the line must not name someone who is not.
                      (t "; nothing to compare against")))))))

;;;; Findings: handing back what the quiz found out about the code
;;
;; The four-way outcome the comparison produces is not symmetric.  You wrong
;; and the cold reader right is your gap and nobody else's business.  But you
;; right and the cold reader wrong says the code misleads, and both of you
;; wrong says the intent is not recoverable from what is written: those are
;; defects, located precisely, and the whole exchange that found them is the
;; evidence.  Flagging one and publishing the set is the review's own
;; drafts-then-publish gesture, for the same reason: a finding is worth
;; sending as part of a considered set rather than one blurted message at a
;; time.

(defun sprig-quiz--question-at-point ()
  "The number of the question point is under, or nil."
  (save-excursion
    (end-of-line)
    (when (re-search-backward "^## \\([0-9]+\\)\\." nil t)
      (string-to-number (match-string 1)))))

(defun sprig-quiz--finding (n)
  "The finding flagged on question N, or nil."
  (seq-find (lambda (f) (= (plist-get f :n) n)) sprig-quiz--findings))

(defun sprig-quiz-flag ()
  "Flag the question at point as a finding, or unflag it (C-c C-f).
Opens an editable note under the exchange for what it showed, which is the
part the agent cannot work out for itself: the question and the answers say
where the gap is, and you say what it means."
  (interactive)
  (unless (derived-mode-p 'sprig-quiz-mode)
    (user-error "Not in a quiz buffer"))
  (let* ((n (or (sprig-quiz--question-at-point)
                (user-error "Point is not under a question")))
         (found (sprig-quiz--finding n))
         (inhibit-read-only t))
    (if found
        (progn
          (delete-region (plist-get found :label) (plist-get found :end))
          (setq sprig-quiz--findings (delq found sprig-quiz--findings))
          (message "sprig: question %d is no longer a finding" n))
      (when-let* ((bounds (sprig-quiz--question-bounds n)))
        (save-excursion
          (goto-char (cdr bounds))
          (unless (bolp) (insert "\n\n"))
          (let ((label (copy-marker (point) nil)))
            (insert (propertize "  \u2691 what this shows\n"
                                'face 'sprig-quiz-finding 'read-only t))
            (let ((beg (copy-marker (point) nil)))
              (insert "    \n\n")
              (push (list :n n :label label :beg beg
                          :end (copy-marker (point) nil))
                    sprig-quiz--findings))))
        ;; Land in the note, since flagging is the start of writing one.
        (goto-char (+ 4 (plist-get (sprig-quiz--finding n) :beg)))
        (message "sprig: question %d flagged; say what it shows, then C-c C-p"
                 n)))))

(defun sprig-quiz--note (finding)
  "The note written under FINDING, trimmed, or nil when it is blank."
  (let ((text (string-trim (buffer-substring-no-properties
                            (plist-get finding :beg)
                            (plist-get finding :end)))))
    (unless (string-empty-p text) text)))

(defun sprig-quiz--slot-text (n source)
  "What SOURCE answered under question N, un-indented, or nil."
  (when-let* ((slot (seq-find (lambda (s)
                                (and (= (plist-get s :n) n)
                                     (eq (plist-get s :source) source)))
                              sprig-quiz--slots)))
    (let ((text (string-trim
                 (replace-regexp-in-string
                  "^    " ""
                  (buffer-substring-no-properties (plist-get slot :beg)
                                                  (plist-get slot :end))))))
      (unless (or (string-empty-p text) (equal text "\u2026")) text))))

(defun sprig-quiz--findings-text (findings)
  "Render FINDINGS as the body of a message back to the agent.
Carries the whole exchange, because what the gap is cannot be read off the
note alone.  The author's own answer is left out: the session being sent to
already has it, and quoting an agent to itself is noise."
  (mapconcat
   (lambda (f)
     (let* ((n (plist-get f :n))
            (cold (sprig-quiz--slot-text n 'cold)))
       (string-join
        (delq nil
              (list (format "### %s" (alist-get n sprig-quiz--questions))
                    (when-let* ((mine (alist-get n sprig-quiz--answers)))
                      (format "What I said:\n\n%s" mine))
                    (when cold
                      (format "What a cold read of the code said:\n\n%s"
                              cold))
                    (when-let* ((note (sprig-quiz--note f)))
                      (format "What I take from that:\n\n%s" note))))
        "\n\n")))
   (reverse findings) "\n\n"))

(defun sprig-quiz--publish-format (text body)
  "Frame the published findings BODY under the covering note TEXT."
  (concat
   "I ran a comprehension quiz on this change and it turned up the \
following. Each one is a question I got wrong, or answered differently from \
a cold read of the code.\n\n"
   "Where the gap is mine, say so plainly and correct me. Where it is the \
code's, that is a defect: either the intent is not recoverable from what is \
written, or the code actively misleads a careful reader. Fix those rather \
than explaining them to me, and say which of the two each one was.\n\n"
   (if (string-blank-p text) "" (concat text "\n\n"))
   body))

(defun sprig-quiz-publish ()
  "Send the flagged findings back to the session in one turn (C-c C-p).
Composed as a set, the way a review publishes its drafts: a finding is
worth handing over alongside the others rather than blurted one message at
a time."
  (interactive)
  (unless (derived-mode-p 'sprig-quiz-mode)
    (user-error "Not in a quiz buffer"))
  (unless sprig-quiz--findings
    (user-error "Nothing flagged; C-c C-f on a question the quiz found \
something out through"))
  (let ((session (seq-find
                  (lambda (b) (with-current-buffer b
                                (and (derived-mode-p 'sprig-session-mode)
                                     (equal sprig--session-id sprig-quiz--id))))
                  (buffer-list))))
    (unless (and sprig-quiz--id session)
      (user-error "No session to send this to"))
    (let ((body (sprig-quiz--findings-text sprig-quiz--findings))
          (n (length sprig-quiz--findings)))
      (sprig-session--compose
       session body nil nil
       (lambda (text ctx) (sprig-quiz--publish-format text ctx))
       (format "%d quiz finding(s)" n)))))

(defun sprig-quiz-abort ()
  "Walk away from the worksheet (C-c C-k).
Nothing was sent, so there is nothing to take back."
  (interactive)
  (quit-window t))

;;;; Entry

(defun sprig-quiz--start (buf questions diff id dir remote)
  "Open the worksheet for QUESTIONS, drawn from DIFF, replacing BUF's contents."
  (with-current-buffer buf
    (sprig-quiz-mode)
    (setq sprig-quiz--questions questions
          sprig-quiz--diff diff
          sprig-quiz--id id
          sprig-quiz--dir dir
          sprig-quiz--remote remote
          sprig-quiz--slots nil
          sprig-quiz--pending 0
          sprig-quiz--submitted nil
          buffer-read-only nil)
    (sprig-quiz--render questions))
  (pop-to-buffer buf)
  (message "sprig: %d questions.  Answer under each, then C-c C-c"
           (length questions)))

;;;###autoload
(defun sprig-quiz ()
  "Quiz yourself on the changeset under review (`Q').
Asks about the most consequential parts of this change, up to a ceiling
that scales with its size (`sprig-quiz-questions'), and opens them as a
worksheet.  You answer from memory; only on `C-c C-c' does a cold reader
answer beside you, with the author's own account folded away as the
adjudicator.

Nothing here is scored, kept, or sent to the session: the whole exchange
rides the side-question transport, which writes no log."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (unless sprig-review--changes
    (user-error "Nothing changed to quiz you on"))
  (let* ((changes sprig-review--changes)
         (n (sprig-quiz--count changes))
         (diff (sprig-quiz--diff-text changes))
         (session sprig-review--session)
         (remote sprig-review--remote)
         (id (and (buffer-live-p session)
                  (buffer-local-value 'sprig--session-id session)))
         (dir (or (and (buffer-live-p session)
                       (with-current-buffer session (sprig--directory)))
                  sprig-review--root))
         (buf (get-buffer-create
               (format "*sprig-quiz: %s*" (buffer-name)))))
    ;; The generator forks the session when there is one, so it can ask about
    ;; intent as well as code; with no session it reads the diff cold.
    (sprig-quiz--ask
     (if id (sprig--btw-command id dir remote)
       (sprig-quiz--cold-command dir remote))
     dir remote "sprig-quiz-set"
     (sprig-quiz--generate-prompt diff n)
     (lambda (text)
       (let ((questions (and text (sprig-quiz--split text))))
         (if (null questions)
             (message "sprig: the quiz came back empty; try again")
           (sprig-quiz--start buf questions diff id dir remote)))))
    (message "sprig: setting up to %d question(s) on %d changed line(s)…"
             n (sprig-quiz--changed-lines changes))))

(provide 'sprig-quiz)
;;; sprig-quiz.el ends here
