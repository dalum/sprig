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
timestamp followed by the running-bar column."
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
      (should (equal (buffer-string) "\nthe question\n\nthe answer\n"))
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
                             "done\n"))))))

(ert-deftest sprig-review-mode-test-thinking-packs-with-the-tool-rows ()
  ;; A thinking block folds to a one-line row too, so it joins the run
  ;; rather than breaking it in two.
  (let ((model (sprig-review-build
                `((text "on it")
                  (thinking "pondering")
                  (tool-call "t1" "Read" ,(json-serialize (list :file_path "a")))))))
    (sprig-review-tests--rendered model nil
      (should (equal (buffer-string) "\non it\n\nthinking\nRead  a\n")))))

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
    (should (= (sprig-review--margin-width) 1))))

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
        (should (equal (buffer-string) "\nq\n\nBash  ls\n"))
        ;; One per block, each against its own first line.  Nothing is
        ;; running, so the bar column is blank.
        (should (equal (sprig-review-tests--margins) '("09:16 " "09:17 "))))
      ;; With the format off, only the bar column is left.
      (let ((sprig-review-timestamp-format nil))
        (sprig-review-tests--rendered model nil
          (should (equal (sprig-review-tests--margins) '(" " " ")))
          (should (= left-margin-width 1)))))))

(ert-deftest sprig-review-mode-test-running-bar-marks-the-turn-in-flight ()
  ;; The bar runs down the side of what the agent is working on, and goes the
  ;; moment the turn lands: that is the whole signal that nothing is still
  ;; running in the background.
  (cl-flet ((bars ()
              ;; Just the bar column; the live path stamps its own arrival
              ;; times, so the rest of the margin is the clock's business.
              (mapcar (lambda (m) (substring m -1))
                      (sprig-review-tests--margins))))
    (with-temp-buffer
      (sprig-review-mode)
      (sprig-review-consume '(user "do it"))
      (sprig-review-consume '(text "on it"))
      (sprig-review-consume (list 'tool-call "t1" "Bash"
                                  (json-serialize (list :command "ls"))))
      (sprig-review-flush)
      ;; Mid-turn: your own turn is unbarred, the agent's work carries it.
      (should sprig-review--streaming)
      (should (equal (bars) '(" " "▌" "▌")))
      ;; The turn lands and every bar goes.
      (sprig-review-consume '(done 0.01 nil))
      (sprig-review-flush)
      (should-not sprig-review--streaming)
      (should (equal (bars) '(" " " " " "))))))

(ert-deftest sprig-review-mode-test-a-tool-only-turn-is-barred ()
  ;; The bar has to follow the turn, not the prose: a turn opening with a tool
  ;; call is working just as much as one opening with text.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume (list 'tool-call "t1" "Bash"
                                (json-serialize (list :command "ls"))))
    (sprig-review-flush)
    (should sprig-review--streaming)
    (should (equal (mapcar (lambda (m) (substring m -1))
                           (sprig-review-tests--margins))
                   '("▌")))))

(ert-deftest sprig-review-mode-test-replayed-history-is-never-barred ()
  ;; A conversation read from disk is finished by definition; it must not
  ;; read as though work were still going on in the background.
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-seed '((time "2026-07-15T09:00:00.000Z") (user "q")
                         (time "2026-07-15T09:01:00.000Z") (text "a")))
    (should-not sprig-review--streaming)
    (should-not (sprig-review--live-blocks
                 (plist-get (sprig-review-build (reverse sprig-review--events))
                            :blocks)))
    (dolist (margin (sprig-review-tests--margins))
      (should-not (string-match-p "▌" margin)))))

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
                    ("a"   . sprig-review-accept)
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
  ;; hand it to the send (stubbed here to capture it).
  (sprig-review-tests--rendered-expanded (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (re-search-forward "^\\+new$")
    (let (sent)
      (cl-letf (((symbol-function 'sprig-review--send)
                 (lambda (text) (setq sent text))))
        (sprig-review-reject))
      (should (string-match-p "undo this change" sent))
      (should (string-match-p "/tmp/x\\.el" sent))
      (should (string-match-p "\\+new" sent)))))

(ert-deftest sprig-review-mode-test-run-verb ()
  (let ((model (sprig-review-build
                `((tool-call "b1" "Bash"
                             ,(json-serialize (list :command "make test")))
                  (tool-result "b1" nil "ok")))))
    (sprig-review-tests--rendered model nil
      (goto-char (point-min))
      (re-search-forward "^Bash  ")
      (let (sent)
        (cl-letf (((symbol-function 'sprig-review--send)
                   (lambda (text) (setq sent text))))
          (sprig-review-run))
        (should (string-match-p "make test" sent))))))

(ert-deftest sprig-review-mode-test-commit-verb ()
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (let (sent)
      (cl-letf (((symbol-function 'sprig-review--send)
                 (lambda (text) (setq sent text))))
        (sprig-review-commit))
      (should (string-match-p "commit" sent)))))

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
  ;; `c s' routes to the steer path, not the ordinary send, and carries any
  ;; marked context with it just the same.
  (with-temp-buffer
    (sprig-review-mode)
    (let ((review (current-buffer)))
      (with-temp-buffer
        (sprig-review-compose-mode)
        (insert "actually, stop and do X")
        (setq sprig-review--compose-target review
              sprig-review--compose-context "Regarding this hunk"
              sprig-review--compose-mode nil
              sprig-review--compose-steer t)
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

(ert-deftest sprig-review-mode-test-steer-composes-with-the-flag ()
  ;; `sprig-review-steer' opens the compose buffer marked to steer, and in no
  ;; permission mode of its own: a turn in flight has already picked one.
  (with-temp-buffer
    (sprig-review-mode)
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (sprig-review-steer))
    (with-current-buffer "*sprig-message*"
      (should sprig-review--compose-steer)
      (should-not sprig-review--compose-mode))
    ;; Whereas a plain `c c' compose does not steer.
    (with-temp-buffer
      (sprig-review-mode)
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (sprig-review-message))
      (with-current-buffer "*sprig-message*"
        (should-not sprig-review--compose-steer)))
    (kill-buffer "*sprig-message*")))

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
  "An owned interrupt tears the session down when a turn is in flight."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig--sink #'sprig--review-sink
          sprig--busy t)
    (cl-letf (((symbol-function 'sprig--teardown-process)
               (lambda () (setq sprig--busy nil)))
              ((symbol-function 'sprig--status-refresh) #'ignore))
      (sprig-review-interrupt))
    (should-not sprig--busy)))

(provide 'sprig-review-mode-tests)
;;; sprig-review-mode-tests.el ends here
