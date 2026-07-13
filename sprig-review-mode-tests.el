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
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (let ((s (buffer-string)))
      (should (string-match-p "assistant" s))
      (should (string-match-p "Editing the file\\." s))
      (should (string-match-p "🔧 Edit" s))
      (should (string-match-p "/tmp/x\\.el" s))
      ;; The diff header shows the +/- counts.
      (should (string-match-p "(\\+1 -2)" s))
      ;; Removed lines then added lines.
      (should (string-match-p "^-old$" s))
      (should (string-match-p "^-gone$" s))
      (should (string-match-p "^\\+new$" s))
      ;; The result is present.
      (should (string-match-p "↳ result" s))
      (should (string-match-p "applied" s)))))

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
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (should (re-search-forward "^\\+new$" nil t))
    (let ((sec (magit-current-section)))
      (should (eq (oref sec type) 'sprig-hunk))
      (should (equal (plist-get (oref sec value) :new) '("new"))))))

(ert-deftest sprig-review-mode-test-tool-section-carries-block ()
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (should (re-search-forward "🔧 Edit" nil t))
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
        (should (string-match-p "🔧 Bash" s))
        ;; Only the first command line is summarised in the heading.
        (should (string-match-p "ls -la" s))
        (should-not (string-match-p "🔧 Bash.*second" s))))))

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
    (should-not (string-match-p "🔧" (buffer-string)))
    (let ((input (json-serialize (list :file_path "x" :old_string "a"
                                       :new_string "b"))))
      (sprig-review-consume (list 'tool-call "t1" "Edit" input))
      (sprig-review-consume '(tool-result "t1" nil "ok")))
    (sprig-review-consume '(done 0.02 nil))
    (sprig-review-flush)
    (let ((s (buffer-string)))
      (should (string-match-p "Hello" s))
      (should (string-match-p "🔧 Edit" s))
      (should (string-match-p "ok" s))
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
    (goto-char (point-min))
    (should (re-search-forward "↳ result" nil t))
    (let ((sec (magit-current-section)))
      (should (eq (oref sec type) 'sprig-result))
      ;; Results fold by default; unfold like a user would.
      (should (oref sec hidden))
      (magit-section-show sec)
      (should-not (oref sec hidden)))
    ;; A later event refreshes the buffer; the unfold must survive.
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

(ert-deftest sprig-review-mode-test-renders-user-and-thinking ()
  (let ((model (sprig-review-build
                '((user "the question") (thinking "pondering")
                  (text "the answer") (title "T")))))
    (sprig-review-tests--rendered model nil
      (let ((s (buffer-string)))
        (should (string-match-p "^user$" s))
        (should (string-match-p "the question" s))
        (should (string-match-p "^thinking$" s))
        (should (string-match-p "pondering" s))
        (should (string-match-p "^assistant$" s))
        (should (string-match-p "the answer" s))
        ;; The model-carried title shows in the header.
        (should (string-match-p "T" s))))
    ;; The thinking section folds by default.
    (sprig-review-tests--rendered model nil
      (goto-char (point-min))
      (should (re-search-forward "^thinking$" nil t))
      (should (oref (magit-current-section) hidden)))))

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
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
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
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
    (goto-char (point-min))
    (re-search-forward "^\\+new$")
    (let ((pairs (sprig-review--reject-pairs (list (magit-current-section)))))
      (should (= (length pairs) 1))
      (should (equal (caar pairs) "/tmp/x.el"))
      (should (equal (plist-get (cdar pairs) :new) '("new"))))))

(ert-deftest sprig-review-mode-test-reject-verb ()
  ;; The whole verb path: extract the hunk at point, build the instruction,
  ;; hand it to the send (stubbed here to capture it).
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
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
      (re-search-forward "🔧 Bash")
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
  (sprig-review-tests--rendered (sprig-review-tests--edit-model) nil
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
      (re-search-forward "🔧 Bash")
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

(provide 'sprig-review-mode-tests)
;;; sprig-review-mode-tests.el ends here
