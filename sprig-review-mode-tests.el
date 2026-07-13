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
    ;; Text accumulates; no tool yet.
    (should (string-match-p "Hello" (buffer-string)))
    (should-not (string-match-p "🔧" (buffer-string)))
    (let ((input (json-serialize (list :file_path "x" :old_string "a"
                                       :new_string "b"))))
      (sprig-review-consume (list 'tool-call "t1" "Edit" input))
      (sprig-review-consume '(tool-result "t1" nil "ok")))
    (sprig-review-consume '(done 0.02 nil))
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
    (goto-char (point-min))
    (should (re-search-forward "keep\\.el" nil t))
    (let ((type-before (oref (magit-current-section) type)))
      ;; A later turn streams in; point must stay in the same section, not
      ;; bounce to the top of the buffer.
      (sprig-review-consume '(text-block))
      (sprig-review-consume '(text "more"))
      (should (eq (oref (magit-current-section) type) type-before))
      (should (> (point) (point-min))))))

(ert-deftest sprig-review-mode-test-consume-preserves-folds ()
  (with-temp-buffer
    (sprig-review-mode)
    (let ((input (json-serialize (list :file_path "x" :old_string "a"
                                       :new_string "b"))))
      (sprig-review-consume (list 'tool-call "t1" "Edit" input))
      (sprig-review-consume '(tool-result "t1" nil "secret")))
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
    (goto-char (point-min))
    (should (re-search-forward "↳ result" nil t))
    (should-not (oref (magit-current-section) hidden))))

(ert-deftest sprig-review-mode-test-reset ()
  (with-temp-buffer
    (sprig-review-mode)
    (sprig-review-consume '(text "gone"))
    (should (string-match-p "gone" (buffer-string)))
    (sprig-review-reset '(:title "Fresh"))
    (should-not (string-match-p "gone" (buffer-string)))
    (should (string-match-p "Fresh" (buffer-string)))))

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

(provide 'sprig-review-mode-tests)
;;; sprig-review-mode-tests.el ends here
