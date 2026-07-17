;;; sprig-review-mode-tests.el --- ERT tests for the review renderer -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the magit-section renderer (sprig-review-mode.el).  Unlike
;; the process-free suite in sprig-tests.el, these load magit-section, so
;; run them with its load path:
;;
;;   emacs -Q --batch -L . -L .deps/compat -L .deps/cond-let \
;;         -L .deps/llama -L .deps/magit-section \
;;         -l sprig-review-mode.el -l sprig-review-mode-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'magit-section)
(require 'sprig-review-mode)

(defmacro sprig-review-tests--rendered (model meta &rest body)
  "Render MODEL (with META) into a `sprig-review-mode' buffer, run BODY there."
  (declare (indent 2) (debug (form form body)))
  `(with-temp-buffer
     (sprig-review-mode)
     (sprig-review-render ,model ,meta)
     (goto-char (point-min))
     ,@body))

(defmacro sprig-review-tests--rendered-expanded (model meta &rest body)
  "Like `sprig-review-tests--rendered', with diff-bearing tools expanded.
Tools fold by default, which keeps their hunks out of the buffer entirely;
the tests that reach into a hunk section need them drawn."
  (declare (indent 2) (debug (form form body)))
  `(let ((sprig-review-expand-diffs t))
     (sprig-review-tests--rendered ,model ,meta ,@body)))

(defun sprig-review-tests--margins ()
  "Return the current buffer's left-margin strings, in buffer order.
They ride an overlay's `before-string' display property, not the buffer
text, so they have to be read back off the overlays.  Each is the block's
timestamp, or the state line's rule."
  (let (margins)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'sprig-review-margin)
        (let ((display (get-text-property 0 'display
                                          (overlay-get ov 'before-string))))
          (should (equal (car display) '(margin left-margin)))
          (push (cons (overlay-start ov)
                      (substring-no-properties (cadr display)))
                margins))))
    (mapcar #'cdr (sort margins (lambda (a b) (< (car a) (car b)))))))

(defun sprig-review-tests--edit-model ()
  "A model with one Edit call and its result, plus a text block."
  (let ((input (json-serialize
                (list :file_path "/tmp/x.el"
                      :old_string "old\ngone" :new_string "new"))))
    (sprig-review-build
     `((session "s1")
       (text "Editing the file.")
       (tool-call "t1" "Edit" ,input)
       (tool-result "t1" nil "applied")
       (done 0.0123 nil)))))

(defun sprig-review-tests--todo-model ()
  "A model with one TodoWrite call carrying a three-item checklist."
  (let ((input (json-serialize
                (list :todos
                      (vector
                       (list :content "First" :status "completed"
                             :activeForm "Doing first")
                       (list :content "Second" :status "in_progress"
                             :activeForm "Doing second")
                       (list :content "Third" :status "pending"
                             :activeForm "Doing third"))))))
    (sprig-review-build
     `((tool-call "t1" "TodoWrite" ,input)
       (tool-result "t1" nil "Todos have been modified successfully")))))

(ert-deftest sprig-review-mode-test-renders-text-and-diff ()
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    (let ((s (buffer-string)))
      (should (string-match-p "Editing the file\\." s))
      (should (string-match-p "^Edit  " s))
      (should (string-match-p "/tmp/x\\.el" s))
      ;; The diff header shows the +/- counts.
      (should (string-match-p "(\\+1 -2)" s))
      ;; Removed lines then added lines.
      (should (string-match-p "^-old$" s))
      (should (string-match-p "^-gone$" s))
      (should (string-match-p "^\\+new$" s))
      ;; The result heading is present; its body folds away by default.
      (should (string-match-p "↳ result" s))
      (should-not (string-match-p "applied" s)))
    ;; Expanding the result draws its deferred body into the buffer.
    (goto-char (point-min))
    (should (re-search-forward "↳ result" nil t))
    (magit-section-show (magit-current-section))
    (should (string-match-p "applied" (buffer-string)))))

(ert-deftest sprig-review-mode-test-tools-fold-by-default ()
  ;; Every tool folds to its one-line heading, diff-bearing or not, so a long
  ;; turn reads as a list of what the agent did.  The diff is one TAB away.
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (let ((s (buffer-string)))
      ;; The heading still names the file and its line counts.
      (should (string-match-p "^Edit  " s))
      (should (string-match-p "(\\+1 -2)" s))
      ;; The hunks themselves are not drawn.
      (should-not (string-match-p "^\\+new$" s)))
    (goto-char (point-min))
    (re-search-forward "^Edit  ")
    (should (oref (magit-current-section) hidden))
    (magit-section-show (magit-current-section))
    (should (string-match-p "^\\+new$" (buffer-string)))))

(ert-deftest sprig-review-mode-test-expand-diffs-option ()
  ;; `sprig-review-expand-diffs' opts back into a diff-bearing tool rendering
  ;; open; a tool with no diff folds regardless.
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (re-search-forward "^Edit  ")
    (should-not (oref (magit-current-section) hidden)))
  (let ((model (sprig-review-build
                `((tool-call "b1" "Bash" ,(json-serialize (list :command "ls")))
                  (tool-result "b1" nil "out")))))
    (sprig-review-tests--rendered-expanded model nil
      (goto-char (point-min))
      (re-search-forward "^Bash  ")
      (should (oref (magit-current-section) hidden)))))

(ert-deftest sprig-review-mode-test-faces-survive-font-lock ()
  ;; `magit-section-mode' turns font-lock on, and font-lock's unfontify pass
  ;; strips the plain `face' property off every region it redisplays.  So
  ;; everything rendered must carry `font-lock-face' instead, or it silently
  ;; loses its colours as soon as the window scrolls over it.
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model)
      '(:title "T")
    (font-lock-mode 1)
    (font-lock-fontify-region (point-min) (point-max))
    (cl-flet ((face-at (re)
                (goto-char (point-min))
                (re-search-forward re)
                (get-text-property (match-beginning 0) 'font-lock-face)))
      (should (eq (face-at "^Edit  ") 'sprig-review-tool))
      (should (eq (face-at "^\\+new$") 'sprig-review-added))
      (should (eq (face-at "^-old$") 'sprig-review-removed))
      (should (eq (face-at "^/tmp/x\\.el$") 'sprig-review-file))
      (should (eq (face-at "Title:") 'sprig-review-meta-key)))))

(ert-deftest sprig-review-mode-test-user-block-is-set-off ()
  (let ((model (sprig-review-build '((user "the question") (text "the answer")))))
    (sprig-review-tests--rendered model nil
      ;; No role labels: the tint alone tells the turns apart, and a blank
      ;; line separates them.
      (should (equal (buffer-string)
                     "\nthe question\n\nthe answer\n\n●  idle\n"))
      (goto-char (point-min))
      (re-search-forward "the question")
      (should (memq 'sprig-review-user
                    (ensure-list (get-text-property (match-beginning 0)
                                                    'font-lock-face))))
      ;; The agent's output is the untinted one.
      (re-search-forward "the answer")
      (should-not (memq 'sprig-review-user
                        (ensure-list (get-text-property (match-beginning 0)
                                                        'font-lock-face)))))))

(ert-deftest sprig-review-mode-test-user-highlight-is-its-own ()
  ;; magit paints the section under point with the shared
  ;; `magit-section-highlight', which would drop a user turn's tint just as
  ;; you move onto it.  Naming our own `heading-highlight-face' keeps it
  ;; reading as yours while it is current.
  (let ((model (sprig-review-build '((user "the question") (text "the answer")))))
    (sprig-review-tests--rendered model nil
      (goto-char (point-min))
      (re-search-forward "the question")
      (let ((sec (magit-current-section)))
        (should (eq (oref sec type) 'sprig-user))
        (should (eq (oref sec heading-highlight-face) 'sprig-review-user-highlight))
        ;; With no heading to confine it to, magit paints it over the turn.
        (magit-section-highlight sec)
        (should (memq 'sprig-review-user-highlight
                      (mapcar (lambda (o) (overlay-get o 'font-lock-face))
                              (overlays-at (oref sec start))))))
      ;; The agent's prose claims no face of its own, so it gets magit's.
      (goto-char (point-min))
      (re-search-forward "the answer")
      (let ((sec (magit-current-section)))
        (should (eq (oref sec type) 'sprig-text))
        (should-not (oref sec heading-highlight-face))))))

(ert-deftest sprig-review-mode-test-tool-rows-pack-into-a-block ()
  ;; A run of tool calls reads as one block: a blank line above the run, and
  ;; none between its rows.  Prose keeps its blank line on either side.
  (let ((model (sprig-review-build
                `((user "do it")
                  (text "on it")
                  (tool-call "t1" "Read" ,(json-serialize (list :file_path "a")))
                  (tool-call "t2" "Read" ,(json-serialize (list :file_path "b")))
                  (tool-call "t3" "Bash" ,(json-serialize (list :command "make")))
                  (text "done")))))
    (sprig-review-tests--rendered model nil
      (should (equal (buffer-string)
                     (concat "\n"
                             "do it\n"
                             "\n"
                             "on it\n"
                             "\n"
                             "Read  a\n"
                             "Read  b\n"
                             "Bash  make\n"
                             "\n"
                             "done\n"
                             "\n"
                             "●  idle\n"))))))

(ert-deftest sprig-review-mode-test-thinking-packs-with-the-tool-rows ()
  ;; A thinking block folds to a one-line row too, so it joins the run
  ;; rather than breaking it in two.
  (let ((model (sprig-review-build
                `((text "on it")
                  (thinking "pondering")
                  (tool-call "t1" "Read" ,(json-serialize (list :file_path "a")))))))
    (sprig-review-tests--rendered model nil
      (should (equal (buffer-string)
                     "\non it\n\nthinking\nRead  a\n\n●  idle\n")))))

(ert-deftest sprig-review-mode-test-todo-heading-shows-progress ()
  ;; A folded TodoWrite still tells you how far along the plan is, the way a
  ;; folded edit shows its line counts; the checklist itself is one TAB away.
  (sprig-review-tests--rendered (sprig-review-tests--todo-model) nil
    (let ((s (buffer-string)))
      (should (string-match-p "^TodoWrite  1/3 done" s))
      (should-not (string-match-p "☑" s)))))

(ert-deftest sprig-review-mode-test-todo-checklist-expands ()
  ;; Opening the TodoWrite shows the checklist, each item with a status
  ;; marker, and no bookkeeping result line.
  (sprig-review-tests--rendered (sprig-review-tests--todo-model) nil
    (goto-char (point-min))
    (re-search-forward "^TodoWrite")
    (magit-section-show (magit-current-section))
    (let ((s (buffer-string)))
      (should (string-match-p "☑ First" s))
      (should (string-match-p "▶ Second" s))
      (should (string-match-p "☐ Third" s))
      ;; The result is a reminder, not content; the checklist stands in for it.
      (should-not (string-match-p "↳ result" s)))))

(ert-deftest sprig-review-mode-test-todo-line-glyphs ()
  ;; Each status maps to its own marker, so the checklist reads at a glance.
  (should (string-prefix-p
           "☑ " (substring-no-properties
                 (sprig-review--todo-line '((content . "a") (status . "completed"))))))
  (should (string-prefix-p
           "▶ " (substring-no-properties
                 (sprig-review--todo-line '((content . "b") (status . "in_progress"))))))
  (should (string-prefix-p
           "☐ " (substring-no-properties
                 (sprig-review--todo-line '((content . "c") (status . "pending")))))))

(defun sprig-review-tests--task-events (&rest tail)
  "Build events for a run of task ops: two creates and a start, then TAIL.
Each create's result carries its assigned id, the way the CLI answers, so
the fold learns the id from the result rather than from the call."
  (append
   `((tool-call "c1" "TaskCreate" ,(json-serialize '(:subject "First" :description "d")))
     (tool-result "c1" nil "Task #1 created successfully: First")
     (tool-call "c2" "TaskCreate" ,(json-serialize '(:subject "Second" :description "d")))
     (tool-result "c2" nil "Task #2 created successfully: Second")
     (tool-call "u1" "TaskUpdate" ,(json-serialize '(:taskId "1" :status "in_progress")))
     (tool-result "u1" nil "Updated task #1 status"))
   tail))

(ert-deftest sprig-review-mode-test-task-fold-into-checklist ()
  ;; The granular Task tools fold into one running checklist with heading
  ;; progress, the same shape a TodoWrite renders; no raw TaskCreate rows.
  (let ((model (sprig-review-build (sprig-review-tests--task-events))))
    (sprig-review-tests--rendered model nil
      (let ((s (buffer-string)))
        (should (string-match-p "^Tasks  0/2 done" s))
        (should-not (string-match-p "TaskCreate" s))
        (should-not (string-match-p "TaskUpdate" s)))
      (goto-char (point-min))
      (re-search-forward "^Tasks")
      (magit-section-show (magit-current-section))
      (let ((s (buffer-string)))
        (should (string-match-p "▶ First" s))
        (should (string-match-p "☐ Second" s))))))

(ert-deftest sprig-review-mode-test-task-run-coalesces-then-splits ()
  ;; A run of task ops is one snapshot; a non-task block between runs opens a
  ;; fresh one, so the second checklist shows the moved-on state.
  (let* ((model (sprig-review-build
                 (sprig-review-tests--task-events
                  '(text "Working on it.")
                  `(tool-call "u2" "TaskUpdate"
                              ,(json-serialize '(:taskId "1" :status "completed")))
                  '(tool-result "u2" nil "Updated task #1 status"))))
         (tasks (seq-filter (lambda (b) (eq (plist-get b :type) 'tasks))
                            (plist-get model :blocks))))
    ;; Two runs, so two snapshots, not one merged block and not one per op.
    (should (= (length tasks) 2))
    (should (equal (alist-get 'status (car (plist-get (car tasks) :items)))
                   "in_progress"))
    (should (equal (alist-get 'status (car (plist-get (cadr tasks) :items)))
                   "completed"))))

(ert-deftest sprig-review-mode-test-task-delete-drops-it ()
  ;; A deleted task leaves the checklist; the survivors keep their order.
  (let* ((model (sprig-review-build
                 (sprig-review-tests--task-events
                  `(tool-call "u3" "TaskUpdate"
                              ,(json-serialize '(:taskId "1" :status "deleted")))
                  '(tool-result "u3" nil "Updated task #1 deleted"))))
         (last (car (last (seq-filter
                           (lambda (b) (eq (plist-get b :type) 'tasks))
                           (plist-get model :blocks)))))
         (items (plist-get last :items)))
    (should (= (length items) 1))
    (should (equal (alist-get 'content (car items)) "Second"))))

(defmacro sprig-review-tests--with-tz (tz &rest body)
  "Run BODY with the local timezone set to TZ, restoring it after."
  (declare (indent 1) (debug (form body)))
  `(let ((old (getenv "TZ")))
     (unwind-protect (progn (setenv "TZ" ,tz) ,@body)
       (setenv "TZ" old))))

(ert-deftest sprig-review-mode-test-time-string ()
  ;; The log stamps in UTC; the margin shows local time.
  (sprig-review-tests--with-tz "UTC0"
    (should (equal (sprig-review--time-string "2026-07-15T09:16:56.955Z") "09:16"))
    (let ((sprig-review-timestamp-format "%m-%d %H:%M"))
      (should (equal (sprig-review--time-string "2026-07-15T09:16:56.955Z")
                     "07-15 09:16"))))
  ;; POSIX TZ signs are inverted: UTC-2 is two hours east of Greenwich.
  (sprig-review-tests--with-tz "UTC-2"
    (should (equal (sprig-review--time-string "2026-07-15T09:16:56.955Z") "11:16")))
  ;; A block with no usable time is worth more than a render that dies on one.
  (should-not (sprig-review--time-string "not a time"))
  (should-not (sprig-review--time-string nil))
  (let ((sprig-review-timestamp-format nil))
    (should-not (sprig-review--time-string "2026-07-15T09:16:56.955Z"))))

(ert-deftest sprig-review-mode-test-margin-width ()
  ;; The margin is the stamp plus one column for the running bar, so the bar
  ;; costs nothing next to a timestamp and the margin narrows to just the bar
  ;; when timestamps are off.
  (let ((sprig-review-timestamp-format "%H:%M"))
    (should (= (sprig-review--margin-width) 6)))
  (let ((sprig-review-timestamp-format "%m-%d %H:%M"))
    (should (= (sprig-review--margin-width) 12)))
  (let ((sprig-review-timestamp-format nil))
    (should (= (sprig-review--margin-width) 0))))

(ert-deftest sprig-review-mode-test-timestamp-rides-the-margin ()
  ;; The stamp hangs off an overlay, so it dates the block without putting a
  ;; character into the buffer text the verbs read.
  (sprig-review-tests--with-tz "UTC0"
    (let ((model (sprig-review-build
                  `((time "2026-07-15T09:16:56.955Z")
                    (user "q")
                    (time "2026-07-15T09:17:30.000Z")
                    (tool-call "t1" "Bash" ,(json-serialize (list :command "ls")))))))
      (sprig-review-tests--rendered model nil
        (should (equal (buffer-string) "\nq\n\nBash  ls\n\n●  idle\n"))
        ;; One per block, each against its own first line.  Nothing is
        ;; running, so the bar column is blank.
        (should (equal (sprig-review-tests--margins)
                       (list "09:16" "09:17" (make-string 6 ?━)))))
      ;; With the format off, only the bar column is left.
      (let ((sprig-review-timestamp-format nil))
        (sprig-review-tests--rendered model nil
          (should (equal (sprig-review-tests--margins) nil))
          (should (= left-margin-width 0)))))))

(defun sprig-review-tests--state-line ()
  "Return the buffer's last line, which is the state line, and its face."
  (save-excursion
    (goto-char (point-max))
    (forward-line -1)
    (cons (buffer-substring-no-properties (line-beginning-position)
                                          (line-end-position))
          (get-text-property (line-beginning-position) 'font-lock-face))))

(ert-deftest sprig-review-mode-test-state-line-says-the-turn-is-over ()
  ;; The buffer has to say a turn landed, below the last message, rather than
  ;; leave it to be inferred from nothing having moved for a while.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(user "do it"))
    (sprig-review-consume '(text "on it"))
    (sprig-review-consume (list 'tool-call "t1" "Bash"
                                (json-serialize (list :command "ls"))))
    (sprig-review-flush)
    (should sprig-review--streaming)
    (should (equal (sprig-review-tests--state-line)
                   '("▶  working…" . sprig-review-working)))
    ;; The turn lands: said outright, with what it cost.
    (sprig-review-consume '(done 0.0312 nil))
    (sprig-review-flush)
    (should-not sprig-review--streaming)
    (should (equal (sprig-review-tests--state-line)
                   '("✓  turn over" . sprig-review-done)))
    ;; A new turn takes the line back.
    (sprig-review-consume '(text "more"))
    (sprig-review-flush)
    (should (equal (car (sprig-review-tests--state-line)) "▶  working…"))))

(ert-deftest sprig-review-mode-test-state-line-reports-a-failed-turn ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "trying"))
    (sprig-review-consume '(done nil t))
    (sprig-review-flush)
    (should (equal (sprig-review-tests--state-line)
                   '("✗  turn failed" . sprig-review-failed)))))

(ert-deftest sprig-review-mode-test-state-line-awaiting-after-send ()
  ;; After a turn lands and a new message is sent, the transport is busy while
  ;; it waits on the agent's first token; the line must say so, not fall back
  ;; to the previous turn's stale `✓ turn over'.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "done that"))
    (sprig-review-consume '(done 0.01 nil))
    (sprig-review-flush)
    (should (equal (car (sprig-review-tests--state-line)) "✓  turn over"))
    ;; Send: the transport sets busy before the user event is consumed, and
    ;; nothing has streamed back yet.
    (setq-local sprig--busy t)
    (sprig-review-consume '(user "and now this"))
    (sprig-review-flush)
    (should-not sprig-review--streaming)
    (should (equal (sprig-review-tests--state-line)
                   '("▷  sent, awaiting reply" . sprig-review-pending)))
    ;; The agent's first token flips it to working.
    (sprig-review-consume '(text "starting"))
    (sprig-review-flush)
    (should (equal (car (sprig-review-tests--state-line)) "▶  working…"))))

(ert-deftest sprig-review-mode-test-state-line-of-replayed-history ()
  ;; A conversation read from disk carries no `done', but nothing is running
  ;; in it either; it must not claim to be working, nor to have just landed.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-seed '((user "q") (text "a")))
    (should-not sprig-review--streaming)
    (should (equal (sprig-review-tests--state-line)
                   '("●  idle" . sprig-review-idle)))))

(ert-deftest sprig-review-mode-test-state-line-rules-the-side-bar ()
  ;; The side bar carries the same mark, in the same colour, so the gutter
  ;; ends the turn as plainly as the line does.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "hi"))
    (sprig-review-consume '(done 0.01 nil))
    (sprig-review-flush)
    (let ((rule (car (last (sprig-review-tests--margins)))))
      (should (equal rule (make-string (sprig-review--margin-width) ?━))))))

(ert-deftest sprig-review-mode-test-a-tool-only-turn-is-working ()
  ;; The state line follows the turn, not the prose: a turn opening with a
  ;; tool call is working just as much as one opening with text.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'tool-call "t1" "Bash"
                                (json-serialize (list :command "ls"))))
    (sprig-review-flush)
    (should sprig-review--streaming)
    (should (equal (car (sprig-review-tests--state-line)) "▶  working…"))))

(ert-deftest sprig-review-mode-test-live-stamps-once-per-block ()
  ;; The wire carries no times, so the sink stamps on arrival: once per block,
  ;; not once per streamed token.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "Hel"))
    (sprig-review-consume '(text "lo"))
    (sprig-review-consume '(tool-call "t1" "Bash" "{}"))
    (should (= 2 (seq-count (lambda (e) (eq (car e) 'time)) sprig-review--events)))
    ;; And the stamps reach the blocks.
    (let ((blocks (plist-get (sprig-review-build (reverse sprig-review--events))
                             :blocks)))
      (should (= 2 (length blocks)))
      (should (plist-get (nth 0 blocks) :time))
      (should (plist-get (nth 1 blocks) :time)))))

(ert-deftest sprig-review-mode-test-live-stamp-survives-a-rebuild ()
  ;; The stamp lives in the event list, not the clock, so rebuilding the model
  ;; (which every render does) redates nothing.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "hi"))
    (let ((first (plist-get (car (plist-get (sprig-review-build
                                             (reverse sprig-review--events))
                                            :blocks))
                            :time)))
      (should first)
      (sprig-review-consume '(done 0.01 nil))
      (should (equal first
                     (plist-get (car (plist-get (sprig-review-build
                                                 (reverse sprig-review--events))
                                                :blocks))
                                :time))))))

(ert-deftest sprig-review-mode-test-refresh-re-reads-the-log ()
  ;; A buffer's events are seeded once at open and never re-read, so a log
  ;; that has grown (or a parser taught to read more of it) needs `g'.  This
  ;; is why a timestamp added to the parser did not reach an open buffer.
  (let ((file (make-temp-file "sprig-session" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-serialize
                     '(:type "user" :timestamp "2026-07-15T09:00:00.000Z"
                       :message (:role "user" :content "first")))
                    "\n"))
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (sprig-review-open-file file))
          (with-current-buffer (format "*sprig-review: %s*" (file-name-base file))
            (should (string-match-p "first" (buffer-string)))
            ;; The log grows behind the buffer's back.
            (with-temp-buffer
              (insert (json-serialize
                       '(:type "assistant" :timestamp "2026-07-15T09:01:00.000Z"
                         :message (:content [(:type "text" :text "second")])))
                      "\n")
              (append-to-file (point-min) (point-max) file))
            ;; A re-render alone does not notice: it rebuilds from the events
            ;; the buffer already holds.
            (sprig-review--refresh)
            (should-not (string-match-p "second" (buffer-string)))
            ;; `g' re-reads the file it was opened from.
            (sprig-review-refresh)
            (should (string-match-p "second" (buffer-string)))
            (kill-buffer)))
      (delete-file file))))

(ert-deftest sprig-review-mode-test-refresh-is-on-g-and-waits-for-the-turn ()
  (with-temp-buffer
    (sprig-review-mode)
    ;; `g' is bound to `revert-buffer' by the parent mode, so the refresh has
    ;; to hang off `revert-buffer-function' to be reachable there at all.
    (should (eq (key-binding (kbd "g")) 'revert-buffer))
    (should (eq revert-buffer-function #'sprig-review-refresh))
    ;; Mid-turn it refuses: the in-flight turn is not in the log yet, so
    ;; re-seeding from the log would drop it out of the buffer.
    (setq-local sprig--busy t)
    (should-error (sprig-review-refresh) :type 'user-error)))

(defun sprig-review-tests--dialog-input (&optional multi)
  "A two-option question, MULTI when it takes more than one answer."
  `((questions . [((question . "Which approach?")
                   (header . "Approach")
                   (multiSelect . ,(if multi t :false))
                   (options . [((label . "Rewrite it (Recommended)")
                                (description . "start over"))
                               ((label . "Patch it")
                                (description . "keep going"))]))])))

(ert-deftest sprig-review-mode-test-pending-dialog-renders-and-waits ()
  ;; A question renders in the buffer, with what it offers, and the state
  ;; line says the turn is stopped on you rather than working.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "I need to know something."))
    (sprig-review-consume (list 'dialog "req-1" "ask_user_question"
                                (sprig-review-tests--dialog-input)))
    (sprig-review-flush)
    (let ((s (buffer-string)))
      (should (string-match-p "? Which approach?" s))
      (should (string-match-p "Rewrite it (Recommended)" s))
      (should (string-match-p "Patch it" s))
      ;; It says how to answer, rather than pretending to be pickable.
      (should (string-match-p "a a to answer" s)))
    ;; Waiting beats working: the turn is stopped, not running.
    (should (equal (sprig-review-tests--state-line)
                   '("?  waiting on you  ·  a a to answer" . sprig-review-waiting)))))

(ert-deftest sprig-review-mode-test-answered-dialog-shows-the-answer ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'dialog "req-1" "ask_user_question"
                                (sprig-review-tests--dialog-input)))
    (sprig-review-consume (list 'dialog-answer "req-1"
                                (list (cons (intern "Which approach?")
                                            "Patch it"))))
    (sprig-review-consume '(done 0.01 nil))
    (sprig-review-flush)
    (let ((s (buffer-string)))
      (should (string-match-p "? Which approach?" s))
      ;; Settled: what was said, and no longer how to say it.
      (should (string-match-p "Patch it" s))
      (should-not (string-match-p "a a to answer" s)))
    (should (equal (car (sprig-review-tests--state-line)) "✓  turn over"))))

(ert-deftest sprig-review-mode-test-answer-recommended ()
  ;; `a r' takes the option the tool marked, without opening anything.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'dialog "req-1" "ask_user_question"
                                (sprig-review-tests--dialog-input)))
    (sprig-review-flush)
    (let (answered)
      (cl-letf (((symbol-function 'sprig--review-answer-dialog)
                 (lambda (id _input answers) (setq answered (list id answers)))))
        (sprig-review-answer-recommended))
      (should (equal (car answered) "req-1"))
      (should (equal (cdar (cadr answered)) "Rewrite it (Recommended)")))))

(ert-deftest sprig-review-mode-test-answer-skip ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'dialog "req-1" "ask_user_question"
                                (sprig-review-tests--dialog-input)))
    (sprig-review-flush)
    (let (answered)
      (cl-letf (((symbol-function 'sprig--review-answer-dialog)
                 (lambda (_id _input answers) (setq answered (list :answers answers)))))
        (sprig-review-answer-skip))
      (should (equal answered '(:answers nil)))))
  ;; With nothing waiting, the verbs say so rather than doing something.
  (with-temp-buffer
    (sprig-review-mode)
    (should-error (sprig-review-answer-skip) :type 'user-error)
    (should-error (sprig-review-answer-recommended) :type 'user-error)
    (should-error (sprig-review-answer) :type 'user-error)))

(ert-deftest sprig-review-mode-test-answer-buffer-picks-and-sends ()
  ;; `a a' opens a buffer on the question; picking an option answers it.
  (let (answered)
    (cl-letf (((symbol-function 'sprig--review-answer-dialog)
               (lambda (id _input answers) (setq answered (list id answers))))
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'quit-window) #'ignore))
      (with-temp-buffer
        (sprig-review-mode)
        (sprig-review-consume (list 'dialog "req-1" "ask_user_question"
                                    (sprig-review-tests--dialog-input)))
        (sprig-review-flush)
        (sprig-review-answer)
        (with-current-buffer "*sprig-answer*"
          (should (string-match-p "? Which approach?" (buffer-string)))
          (should (string-match-p "1  Rewrite it" (buffer-string)))
          (should (string-match-p "2  Patch it" (buffer-string)))
          ;; Pick the second by number.
          (setq last-command-event ?2)
          (sprig-answer-pick-number))))
    (should (equal (car answered) "req-1"))
    (should (equal (cdar (cadr answered)) "Patch it")))
  (kill-buffer "*sprig-answer*"))

(ert-deftest sprig-review-mode-test-answer-buffer-multi-select ()
  ;; A multi-select question toggles rather than settling, and takes what is
  ;; picked on C-c C-c, joined the way the CLI joins them.
  (let (answered)
    (cl-letf (((symbol-function 'sprig--review-answer-dialog)
               (lambda (_id _input answers) (setq answered answers)))
              ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'quit-window) #'ignore))
      (with-temp-buffer
        (sprig-review-mode)
        (sprig-review-consume (list 'dialog "req-1" "ask_user_question"
                                    (sprig-review-tests--dialog-input t)))
        (sprig-review-flush)
        (sprig-review-answer)
        (with-current-buffer "*sprig-answer*"
          (setq last-command-event ?1)
          (sprig-answer-pick-number)
          (should-not answered)          ; toggled, not settled
          (setq last-command-event ?2)
          (sprig-answer-pick-number)
          (should (string-match-p "▸1" (buffer-string)))
          (sprig-answer-confirm))))
    (should (equal (cdar answered) "Rewrite it (Recommended), Patch it")))
  (kill-buffer "*sprig-answer*"))

(defun sprig-review-tests--permission-input ()
  "The request a Bash call wanting permission arrives as."
  '((subtype . "can_use_tool")
    (tool_name . "Bash")
    (input . ((command . "rm -rf /tmp/scratch")))))

(ert-deftest sprig-review-mode-test-permission-renders-and-waits ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'dialog "req-b" "can_use_tool"
                                (sprig-review-tests--permission-input)))
    (sprig-review-flush)
    (let ((s (buffer-string)))
      (should (string-match-p "? Allow Bash?" s))
      ;; What you are being asked to allow, not just that you are.
      (should (string-match-p "rm -rf /tmp/scratch" s))
      (should (string-match-p "a a to allow or deny" s)))
    (should (equal (car (sprig-review-tests--state-line))
                   "?  waiting on you  ·  a a to answer"))))

(ert-deftest sprig-review-mode-test-permission-allow-and-deny ()
  (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
            ((symbol-function 'quit-window) #'ignore))
    ;; Allow: picked in the answer buffer.
    (let (allowed)
      (cl-letf (((symbol-function 'sprig--review-allow-tool)
                 (lambda (id) (setq allowed id)))
                ((symbol-function 'sprig--review-deny-tool)
                 (lambda (_id) (ert-fail "denied when allowed"))))
        (with-temp-buffer
          (sprig-review-mode)
          (sprig-review-consume (list 'dialog "req-b" "can_use_tool"
                                      (sprig-review-tests--permission-input)))
          (sprig-review-flush)
          (sprig-review-answer)
          (with-current-buffer "*sprig-answer*"
            (should (string-match-p "Allow this call?" (buffer-string)))
            (setq last-command-event ?1)
            (sprig-answer-pick-number))))
      (should (equal allowed "req-b")))
    ;; Deny: the other option.
    (let (denied)
      (cl-letf (((symbol-function 'sprig--review-deny-tool)
                 (lambda (id) (setq denied id))))
        (with-temp-buffer
          (sprig-review-mode)
          (sprig-review-consume (list 'dialog "req-b" "can_use_tool"
                                      (sprig-review-tests--permission-input)))
          (sprig-review-flush)
          (sprig-review-answer)
          (with-current-buffer "*sprig-answer*"
            (setq last-command-event ?2)
            (sprig-answer-pick-number))))
      (should (equal denied "req-b"))))
  (kill-buffer "*sprig-answer*"))

(ert-deftest sprig-review-mode-test-permission-guards-the-shortcuts ()
  ;; `a r' would be one keypress allowing an unread call, so it refuses; `a s'
  ;; denies, no being the answer that cannot do damage.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'dialog "req-b" "can_use_tool"
                                (sprig-review-tests--permission-input)))
    (sprig-review-flush)
    (should-error (sprig-review-answer-recommended) :type 'user-error)
    (let (denied)
      (cl-letf (((symbol-function 'sprig--review-deny-tool)
                 (lambda (id) (setq denied id))))
        (sprig-review-answer-skip))
      (should (equal denied "req-b")))))

(ert-deftest sprig-review-mode-test-plan-skip-does-not-ask-for-feedback ()
  ;; Skipping is not rejecting-with-something-to-say: it must not stop to ask.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'dialog "req-p" "exit_plan_mode"
                                '((plan . "# A plan"))))
    (sprig-review-flush)
    (let (rejected)
      (cl-letf (((symbol-function 'sprig--review-reject-plan)
                 (lambda (id feedback) (setq rejected (list id feedback))))
                ((symbol-function 'read-string)
                 (lambda (&rest _) (ert-fail "asked for feedback on a skip"))))
        (sprig-review-answer-skip))
      (should (equal rejected '("req-p" ""))))))

(ert-deftest sprig-review-mode-test-navigation-passes-a-dialog ()
  ;; A section starting where its first child starts traps
  ;; `magit-section-backward': `p' walks up to the parent, goes to the
  ;; parent's start, and lands on the position it came from, forever.
  (dolist (dialog (list (list 'dialog "req-p" "exit_plan_mode"
                              '((plan . "# A plan\n\nStep one.")))
                        (list 'dialog "req-b" "can_use_tool"
                              (sprig-review-tests--permission-input))
                        (list 'dialog "req-1" "ask_user_question"
                              (sprig-review-tests--dialog-input))))
    (with-temp-buffer
      (sprig-review-mode)
      (sprig-review-consume '(text "before"))
      (sprig-review-consume dialog)
      (sprig-review-consume '(text "after"))
      (sprig-review-flush)
      ;; Forward, from the top, reaches the text below the dialog.
      (goto-char (point-min))
      (let ((seen nil))
        (dotimes (_ 6)
          (ignore-errors (magit-section-forward))
          (push (oref (magit-current-section) type) seen))
        (should (memq 'sprig-state seen)))
      ;; Backward, from the bottom, gets past the dialog to the text above it.
      (goto-char (point-max))
      (let ((seen nil))
        (dotimes (_ 6)
          (ignore-errors (magit-section-backward))
          (push (oref (magit-current-section) type) seen))
        (should (memq 'sprig-headers seen))))))

(ert-deftest sprig-review-mode-test-diffstat-is-coloured ()
  ;; The counts are what a folded edit tells you about its size.
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (font-lock-mode 1)
    (font-lock-fontify-region (point-min) (point-max))
    (goto-char (point-min))
    (re-search-forward "\\+1")
    (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                'sprig-review-stat-added))
    (re-search-forward "-2")
    (should (eq (get-text-property (match-beginning 0) 'font-lock-face)
                'sprig-review-stat-removed))))

(ert-deftest sprig-review-mode-test-verbs-are-bound ()
  ;; Every verb the README documents as a key has to actually be on that key.
  ;; `C' was documented and unbound, reachable only through the transient.
  (with-temp-buffer
    (sprig-review-mode)
    (dolist (pair '(("SPC" . sprig-review-toggle-mark)
                    ("m"   . sprig-review-toggle-mark)
                    ("U"   . sprig-review-unmark-all)
                    ("c"   . sprig-review-dispatch)
                    ("k"   . sprig-review-reject)
                    ("a"   . sprig-review-answer-dispatch)
                    ("C"   . sprig-review-commit)
                    ("x"   . sprig-review-run)
                    ("RET" . sprig-review-visit)
                    ("t"   . sprig-review-set-title)))
      (should (eq (key-binding (kbd (car pair))) (cdr pair))))
    ;; magit-section's own navigation still comes through the parent map.
    (should (eq (key-binding (kbd "n")) 'magit-section-forward))
    (should (eq (key-binding (kbd "p")) 'magit-section-backward))))

(ert-deftest sprig-review-mode-test-header ()
  (sprig-review-tests--rendered (sprig-review-tests--edit-model)
      '(:title "My branch" :project "~/p" :model "claude-opus-4-8"
        :status "idle")
    (let ((s (buffer-string)))
      (should (string-match-p "Title:" s))
      (should (string-match-p "My branch" s))
      (should (string-match-p "Project:" s))
      (should (string-match-p "Session:" s))
      (should (string-match-p "s1" s))
      (should (string-match-p "Cost:" s))
      (should (string-match-p "\\$0\\.0123" s)))))

(ert-deftest sprig-review-mode-test-blank-meta-lines-omitted ()
  ;; With no meta and no session, those header lines simply do not appear.
  (let ((model (sprig-review-build '((text "hi") (done nil nil)))))
    (sprig-review-tests--rendered model nil
      (let ((s (buffer-string)))
        (should-not (string-match-p "Title:" s))
        (should-not (string-match-p "Session:" s))
        (should-not (string-match-p "Cost:" s))))))

(ert-deftest sprig-review-mode-test-hunk-section-carries-plist ()
  ;; The verbs will read the object under point; a hunk section must hold
  ;; its hunk plist on the `value' slot.
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (should (re-search-forward "^\\+new$" nil t))
    (let ((sec (magit-current-section)))
      (should (eq (oref sec type) 'sprig-hunk))
      (should (equal (plist-get (oref sec value) :new) '("new"))))))

(ert-deftest sprig-review-mode-test-tool-section-carries-block ()
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (should (re-search-forward "^Edit  " nil t))
    (let ((sec (magit-current-section)))
      (should (eq (oref sec type) 'sprig-tool))
      (should (equal (plist-get (oref sec value) :name) "Edit")))))

(ert-deftest sprig-review-mode-test-buffer-read-only ()
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (should buffer-read-only)))

(ert-deftest sprig-review-mode-test-bash-summary ()
  (let ((model (sprig-review-build
                `((tool-call "b1" "Bash"
                             ,(json-serialize (list :command "ls -la\nsecond")))
                  (tool-result "b1" nil "output")))))
    (sprig-review-tests--rendered model nil
      (let ((s (buffer-string)))
        (should (string-match-p "^Bash  " s))
        ;; Only the first command line is summarised in the heading.
        (should (string-match-p "ls -la" s))
        (should-not (string-match-p "^Bash  .*second" s))))))

;;;; Live sink

(ert-deftest sprig-review-mode-test-consume-incremental ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(session "s1"))
    (sprig-review-consume '(text "Hel"))
    (sprig-review-consume '(text "lo"))
    (sprig-review-flush)
    ;; Text accumulates; no tool yet.
    (should (string-match-p "Hello" (buffer-string)))
    (should-not (string-match-p "^Edit  " (buffer-string)))
    (let ((input (json-serialize (list :file_path "x" :old_string "a"
                                       :new_string "b"))))
      (sprig-review-consume (list 'tool-call "t1" "Edit" input))
      (sprig-review-consume '(tool-result "t1" nil "ok")))
    (sprig-review-consume '(done 0.02 nil))
    (sprig-review-flush)
    (let ((s (buffer-string)))
      (should (string-match-p "Hello" s))
      (should (string-match-p "^Edit  " s))
      ;; The tool folds by default, so neither its diff nor its result is drawn.
      (should-not (string-match-p "↳ result" s))
      (should-not (string-match-p "ok" s))
      (should (string-match-p "\\$0\\.02" s)))))

(ert-deftest sprig-review-mode-test-consume-preserves-point ()
  (with-temp-buffer
    (sprig-review-mode)
    (let ((input (json-serialize (list :file_path "keep.el" :old_string "a"
                                       :new_string "b"))))
      (sprig-review-consume '(text "intro"))
      (sprig-review-consume (list 'tool-call "t1" "Edit" input))
      (sprig-review-consume '(tool-result "t1" nil "ok")))
    (sprig-review-flush)
    (goto-char (point-min))
    (should (re-search-forward "keep\\.el" nil t))
    (let ((type-before (oref (magit-current-section) type)))
      ;; A later turn streams in; point must stay in the same section, not
      ;; bounce to the top of the buffer.
      (sprig-review-consume '(text-block))
      (sprig-review-consume '(text "more"))
      (sprig-review-flush)
      (should (eq (oref (magit-current-section) type) type-before))
      (should (> (point) (point-min))))))

(ert-deftest sprig-review-mode-test-consume-preserves-folds ()
  (with-temp-buffer
    (sprig-review-mode)
    (let ((input (json-serialize (list :file_path "x" :old_string "a"
                                       :new_string "b"))))
      (sprig-review-consume (list 'tool-call "t1" "Edit" input))
      (sprig-review-consume '(tool-result "t1" nil "secret")))
    (sprig-review-flush)
    ;; The tool folds by default; unfold it like a user would, to reach the
    ;; result section nested inside it, which folds by default too.
    (goto-char (point-min))
    (should (re-search-forward "^Edit  " nil t))
    (should (oref (magit-current-section) hidden))
    (magit-section-show (magit-current-section))
    (goto-char (point-min))
    (should (re-search-forward "↳ result" nil t))
    (let ((sec (magit-current-section)))
      (should (eq (oref sec type) 'sprig-result))
      (should (oref sec hidden))
      (magit-section-show sec)
      (should-not (oref sec hidden)))
    ;; A later event refreshes the buffer; both unfolds must survive.
    (sprig-review-consume '(done 0.01 nil))
    (sprig-review-flush)
    (goto-char (point-min))
    (should (re-search-forward "↳ result" nil t))
    (should-not (oref (magit-current-section) hidden))))

(ert-deftest sprig-review-mode-test-refresh-keeps-a-window-put ()
  ;; A window has its own point and start, and `erase-buffer' collapses both.
  ;; The refresh also runs from a timer, in whatever buffer is current, so the
  ;; buffer's own point is not the one on screen.  Restoring only that threw
  ;; the window to the top of the buffer mid-turn.
  (let ((buf (get-buffer-create "*sprig-review-scroll-test*")))
    (unwind-protect
        (with-current-buffer buf
          (sprig-review-mode)
          (dotimes (i 60)
            (sprig-review-consume (list 'text (format "line %d\n" i)))
            (sprig-review-consume '(text-block)))
          (sprig-review-flush)
          (let ((win (display-buffer buf '(display-buffer-same-window))))
            (should (window-live-p win))
            (set-window-buffer win buf)
            ;; Park the window part-way down, as if reading mid-turn.
            (goto-char (point-min))
            (re-search-forward "line 40")
            (let ((mark (magit-section-ident (magit-current-section))))
              (set-window-point win (point))
              (set-window-start win (line-beginning-position))
              (let ((start-line (line-number-at-pos (window-start win))))
                ;; A refresh driven from another buffer, exactly as the
                ;; coalescing timer drives it.
                (with-temp-buffer
                  (sprig-review-flush buf)
                  (with-current-buffer buf (sprig-review--refresh)))
                ;; The window is still on the same section, not at the top.
                (should (window-live-p win))
                (should (equal (save-excursion (goto-char (window-point win))
                                               (magit-section-ident
                                                (magit-current-section)))
                               mark))
                (should (> (line-number-at-pos (window-start win)) 1))
                (should (= (line-number-at-pos (window-start win))
                           start-line))))))
      (kill-buffer buf))))

(ert-deftest sprig-review-mode-test-reset ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "gone"))
    (sprig-review-flush)
    (should (string-match-p "gone" (buffer-string)))
    ;; reset renders synchronously, no flush needed.
    (sprig-review-reset '(:title "Fresh"))
    (should-not (string-match-p "gone" (buffer-string)))
    (should (string-match-p "Fresh" (buffer-string)))))

(ert-deftest sprig-review-mode-test-consume-debounces ()
  (with-temp-buffer
    (sprig-review-mode)
    ;; The first text of a run defers (no tail yet) until a flush.
    (sprig-review-consume '(text "a"))
    (sprig-review-consume '(text "b"))
    (should-not (string-match-p "ab" (buffer-string)))
    (sprig-review-flush)
    (should (string-match-p "ab" (buffer-string)))))

(ert-deftest sprig-review-mode-test-text-fast-path ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "Hel"))
    (sprig-review-flush)                 ; establishes the tail
    (should (string-match-p "Hel" (buffer-string)))
    ;; A further delta now appends in place, with no flush and no timer.
    (should (null sprig-review--timer))
    (sprig-review-consume '(text "lo"))
    (should (null sprig-review--timer))
    (should (string-match-p "Hello" (buffer-string)))
    ;; A structural event rebuilds from the model to the same text.
    (sprig-review-consume '(done 0.01 nil))
    (sprig-review-flush)
    (should (string-match-p "Hello" (buffer-string)))))

(ert-deftest sprig-review-mode-test-text-fast-path-newlines ()
  ;; The in-place append and a full rebuild must agree across a newline
  ;; boundary in the streamed text.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "line1\n"))
    (sprig-review-flush)
    (sprig-review-consume '(text "line2"))   ; fast append after a newline
    (should (string-match-p "line1\nline2" (buffer-string)))
    ;; Force a rebuild from the model; it must contain the same.
    (sprig-review-consume '(tool-call "t1" "Bash" "{}"))
    (sprig-review-flush)
    (should (string-match-p "line1\nline2" (buffer-string)))))

(ert-deftest sprig-review-mode-test-replayed-text-is-not-a-live-tail ()
  ;; A stored session log carries no `done' event, so the last text block must
  ;; not be taken for a streaming tail on position alone: replayed history is
  ;; settled, and a live tail renders raw, costing that block its markdown.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-seed '((user "q") (text "the answer")))
    (should-not sprig-review--streaming)
    (should-not sprig-review--tail)
    (should (string-match-p "the answer" (buffer-string)))))

(ert-deftest sprig-review-mode-test-tail-follows-streaming ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "partial"))
    (sprig-review-flush)
    ;; Mid-turn: the block is live, so it takes appends in place.
    (should sprig-review--streaming)
    (should sprig-review--tail)
    (sprig-review-consume '(done 0.01 nil))
    (sprig-review-flush)
    ;; The turn settled, so the block re-renders as prose, with no tail.
    (should-not sprig-review--streaming)
    (should-not sprig-review--tail)
    (should (string-match-p "partial" (buffer-string)))))

(ert-deftest sprig-review-mode-test-renders-user-and-thinking ()
  (let ((model (sprig-review-build
                '((user "the question") (thinking "pondering")
                  (text "the answer") (title "T")))))
    (sprig-review-tests--rendered model nil
      (let ((s (buffer-string)))
        (should (string-match-p "the question" s))
        ;; Thinking keeps its label, being a folded row rather than prose.
        (should (string-match-p "^thinking$" s))
        ;; The thinking body folds away, so its text is not in the buffer.
        (should-not (string-match-p "pondering" s))
        (should (string-match-p "the answer" s))
        ;; The model-carried title shows in the header.
        (should (string-match-p "T" s))))
    ;; The thinking section folds by default; expanding draws in its body.
    (sprig-review-tests--rendered model nil
      (goto-char (point-min))
      (should (re-search-forward "^thinking$" nil t))
      (should (oref (magit-current-section) hidden))
      (magit-section-show (magit-current-section))
      (should (string-match-p "pondering" (buffer-string))))))

(ert-deftest sprig-review-mode-test-open-file ()
  (let ((file (make-temp-file "sprig-session" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-serialize (list :type "ai-title" :aiTitle "Fixture"))
                    "\n"
                    (json-serialize
                     (list :type "user" :message (list :content "hello")))
                    "\n"
                    (json-serialize
                     (list :type "assistant"
                           :message (list :content
                                          (vector (list :type "text"
                                                        :text "world")))))
                    "\n"))
          (should (= (length (sprig-review-read-session-lines file)) 3))
          (save-window-excursion
            (sprig-review-open-file file)
            (with-current-buffer (format "*sprig-review: %s*"
                                         (file-name-base file))
              (should (derived-mode-p 'sprig-review-mode))
              (let ((s (buffer-string)))
                (should (string-match-p "Fixture" s))
                (should (string-match-p "hello" s))
                (should (string-match-p "world" s))))))
      (delete-file file))))

;;;; Marks and verbs

(ert-deftest sprig-review-mode-test-reject-instruction ()
  (let ((one (sprig-review-reject-instruction
              (list (cons "foo.el" (list :old '("a") :new '("b")))))))
    (should (string-match-p "undo this change" one))
    (should (string-match-p "foo\\.el" one))
    (should (string-match-p "-a" one))
    (should (string-match-p "\\+b" one)))
  (should (string-match-p
           "undo these changes"
           (sprig-review-reject-instruction
            (list (cons "a" (list :old '("x") :new nil))
                  (cons "b" (list :old '("y") :new nil)))))))

(ert-deftest sprig-review-mode-test-run-instruction ()
  (should (string-match-p "make test"
                          (sprig-review-run-instruction "make test"))))

(ert-deftest sprig-review-mode-test-marking ()
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (should (re-search-forward "^\\+new$" nil t))
    (let ((ident (magit-section-ident (magit-current-section))))
      (sprig-review-toggle-mark)
      (should (member ident sprig-review--marks))
      (should (memq (magit-get-section ident) (sprig-review--marked-sections)))
      ;; Toggling again clears it.
      (goto-char (point-min))
      (re-search-forward "^\\+new$")
      (sprig-review-toggle-mark)
      (should-not (member ident sprig-review--marks)))))

(ert-deftest sprig-review-mode-test-reject-pairs ()
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (re-search-forward "^\\+new$")
    (let ((pairs (sprig-review--reject-pairs (list (magit-current-section)))))
      (should (= (length pairs) 1))
      (should (equal (caar pairs) "/tmp/x.el"))
      (should (equal (plist-get (cdar pairs) :new) '("new"))))))

(ert-deftest sprig-review-mode-test-reject-verb ()
  ;; The whole verb path: extract the hunk at point, build the instruction,
  ;; hand it to the steer (stubbed here to capture it).  It steers, since a
  ;; hunk lands mid-turn and the agent should hear about a bad one at once.
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (re-search-forward "^\\+new$")
    (let (sent)
      (cl-letf (((symbol-function 'sprig-review--steer)
                 (lambda (text) (setq sent text))))
        (sprig-review-reject))
      (should (string-match-p "undo this change" sent))
      (should (string-match-p "/tmp/x\\.el" sent))
      (should (string-match-p "\\+new" sent)))))

(ert-deftest sprig-review-mode-test-state-says-compacting ()
  ;; A compaction stops a turn for a minute or more, so it outranks the
  ;; turn's own state: `working…' or `sent, awaiting reply' would both read
  ;; as an ordinary wait and leave the buffer looking stalled.
  (with-temp-buffer
    (let ((sprig--compacting t)
          (sprig--busy t)
          (sprig-review--streaming t))
      (should (equal (sprig-review--state nil)
                     '("▼" "compacting…" sprig-review-working))))
    ;; Once it lands, the turn speaks for itself again.
    (let ((sprig--compacting nil)
          (sprig--busy t)
          (sprig-review--streaming t))
      (should (equal (cadr (sprig-review--state nil)) "working…"))))
  ;; A dialog still wins: it is stopped on you, which no wait outranks.
  (with-temp-buffer
    (let ((sprig--compacting t)
          (model (list :blocks (list (list :type 'dialog :id "d" :request nil)))))
      (should (equal (car (sprig-review--state model)) "?")))))

(ert-deftest sprig-review-mode-test-context-indicator ()
  (let ((sprig-context-large-tokens 150000)
        (sprig-context-huge-tokens 200000))
    ;; Below the first threshold: bare count, no escalation face.
    ;; Below the thresholds it still carries a face of its own, never nil:
    ;; inheriting the state face would paint a normal context yellow purely
    ;; because a turn was running.
    (should (equal (sprig-review--context-indicator 90000)
                   '("90.0k" . sprig-review-context)))
    ;; Large and very large: a word and an escalating face.
    (should (equal (sprig-review--context-indicator 160000)
                   '("160.0k (large)" . sprig-review-context-large)))
    (should (equal (sprig-review--context-indicator 250000)
                   '("250.0k (very large)" . sprig-review-context-huge)))
    (should-not (sprig-review--context-indicator 0))
    (should-not (sprig-review--context-indicator nil))))

(ert-deftest sprig-review-mode-test-state-line-flags-large-context ()
  ;; The context in use rides on the state line, where the reader is watching
  ;; the turn, and its face escalates once it grows large.
  (let ((sprig-context-large-tokens 150000)
        (sprig-context-huge-tokens 200000)
        (model (sprig-review-build
                '((context 160000) (text "hi") (done 0.01 nil)))))
    (sprig-review-tests--rendered model nil
      (goto-char (point-max)) (forward-line -1)
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        (should (string-match-p "turn over" line))
        (should (string-match-p "160\\.0k (large)" line)))
      ;; The large segment carries its own escalation face, not the state face.
      (goto-char (point-min))
      (should (re-search-forward "large" nil t))
      (should (eq (get-text-property (1- (point)) 'font-lock-face)
                  'sprig-review-context-large)))))

(ert-deftest sprig-review-mode-test-no-section-highlight ()
  ;; The section at point is not what the verbs act on, so magit's highlight
  ;; only washes out the faces the conversation is read through.  Both
  ;; switches are buffer-local, so a magit buffer keeps its own highlight.
  (with-temp-buffer
    (sprig-review-mode)
    (should-not magit-section-highlight-current)
    (should-not magit-section-highlight-selection)
    (should (local-variable-p 'magit-section-highlight-current))
    (should (local-variable-p 'magit-section-highlight-selection)))
  (with-temp-buffer
    (should magit-section-highlight-current)))

(ert-deftest sprig-review-mode-test-reload-resettles-an-open-buffer ()
  ;; A mode body runs once, at buffer creation, so a reload alone leaves a
  ;; buffer opened beforehand with the old settings: the very buffer the
  ;; reload was meant to fix keeps the highlight.
  (with-temp-buffer
    (sprig-review-mode)
    ;; Stand in for a buffer whose mode body ran before the edit.
    (setq-local magit-section-highlight-current t)
    (setq-local magit-section-highlight-selection t)
    (setq magit-section-highlight-force-update nil)
    (sprig--resettle-review-buffers)
    (should-not magit-section-highlight-current)
    (should-not magit-section-highlight-selection)
    ;; A highlight already drawn goes on the next command, not just later.
    (should magit-section-highlight-force-update)))

(ert-deftest sprig-review-mode-test-context-face-is-not-the-turn-face ()
  ;; A normal context must not be painted by the turn: the busy state and
  ;; the large-context face are both yellow, so inheriting the state face
  ;; made a perfectly ordinary context read as a warning mid-turn.
  (let ((sprig-context-large-tokens 150000)
        (sprig-context-huge-tokens 200000)
        (model (sprig-review-build '((context 90000) (text "hi")))))
    (sprig-review-tests--rendered model nil
      (goto-char (point-min))
      (should (re-search-forward "90\\.0k" nil t))
      (should (eq (get-text-property (1- (point)) 'font-lock-face)
                  'sprig-review-context)))))

(ert-deftest sprig-review-mode-test-new-sessions-same-dir-get-distinct-buffers ()
  ;; Two fresh sessions in one directory must not share a buffer: reusing it
  ;; would stomp the first session and stream its output into the second.
  (let ((sprig-remote nil) buffers)
    (unwind-protect
        (progn
          (push (sprig-review-session "/tmp/sprig-newsess-probe/") buffers)
          (push (sprig-review-session "/tmp/sprig-newsess-probe/") buffers)
          (should (= 2 (length buffers)))
          (should (not (eq (nth 0 buffers) (nth 1 buffers))))
          (should (= 2 (length (seq-uniq (mapcar #'buffer-name buffers))))))
      (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest sprig-review-mode-test-fork-gets-its-own-buffer ()
  ;; A fork carries its parent's id until the CLI answers with its own, so it
  ;; must not land in the parent's buffer: that would stomp the very session
  ;; it was forked from.  It resumes the parent id with the fork flag set.
  (let ((sprig-remote nil) parent forked)
    (unwind-protect
        (progn
          (setq parent (sprig-review-session "/tmp/sprig-fork-probe/" "sess-1"))
          (setq forked (sprig-review-session "/tmp/sprig-fork-probe/" "sess-1"
                                             nil t))
          (should-not (eq parent forked))
          (with-current-buffer forked
            (should (equal sprig--session-id "sess-1"))
            (should sprig--fork-session)
            (should (string-match-p "fork" (buffer-name))))
          ;; The parent is left alone: it is no fork, and keeps its own buffer.
          (with-current-buffer parent
            (should-not sprig--fork-session))
          ;; Opening the parent again still reuses the parent's buffer.
          (should (eq parent (sprig-review-session "/tmp/sprig-fork-probe/"
                                                   "sess-1"))))
      (dolist (b (list parent forked))
        (when (buffer-live-p b) (kill-buffer b))))))

(ert-deftest sprig-review-mode-test-fork-needs-a-session ()
  ;; Nothing to fork from before the session has an id of its own.
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig--session-id nil)
    (should-error (sprig-review-fork) :type 'user-error)))

(ert-deftest sprig-review-mode-test-run-verb ()
  ;; `x' steers rather than sends, so asking for a command lands in the turn
  ;; you are watching instead of waiting it out.
  (let ((model (sprig-review-build
                `((tool-call "b1" "Bash"
                             ,(json-serialize (list :command "make test")))
                  (tool-result "b1" nil "ok")))))
    (sprig-review-tests--rendered model nil
      (goto-char (point-min))
      (re-search-forward "^Bash  ")
      (let (sent)
        (cl-letf (((symbol-function 'sprig-review--steer)
                   (lambda (text) (setq sent text))))
          (sprig-review-run))
        (should (string-match-p "make test" sent))))))

(ert-deftest sprig-review-mode-test-fenced-blocks-parse ()
  ;; The parser pulls each triple-backtick block with its language tag, and
  ;; the runnable filter keeps untagged/shell fences, dropping code and data.
  (let ((bs (sprig-review--fenced-blocks
             "intro\n```sh\nmake test\n```\nmid\n```diff\n- a\n+ b\n```\nend")))
    (should (equal (mapcar (lambda (b) (plist-get b :lang)) bs) '("sh" "diff")))
    (should (equal (plist-get (car bs) :body) "make test"))
    (should (equal (plist-get (cadr bs) :body) "- a\n+ b")))
  (should (equal (mapcar (lambda (b) (plist-get b :lang))
                         (sprig-review--runnable-blocks
                          "```sh\na\n```\n```diff\n-x\n```\n```\nb\n```"))
                 '("sh" nil))))

(ert-deftest sprig-review-mode-test-run-verb-prose-fence ()
  ;; `x' on a prose block runs the fenced command point is in, reaching a
  ;; command the agent proposed but did not execute.
  (let ((model (sprig-review-build
                '((text "First:\n\n```sh\nmake test\n```\n\nOr:\n\n```bash\n./deploy.sh\n```\n\nWhich?")))))
    (sprig-review-tests--rendered model nil
      (let (sent)
        (cl-letf (((symbol-function 'sprig-review--steer)
                   (lambda (text) (setq sent text))))
          (goto-char (point-min)) (search-forward "make test")
          (sprig-review-run)
          (should (string-match-p "make test" sent))
          (goto-char (point-min)) (search-forward "deploy.sh")
          (sprig-review-run)
          (should (string-match-p "deploy\\.sh" sent))
          ;; Point in prose between two blocks is ambiguous; it refuses.
          (goto-char (point-min)) (search-forward "Which?")
          (should-error (sprig-review-run) :type 'user-error))))))

(ert-deftest sprig-review-mode-test-run-verb-skips-non-shell-fence ()
  ;; A diff (or other code/data) block is not a command, so `x' refuses it.
  (let ((model (sprig-review-build '((text "Change:\n\n```diff\n- old\n+ new\n```")))))
    (sprig-review-tests--rendered model nil
      (goto-char (point-min)) (search-forward "old")
      (should-error (sprig-review-run) :type 'user-error))))

(ert-deftest sprig-review-mode-test-commit-verb ()
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (let (sent)
      (cl-letf (((symbol-function 'sprig-review--send)
                 (lambda (text) (setq sent text))))
        (sprig-review-commit))
      (should (string-match-p "commit" sent)))))

(ert-deftest sprig-review-mode-test-compact-verb ()
  ;; Compact sends the CLI's own /compact command as a turn; a prefix arg's
  ;; instructions ride along to steer the summary.
  (let (sent)
    (cl-letf (((symbol-function 'sprig-review--send)
               (lambda (text &optional _mode) (setq sent text))))
      (sprig-review-compact)
      (should (equal sent "/compact"))
      (sprig-review-compact "keep the design decisions")
      (should (equal sent "/compact keep the design decisions"))
      ;; A blank instruction falls back to the bare command.
      (sprig-review-compact "   ")
      (should (equal sent "/compact")))))

(ert-deftest sprig-review-mode-test-yes-and-no-verbs ()
  ;; Yes/no affirm and decline the agent's last prose question: each sends its
  ;; configured instruction, and neither commits (that stays the `C' verb).
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (let (sent)
      (cl-letf (((symbol-function 'sprig-review--send)
                 (lambda (text) (setq sent text))))
        (sprig-review-accept)
        (should (equal sent sprig-review-accept-instruction))
        (sprig-review-decline)
        (should (equal sent sprig-review-decline-instruction))))))

(ert-deftest sprig-review-mode-test-retry-verb ()
  (let ((model (sprig-review-build '((user "first ask") (text "reply")))))
    (sprig-review-tests--rendered model nil
      ;; retry rebuilds from events; seed them so the model is discoverable.
      (setq sprig-review--events '((text "reply") (user "first ask")))
      (let (sent)
        (cl-letf (((symbol-function 'sprig-review--send)
                   (lambda (text) (setq sent text))))
          (sprig-review-retry))
        (should (equal sent "first ask"))))))

(ert-deftest sprig-review-mode-test-file-location ()
  (with-temp-buffer
    (sprig-review-mode)
    ;; Local: the path is used as-is.
    (should (equal (sprig-review--file-location "/a/b.el") "/a/b.el"))
    ;; Remote: a TRAMP name on the session host.
    (setq sprig-review--remote "me@host")
    (should (equal (sprig-review--file-location "/a/b.el")
                   "/ssh:me@host:/a/b.el"))))

(ert-deftest sprig-review-mode-test-section-file ()
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    ;; On a hunk: the owning change's file.
    (goto-char (point-min))
    (re-search-forward "^\\+new$")
    (should (equal (sprig-review--section-file (magit-current-section))
                   "/tmp/x.el"))
    ;; On the change (file) heading: the same file.
    (goto-char (point-min))
    (re-search-forward "^/tmp/x\\.el$")
    (should (equal (sprig-review--section-file (magit-current-section))
                   "/tmp/x.el")))
  ;; A Bash tool refers to no file.
  (let ((model (sprig-review-build
                `((tool-call "b1" "Bash"
                             ,(json-serialize (list :command "ls")))
                  (tool-result "b1" nil "out")))))
    (sprig-review-tests--rendered model nil
      (goto-char (point-min))
      (re-search-forward "^Bash  ")
      (should (null (sprig-review--section-file (magit-current-section)))))))

(ert-deftest sprig-review-mode-test-set-title ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-seed '((text "hi")) '(:title "Old"))
    (should (string-match-p "Old" (buffer-string)))
    (sprig-review-set-title "New")
    (should (equal (plist-get sprig-review--meta :title) "New"))
    (should (string-match-p "New" (buffer-string)))
    (should-not (string-match-p "Old" (buffer-string)))))

(ert-deftest sprig-review-mode-test-header-mode ()
  ;; Plan mode shows in the header; auto (the normal state) does not.
  (sprig-review-tests--rendered (sprig-review-build '((mode "plan") (user "x"))) nil
    (should (string-match-p "Mode:" (buffer-string)))
    (should (string-match-p "plan" (buffer-string))))
  (sprig-review-tests--rendered (sprig-review-build '((mode "auto") (user "x"))) nil
    (should-not (string-match-p "Mode:" (buffer-string)))))

(ert-deftest sprig-review-mode-test-compose-plan-mode ()
  ;; Composing in plan mode sends the turn with mode "plan".
  (with-temp-buffer
    (sprig-review-mode)
    (let ((review (current-buffer)))
      (with-temp-buffer
        (sprig-review-compose-mode)
        (insert "make a plan")
        (setq sprig-review--compose-target review
              sprig-review--compose-context nil
              sprig-review--compose-mode "plan")
        (let (sent-text sent-mode)
          (cl-letf (((symbol-function 'sprig-review--send)
                     (lambda (text &optional mode)
                       (setq sent-text text sent-mode mode)))
                    ((symbol-function 'quit-window) #'ignore))
            (sprig-review-compose-send))
          (should (equal sent-text "make a plan"))
          (should (equal sent-mode "plan")))))))

(ert-deftest sprig-review-mode-test-compose-steer ()
  ;; A plain `c c' routes to the steer path, not the ordinary send, and
  ;; carries any marked context with it just the same.
  (with-temp-buffer
    (sprig-review-mode)
    (let ((review (current-buffer)))
      (with-temp-buffer
        (sprig-review-compose-mode)
        (insert "actually, stop and do X")
        (setq sprig-review--compose-target review
              sprig-review--compose-context "Regarding this hunk"
              sprig-review--compose-mode nil
              sprig-review--compose-queue nil)
        (let (steered sent)
          (cl-letf (((symbol-function 'sprig-review--steer)
                     (lambda (text) (setq steered text)))
                    ((symbol-function 'sprig-review--send)
                     (lambda (text &optional _mode) (setq sent text)))
                    ((symbol-function 'quit-window) #'ignore))
            (sprig-review-compose-send))
          (should-not sent)
          (should (equal steered
                         "Regarding:\n\nRegarding this hunk\n\nactually, stop and do X")))))))

(ert-deftest sprig-review-mode-test-queue-composes-with-the-flag ()
  ;; `sprig-review-queue' opens the compose buffer marked to wait, and in no
  ;; permission mode of its own: the turn it queues behind has picked one.
  (with-temp-buffer
    (sprig-review-mode)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (sprig-review-queue))
    (with-current-buffer "*sprig-message*"
      (should sprig-review--compose-queue)
      (should-not sprig-review--compose-mode))
    ;; Whereas a plain `c c' compose does not wait: it speaks now.
    (with-temp-buffer
      (sprig-review-mode)
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (sprig-review-message))
      (with-current-buffer "*sprig-message*"
        (should-not sprig-review--compose-queue)))
    (kill-buffer "*sprig-message*")))

(ert-deftest sprig-review-mode-test-compose-send-routes-by-flag ()
  "A plain `c c' steers, `c q' queues, `c p' delivers with its mode."
  (dolist (case '((nil     nil    steer)
                  (nil     t      queue)
                  ("plan"  nil    send)))
    (pcase-let ((`(,mode ,queue ,want) case)
                (took nil))
      (with-temp-buffer
        (let ((review (current-buffer)))
          (sprig-review-mode)
          (with-current-buffer (get-buffer-create "*sprig-message*")
            (sprig-review-compose-mode)
            (erase-buffer)
            (insert "do the thing")
            (setq sprig-review--compose-target review
                  sprig-review--compose-context nil
                  sprig-review--compose-mode mode
                  sprig-review--compose-queue queue)
            (cl-letf (((symbol-function 'quit-window) #'ignore)
                      ((symbol-function 'sprig-review--steer)
                       (lambda (_) (setq took 'steer)))
                      ((symbol-function 'sprig-review--queue)
                       (lambda (_) (setq took 'queue)))
                      ((symbol-function 'sprig-review--send)
                       (lambda (&rest _) (setq took 'send))))
              (sprig-review-compose-send)))
          (should (eq took want))))))
  (kill-buffer "*sprig-message*"))

(ert-deftest sprig-review-mode-test-compose-send-keeps-text-when-the-send-fails ()
  ;; `quit-window' kills the compose buffer, so sending has to come first: a
  ;; `c p' refused mid-turn used to signal after the kill and take the prose
  ;; with it, leaving the user an error where their message had been.
  (with-temp-buffer
    (let ((review (current-buffer))
          (quit nil))
      (sprig-review-mode)
      (with-current-buffer (get-buffer-create "*sprig-message*")
        (sprig-review-compose-mode)
        (erase-buffer)
        (insert "plan me something")
        (setq sprig-review--compose-target review
              sprig-review--compose-context nil
              sprig-review--compose-mode "plan"
              sprig-review--compose-queue nil)
        (cl-letf (((symbol-function 'quit-window) (lambda (&rest _) (setq quit t)))
                  ((symbol-function 'sprig-review--send)
                   (lambda (&rest _) (user-error "A turn is already in flight"))))
          (should-error (sprig-review-compose-send) :type 'user-error))
        ;; The window never quit, so the buffer lives and still holds the text.
        (should-not quit)
        (should (equal (string-trim (buffer-string)) "plan me something"))))
    (kill-buffer "*sprig-message*")))

(ert-deftest sprig-review-mode-test-state-shows-the-queue ()
  "A queued message is visible on the state line, and only while queued."
  (with-temp-buffer
    (sprig-review-mode)
    (let ((inhibit-read-only t))
      (setq-local sprig--busy t)
      (setq-local sprig--queued '("later, do X" "and then Y"))
      (sprig-review--insert-state nil)
      (should (string-match-p "2 queued" (buffer-string)))
      (erase-buffer)
      ;; Flushed: the line stops advertising a queue that is gone.
      (setq-local sprig--queued nil)
      (sprig-review--insert-state nil)
      (should-not (string-match-p "queued" (buffer-string))))))

;;;; A review buffer that owns its session

(ert-deftest sprig-review-mode-test-owned-sink-tracks-and-consumes ()
  "The owner sink books transport state and folds events into the model."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig--sink #'sprig--review-sink)
    (should (eq sprig--sink #'sprig--review-sink))
    (cl-letf (((symbol-function 'sprig--status-refresh) #'ignore))
      (sprig--review-sink '(session "abc"))
      (should (equal sprig--session-id "abc"))
      (sprig--review-sink '(mode "plan"))
      (should (equal sprig--permission-mode "plan"))
      (setq sprig--busy t)
      (sprig--review-sink '(done nil nil))
      (should-not sprig--busy))
    (should (member '(session "abc") sprig-review--events))))

(ert-deftest sprig-review-mode-test-transport-routes-to-owned-sink ()
  "`sprig--handle' funcalls the buffer-local sink, so a self-owned review
buffer receives streamed transport events without a Markdown transcript."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig--sink #'sprig--review-sink)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'process-get)
                 (lambda (_proc key) (when (eq key :conv-buffer) buf)))
                ((symbol-function 'sprig--status-refresh) #'ignore))
        (sprig--handle
         'fake-proc
         (json-serialize
          '(:type "stream_event"
            :event (:type "content_block_delta" :index 0
                    :delta (:type "text_delta" :text "hello")))))))
    (should (member '(text "hello") sprig-review--events))))

(ert-deftest sprig-review-mode-test-owned-send-echoes-user ()
  "An owned send transmits the turn and echoes the user block locally."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig--sink #'sprig--review-sink)
    (let (sent)
      (cl-letf (((symbol-function 'sprig--ensure) #'ignore)
                ((symbol-function 'sprig--send-user)
                 (lambda (text) (setq sent text)))
                ((symbol-function 'sprig--status-refresh) #'ignore))
        (sprig-review--send "do it"))
      (should (equal sent "do it"))
      (should sprig--busy)
      (should (member '(user "do it") sprig-review--events)))))

(ert-deftest sprig-review-mode-test-owned-interrupt ()
  "An owned interrupt asks the CLI to end the turn and keeps the session live.
It sends an `interrupt' request and arms the fallback timer without
tearing the process down; the turn's `done' does the clearing later."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig--sink #'sprig--review-sink
          sprig--busy t sprig--interrupt-timer nil)
    (let (interrupted torn)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'sprig--send-interrupt)
                       (lambda () (setq interrupted t)))
                      ((symbol-function 'sprig--teardown-process)
                       (lambda () (setq torn t)))
                      ((symbol-function 'sprig--status-refresh) #'ignore))
              (sprig-review-interrupt))
            (should interrupted)
            (should-not torn)
            (should sprig--busy)
            (should (timerp sprig--interrupt-timer)))
        (sprig--clear-interrupt)))))

(provide 'sprig-review-mode-tests)
;;; sprig-review-mode-tests.el ends here
