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

(defconst sprig-review-tests--two-hunk-diff
  "diff --git a/gap.el b/gap.el
--- a/gap.el
+++ b/gap.el
@@ -1,2 +1,2 @@
 one
-two
+TWO
@@ -10,2 +10,2 @@
 ten
-eleven
+ELEVEN
"
  "One file changed in two places, with unshown lines between them.")

(defmacro sprig-review-tests--with-diff (diff &rest body)
  "Run BODY in a review buffer rendered from DIFF."
  (declare (indent 1))
  `(with-temp-buffer
     (sprig-review-mode)
     (setq sprig-review--changes (sprig-parse-diff ,diff))
     (sprig-review--render)
     ,@body))

(defmacro sprig-review-tests--with (&rest body)
  "Run BODY in a review buffer rendered from `sprig-review-tests--diff'."
  (declare (indent 0))
  `(sprig-review-tests--with-diff sprig-review-tests--diff ,@body))

(defun sprig-review-tests--goto (needle)
  "Move point to the start of the rendered line containing NEEDLE."
  (goto-char (point-min))
  (search-forward needle)
  (beginning-of-line))

;;;; Rendering

(ert-deftest sprig-review-test-renders-summary-and-numbered-lines ()
  "The review opens with a one-line summary, then each file as numbered hunks."
  (sprig-review-tests--with
    (let ((s (buffer-string)))
      (should (string-match-p "^2 files  (\\+2 -1)" s))
      ;; Each file heading names the file and its own stat.
      (should (string-match-p "foo\\.el  (\\+1 -1)" s))
      (should (string-match-p "new\\.txt  (\\+1 -0)" s))
      ;; The hunk heading carries git's own function context.
      (should (string-match-p "@@ -1,3 \\+1,3 @@ defun foo ()" s))
      ;; Context keeps both numbers; a removal has no new-side number and
      ;; an addition no old-side one.
      (should (string-match-p "^ +1 +1 +(defun foo ()$" s))
      (should (string-match-p "^ +2 +- +(bar))$" s))
      (should (string-match-p "^ +2 +\\+ +(baz))$" s)))))

(defun sprig-review-tests--file-section (file)
  "Return the rendered file section for FILE."
  (seq-find (lambda (s) (equal (sprig--section-file s) file))
            (oref magit-root-section children)))

(ert-deftest sprig-review-test-files-open-folded ()
  "Files start folded, so the buffer opens as the list of what changed."
  (sprig-review-tests--with
    (should (oref (sprig-review-tests--file-section "foo.el") hidden))
    (should (oref (sprig-review-tests--file-section "new.txt") hidden))
    ;; Folded still says which file and how much of it moved.
    (should (string-match-p "foo\\.el  (\\+1 -1)" (buffer-string)))
    ;; And the fold is drawn, not merely recorded on the section: nothing
    ;; but the render applies it, since sprig runs no magit refresh.
    (sprig-review-tests--goto "(bar))")
    (should (seq-some (lambda (o) (overlay-get o 'invisible))
                      (overlays-at (point))))))

(ert-deftest sprig-review-test-an-opened-file-stays-open ()
  "Re-reading the diff must not shut the file you are reading, even when
the file itself changed underneath and magit\='s own cache cannot match it."
  (sprig-review-tests--with
    (magit-section-show (sprig-review-tests--file-section "foo.el"))
    (setq sprig-review--changes
          (sprig-parse-diff (replace-regexp-in-string
                             "(baz))" "(quux))" sprig-review-tests--diff)))
    (sprig-review--render)
    (should-not (oref (sprig-review-tests--file-section "foo.el") hidden))
    ;; Only that one: folding the rest is still the default.
    (should (oref (sprig-review-tests--file-section "new.txt") hidden))))

(ert-deftest sprig-review-test-a-commented-file-opens-itself ()
  "A file carrying a draft is never folded: a comment you cannot see is
worse than a longer buffer, and the heading counts it either way."
  (sprig-review-tests--with
    (setq sprig-review--drafts
          (list (sprig-review-tests--draft "foo.el" 'new 2 2
                                           "Use bar, not baz." '("  (baz))"))))
    (sprig-review--render)
    (should-not (oref (sprig-review-tests--file-section "foo.el") hidden))
    (should (oref (sprig-review-tests--file-section "new.txt") hidden))
    (should (string-match-p "foo\\.el.*(1 comment)" (buffer-string)))))

(ert-deftest sprig-review-test-empty-diff-says-so ()
  "An empty diff names the base it found nothing against, and clears marks."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig-review--changes (sprig-parse-diff ""))
    (sprig-review--render)
    (should (string-match-p "No uncommitted changes, against HEAD\\."
                            (buffer-string)))
    (should-not sprig--marks)))

(defun sprig-review-tests--face-on (needle)
  "Return the `font-lock-face' on the first character of NEEDLE."
  (save-excursion
    (goto-char (point-min))
    (search-forward needle)
    (get-text-property (match-beginning 0) 'font-lock-face)))

(ert-deftest sprig-review-test-code-is-syntax-highlighted ()
  "The code carries its own major mode's faces, not the diff's."
  (sprig-review-tests--with
    ;; `defun' in foo.el is elisp, so it fontifies as a keyword.  The diff
    ;; faces must not be what is on the code.
    (let ((face (sprig-review-tests--face-on "defun foo")))
      (should face)
      (should-not (memq 'sprig-diff-added (ensure-list face)))
      (should-not (memq 'sprig-diff-removed (ensure-list face))))))

(ert-deftest sprig-review-test-the-gutter-carries-the-change ()
  "Added and removed are said by the line-number columns and the marker,
so colour is not the only signal and the code keeps its syntax colours."
  (sprig-review-tests--with
    (goto-char (point-min))
    ;; The added line's *new* number is the one that exists, so it is the
    ;; one coloured; the blank old column stays plain.
    (search-forward "(baz))")
    (beginning-of-line)
    (should (eq (get-text-property (+ (point) 4) 'font-lock-face)
                'sprig-review-lineno))
    (should (eq (get-text-property (+ (point) 9) 'font-lock-face)
                'sprig-review-lineno-added))
    (goto-char (point-min))
    (search-forward "(bar))")
    (beginning-of-line)
    (should (eq (get-text-property (+ (point) 4) 'font-lock-face)
                'sprig-review-lineno-removed))
    (should (eq (get-text-property (+ (point) 9) 'font-lock-face)
                'sprig-review-lineno))))

(ert-deftest sprig-review-test-fontify-can-be-turned-off ()
  "With highlighting off the whole line carries the diff colour again,
so the buffer never ends up with no signal at all."
  (let ((sprig-review-fontify-code nil))
    (sprig-review-tests--with
      (should (memq 'sprig-diff-added
                    (ensure-list (sprig-review-tests--face-on "(baz))"))))
      (should (memq 'sprig-diff-removed
                    (ensure-list (sprig-review-tests--face-on "(bar))")))))))

(ert-deftest sprig-review-test-fontify-spans-the-hunk-not-the-line ()
  "Each side is fontified as one block, so a construct crossing lines
inside the hunk resolves; line-by-line fontification would not."
  (let* ((text "def f():\n    return \"\"\"\n    still a string\n    \"\"\"")
         (out (sprig-review--fontify-uncached "a.py" text))
         (at (lambda (needle)
               (get-text-property (string-match (regexp-quote needle) out)
                                  'font-lock-face out))))
    (should (eq (funcall at "still a string") 'font-lock-string-face))))

(ert-deftest sprig-review-test-fontify-survives-an-unknown-file ()
  "An unrecognised name is not an error; it just comes back plain."
  (should (equal (sprig-review--fontify-uncached "x.zzzz" "a b c") "a b c"))
  (let ((sprig-review-fontify-code nil))
    (should (equal (sprig-review--fontify-block "a.py" "def f():") "def f():"))))

(ert-deftest sprig-review-test-fontify-is-memoised ()
  "A re-render must not re-fontify: comments move often, hunks do not."
  (clrhash sprig-review--fontify-cache)
  (let ((calls 0))
    (cl-letf* ((orig (symbol-function 'sprig-review--fontify-uncached))
               ((symbol-function 'sprig-review--fontify-uncached)
                (lambda (&rest args) (cl-incf calls) (apply orig args))))
      (sprig-review--fontify-block "a.py" "def f():")
      (sprig-review--fontify-block "a.py" "def f():")
      (should (= calls 1))
      ;; The same text in another language is a different question.
      (sprig-review--fontify-block "a.el" "def f():")
      (should (= calls 2)))))

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
    (should (string-match-p "2 files  (\\+2 -1) +uncommitted changes, against HEAD"
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

(defun sprig-review-tests--git-stub (refs &optional head)
  "Return a `sprig-review--run-git' stub answering with REFS and HEAD.
REFS are the short names `for-each-ref' finds; HEAD is what
`origin/HEAD' resolves to, or nil when it is not set."
  (lambda (_remote _root args)
    (pcase (car args)
      ("for-each-ref"
       ;; Only report refs whose pattern was actually asked for, the way
       ;; git does: a pattern matching nothing is simply absent.
       (concat (string-join
                (seq-filter
                 (lambda (r)
                   (seq-some (lambda (p)
                               (or (equal p (concat "refs/heads/" r))
                                   (string-suffix-p
                                    (concat "/" (car (last (split-string r "/"))))
                                    p)))
                             (cdr args)))
                 refs)
                "\n")
               "\n"))
      ("symbolic-ref" (or head (error "no origin/HEAD")))
      (_ (error "unexpected git %S" args)))))

(ert-deftest sprig-review-test-default-branch-finds-either-name ()
  "master and main are both ordinary answers, and so is only-a-remote-one."
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '("main"))))
    (should (equal (sprig-review--default-branch nil "/r") "main")))
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '("master"))))
    (should (equal (sprig-review--default-branch nil "/r") "master")))
  ;; No local branch at all: the remote-tracking one still diffs fine, and
  ;; returning nil here was the old bug.
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '("origin/master"))))
    (should (equal (sprig-review--default-branch nil "/r") "origin/master"))))

(ert-deftest sprig-review-test-default-branch-prefers-the-local-ref ()
  "Given both, take the local name: it is what you would type, and it
diffs without the remote having been fetched."
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '("main" "origin/main"))))
    (should (equal (sprig-review--default-branch nil "/r") "main"))))

(ert-deftest sprig-review-test-both-names-are-broken-by-origin-head ()
  "A repo part-way through renaming carries both, and only the forge knows
which one it means.  The list's own order must not decide it."
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '("main" "master") "origin/master")))
    (should (equal (sprig-review--default-branch nil "/r") "master")))
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '("main" "master") "origin/main")))
    (should (equal (sprig-review--default-branch nil "/r") "main")))
  ;; With no origin/HEAD to ask, the list order is the tie-break left.
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '("main" "master"))))
    (should (equal (sprig-review--default-branch nil "/r") "main"))))

(ert-deftest sprig-review-test-default-branch-takes-an-unusual-name ()
  "A project calling its default something else is configuration, and
`origin/HEAD' still answers for one that is not on the list at all."
  (let ((sprig-review-default-branches '("main" "master" "trunk")))
    (cl-letf (((symbol-function 'sprig-review--run-git)
               (sprig-review-tests--git-stub '("trunk"))))
      (should (equal (sprig-review--default-branch nil "/r") "trunk"))))
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '() "origin/release")))
    (should (equal (sprig-review--default-branch nil "/r") "origin/release"))))

(ert-deftest sprig-review-test-default-branch-gives-up-cleanly ()
  "Nothing found and nothing to ask: nil, so `d m' can prompt instead."
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (sprig-review-tests--git-stub '())))
    (should-not (sprig-review--default-branch nil "/r")))
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (lambda (&rest _) (error "not a repo"))))
    (should-not (sprig-review--default-branch nil "/r"))))

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

(defconst sprig-review-tests--grown-diff
  "diff --git a/aaa.txt b/aaa.txt
new file mode 100644
--- /dev/null
+++ b/aaa.txt
@@ -0,0 +1,2 @@
+one
+two
diff --git a/foo.el b/foo.el
--- a/foo.el
+++ b/foo.el
@@ -1,2 +1,3 @@ defun foo ()
 (defun foo ()
-  (bar))
+  (setq n 1)
+  (baz))
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,1 @@
+hello
"
  "The test diff grown twice over: a file added above it, shifting every
buffer offset, and a line added inside foo.el, shifting `  (baz))\=' from
new line 2 to 3.  Both are what a refresh after the agent has worked
looks like, and each defeats a different lazy way of keeping point.")

(ert-deftest sprig-review-test-refresh-holds-your-place ()
  "`g\=' keeps the line under point and the files you opened, even when the
diff above it and the file around it have both grown.  A refresh is a
re-read, not a fresh start."
  (sprig-review-tests--with
    (setq sprig-review--remote nil sprig-review--root "/repo")
    (magit-section-show (sprig-review-tests--file-section "foo.el"))
    (sprig-review-tests--goto "(baz))")
    (cl-letf (((symbol-function 'sprig-review--git)
               (lambda (&rest _) sprig-review-tests--grown-diff)))
      (sprig-review--reload t))
    ;; The same line, not the same offset: aaa.txt pushed everything down.
    (let ((l (sprig-review--line-at)))
      (should (equal (plist-get l :file) "foo.el"))
      (should (equal (plist-get l :text) "  (baz))"))
      ;; Followed the text, not the number: it was line 2, it is now 3.
      (should (= (plist-get l :new) 3)))
    (should-not (oref (sprig-review-tests--file-section "foo.el") hidden))
    (should (oref (sprig-review-tests--file-section "aaa.txt") hidden))))

(ert-deftest sprig-review-test-refresh-survives-the-line-going-away ()
  "The agent can unwrite the very line you were reading.  Refresh then
falls back to the buffer offset rather than erroring."
  (sprig-review-tests--with
    (setq sprig-review--remote nil sprig-review--root "/repo")
    (sprig-review-tests--goto "(baz))")
    (cl-letf (((symbol-function 'sprig-review--git)
               (lambda (&rest _) "")))
      (sprig-review--reload t))
    (should (string-match-p "No uncommitted changes" (buffer-string)))
    (should (<= (point) (point-max)))))

;;;; What point resolves to

(ert-deftest sprig-review-test-point-resolves-to-a-line ()
  "Point on a rendered line yields its file, side, number, and text."
  (sprig-review-tests--with
    (sprig-review-tests--goto "(baz))")
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
    (sprig-review-tests--goto "(bar))")
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
      (sprig-review-tests--goto "(baz))")
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
  "Point on the summary line (or any chrome) is not a line to comment on."
  (sprig-review-tests--with
    (goto-char (point-min))
    (should-error (sprig-review--region-lines) :type 'user-error)))

;;;; Draft comments

(defun sprig-review-tests--draft (file side start end text anchor)
  "Return a draft comment plist for the tests."
  (list :id (cl-incf sprig-review--next-id) :file file :side side
        :start start :end end :text text :anchor anchor :orphan nil))

(ert-deftest sprig-review-test-a-draft-renders-under-its-line ()
  "A filed draft renders beneath the line it annotates, and counts on its
file's heading, so an annotated review reads back as one document."
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
      (sprig-review-tests--goto "(baz))")
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

(ert-deftest sprig-review-test-filing-a-comment-holds-your-place ()
  "Filing a draft redraws the review, and the redraw must not cost you your
place: point stays on the line you were commenting on, not the top."
  (sprig-review-tests--with
    (let ((review (current-buffer)))
      (sprig-review-tests--goto "(baz))")
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (sprig-review-comment))
      (unwind-protect
          (with-current-buffer "*sprig-comment*"
            (insert "Prefer bar.")
            (cl-letf (((symbol-function 'quit-window) #'ignore))
              (sprig-review-comment-save)))
        (kill-buffer "*sprig-comment*"))
      (with-current-buffer review
        (let ((l (sprig-review--line-at)))
          (should (equal (plist-get l :file) "foo.el"))
          (should (equal (plist-get l :text) "  (baz))")))))))

(ert-deftest sprig-review-test-filing-a-comment-holds-the-window ()
  "The window showing the review keeps its point too.  The redraw runs from
the comment buffer, so the review is not even current, and a window keeps
its own point that `erase-buffer\=' collapses independently."
  (let ((buf (get-buffer-create "*sprig-review-place-test*")))
    (unwind-protect
        (with-current-buffer buf
          (sprig-review-mode)
          (setq sprig-review--changes
                (sprig-parse-diff sprig-review-tests--diff))
          (sprig-review--render)
          (let ((win (display-buffer buf '(display-buffer-same-window))))
            (should (window-live-p win))
            (set-window-buffer win buf)
            (sprig-review-tests--goto "(baz))")
            (set-window-point win (point))
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
              (sprig-review-comment))
            (unwind-protect
                (with-current-buffer "*sprig-comment*"
                  (insert "Prefer bar.")
                  (cl-letf (((symbol-function 'quit-window) #'ignore))
                    (sprig-review-comment-save)))
              (kill-buffer "*sprig-comment*"))
            (should (window-live-p win))
            (should (equal (plist-get (sprig-review--line-at (window-point win))
                                      :text)
                           "  (baz))"))))
      (kill-buffer buf))))

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

(defmacro sprig-review-tests--staging (&rest body)
  "Run BODY with `sprig-session--open-stage-buffer' recording into SEEDED.
SEEDED reads (FILE TEXT LINE), which is the whole of what `e' decides."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'sprig-session--open-stage-buffer)
              (lambda (_review file anchor &optional line _apply)
                (setq seeded (list file anchor line))
                (current-buffer))))
     ,@body))

(defmacro sprig-review-tests--with-region (from to &rest body)
  "Run BODY with the region covering the lines holding FROM and TO."
  (declare (indent 2))
  `(progn
     (transient-mark-mode 1)
     (sprig-review-tests--goto ,from)
     (set-mark (point))
     (sprig-review-tests--goto ,to)
     (end-of-line)
     (activate-mark)
     ,@body))

(ert-deftest sprig-review-test-stage-takes-the-line-at-point ()
  "`e' on a line hands you that line and no more: the grain most
hand-authored feedback wants, anchored at the line it sits on."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--goto "(baz))")
          (sprig-review-tests--staging (sprig-review-stage))
          (should (equal seeded '("foo.el" "  (baz))" 2))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-widens-from-a-hunk-heading ()
  "The `@@' heading is not a line of the file, so `e' there means the
whole hunk: its context and added lines, never the removed ones."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--goto "@@ -1,3")
          (sprig-review-tests--staging (sprig-review-stage))
          (should (equal seeded '("foo.el" "(defun foo ()\n  (baz))" 1))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-widens-from-a-removed-line ()
  "A removed line is not in the file, so there is nothing there to
hand-author; `e' widens to the hunk rather than refusing."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--goto "(bar))")
          (sprig-review-tests--staging (sprig-review-stage))
          (should (equal seeded '("foo.el" "(defun foo ()\n  (baz))" 1))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-takes-the-region-when-there-is-one ()
  "A region narrows `e' to the lines you selected rather than the whole
hunk, anchored at the line they start on."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--with-region "(baz))" "(baz))"
            (sprig-review-tests--staging (sprig-review-stage)))
          (should (equal seeded '("foo.el" "  (baz))" 2))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-region-drops-the-removed-lines ()
  "A region over both sides of a change stages only what the file holds
now: the removed line is not on disk, so it cannot anchor an edit."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--with-region "(bar))" "(baz))"
            (sprig-review-tests--staging (sprig-review-stage)))
          (should (equal seeded '("foo.el" "  (baz))" 2))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-refuses-a-region-with-a-gap ()
  "Two hunks have unshown file between them, so a region across both is
not one `old_string' and `e' says so rather than staging a lie."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (sprig-review-tests--with-diff sprig-review-tests--two-hunk-diff
          (setq sprig-review--session session)
          (sprig-review-tests--with-region "one" "ELEVEN"
            (should-error (sprig-review-stage) :type 'user-error)))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-takes-the-marked-hunk ()
  "A marked hunk is what `e' edits, wherever point has wandered to since."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--goto "@@ -1,3")
          (setq sprig--marks (list (magit-section-ident (magit-current-section))))
          ;; Point rests on a line of its own, which the mark outranks.
          (sprig-review-tests--goto "hello")
          (sprig-review-tests--staging (sprig-review-stage))
          (should (equal seeded '("foo.el" "(defun foo ()\n  (baz))" 1))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-refuses-several-marks ()
  "`e' writes one block, so two marked hunks are an ambiguity to raise,
not one to guess at."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (sprig-review-tests--with-diff sprig-review-tests--two-hunk-diff
          (setq sprig-review--session session)
          (setq sprig--marks
                (mapcar (lambda (needle)
                          (sprig-review-tests--goto needle)
                          (magit-section-ident (magit-current-section)))
                        '("@@ -1,2" "@@ -10,2")))
          (should-error (sprig-review-stage) :type 'user-error))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-from-a-file-with-one-hunk ()
  "On a file heading, a file changed in one place has named its hunk."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--goto "new.txt")
          (sprig-review-tests--staging (sprig-review-stage))
          (should (equal seeded '("new.txt" "hello" 1))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-from-a-file-with-several-hunks ()
  "A file changed in two places has not, so it asks for one."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (sprig-review-tests--with-diff sprig-review-tests--two-hunk-diff
          (setq sprig-review--session session)
          (sprig-review-tests--goto "gap.el")
          (should-error (sprig-review-stage) :type 'user-error))
      (kill-buffer session))))

(defmacro sprig-review-tests--staged (needle new &rest body)
  "Stage the line holding NEEDLE, edit it to NEW, `C-c C-c', then run BODY.
Runs the real staging buffer, so it covers the whole `e' round trip."
  (declare (indent 2))
  `(unwind-protect
       (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                 ((symbol-function 'quit-window) #'ignore))
         (sprig-review-tests--goto ,needle)
         (sprig-review-stage)
         (with-current-buffer "*sprig-stage*"
           (erase-buffer)
           (insert ,new)
           (sprig-session-stage-apply))
         ,@body)
     (when (get-buffer "*sprig-stage*") (kill-buffer "*sprig-stage*"))))

(ert-deftest sprig-review-test-stage-files-a-draft-rather-than-sending ()
  "`C-c C-c' in the staging buffer files the edit as a draft next to the
comments.  Nothing is sent: a review is composed as a whole."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        sent)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (cl-letf (((symbol-function 'sprig-session--send)
                     (lambda (&rest _) (setq sent t))))
            (sprig-review-tests--staged "(baz))" "  (qux))"
              (should-not sent)
              (should (= 1 (length sprig-review--drafts)))
              (let ((d (car sprig-review--drafts)))
                (should (equal (plist-get d :edit) "  (qux))"))
                (should (equal (plist-get d :anchor) '("  (baz))")))
                (should (equal (plist-get d :file) "foo.el"))
                (should (eq (plist-get d :side) 'new))
                (should (= (plist-get d :start) 2))
                (should (= (plist-get d :end) 2)))
              ;; And it is on screen, as what it is.
              (should (string-match-p "your edit (line 2)" (buffer-string)))
              (should (string-match-p "(qux))" (buffer-string))))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-staged-edit-publishes-with-the-comments ()
  "Publishing sends both blocks of every edit, in full, alongside the
comments, and tells the agent the edits are not up for interpretation."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (progn
          (with-current-buffer session (sprig-session-mode))
          (sprig-review-tests--with
            (setq sprig-review--session session)
            (sprig-review-tests--staged "(baz))" "  (qux))"
              (let ((body (sprig-review--publish-text sprig-review--drafts)))
                (should (string-match-p "## foo.el" body))
                (should (string-match-p "an edit I wrote by hand" body))
                (should (string-match-p "(baz))" body))
                (should (string-match-p "(qux))" body))
                (should (string-match-p
                         "character for character"
                         (sprig-review--publish-format "note" body 1)))))))
      (kill-buffer session)
      (when (get-buffer "*sprig-message*") (kill-buffer "*sprig-message*")))))

(ert-deftest sprig-review-test-staged-edit-re-edits-and-is-taken-back ()
  "`c e' on an edit re-opens it seeded with what you wrote, and re-files
it as the same draft rather than a second one; `k' takes it back."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--staged "(baz))" "  (qux))"
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'quit-window) #'ignore))
              (sprig-review-tests--goto "your edit")
              (sprig-review-comment-edit)
              (with-current-buffer "*sprig-stage*"
                (should (equal (buffer-substring-no-properties
                                (point-min) (point-max))
                               "  (qux))"))
                (erase-buffer)
                (insert "  (quux))")
                (sprig-session-stage-apply))
              (should (= 1 (length sprig-review--drafts)))
              (should (equal (plist-get (car sprig-review--drafts) :edit)
                             "  (quux))"))
              (sprig-review-tests--goto "your edit")
              (sprig-review-comment-delete)
              (should (null sprig-review--drafts)))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-staged-edit-orphans-when-its-lines-go ()
  "An edit re-anchors like a comment, so one whose lines the agent has
since changed floats as orphaned instead of being applied blind."
  (let ((session (get-buffer-create "*sprig-review-test-session*")))
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--staged "(baz))" "  (qux))"
            (setq sprig-review--drafts
                  (sprig-review--reanchor
                   sprig-review--drafts
                   (sprig-parse-diff "diff --git a/foo.el b/foo.el
--- a/foo.el
+++ b/foo.el
@@ -1,3 +1,3 @@
 (defun foo ()
-  (bar))
+  (elsewhere))
")))
            (should (plist-get (car sprig-review--drafts) :orphan))
            (should (string-match-p
                     "check where it belongs"
                     (sprig-review--publish-text sprig-review--drafts)))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-d-reopens-the-review-you-left ()
  "`d' on a review already open shows it as it stands, drafts and all,
and re-reads the tree only when it is fresh or the scope has changed."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        (review "*sprig-review: *sprig-review-test-session**")
        (reads 0))
    (unwind-protect
        (cl-letf (((symbol-function 'sprig-review--session-root)
                   (lambda () (cons nil "/repo")))
                  ((symbol-function 'sprig-review--git)
                   (lambda (&rest _) (cl-incf reads) sprig-review-tests--diff))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (with-current-buffer session (sprig-session-mode))
          (with-current-buffer session (sprig-session-review "HEAD"))
          (should (= reads 1))
          (with-current-buffer review
            (setq sprig-review--drafts
                  (list (list :id 1 :file "foo.el" :side 'new :start 2 :end 2
                              :text "mine" :anchor '("  (baz))") :orphan nil))))
          ;; Same scope: the review comes back untouched, no git call.
          (with-current-buffer session (sprig-session-review "HEAD"))
          (should (= reads 1))
          (with-current-buffer review
            (should (= 1 (length sprig-review--drafts))))
          ;; A different scope is a different review, so it must read.
          (with-current-buffer session (sprig-session-review "main"))
          (should (= reads 2))
          (with-current-buffer review
            (should (equal sprig-review-base "main"))))
      (kill-buffer session)
      (when (get-buffer review) (kill-buffer review)))))

(defconst sprig-review-tests--narrow-diff
  "diff --git a/blk.py b/blk.py
--- a/blk.py
+++ b/blk.py
@@ -10,3 +10,3 @@ def f(a):
     x = 1
-    y = 2
+    y = 3
     return x
"
  "What the review renders: three lines of context round one change.")

(defconst sprig-review-tests--wide-diff
  "diff --git a/blk.py b/blk.py
--- a/blk.py
+++ b/blk.py
@@ -8,7 +8,7 @@
 def f(a):
     \"doc\"
     x = 1
-    y = 2
+    y = 3
     return x
 
 def g(b):
"
  "The same file re-read wide: the whole of `f' and the start of `g'.")

;;;; The block around point

(ert-deftest sprig-review-test-indent-counts-tabs-as-eight ()
  "Indentation is measured in columns, so a tab-indented file compares
with a space-indented one; a blank line has no indentation at all."
  (should (equal (sprig-review--indent "  x") 2))
  (should (equal (sprig-review--indent "\tx") 8))
  (should (equal (sprig-review--indent "    \tx") 8))
  (should (equal (sprig-review--indent "x") 0))
  (should (null (sprig-review--indent "")))
  (should (null (sprig-review--indent "   "))))

(ert-deftest sprig-review-test-closer-lines ()
  "A line of nothing but closing delimiters ends the block it shuts,
even though it sits back at the opening line's indentation."
  (should (sprig-review--closer-p "}"))
  (should (sprig-review--closer-p "  });"))
  (should (sprig-review--closer-p "end"))
  (should-not (sprig-review--closer-p "    return 1;"))
  (should-not (sprig-review--closer-p "} else {")))

(ert-deftest sprig-review-test-block-bounds-lisp ()
  "In the body of a defun, the block is the defun; on its opening line,
the block is still the defun and not whatever encloses it."
  (let ((texts (vconcat '("(defun foo ()"
                          "  (bar)"
                          "  (baz))"
                          ""
                          "(defun qux ()"
                          "  (quux))"))))
    (should (equal (sprig-review--block-bounds texts 1) '(0 2 nil)))
    (should (equal (sprig-review--block-bounds texts 0) '(0 2 nil)))))

(ert-deftest sprig-review-test-block-bounds-nested ()
  "A method body gives the method, not the class it sits in: the rule
stops at the nearest enclosing indentation, not the outermost."
  (let ((texts (vconcat '("class A:"
                          "    def f(self):"
                          "        x = 1"
                          "    def g(self):"
                          "        return 2"))))
    (should (equal (sprig-review--block-bounds texts 2) '(1 2 nil)))
    (should (equal (sprig-review--block-bounds texts 1) '(1 2 nil)))))

(ert-deftest sprig-review-test-block-bounds-keeps-the-closing-brace ()
  "A C-like block shuts at its opening line's column, so the brace is
part of the block rather than the line that ends it."
  (let ((texts (vconcat '("int f(void) {"
                          "    return 1;"
                          "}"
                          "int g(void) {"
                          "    return 2;"
                          "}"))))
    (should (equal (sprig-review--block-bounds texts 1) '(0 2 nil)))))

(ert-deftest sprig-review-test-block-bounds-flags-the-edge ()
  "When the read runs out before the code does, the block says so: it is
the one way this hands you less of the block than there is."
  (let ((texts (vconcat '("    x = 1"
                          "    y = 2"))))
    ;; Nothing less-indented above, nothing at all below.
    (should (equal (nth 2 (sprig-review--block-bounds texts 0)) t))))

(ert-deftest sprig-review-test-runs-split-at-a-gap ()
  "Lines the wider read never covered break the run, since the block
rule may only look at code that was actually read."
  (let ((lines '((:new 1 :text "a") (:new 2 :text "b")
                 (:new 9 :text "c") (:new 10 :text "d"))))
    (should (equal (mapcar #'length (sprig-review--runs lines)) '(2 2)))))

(ert-deftest sprig-review-test-stage-block-reads-wider ()
  "`e b' re-runs git for the one file with wide context and stages the
whole block round point, anchored where the block starts."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded args)
    (unwind-protect
        (sprig-review-tests--with-diff sprig-review-tests--narrow-diff
          (setq sprig-review--session session)
          (cl-letf (((symbol-function 'sprig-review--run-git)
                     (lambda (_remote _root a)
                       (setq args a)
                       sprig-review-tests--wide-diff)))
            (sprig-review-tests--goto "y = 3")
            (sprig-review-tests--staging (sprig-review-stage-block)))
          ;; The wider read is the same read, one file, more context.
          (should (member "-U400" args))
          (should (member "--" args))
          (should (member "blk.py" args))
          ;; The whole of `f', from its own first line, not the hunk's.
          (should (equal seeded
                         (list "blk.py"
                               "def f(a):\n    \"doc\"\n    x = 1\n    y = 3\n    return x"
                               8))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-block-memoises-the-read ()
  "Blocks are staged in runs, so the second one in a file does not pay
for another round trip."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        (reads 0) seeded)
    (unwind-protect
        (sprig-review-tests--with-diff sprig-review-tests--narrow-diff
          (setq sprig-review--session session)
          (cl-letf (((symbol-function 'sprig-review--run-git)
                     (lambda (&rest _)
                       (cl-incf reads)
                       sprig-review-tests--wide-diff)))
            (sprig-review-tests--goto "y = 3")
            (sprig-review-tests--staging (sprig-review-stage-block))
            (sprig-review-tests--staging (sprig-review-stage-block))
            (should (= reads 1))
            ;; Re-reading the diff moves the tree on, so the cache goes.
            (sprig-review--reload)
            (sprig-review-tests--goto "y = 3")
            (sprig-review-tests--staging (sprig-review-stage-block))
            (should (= reads 3))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-hunk-verb-takes-the-whole-hunk ()
  "`e h' takes the hunk however small a thing point is resting on."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with
          (setq sprig-review--session session)
          (sprig-review-tests--goto "(baz))")
          (sprig-review-tests--staging (sprig-review-stage-hunk))
          (should (equal seeded '("foo.el" "(defun foo ()\n  (baz))" 1))))
      (kill-buffer session))))

(defconst sprig-review-tests--elisp-narrow-diff
  "diff --git a/mod.el b/mod.el
--- a/mod.el
+++ b/mod.el
@@ -4,3 +4,3 @@ (defun f (x)
   (let ((y x))
-    (+ y 1)))
+    (+ y 2)))
 
"
  "The rendered view of a change inside a Lisp function.")

(defconst sprig-review-tests--elisp-wide-diff
  "diff --git a/mod.el b/mod.el
--- a/mod.el
+++ b/mod.el
@@ -1,7 +1,7 @@
 (defun f (x)
   \"Doc line one.
 A continuation at column zero.\"
   (let ((y x))
-    (+ y 1)))
+    (+ y 2)))
 
 (defun g () nil)
"
  "The same file read wide.  Its docstring runs to column zero, which is
what indentation alone reads as the start of a block and a major mode
reads as what it is.")

(ert-deftest sprig-review-test-defun-bounds-sees-the-docstring ()
  "The file's own mode bounds a Lisp function correctly through a
docstring that reaches column zero, where indentation cannot."
  (let ((texts (vconcat '("(defun f (x)"
                          "  \"Doc line one."
                          "A continuation at column zero.\""
                          "  (let ((y x))"
                          "    (+ y 2)))"
                          ""
                          "(defun g () nil)"))))
    (should (equal (sprig-review--defun-bounds texts 4 "mod.el") '(0 . 4)))
    (should (equal (sprig-review--defun-bounds texts 0 "mod.el") '(0 . 4)))))

(ert-deftest sprig-review-test-defun-bounds-declines-without-a-mode ()
  "With no major mode to ask, it says so rather than guessing, and the
caller falls back to the indentation rule."
  (let ((texts (vconcat '("alpha" "beta"))))
    (should (null (sprig-review--defun-bounds texts 0 "no-such.zzzz")))))

(ert-deftest sprig-review-test-stage-defun-takes-the-whole-function ()
  "`e d' stages the function around point, from its own first line."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with-diff sprig-review-tests--elisp-narrow-diff
          (setq sprig-review--session session)
          (cl-letf (((symbol-function 'sprig-review--run-git)
                     (lambda (&rest _) sprig-review-tests--elisp-wide-diff)))
            (sprig-review-tests--goto "(+ y 2)")
            (sprig-review-tests--staging (sprig-review-stage-defun)))
          (should (equal (nth 0 seeded) "mod.el"))
          (should (equal (nth 2 seeded) 1))
          (should (string-prefix-p "(defun f (x)" (nth 1 seeded)))
          (should (string-suffix-p "(+ y 2)))" (nth 1 seeded))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-stage-block-climbs-levels ()
  "One level is the innermost form round point; another climbs out of it."
  (let ((session (get-buffer-create "*sprig-review-test-session*"))
        seeded)
    (unwind-protect
        (sprig-review-tests--with-diff sprig-review-tests--elisp-narrow-diff
          (setq sprig-review--session session)
          (cl-letf (((symbol-function 'sprig-review--run-git)
                     (lambda (&rest _) sprig-review-tests--elisp-wide-diff)))
            (sprig-review-tests--goto "(+ y 2)")
            (sprig-review-tests--staging (sprig-review-stage-block 1))
            (should (equal (nth 1 seeded) "  (let ((y x))\n    (+ y 2)))"))
            (should (equal (nth 2 seeded) 4))))
      (kill-buffer session))))

(ert-deftest sprig-review-test-reloading-reaches-the-keys ()
  "Re-loading the file must reach an open review's keys.  A `defvar' does
nothing to a variable that is already bound, so the bindings live outside
it and mutate the map every open review is already using: same object,
new keys."
  (let ((map sprig-review-mode-map))
    (load (locate-library "sprig-review") nil t)
    (should (eq map sprig-review-mode-map))
    (should (eq (lookup-key sprig-review-mode-map (kbd "e"))
                'sprig-review-stage-dispatch))))

(defmacro sprig-review-tests--decorated (head decorations &rest body)
  "Run BODY with git stubbed to report HEAD and DECORATIONS."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'sprig-review--run-git)
              (lambda (_remote _root args)
                (cond ((equal args '("rev-parse" "--abbrev-ref" "HEAD")) ,head)
                      ((equal (car args) "log")
                       (string-join ,decorations "\n"))
                      (t "")))))
     ,@body))

(ert-deftest sprig-review-test-parent-is-the-branch-below ()
  "On a stack the parent is the first branch met walking back, which is the
branch immediately below rather than main at the bottom of it."
  (sprig-review-tests--decorated "feature/c"
      '("HEAD -> feature/c, origin/feature/c" "" "feature/b, origin/feature/b"
        "" "feature/a" "main, origin/main")
    (should (equal "feature/b" (sprig-review--parent-branch nil "/tmp")))))

(ert-deftest sprig-review-test-parent-prefers-the-local-branch ()
  "A commit usually carries both `foo' and `origin/foo'.  The local one is
what you would type and diffs without a fetch, so it wins; a remote-tracking
ref on its own is still a perfectly good base."
  (sprig-review-tests--decorated "feature/c"
      '("HEAD -> feature/c" "origin/feature/b, feature/b")
    (should (equal "feature/b" (sprig-review--parent-branch nil "/tmp"))))
  (sprig-review-tests--decorated "feature/c"
      '("HEAD -> feature/c" "origin/feature/b")
    (should (equal "origin/feature/b"
                   (sprig-review--parent-branch nil "/tmp")))))

(ert-deftest sprig-review-test-parent-ignores-tags-and-its-own-refs ()
  "A tag is not a branch, and neither side of this branch counts as below it."
  (sprig-review-tests--decorated "feature/c"
      '("HEAD -> feature/c, origin/feature/c, tag: v2" "tag: v1" "main")
    (should (equal "main" (sprig-review--parent-branch nil "/tmp")))))

(ert-deftest sprig-review-test-parent-of-an-unstacked-branch-is-nothing ()
  "Nothing below means nothing to report, and `d p' says so rather than
quietly reviewing a scope that is not the one asked for."
  (sprig-review-tests--decorated "main" '("HEAD -> main, origin/main" "" "")
    (should-not (sprig-review--parent-branch nil "/tmp"))))

(defconst sprig-review-tests--documented
  '("import os"
    ""
    "def other():"
    "    pass"
    ""
    "\"\"\""
    "Build one operation."
    ""
    "The prose runs to a second paragraph."
    "\"\"\""
    "def route(a, b):"
    "    x = 1  # a trailing comment"
    "    return x"
    ""
    "def after():"
    "    pass")
  "A file whose function carries a docstring with a blank line in it.")

(ert-deftest sprig-review-test-defun-takes-its-docstring ()
  "`e d' hands you the function and the prose explaining it, since those are
one thing to edit and `beginning-of-defun' stops below the prose."
  (should (equal '(5 . 12)
                 (sprig-review--defun-bounds
                  sprig-review-tests--documented 12 "/tmp/x.py"))))

(ert-deftest sprig-review-test-a-docstring-may-hold-a-blank-line ()
  "A paragraph break inside the docstring is not the end of it.  Stopping
at the first blank line would hand over half a docstring."
  (let ((bounds (sprig-review--defun-bounds
                 sprig-review-tests--documented 11 "/tmp/x.py")))
    (should (equal "\"\"\"" (nth (car bounds) sprig-review-tests--documented)))))

(ert-deftest sprig-review-test-a-trailing-comment-is-not-doc ()
  "Doc is decided from a line's first character, not its last: `x = 1  #
note' is code, and testing the end of the line would walk on up through it."
  ;; Point on `def after()', whose only neighbour above is code with a
  ;; trailing comment two lines up; nothing is taken with it.
  (should (equal '(14 . 15)
                 (sprig-review--defun-bounds
                  sprig-review-tests--documented 15 "/tmp/x.py"))))

(ert-deftest sprig-review-test-comment-block-counts-as-doc ()
  "A run of comment lines above a defun is the same case as a docstring,
which is what every Lisp and every C-like language writes instead."
  (let ((el '("(require 'x)" "" ";; What foo is for." ";; And why."
              "(defun foo ()" "  (bar))")))
    (should (equal '(2 . 5) (sprig-review--defun-bounds el 5 "/tmp/x.el")))))

;;;; Where the session is (`d w')

(defmacro sprig-review-tests--rev-parse (out &rest body)
  "Run BODY with `git rev-parse' answering OUT and every other call empty.
OUT nil makes the call fail the way it does in a repository with no
commits, or outside one altogether."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'sprig-review--run-git)
              (lambda (_remote _dir args)
                (if (equal (car args) "rev-parse")
                    (or ,out (error "git rev-parse failed"))
                  ""))))
     ,@body))

(ert-deftest sprig-review-test-tree-facts-reads-a-plain-checkout ()
  "One `rev-parse' names the top level and the branch.  A checkout that is
not a worktree reads `.git' for both git dirs, so there is no main to name."
  (sprig-review-tests--rev-parse "/home/me/proj\n.git\n.git\nmain\n"
    (let ((facts (sprig-review--tree-facts nil "/home/me/proj")))
      (should (equal "/home/me/proj" (plist-get facts :root)))
      (should (equal "main" (plist-get facts :branch)))
      (should-not (plist-get facts :main)))))

(ert-deftest sprig-review-test-tree-facts-names-the-main-checkout ()
  "A linked worktree is the case where the two git dirs part company, and
the checkout it was added from is the common one with its `/.git' removed."
  (sprig-review-tests--rev-parse
      (concat "/home/me/proj/.worktrees/x\n/home/me/proj/.git\n"
              "/home/me/proj/.git/worktrees/x\nfeature/x\n")
    (let ((facts (sprig-review--tree-facts nil "/home/me/proj/.worktrees/x")))
      (should (equal "feature/x" (plist-get facts :branch)))
      (should (equal "/home/me/proj" (plist-get facts :main))))))

(ert-deftest sprig-review-test-tree-facts-reports-a-detached-head ()
  "`--abbrev-ref HEAD' answers `HEAD' when nothing is checked out by name,
which is no branch rather than a branch called HEAD."
  (sprig-review-tests--rev-parse "/home/me/proj\n.git\n.git\nHEAD\n"
    (should-not (plist-get (sprig-review--tree-facts nil "/home/me/proj")
                           :branch))))

(ert-deftest sprig-review-test-tree-facts-tells-unborn-from-absent ()
  "A repository with no commits cannot resolve HEAD, so the one call fails.
It is still a repository, and saying so is not the same as saying there is
none: the retry for the top level alone is what tells the two apart."
  (cl-letf (((symbol-function 'sprig-review--run-git)
             (lambda (_remote _dir args)
               (if (equal args '("rev-parse" "--show-toplevel"))
                   "/home/me/fresh\n"
                 (error "git rev-parse failed")))))
    (should (plist-get (sprig-review--tree-facts nil "/home/me/fresh") :unborn)))
  (sprig-review-tests--rev-parse nil
    (should-not (sprig-review--tree-facts nil "/tmp"))))

(ert-deftest sprig-review-test-where-names-the-tree-and-its-branch ()
  "The plain case says the two things `d' depends on and nothing else."
  (should (equal "sprig: /home/me/proj on main"
                 (sprig-review--where-line
                  nil "/home/me/proj"
                  '(:root "/home/me/proj" :branch "main") nil nil))))

(ert-deftest sprig-review-test-where-spots-a-different-tree ()
  "The point of the command: a worktree usually sits *under* the checkout it
was added from, so comparing paths would call it the same tree.  The top
level is what separates them, and both branches get named."
  (let ((line (sprig-review--where-line
               nil "/home/me/proj"
               '(:root "/home/me/proj" :branch "main")
               "/home/me/proj/.worktrees/x"
               '(:root "/home/me/proj/.worktrees/x" :branch "feature/x"
                 :main "/home/me/proj"))))
    (should (string-match-p "\\`sprig: /home/me/proj on main;" line))
    (should (string-match-p "running in /home/me/proj/.worktrees/x on feature/x"
                            line))))

(ert-deftest sprig-review-test-where-is-quiet-about-a-subdirectory ()
  "Same repository, so the review is right wherever in it the agent sits;
saying so every time would bury the case that matters."
  (let ((facts '(:root "/home/me/proj" :branch "main")))
    (should (equal "sprig: /home/me/proj on main"
                   (sprig-review--where-line nil "/home/me/proj" facts
                                             "/home/me/proj/src" facts)))))

(ert-deftest sprig-review-test-where-says-what-it-found-instead ()
  "No repository, no commits and no branch are three different answers, and
`d w' is the command you reach for when a `d' did something you did not
expect, so none of them may read as one of the others."
  (should (string-suffix-p "(not a git repository)"
                           (sprig-review--where-line nil "/tmp" nil nil nil)))
  (should (string-suffix-p "(a repository with no commits yet)"
                           (sprig-review--where-line
                            nil "/tmp/fresh"
                            '(:root "/tmp/fresh" :unborn t) nil nil)))
  (should (string-suffix-p "on a detached HEAD"
                           (sprig-review--where-line
                            nil "/home/me/proj"
                            '(:root "/home/me/proj") nil nil)))
  (should (equal "sprig: this session has no working directory"
                 (sprig-review--where-line nil nil nil nil nil))))

(ert-deftest sprig-review-test-where-keeps-a-remote-path-whole ()
  "A remote path is named with its host and left unshortened: `~' here is
not `~' there, and abbreviating against this host's home would be a guess."
  (let ((line (sprig-review--where-line
               "box" "/home/them/proj"
               '(:root "/home/them/proj" :branch "main") nil nil)))
    (should (equal "sprig: box:/home/them/proj on main" line))))

(provide 'sprig-review-tests)
;;; sprig-review-tests.el ends here
