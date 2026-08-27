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
;; *It is never a score, and never unprompted.*  No grade, no history, no
;; streak, nothing on a timer.  An agent grading a human is the exact posture
;; that erodes ownership, dressed up as the cure for it.  Questions are
;; weighted towards the files you never unfolded (`sprig-review--expanded'),
;; because "accepted without opening" is the one attention signal the review
;; already keeps and is a strictly correct negative: unfolding is weak
;; evidence that you read a file, but never unfolding is proof that you did
;; not.
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

(defvar sprig-program)
(defvar sprig-model)
(defvar sprig-system-prompt)
(defvar sprig-extra-args)
(defvar sprig--sink)
(defvar sprig--session-id)

;;;; Options

(defcustom sprig-quiz-questions 3
  "How many questions a quiz asks.
Three is enough to find a gap and few enough to answer in one sitting.  A
quiz you do not finish teaches nothing, and the failure mode of this whole
idea is that it becomes a chore."
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

(defvar-local sprig-quiz--submitted nil
  "Non-nil once the worksheet has been handed in.")

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

(defun sprig-quiz--diff-text (changes unread)
  "Render CHANGES back to diff text for a prompt, flagging files in UNREAD.
UNREAD is the files whose section the reader never unfolded; they are marked
so the generator can aim at them.  Capped at `sprig-quiz-max-diff-lines',
with what was dropped stated in the text rather than silently cut."
  (let ((lines nil) (count 0) (dropped 0))
    (cl-flet ((emit (s) (if (< count sprig-quiz-max-diff-lines)
                            (progn (push s lines) (cl-incf count))
                          (cl-incf dropped))))
      (dolist (c changes)
        (let ((file (plist-get c :file)))
          (emit (format "--- %s%s" file
                        (if (member file unread)
                            "   [ACCEPTED WITHOUT OPENING]" "")))
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
          (emit ""))))
    (concat (string-join (nreverse lines) "\n")
            (when (> dropped 0)
              (format "\n[%d further diff lines omitted; ask only about \
what is shown]" dropped)))))

(defun sprig-quiz--unread (changes expanded)
  "Files in CHANGES whose section is not among EXPANDED.
Never unfolding a file is proof it went unread; unfolding one is only weak
evidence that it did not, so the signal is used in this direction alone."
  (seq-remove (lambda (f) (member f expanded))
              (mapcar (lambda (c) (plist-get c :file)) changes)))

;;;; Prompts

(defun sprig-quiz--generate-prompt (diff unread n)
  "Ask for N questions about DIFF, aimed at the files in UNREAD."
  (concat
   (format "Set a short comprehension quiz for the person who just reviewed \
the changeset below. You are finding out whether they understand the change, \
not whether they can read.

Ask exactly %d questions. Every one must satisfy all of:

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
" n)
   (when unread
     (format "\nAim at these files first. They were accepted without being \
opened, so that is where the reader's model is thinnest: %s\n"
             (string-join unread ", ")))
   "\nReply with the questions alone, as markdown headings numbered from 1, \
and nothing else. No preamble, no answers, no commentary.

## 1. <question>
## 2. <question>

The changeset:

"
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

(defvar sprig-quiz-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'sprig-quiz-submit)
    (define-key map (kbd "C-c C-k") #'sprig-quiz-abort)
    (define-key map (kbd "TAB")     #'sprig-quiz-toggle)
    map)
  "Keymap for `sprig-quiz-mode'.")

(define-derived-mode sprig-quiz-mode text-mode "sprig-quiz"
  "Worksheet for a quiz about the changeset under review.
Questions are read-only; you type in the gap under each, then hand the lot
in with \\[sprig-quiz-submit].  After that the buffer is read-only, and
\\[sprig-quiz-toggle] unfolds the author's answer."
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
                     "C-c C-c hands it in and asks for the other answers; "
                     "C-c C-k walks away.\n"
                     "Nothing is sent until you do, and nothing is written "
                     "to the session log.\n\n")
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

(defun sprig-quiz--tint-answers ()
  "Tint what you wrote under each question as yours."
  (let ((inhibit-read-only t))
    (dolist (q sprig-quiz--questions)
      (when-let* ((b (sprig-quiz--question-bounds (car q))))
        (unless (string-blank-p (buffer-substring-no-properties
                                 (car b) (cdr b)))
          (add-face-text-property (car b) (cdr b) 'sprig-quiz-answer))))))

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
        (insert (replace-regexp-in-string
                 "^" "    " (sprig-quiz--fontify (string-trim text)))
                "\n\n")
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

(defun sprig-quiz--receive (source text)
  "Distribute a fork's whole answer TEXT from SOURCE across the worksheet."
  (if (null text)
      (dolist (q sprig-quiz--questions)
        (sprig-quiz--landed (car q) source "(this one failed)"))
    (dolist (q sprig-quiz--questions)
      (sprig-quiz--landed (car q) source text)))
  (cl-decf sprig-quiz--pending)
  (when (<= sprig-quiz--pending 0)
    (message "sprig: quiz answered.  TAB on a ▸ line for what the author says")))

(defun sprig-quiz-submit ()
  "Hand the worksheet in and ask the other two (C-c C-c).
Fires both forks at once and reserves their slots first, so the cold read
sits above the author's answer however the two race.  Neither fork is shown
what you wrote: they answer independently, or the comparison is not one."
  (interactive)
  (unless (derived-mode-p 'sprig-quiz-mode)
    (user-error "Not in a quiz buffer"))
  (when sprig-quiz--submitted
    (user-error "This worksheet is already handed in"))
  (setq sprig-quiz--submitted t)
  (sprig-quiz--tint-answers)
  ;; Reserve every slot before anything can land in one.
  ;; Cold first, then the author: each is inserted at the end of the
  ;; question's body, so the one reserved first ends up above.
  (let ((slots nil))
    (dolist (q sprig-quiz--questions)
      (when sprig-quiz-cold-read
        (push (sprig-quiz--reserve (car q) 'cold "cold read") slots))
      (when sprig-quiz--id
        (push (sprig-quiz--reserve (car q) 'author "what the author says")
              slots)))
    (setq sprig-quiz--slots (delq nil slots)))
  (setq buffer-read-only t)
  (let ((buf (current-buffer))
        (dir sprig-quiz--dir)
        (remote sprig-quiz--remote)
        (id sprig-quiz--id)
        (questions sprig-quiz--questions)
        (diff sprig-quiz--diff))
    (setq sprig-quiz--pending 0)
    (cl-flet ((receive (source)
                (lambda (text)
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (sprig-quiz--receive source text))))))
      (when sprig-quiz-cold-read
        (cl-incf sprig-quiz--pending)
        (sprig-quiz--ask (sprig-quiz--cold-command dir remote)
                         dir remote "sprig-quiz-cold"
                         (sprig-quiz--cold-prompt questions diff)
                         (receive 'cold)))
      (when id
        (cl-incf sprig-quiz--pending)
        (sprig-quiz--ask (sprig--btw-command id dir remote)
                         dir remote "sprig-quiz-author"
                         (sprig-quiz--author-prompt questions)
                         (receive 'author)))))
  (message "sprig: %s"
           (cond ((and sprig-quiz-cold-read sprig-quiz--id)
                  "handed in; a cold reader and the author are answering…")
                 (sprig-quiz-cold-read
                  "handed in; a cold reader is answering…")
                 (sprig-quiz--id "handed in; the author is answering…")
                 ;; No peer and no author: the retrieval still happened, which
                 ;; was most of the value, but nothing is coming back and the
                 ;; line must not name someone who is not answering.
                 (t "handed in; nothing to compare against"))))

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
Asks `sprig-quiz-questions' questions about this review, weighted towards
the files you never unfolded, and opens them as a worksheet.  You answer
from memory; only on `C-c C-c' does a cold reader answer beside you, with
the author's own account folded away as the adjudicator.

Nothing here is scored, kept, or sent to the session: the whole exchange
rides the side-question transport, which writes no log."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (unless sprig-review--changes
    (user-error "Nothing changed to quiz you on"))
  ;; The fold record is only refreshed on a redraw, so ask the live sections
  ;; where they stand rather than trusting the last render's answer.
  (sprig-review--note-expansion)
  (let* ((changes sprig-review--changes)
         (unread (sprig-quiz--unread changes sprig-review--expanded))
         (diff (sprig-quiz--diff-text changes unread))
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
     (sprig-quiz--generate-prompt diff unread sprig-quiz-questions)
     (lambda (text)
       (let ((questions (and text (sprig-quiz--split text))))
         (if (null questions)
             (message "sprig: the quiz came back empty; try again")
           (sprig-quiz--start buf questions diff id dir remote)))))
    (message "sprig: setting %d questions%s…" sprig-quiz-questions
             (if unread (format " (%d file(s) you never opened)"
                                (length unread))
               ""))))

(provide 'sprig-quiz)
;;; sprig-quiz.el ends here
