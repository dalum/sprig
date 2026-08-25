;;; sprig-review-tests.el --- ERT tests for the changeset review -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers the review surface: how a diff renders, what point resolves to,
;; and the draft-comment lifecycle from writing one through re-anchoring
;; it across a refresh to publishing the set.  Runs offline: the git read
;; is stubbed, and no session is started.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sprig-change)
(require 'sprig-render)
(require 'sprig-review)
(require 'sprig-session-mode)

(defconst sprig-review-tests--diff
  "diff --git a/foo.el b/foo.el
--- a/foo.el
+++ b/foo.el
@@ -1,3 +1,3 @@ defun foo ()
 (defun foo ()
-  (bar))
+  (baz))
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,1 @@
+hello
"
  "A two-file unified diff: one edit and one new file.")

(defmacro sprig-review-tests--with (&rest body)
  "Run BODY in a review buffer rendered from `sprig-review-tests--diff'."
  (declare (indent 0))
  `(with-temp-buffer
     (sprig-review-mode)
     (setq sprig-review--changes (sprig-parse-diff sprig-review-tests--diff))
     (sprig-review--render)
     ,@body))

(defun sprig-review-tests--goto (needle)
  "Move point to the start of the rendered line containing NEEDLE."
  (goto-char (point-min))
  (search-forward needle)
  (beginning-of-line))

;;;; Rendering

(ert-deftest sprig-review-test-renders-index-and-numbered-lines ()
  "The review opens with a file index, then each file as numbered hunks."
  (sprig-review-tests--with
    (let ((s (buffer-string)))
      (should (string-match-p "Changed files (2)" s))
      ;; The index names every changed file with its stat.
      (should (string-match-p "(\\+1 -1)  foo\\.el" s))
      (should (string-match-p "(\\+1 -0)  new\\.txt" s))
      ;; The hunk heading carries git's own function context.
      (should (string-match-p "@@ -1,3 \\+1,3 @@ defun foo ()" s))
      ;; Context keeps both numbers; a removal has no new-side number and
      ;; an addition no old-side one.
      (should (string-match-p "^ +1 +1 +(defun foo ()$" s))
      (should (string-match-p "^ +2 +- +(bar))$" s))
      (should (string-match-p "^ +2 +\\+ +(baz))$" s)))))

(ert-deftest sprig-review-test-empty-diff-says-so ()
  "An empty diff names the base it found nothing against, and clears marks."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig-review--changes (sprig-parse-diff ""))
    (sprig-review--render)
    (should (string-match-p "No uncommitted changes, against HEAD\\."
                            (buffer-string)))
    (should-not sprig--marks)))

;;;; Reading the tree

(ert-deftest sprig-review-test-diff-args-pick-the-right-formulation ()
  "The base decides which of git's three diffs the review actually runs.

`main' must not become `git diff main': that compares against main's tip,
so every commit main gained since the branch point shows up inverted, as
changes the branch appears to have reverted.  `--merge-base' is the whole
branch and nothing of main's own advance, uncommitted work included."
  (should (equal (sprig-review--diff-args "HEAD") '("diff" "HEAD")))
  (should (equal (sprig-review--diff-args "") '("diff" "HEAD")))
  (should (equal (sprig-review--diff-args "main")
                 '("diff" "--merge-base" "main")))
  (should (equal (sprig-review--diff-args "origin/main")
                 '("diff" "--merge-base" "origin/main")))
  ;; An explicit range is the caller saying what they mean; leave it alone.
  (should (equal (sprig-review--diff-args "main...HEAD")
                 '("diff" "main...HEAD")))
  (should (equal (sprig-review--diff-args "v1..v2") '("diff" "v1..v2"))))

(ert-deftest sprig-review-test-scope-label-says-what-is-covered ()
  "The base string does not say what it covers, so the buffer spells it out."
  (should (equal (sprig-review--scope-label "HEAD")
                 "uncommitted changes, against HEAD"))
  (should (equal (sprig-review--scope-label "main")
                 "whole branch, against main"))
  (should (equal (sprig-review--scope-label "main...HEAD")
                 "range main...HEAD")))

(ert-deftest sprig-review-test-the-scope-is-on-screen ()
  "You can always see what you are reviewing against, not just when empty."
  (sprig-review-tests--with
    (should (string-match-p "Changed files (2) +uncommitted changes, against HEAD"
                            (buffer-string)))
    (setq-local sprig-review-base "main")
    (sprig-review--render)
    (should (string-match-p "whole branch, against main" (buffer-string)))))

(ert-deftest sprig-review-test-git-runs-local-and-remote ()
  "Local reads run git in the repo dir; a remote read rides the session's
SSH transport (`sprig--remote-sh'), not TRAMP, and honours the base."
  (let (local-args remote-cmd remote-host)
    (cl-letf (((symbol-function 'process-file)
               (lambda (_prog _infile _buf _display &rest args)
                 (setq local-args args)
                 (insert "")
                 0))
              ((symbol-function 'sprig--remote-sh)
               (lambda (command &optional host)
                 (setq remote-cmd command remote-host host)
                 "")))
      (let ((sprig-review-base "HEAD"))
        (sprig-review--git nil "/repo")
        (should (equal local-args '("diff" "HEAD"))))
      (let ((sprig-review-base "main"))
        (sprig-review--git "me@box" "/srv/app")
        (should (equal remote-host "me@box"))
        (should (string-match-p "cd /srv/app && git diff --merge-base main"
                                remote-cmd))))))

(ert-deftest sprig-review-test-default-branch-prefers-the-local-name ()
  "The forge's HEAD names the branch; the local one is what you would type."
  (let ((answers '(("symbolic-ref" . "origin/main\n")
                   ("rev-parse" . "abc123\n"))))
    (cl-letf (((symbol-function 'sprig-review--run-git)
               (lambda (_remote _root args)
                 (or (cdr (assoc (car args) answers))
                     (error "git %s failed" (car args))))))
      (should (equal (sprig-review--default-branch nil "/repo") "main"))))
  ;; With no remote HEAD, fall back to whichever of main/master exists.
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (lambda (_remote _root args)
               (if (and (equal (car args) "rev-parse")
                        (member "master" args))
                   "abc\n"
                 (error "no")))))
    (should (equal (sprig-review--default-branch nil "/repo") "master")))
  ;; Neither: the caller has to name a base itself.
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (lambda (&rest _) (error "no"))))
    (should-not (sprig-review--default-branch nil "/repo"))))

(ert-deftest sprig-review-test-set-base-keeps-the-drafts ()
  "Widening the scope mid-review re-anchors the comments rather than
losing them: that is the whole reason `b' lives in the review buffer."
  (sprig-review-tests--with
    (setq sprig-review--remote nil sprig-review--root "/repo"
          sprig-review--drafts
          (list (sprig-review-tests--draft "foo.el" 'new 2 2
                                           "Keep me." '("  (baz))"))))
    (cl-letf (((symbol-function 'sprig-review--git)
               (lambda (&rest _) sprig-review-tests--diff)))
      (sprig-review-set-base "main"))
    (should (equal sprig-review-base "main"))
    (should (= (length sprig-review--drafts) 1))
    (should-not (plist-get (car sprig-review--drafts) :orphan))
    (should (string-match-p "Keep me\\." (buffer-string)))))

;;;; What point resolves to

(ert-deftest sprig-review-test-point-resolves-to-a-line ()
  "Point on a rendered line yields its file, side, number, and text."
  (sprig-review-tests--with
    (sprig-review-tests--goto "+  (baz))")
    (pcase-let ((`(,file ,side ,start ,end ,anchor)
                 (sprig-review--region-lines)))
      (should (equal file "foo.el"))
      (should (eq side 'new))
      (should (= start 2))
      (should (= end 2))
      (should (equal anchor '("  (baz))"))))))

(ert-deftest sprig-review-test-a-removed-line-anchors-to-the-old-side ()
  "A removal exists on no other side, so it anchors to the pre-image."
  (sprig-review-tests--with
    (sprig-review-tests--goto "-  (bar))")
    (pcase-let ((`(,_file ,side ,start ,_end ,anchor)
                 (sprig-review--region-lines)))
      (should (eq side 'old))
      (should (= start 2))
      (should (equal anchor '("  (bar))"))))))

(ert-deftest sprig-review-test-a-region-spans-its-lines ()
  "A region covering context and an addition anchors to the new side, and
takes the whole span rather than either end of it."
  (sprig-review-tests--with
    (sprig-review-tests--goto "(defun foo ()")
    (let ((beg (point)))
      (sprig-review-tests--goto "+  (baz))")
      (set-mark beg)
      (goto-char (line-end-position))
      (activate-mark)
      (pcase-let ((`(,_file ,side ,start ,end ,anchor)
                   (sprig-review--region-lines)))
        (should (eq side 'new))
        (should (= start 1))
        (should (= end 2))
        ;; The removed line falls out: it has no new-side number.
        (should (equal anchor '("(defun foo ()" "  (baz))")))))))

(ert-deftest sprig-review-test-point-off-the-diff-refuses ()
  "Point on the index (or any chrome) is not a line to comment on."
  (sprig-review-tests--with
    (goto-char (point-min))
    (should-error (sprig-review--region-lines) :type 'user-error)))

;;;; Draft comments

(defun sprig-review-tests--draft (file side start end text anchor)
  "Return a draft comment plist for the tests."
  (list :id (cl-incf sprig-review--next-id) :file file :side side
        :start start :end end :text text :anchor anchor :orphan nil))

(ert-deftest sprig-review-test-a-draft-renders-under-its-line ()
  "A filed draft renders beneath the line it annotates, and counts in
the index, so an annotated review reads back as one document."
  (sprig-review-tests--with
    (setq sprig-review--drafts
          (list (sprig-review-tests--draft "foo.el" 'new 2 2
                                           "Use bar, not baz." '("  (baz))"))))
    (sprig-review--render)
    (let* ((s (buffer-string))
           (line (string-match "^ +2 +\\+ +(baz))$" s))
           (note (string-match "Use bar, not baz\\." s)))
      (should line)
      (should note)
      (should (< line note))
      (should (string-match-p "↳ comment (line 2)" s))
      (should (string-match-p "foo\\.el.*(1 comment)" s)))))

(ert-deftest sprig-review-test-a-draft-is-taken-back-at-point ()
  "`k' on a draft removes it and redraws without it."
  (sprig-review-tests--with
    (setq sprig-review--drafts
          (list (sprig-review-tests--draft "foo.el" 'new 2 2
                                           "Wrong." '("  (baz))"))))
    (sprig-review--render)
    (sprig-review-tests--goto "Wrong.")
    (sprig-review-comment-delete)
    (should-not sprig-review--drafts)
    (should-not (string-match-p "Wrong\\." (buffer-string)))))

(ert-deftest sprig-review-test-writing-a-comment-files-a-draft ()
  "The comment buffer files its draft on the review, not to the agent."
  (sprig-review-tests--with
    (let ((review (current-buffer)))
      (sprig-review-tests--goto "+  (baz))")
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (sprig-review-comment))
      (unwind-protect
          (with-current-buffer "*sprig-comment*"
            (should (eq sprig-review--comment-target review))
            (insert "Prefer bar.")
            (cl-letf (((symbol-function 'quit-window) #'ignore))
              (sprig-review-comment-save)))
        (kill-buffer "*sprig-comment*"))
      (should (= (length sprig-review--drafts) 1))
      (let ((d (car sprig-review--drafts)))
        (should (equal (plist-get d :text) "Prefer bar."))
        (should (equal (plist-get d :file) "foo.el"))
        (should (equal (plist-get d :anchor) '("  (baz))")))))))

;;;; Re-anchoring across a refresh

(ert-deftest sprig-review-test-reanchor-keeps-an-unmoved-comment ()
  "Text still at its line keeps the line, and stays un-orphaned."
  (let* ((changes (sprig-parse-diff sprig-review-tests--diff))
         (d (list :id 1 :file "foo.el" :side 'new :start 2 :end 2
                  :text "x" :anchor '("  (baz))") :orphan nil))
         (out (car (sprig-review--reanchor (list d) changes))))
    (should (= (plist-get out :start) 2))
    (should-not (plist-get out :orphan))))

(ert-deftest sprig-review-test-reanchor-follows-moved-text ()
  "Text that shifted down re-points to where it went, rather than
staying on a line number that now means something else."
  (let* ((moved (replace-regexp-in-string
                 "@@ -1,3 \\+1,3 @@ defun foo ()\n (defun foo ()"
                 "@@ -1,4 +1,4 @@ defun foo ()\n (defun foo ()\n (blank)"
                 sprig-review-tests--diff))
         (changes (sprig-parse-diff moved))
         (d (list :id 1 :file "foo.el" :side 'new :start 2 :end 2
                  :text "x" :anchor '("  (baz))") :orphan nil))
         (out (car (sprig-review--reanchor (list d) changes))))
    (should (= (plist-get out :start) 3))
    (should-not (plist-get out :orphan))))

(ert-deftest sprig-review-test-reanchor-orphans-rather-than-drops ()
  "Text gone from the diff orphans its comment; it is never discarded.
A review tool that silently loses a comment is worse than one with none."
  (let* ((changes (sprig-parse-diff sprig-review-tests--diff))
         (d (list :id 1 :file "foo.el" :side 'new :start 2 :end 2
                  :text "x" :anchor '("  (vanished))") :orphan nil))
         (out (sprig-review--reanchor (list d) changes)))
    (should (= (length out) 1))
    (should (plist-get (car out) :orphan))))

(ert-deftest sprig-review-test-an-orphan-floats-to-the-top-of-its-file ()
  "An orphan has no line to sit under, so it renders above the hunks."
  (sprig-review-tests--with
    (setq sprig-review--drafts
          (list (list :id 1 :file "foo.el" :side 'new :start 2 :end 2
                      :text "Stale note." :anchor '("  (gone))") :orphan t)))
    (sprig-review--render)
    (let* ((s (buffer-string))
           (note (string-match "Stale note\\." s))
           (hunk (string-match "@@ -1,3" s)))
      (should (string-match-p "orphaned, was line 2" s))
      (should (< note hunk)))))

;;;; Publishing

(ert-deftest sprig-review-test-publish-text-groups-and-quotes ()
  "The published review groups by file, orders by line, and quotes the
annotated text so the agent can find it even if it has moved since."
  (let* ((drafts (list (list :id 2 :file "foo.el" :side 'new :start 9 :end 9
                             :text "Second." :anchor '("nine") :orphan nil)
                       (list :id 1 :file "foo.el" :side 'new :start 2 :end 3
                             :text "First." :anchor '("two" "three")
                             :orphan nil)))
         (out (sprig-review--publish-text drafts)))
    (should (string-match-p "^## foo\\.el$" out))
    (should (string-match-p "^### Lines 2-3$" out))
    (should (string-match-p "^> two\n> three$" out))
    (should (string-match-p "^### Line 9$" out))
    ;; Ordered by line, not by the order they were written in.
    (should (< (string-match "First\\." out) (string-match "Second\\." out)))))

(ert-deftest sprig-review-test-publish-text-truncates-a-long-quote ()
  "A long region cites its numbers exactly but quotes only a head of it."
  (let* ((lines (mapcar #'number-to-string (number-sequence 1 10)))
         (drafts (list (list :id 1 :file "f" :side 'new :start 1 :end 10
                             :text "t" :anchor lines :orphan nil)))
         (sprig-review-quote-lines 3)
         (out (sprig-review--publish-text drafts)))
    (should (string-match-p "> 1\n> 2\n> 3\n> … (7 more lines)" out))
    (should (string-match-p "Lines 1-10" out))))

(ert-deftest sprig-review-test-publish-text-separates-orphans ()
  "An orphan is published under its text, not under a line number it
no longer owns."
  (let* ((drafts (list (list :id 1 :file "f" :side 'new :start 2 :end 2
                             :text "Note." :anchor '("gone") :orphan t)))
         (out (sprig-review--publish-text drafts)))
    (should (string-match-p "Comments whose lines have since moved" out))
    (should (string-match-p "> gone" out))
    (should-not (string-match-p "^### Line 2$" out))))

(ert-deftest sprig-review-test-publish-routes-to-the-session ()
  "Publishing opens the ordinary compose buffer, targeting the session,
with the review attached and framed by its own formatter.  The drafts
survive until the message is actually sent."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (progn
          (with-current-buffer session (sprig-session-mode))
          (sprig-review-tests--with
            (setq sprig-review--session session
                  sprig-review--drafts
                  (list (sprig-review-tests--draft
                         "foo.el" 'new 2 2 "Prefer bar." '("  (baz))"))))
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
              (sprig-review-publish))
            ;; Not sent yet, so the review still holds its draft.
            (should (= (length sprig-review--drafts) 1))
            (with-current-buffer "*sprig-message*"
              (should (eq sprig-session--compose-target session))
              (should (string-match-p "### Line 2"
                                      sprig-session--compose-context))
              (should (functionp sprig-session--compose-format))
              (let ((msg (funcall sprig-session--compose-format
                                  "Covering note."
                                  sprig-session--compose-context)))
                (should (string-match-p "Address each one" msg))
                (should (string-match-p "Covering note\\." msg))
                (should (string-match-p "Prefer bar\\." msg))))
            ;; Framing the message is what commits the review.
            (should-not sprig-review--drafts)))
      (kill-buffer session)
      (when (get-buffer "*sprig-message*") (kill-buffer "*sprig-message*")))))

(ert-deftest sprig-review-test-publish-refuses-an-empty-review ()
  "With no drafts there is no review to publish; `c m' is the plain path."
  (sprig-review-tests--with
    (should-error (sprig-review-publish) :type 'user-error)))

;;;; Plain messages and hand-authoring

(ert-deftest sprig-review-test-marked-hunks-still-send-a-plain-message ()
  "Marking a hunk and `c m' composes a message with it attached, the
escape hatch for feedback that is about the change and not about a line."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (progn
          (with-current-buffer session (sprig-session-mode))
          (sprig-review-tests--with
            (setq sprig-review--session session)
            (sprig-review-tests--goto "@@ -1,3")
            (let ((hunk (magit-current-section)))
              (setq sprig--marks (list (magit-section-ident hunk))))
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
              (sprig-review-message))
            (with-current-buffer "*sprig-message*"
              (should (eq sprig-session--compose-target session))
              (should (string-match-p "(baz))"
                                      sprig-session--compose-context)))))
      (kill-buffer session)
      (when (get-buffer "*sprig-message*") (kill-buffer "*sprig-message*")))))

(ert-deftest sprig-review-test-stage-seeds-the-new-side-of-a-hunk ()
  "`e' hand-authors the hunk at point, seeded with what is on disk now:
its context and added lines, never the removed ones."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--goto "+  (baz))")
          (cl-letf (((symbol-function 'sprig-session--open-stage-buffer)
                     (lambda (_review file anchor) (setq seeded (cons file anchor)))))
            (sprig-review-stage-hunk))
          (should (equal (car seeded) "foo.el"))
          (should (equal (cdr seeded) "(defun foo ()\n  (baz))")))
      (kill-buffer session))))

(provide 'sprig-review-tests)
;;; sprig-review-tests.el ends here
