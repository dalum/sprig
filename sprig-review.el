;;; sprig-review.el --- Changeset review with draft line comments -*- lexical-binding: t; -*-

;; Author: you
;; Version: 0.9.0
;; Package-Requires: ((emacs "28.1") (magit-section "4.0.0"))
;; Keywords: tools, convenience, ai

;;; Commentary:

;; The changeset review buffer: everything the agent (and you) have
;; changed in the working tree, as one navigable diff you annotate line by
;; line and then hand back in a single round.  This is the surface the
;; name `review' belongs to; the transcript is `sprig-session-mode'.
;;
;; The loop it exists for:
;;
;;   d          open the review over the session's working tree
;;   n / p      walk the changed files; TAB folds one away
;;   c c        comment on the line at point, or on the region
;;   e          hand-author a line, block, or function, rather than describe it
;;   c p        publish: every draft, comments and edits, in one turn
;;   Q          quiz yourself on the change before you sign it off
;;
;; Three things make that more than a diff viewer.
;;
;; *Comments are drafts.*  Nothing reaches the agent until you publish, so
;; a review is composed as a whole rather than dribbled out a message at a
;; time.  This is Gerrit's model, and it is the reason the buffer is worth
;; having: reviewing is a pass over a changeset, not a chat.
;;
;; *Comments are anchored, and honestly so.*  A draft records the file,
;; the side, the line range, and the text of the lines it was written
;; against.  A refresh re-anchors it: same text at the same place keeps the
;; line, text that moved re-points to where it went, and text that is gone
;; is marked orphaned and floated at the top of its file rather than
;; silently dropped.  A review tool that quietly loses your comments is
;; worse than one that has none.
;;
;; *Positions come from git, not from tool payloads.*  An `Edit' payload
;; knows the bytes it replaced but never the line they sat on, so
;; line-anchored review can only ride the working-tree diff (source 2 in
;; DESIGN.md).  Sprig reads that diff itself, which the instruction
;; invariant permits: a read is fine, and only writes must go through the
;; agent.  Remotely it rides the session's own SSH transport, never TRAMP.
;; Publishing is an instruction like every other verb, so nothing here
;; touches the repository.

;;; Code:

(require 'cl-lib)
(require 'magit-section)
(require 'seq)
(require 'subr-x)
(require 'eieio)
(require 'transient)
(require 'sprig-change)
(require 'sprig-render)

(declare-function sprig--remote "sprig" ())
(declare-function sprig--remote-sh "sprig" (command host))
(declare-function sprig--remote-dir-arg "sprig" (dir))
(declare-function sprig--directory "sprig" ())
(declare-function sprig-session--compose "sprig-session-mode"
                  (target context &optional plan queue format label))
(declare-function sprig-session--open-stage-buffer "sprig-session-mode"
                  (review file anchor &optional line apply))
(declare-function sprig-quiz "sprig-quiz" ())

;;;; Options

(defcustom sprig-review-base "HEAD"
  "What the changeset review diffs against (`d'); `b' changes it per buffer.

`\"HEAD\"', the default, reviews the uncommitted changes: what the working
tree has that the last commit does not.  That is the right scope while a
turn is in flight.

A *branch* name such as `\"main\"' reviews the whole of what your branch
has done to it, commits and uncommitted work together, from where the two
diverged.  That is the right scope once the agent has been committing as
it goes, and it is the scope a pull request would show.

The middle formulation is deliberately not what you get.  Plain `git diff
main' would compare against main's *tip*, so every commit main gained
since you branched shows up inverted, as changes you appear to have
reverted; `git diff main...HEAD' fixes that but drops the uncommitted work.
Sprig runs `git diff --merge-base main', which is both halves and neither
bug.  See `sprig-review--diff-args'.

Anything containing `..' is passed to `git diff' verbatim, so an explicit
range (`\"main...HEAD\"' for the committed changes alone) still means
exactly what git says it means."
  :type 'string
  :group 'sprig)

(defcustom sprig-review-fontify-code t
  "Syntax-highlight reviewed code in each file's own major mode.
With this on the diff carries the colours you read the code in normally,
and whether a line was added or removed is said by the gutter instead:
the line-number columns and the `+'/`-' marker.  Reading a review is
mostly reading code, so the code gets the syntax colours and the change
gets the margin.  Nil renders the old way, plain text with the whole line
coloured."
  :type 'boolean
  :group 'sprig)

(defcustom sprig-review-default-branches
  '("main" "master" "trunk" "develop" "default")
  "Branch names `d m' considers the default branch, best first.
Sprig looks for each as a local branch and as any remote's, and asks the
forge's own `origin/HEAD' to break a tie when several exist, so a repo
that has both `main' and `master' resolves to whichever one it actually
uses rather than whichever this list happens to name first.  Add yours if
your project calls it something else; `d b' names a base directly and
needs no configuration at all."
  :type '(repeat string)
  :group 'sprig)

(defcustom sprig-review-block-context 400
  "Lines of context `e b' re-reads a file with, to find the block round point.
The review's own diff is read with git's default three lines of context,
which is right for reading a change and far too little for editing one: a
function almost always runs past its own hunk.  So `e b' re-runs `git
diff' for that one file with this many lines of context and finds the
block in the result.  It is the same read the review already does, over
the same transport, so it needs nothing new to work on a remote tree; a
larger number is one bigger round trip and nothing else, and git clamps it
to the file."
  :type 'integer
  :group 'sprig)

(defcustom sprig-review-quote-lines 6
  "How many annotated lines a published comment quotes back at the agent.
A comment cites its line numbers exactly, but numbers alone are brittle
if the agent has moved things since, so the lines themselves ride along.
A long region is truncated to this many with an ellipsis."
  :type 'integer
  :group 'sprig)

;;;; Faces

(defface sprig-review-lineno '((t :inherit line-number))
  "Face for the old/new line-number columns beside a reviewed diff line."
  :group 'sprig)

(defface sprig-review-lineno-added '((t :inherit diff-indicator-added))
  "Face for the line number and marker of an added line."
  :group 'sprig)

(defface sprig-review-lineno-removed '((t :inherit diff-indicator-removed))
  "Face for the line number and marker of a removed line."
  :group 'sprig)

(defface sprig-review-hunk '((t :inherit font-lock-comment-face))
  "Face for a hunk's `@@' heading in the review buffer."
  :group 'sprig)

(defface sprig-review-index '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the summary line at the top of the review."
  :group 'sprig)

(defface sprig-review-comment-body '((t :inherit font-lock-doc-face))
  "Face for the body of a draft review comment."
  :group 'sprig)

(defface sprig-review-comment-heading '((t :inherit font-lock-builtin-face
                                           :weight bold))
  "Face for a draft comment's heading line."
  :group 'sprig)

(defface sprig-review-edit-body '((t :inherit sprig-diff-added))
  "Face for the replacement text of a hand-authored edit draft."
  :group 'sprig)

(defface sprig-review-orphan '((t :inherit warning :weight bold))
  "Face for a draft comment whose lines no longer exist in the diff."
  :group 'sprig)

;;;; Buffer-local state

(defvar-local sprig-review--session nil
  "The `sprig-session-mode' buffer this review publishes to.")

(defvar-local sprig-review--remote nil
  "SSH host the reviewed tree lives on, or nil when it is local.")

(defvar-local sprig-review--root nil
  "Top-level directory of the reviewed repository, on the session host.")

(defvar-local sprig-review--changes nil
  "The parsed changes currently rendered (see `sprig-parse-diff').")

(defvar-local sprig-review--drafts nil
  "Draft comments not yet published, oldest first.
Each is a plist

  (:id N :file PATH :side new|old :start N :end N :text S
   :edit S :anchor LINES :orphan BOOL)

where :start and :end are line numbers on :side, :anchor the text of
those lines when the draft was written, and :orphan non-nil once a
refresh could no longer find that text (see `sprig-review--reanchor').

A draft carries either :text, a comment you wrote about those lines, or
:edit, the replacement you wrote for them by hand (`e').  Both are drafts
in the same store for the same reason: a review is composed as a whole,
and an edit is a comment you were too impatient to phrase.")

(defvar-local sprig-review--next-id 1
  "Counter handing each draft comment an id unique within the buffer.")

(defvar-local sprig-review--wide-cache nil
  "Memoises the wide re-reads `e b' does, keyed by (FILE . BASE).
One `e b' is one `git diff' for one file, which is a round trip on a
remote tree; blocks are usually staged in runs, so the second one in a
file should not pay it again.  Dropped whenever the diff is re-read,
since the file has moved on by then.")

(defvar-local sprig-review--expanded nil
  "Files whose section the reader has unfolded.
Folding is a reading position, not a fact about the diff, so re-reading
the diff must not shut the file you are in the middle of.")

;;;; Reading the tree
;;
;; The one thing sprig runs itself.  A read of the working tree is what
;; DESIGN.md's invariant permits (only writes must go through the agent),
;; and it rides the session's own SSH transport for a remote tree, so
;; neither path needs TRAMP or a local checkout.

(defun sprig-review--run-git (remote dir args)
  "Run git ARGS in DIR and return stdout, on REMOTE over SSH or locally.
REMOTE nil runs git in DIR through `process-file'; a host runs `cd DIR &&
git ARGS' over the session's own SSH transport (`sprig--remote-sh').
Signals on a non-zero git exit."
  (if remote
      (sprig--remote-sh
       (concat "cd " (sprig--remote-dir-arg dir) " && "
               (mapconcat #'shell-quote-argument (cons "git" args) " "))
       remote)
    (let ((default-directory (file-name-as-directory dir)))
      (with-temp-buffer
        (if (zerop (apply #'process-file "git" nil t nil args))
            (buffer-string)
          (error "git %s failed: %s" (string-join args " ")
                 (string-trim (buffer-string))))))))

(defun sprig-review--toplevel (remote dir)
  "Return the git top-level directory containing DIR on REMOTE, or nil."
  (let ((out (ignore-errors
               (sprig-review--run-git remote dir '("rev-parse" "--show-toplevel")))))
    (when out
      (let ((root (string-trim out)))
        (unless (string-empty-p root) root)))))

(defun sprig-review--diff-args (base)
  "Return the `git diff' arguments reviewing against BASE.
Three cases, and the middle one is the point of this function:

- an explicit range (anything with `..') passes through verbatim;
- `\"HEAD\"' diffs the working tree against the last commit, the
  uncommitted changes;
- any other revision diffs from where it and HEAD diverged, so the
  review is everything *this* branch did and nothing the base gained
  since.  Plain `git diff BASE' would show the latter inverted, as
  reversions you never made.

Requires git 2.30 for `--merge-base'."
  (let ((base (string-trim (or base ""))))
    (cond ((string-empty-p base) (list "diff" "HEAD"))
          ((string-match-p "\\.\\." base) (list "diff" base))
          ((equal base "HEAD") (list "diff" "HEAD"))
          (t (list "diff" "--merge-base" base)))))

(defun sprig-review--git (remote root)
  "Return `git diff' output reviewing ROOT on REMOTE against `sprig-review-base'.
Untracked files are not shown, since `git diff' omits them and staging
them would touch the index."
  (sprig-review--run-git remote root
                         (sprig-review--diff-args sprig-review-base)))

(defun sprig-review--ref-branch (ref)
  "Return the branch name REF points at, dropping any remote prefix.
`origin/main' and `main' are the same branch for our purposes.  Safe on
the refs we build ourselves, which always end in a candidate name."
  (car (last (split-string ref "/"))))

(defun sprig-review--candidate-refs (remote root)
  "Return the `sprig-review-default-branches' that exist at ROOT on REMOTE.
Local refs and any remote's, short names, in one `for-each-ref': patterns
that match nothing are simply absent from the output rather than an
error, so a single call can ask about every candidate at once.  That
matters over SSH, where each git call is a round trip."
  (let* ((pats (apply #'append
                      (mapcar (lambda (b)
                                (list (concat "refs/heads/" b)
                                      (concat "refs/remotes/*/" b)))
                              sprig-review-default-branches)))
         (out (ignore-errors
                (sprig-review--run-git
                 remote root
                 (append '("for-each-ref" "--format=%(refname:short)") pats)))))
    (and out (split-string (string-trim out) "\n" t))))

(defun sprig-review--rank-refs (refs)
  "Order REFS by `sprig-review-default-branches', local before remote.
Local first because it is what you would type and it diffs without the
remote being fetched."
  (let (out)
    (dolist (b sprig-review-default-branches)
      (when (member b refs) (push b out))
      (dolist (r refs)
        (when (and (not (equal r b)) (string-suffix-p (concat "/" b) r))
          (push r out))))
    (nreverse out)))

(defun sprig-review--origin-head (remote root)
  "Return the branch `origin/HEAD' points at, or nil.
The forge's own answer to which branch is default, and the only reliable
one when a repo carries both `main' and `master'.  Often absent: `git
init' never sets it and `git clone' can leave it stale."
  (let ((out (ignore-errors
               (sprig-review--run-git
                remote root '("symbolic-ref" "--quiet" "--short"
                              "refs/remotes/origin/HEAD")))))
    (when out
      (let ((ref (string-trim out)))
        (unless (string-empty-p ref) ref)))))

(defun sprig-review--default-branch (remote root)
  "Return the default branch at ROOT on REMOTE, or nil if there is no telling.
Costs one git call in the ordinary case and two when the answer is
genuinely ambiguous:

- exactly one of `sprig-review-default-branches' exists, so take it;
- several do (a repo part-way through renaming `master' to `main'), so
  ask `origin/HEAD' which one the forge means, falling back to the list's
  own order when it cannot say;
- none do, so ask `origin/HEAD' anyway, since a project calling its
  default `release' is beyond guessing but not beyond asking."
  (let* ((refs (sprig-review--rank-refs (sprig-review--candidate-refs remote root)))
         (names (delete-dups (mapcar #'sprig-review--ref-branch refs))))
    (cond
     ((null refs) (sprig-review--origin-head remote root))
     ((null (cdr names)) (car refs))
     (t (or (when-let* ((head (sprig-review--origin-head remote root))
                        (want (sprig-review--ref-branch head)))
              (seq-find (lambda (r) (equal (sprig-review--ref-branch r) want))
                        refs))
            (car refs))))))

;;;; Drafts: anchoring
;;
;; A draft remembers the text it was written against, not just where it
;; sat.  Line numbers are the first thing a fresh diff invalidates, so on
;; refresh the text is what finds the comment its new home; the numbers
;; are only a hint about where to look first.

(defun sprig-review--side-key (side)
  "Return the line-plist key for SIDE, which reads as `old' or `new'."
  (if (eq side 'old) :old :new))

(defun sprig-review--change-for (file changes)
  "Return the change for FILE among CHANGES, or nil."
  (seq-find (lambda (c) (equal (plist-get c :file) file)) changes))

(defun sprig-review--change-lines (change side)
  "Return CHANGE's unified lines that exist on SIDE, in order.
SIDE is `old' or `new'; a line exists on the side that carries a number
for it, so an added line is absent from `old' and a removed one from
`new'."
  (let (out)
    (dolist (u (plist-get change :unified))
      (dolist (l (plist-get u :lines))
        (when (plist-get l (sprig-review--side-key side)) (push l out))))
    (nreverse out)))

(defun sprig-review--text-at (change side start end)
  "Return the text of CHANGE's SIDE lines numbered START..END, in order."
  (let (out)
    (dolist (l (sprig-review--change-lines change side))
      (let ((n (plist-get l (sprig-review--side-key side))))
        (when (and (>= n start) (<= n end)) (push (plist-get l :text) out))))
    (nreverse out)))

(defun sprig-review--find-anchor (change side anchor)
  "Find ANCHOR, a list of line texts, among CHANGE's SIDE lines.
Returns (START . END), the SIDE line numbers of the run whose texts match
ANCHOR exactly, or nil when it is nowhere in the diff.  Used to re-point a
draft whose lines moved."
  (let* ((lines (sprig-review--change-lines change side))
         (texts (mapcar (lambda (l) (plist-get l :text)) lines))
         (n (length anchor))
         (hit nil))
    (when (> n 0)
      (cl-loop for i from 0 to (- (length texts) n)
               until hit
               when (equal (seq-subseq texts i (+ i n)) anchor)
               do (let ((k (sprig-review--side-key side)))
                    (setq hit (cons (plist-get (nth i lines) k)
                                    (plist-get (nth (+ i n -1) lines) k))))))
    hit))

(defun sprig-review--reanchor (drafts changes)
  "Return DRAFTS re-anchored against CHANGES, in place where they still fit.
Three outcomes per draft, and the third is the point of the exercise:
its lines still read the same, so it keeps them; its text moved, so it
follows; or its text is gone from the diff, so it is flagged `:orphan'
and kept.  A comment you wrote is never dropped on your behalf."
  (mapcar
   (lambda (d)
     (let* ((d (copy-sequence d))
            (change (sprig-review--change-for (plist-get d :file) changes))
            (side (plist-get d :side))
            (anchor (plist-get d :anchor))
            (here (and change (sprig-review--text-at
                               change side (plist-get d :start)
                               (plist-get d :end)))))
       (cond
        ((null change) (plist-put d :orphan t))
        ((and here (equal here anchor)) (plist-put d :orphan nil))
        (t (if-let ((hit (sprig-review--find-anchor change side anchor)))
               (progn (plist-put d :start (car hit))
                      (plist-put d :end (cdr hit))
                      (plist-put d :orphan nil))
             (plist-put d :orphan t))))))
   drafts))

;;;; Drafts: what point is on

(defun sprig-review--line-at (&optional pos)
  "Return the diff-line plist rendered at POS (default point), or nil.
The plist is (:file F :kind K :old N :new N), put on the line as a text
property when it was drawn."
  (get-text-property (save-excursion (goto-char (or pos (point)))
                                     (line-beginning-position))
                     'sprig-review-line))

(defun sprig-review--lines-between (beg end)
  "Return the diff-line plists rendered from BEG to END, in order.
Only the diff\='s own lines count: a hunk heading, a file heading, or an
inline draft carries no line plist, so it is skipped rather than ending
the run."
  (let ((lines nil))
    (save-excursion
      (goto-char beg)
      (beginning-of-line)
      (let ((done nil))
        (while (and (not done) (<= (point) end))
          (when-let ((l (sprig-review--line-at))) (push l lines))
          (when (or (eobp) (/= 0 (forward-line 1))) (setq done t)))))
    (nreverse lines)))

(defun sprig-review--region-lines ()
  "Return (FILE SIDE START END ANCHOR) for the line at point or the region.
With an active region, the span it covers; otherwise the single line at
point.  SIDE is `old' only when every covered line is a removal, since a
deletion exists on no other side; anything else anchors to `new', the
post-image, which is what the file on disk actually reads.  Signals a
`user-error' when the selection covers no diff line."
  (let ((lines (sprig-review--lines-between
                (if (use-region-p) (region-beginning) (point))
                (if (use-region-p) (region-end) (point)))))
    (unless lines
      (user-error "Point is not on a line of the diff"))
    (let* ((file (plist-get (car lines) :file))
           (lines (seq-filter (lambda (l) (equal (plist-get l :file) file)) lines))
           (side (if (seq-every-p (lambda (l) (eq (plist-get l :kind) 'del)) lines)
                     'old 'new))
           (key (sprig-review--side-key side))
           (ns (delq nil (mapcar (lambda (l) (plist-get l key)) lines))))
      (unless ns (user-error "That selection has no line on the %s side" side))
      (list file side (apply #'min ns) (apply #'max ns)
            (mapcar (lambda (l) (plist-get l :text))
                    (seq-filter (lambda (l) (plist-get l key)) lines))))))

(defun sprig-review--draft-at-point ()
  "Return the draft comment the section at point belongs to, or nil."
  (let ((sec (magit-current-section)))
    (while (and sec (not (eq (oref sec type) 'sprig-review-draft)))
      (setq sec (oref sec parent)))
    (and sec (oref sec value))))

(defun sprig-review--drafts-at (file side line)
  "Return the drafts on FILE whose SIDE range ends at LINE, in id order."
  (seq-filter (lambda (d)
                (and (equal (plist-get d :file) file)
                     (eq (plist-get d :side) side)
                     (not (plist-get d :orphan))
                     (= (plist-get d :end) line)))
              sprig-review--drafts))

;;;; Syntax highlighting
;;
;; A review is mostly reading code, so the code is fontified in its own
;; file's major mode and the diff's own colours move to the gutter.  Each
;; side of a hunk is fontified as one contiguous block rather than line by
;; line, so a multi-line string or comment inside the hunk comes out right.
;; A construct that *opens before* the hunk still cannot: we have the hunk,
;; not the file, which is the price of never reading the tree beyond the
;; diff (and the only thing that works unchanged for a remote tree).

(defvar sprig-review--fontify-cache (make-hash-table :test 'equal :size 200)
  "Memoises fontified diff blocks, keyed by (FILENAME . TEXT).
A re-render fontifies every hunk afresh though only a comment moved, and
comments move often, so the cache is what keeps `c c' cheap on a big diff.
Keyed by the file's name rather than its path, since the name is all that
picks the major mode.")

(defconst sprig-review--fontify-cache-max 500
  "Entries to hold before clearing `sprig-review--fontify-cache' wholesale.")

(defun sprig-review--fontify-uncached (name text)
  "Return TEXT fontified as a file called NAME would be, or TEXT on failure.
Runs in a temp buffer with the mode hooks delayed, so none of the user's
per-mode machinery (LSP, linters) starts up over a fragment of a diff, and
with file-local variables off, since the text is not a file and should not
be able to act like one."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (let ((buffer-file-name name)
              (enable-local-variables nil)
              (inhibit-message t))
          (delay-mode-hooks (set-auto-mode t)))
        (font-lock-ensure)
        ;; Font-lock in this buffer would strip a plain `face' (see
        ;; `sprig--adopt-faces'), so move them across before they travel.
        (sprig--adopt-faces (buffer-string)))
    (error text)))

(defun sprig-review--fontify-block (file text)
  "Return TEXT fontified for FILE, memoised; TEXT unchanged when off."
  (if (or (not sprig-review-fontify-code) (string-empty-p text))
      text
    (let* ((name (file-name-nondirectory (or file "")))
           (key (cons name text)))
      (or (gethash key sprig-review--fontify-cache)
          (progn
            (when (> (hash-table-count sprig-review--fontify-cache)
                     sprig-review--fontify-cache-max)
              (clrhash sprig-review--fontify-cache))
            (puthash key (sprig-review--fontify-uncached name text)
                     sprig-review--fontify-cache))))))

(defun sprig-review--fontify-side (file lines)
  "Return the texts of LINES fontified together as one block, in order."
  (if (null lines)
      nil
    (let ((text (mapconcat (lambda (l) (plist-get l :text)) lines "\n")))
      (split-string (sprig-review--fontify-block file text) "\n"))))

(defun sprig-review--hunk-texts (file uhunk)
  "Return UHUNK's lines paired with their fontified text, as (LINE . TEXT).
Each side is fontified as its own block: the pre-image for removed lines,
the post-image for added and context ones.  Context appears in both, and
takes the post-image's colours, since that is what the file now reads."
  (let* ((lines (plist-get uhunk :lines))
         (olds (seq-filter (lambda (l) (memq (plist-get l :kind) '(context del)))
                           lines))
         (news (seq-filter (lambda (l) (memq (plist-get l :kind) '(context add)))
                           lines))
         (oldf (sprig-review--fontify-side file olds))
         (newf (sprig-review--fontify-side file news))
         (oi 0) (ni 0))
    (mapcar
     (lambda (l)
       (cons l
             (pcase (plist-get l :kind)
               ('del (prog1 (or (nth oi oldf) (plist-get l :text))
                       (setq oi (1+ oi))))
               ('add (prog1 (or (nth ni newf) (plist-get l :text))
                       (setq ni (1+ ni))))
               (_ (prog1 (or (nth ni newf) (plist-get l :text))
                    (setq oi (1+ oi) ni (1+ ni)))))))
     lines)))

;;;; Rendering

(defun sprig-review--scope-label (base)
  "Return a short phrase naming what a review against BASE covers.
The base alone does not say: `main' means something quite different from
`main...HEAD', and neither is self-evident from the string."
  (let ((base (string-trim (or base ""))))
    (cond ((or (string-empty-p base) (equal base "HEAD"))
           "uncommitted changes, against HEAD")
          ((string-match-p "\\.\\." base) (format "range %s" base))
          (t (format "whole branch, against %s" base)))))

(defun sprig-review--lineno (n)
  "Return N right-aligned in the line-number column, blank when nil."
  (sprig--face (format "%5s" (or n "")) 'sprig-review-lineno))

(defun sprig-review--insert-draft (draft)
  "Insert DRAFT as its own foldable section under the line it annotates.
A hand-authored edit renders as what it is, the replacement text itself,
under a heading that says so: unpublished either way, and both taken back
with `k'."
  (magit-insert-section (sprig-review-draft draft)
    (let* ((orphan (plist-get draft :orphan))
           (edit (plist-get draft :edit))
           (start (plist-get draft :start))
           (end (plist-get draft :end))
           (where (if (= start end) (format "line %d" start)
                    (format "lines %d-%d" start end))))
      (magit-insert-heading
        (concat "      "
                (sprig--face (format "↳ %s (%s%s)"
                                     (if edit "your edit" "comment")
                                     (if orphan "orphaned, was " "") where)
                             (if orphan 'sprig-review-orphan
                               'sprig-review-comment-heading))))
      (dolist (l (split-string (or edit (plist-get draft :text)) "\n"))
        (insert "        "
                (sprig--face l (if edit 'sprig-review-edit-body
                                 'sprig-review-comment-body))
                "\n")))))

(defun sprig-review--insert-uline (file line text)
  "Insert one unified diff LINE of FILE, whose code reads TEXT.
The gutter says what happened to the line and the code keeps its own
syntax colours: the number column that *has* a number on the changed side
carries the added/removed face, along with the `+'/`-' marker.  The marker
stays because colour alone should not be the only thing saying which way a
line went."
  (let* ((kind (plist-get line :kind))
         (marker (pcase kind ('add "+") ('del "-") (_ " ")))
         (gutter (pcase kind
                   ('add 'sprig-review-lineno-added)
                   ('del 'sprig-review-lineno-removed)
                   (_ 'sprig-review-lineno)))
         (plain (if sprig-review-fontify-code
                    text
                  ;; Unfontified, the line itself has to carry the colour.
                  (sprig--face text (pcase kind
                                      ('add 'sprig-diff-added)
                                      ('del 'sprig-diff-removed)
                                      (_ 'default)))))
         (beg (point)))
    (insert (sprig--face (format "%5s" (or (plist-get line :old) ""))
                         (if (eq kind 'del) gutter 'sprig-review-lineno))
            (sprig--face (format "%5s" (or (plist-get line :new) ""))
                         (if (eq kind 'add) gutter 'sprig-review-lineno))
            " "
            (sprig--face marker gutter)
            " "
            plain
            "\n")
    ;; The whole line carries what it is, so a comment at point (or over a
    ;; region) can read its file, side, and number straight off the buffer.
    (put-text-property beg (point) 'sprig-review-line
                       (list :file file :kind kind
                             :old (plist-get line :old)
                             :new (plist-get line :new)
                             :text (plist-get line :text)))
    (dolist (d (sprig-review--drafts-at
                file (if (eq kind 'del) 'old 'new)
                (or (plist-get line (if (eq kind 'del) :old :new)) -1)))
      (sprig-review--insert-draft d))))

(defun sprig-review--insert-uhunk (file uhunk)
  "Insert UHUNK of FILE as a foldable section headed by its `@@' line.
Both sides are fontified in one pass here rather than per line, so a
construct spanning several lines of the hunk comes out right."
  (magit-insert-section (sprig-review-hunk uhunk)
    (magit-insert-heading
      (sprig--face
       (format "  @@ -%d,%d +%d,%d @@%s"
               (plist-get uhunk :old-start) (plist-get uhunk :old-count)
               (plist-get uhunk :new-start) (plist-get uhunk :new-count)
               (if-let ((h (plist-get uhunk :heading))) (concat " " h) ""))
       'sprig-review-hunk))
    (pcase-dolist (`(,l . ,text) (sprig-review--hunk-texts file uhunk))
      (sprig-review--insert-uline file l text))))

(defun sprig-review--file-drafts (file)
  "Return the drafts filed against FILE, in the order they were written."
  (seq-filter (lambda (d) (equal (plist-get d :file) file))
              sprig-review--drafts))

(defun sprig-review--insert-orphans (drafts)
  "Insert the orphans among DRAFTS, if any, above their file's hunks.
An orphan has no line left to sit under, so it floats to the top of the
file it was written against rather than vanishing."
  (dolist (d drafts)
    (when (plist-get d :orphan) (sprig-review--insert-draft d))))

(defun sprig-review--comment-count (n)
  "Return the \"(N comments)\" suffix for a file heading, empty when N is zero.
A folded file has to say that it carries comments, or folding would hide
work the reader has already done."
  (if (zerop n) ""
    (sprig--face (format "  (%d comment%s)" n (if (= n 1) "" "s"))
                 'sprig-review-comment-heading)))

(defun sprig-review--insert-file (change)
  "Insert CHANGE as a file section, folded unless it is open or annotated.
Folded by default: the first question a review answers is what changed,
and forty files unrolled is not an answer.  A file the reader has opened
stays open across a redraw (see `sprig-review--expanded\='), and a file
carrying a draft opens itself, because a comment you cannot see is worse
than a longer buffer."
  (let* ((file (plist-get change :file))
         (drafts (sprig-review--file-drafts file)))
    (magit-insert-section
        (sprig-change change
                      (not (or drafts (member file sprig-review--expanded))))
      (magit-insert-heading
        (concat (sprig--face file 'sprig-diff-file)
                "  " (sprig--stat-string change)
                (sprig-review--comment-count (length drafts))))
      (sprig-review--insert-orphans drafts)
      (if-let ((unified (plist-get change :unified)))
          (dolist (u unified) (sprig-review--insert-uhunk file u))
        (insert "  (no textual hunks)\n")))))

(defun sprig-review--insert-summary (changes)
  "Insert the one line saying how much CHANGES is, and what it is against.
One line, not a file index: the folded headings below already list the
files with their stats, so an index would say it all twice."
  (let ((add 0) (del 0) (n (length changes)))
    (dolist (c changes)
      (let ((stat (sprig-change-stat c)))
        (setq add (+ add (car stat))
              del (+ del (cdr stat)))))
    (insert (sprig--face (format "%d file%s" n (if (= n 1) "" "s"))
                         'sprig-review-index)
            "  ("
            (sprig--face (format "+%d" add) 'sprig-diff-stat-added)
            " "
            (sprig--face (format "-%d" del) 'sprig-diff-stat-removed)
            ")   "
            (sprig--face (sprig-review--scope-label sprig-review-base)
                         'sprig-review-hunk)
            "\n\n")))

(defun sprig-review--note-expansion ()
  "Record which file sections are open, before a redraw throws them away."
  (when magit-root-section
    (setq sprig-review--expanded
          (let (open)
            (dolist (s (oref magit-root-section children) open)
              (when (and (eq (oref s type) 'sprig-change)
                         (not (oref s hidden)))
                (push (sprig--section-file s) open)))))))

(defun sprig-review--render ()
  "Redraw the review buffer from `sprig-review--changes' and its drafts.
Sprig owns which files are folded, in `sprig-review--expanded', so
magit's own visibility cache is bound away for the redraw: left in, it
would answer for a section before the fold rule here gets to."
  (let ((inhibit-read-only t)
        (magit-section-visibility-cache nil)
        (changes sprig-review--changes))
    (sprig-review--note-expansion)
    (remove-overlays (point-min) (point-max) 'sprig-mark t)
    (setq sprig--marks nil)
    (erase-buffer)
    (magit-insert-section (sprig-review-root)
      (if (null changes)
          (insert (format "No %s.\n"
                          (sprig-review--scope-label sprig-review-base)))
        (sprig-review--insert-summary changes)
        (dolist (c changes) (sprig-review--insert-file c))))
    ;; Inserting a section only records that it should be folded; magit
    ;; draws the folds from its own refresh, which sprig does not run.
    (magit-section-show magit-root-section)
    (goto-char (point-min))))

(defun sprig-review--place ()
  "Return where point is as (FILE SIDE N COLUMN TEXT), or nil off the diff.
A buffer position is the wrong thing to remember across a redraw: the
diff above point may have grown or shrunk, so the same offset lands on a
different line.  The line\='s own identity survives that."
  (when-let ((l (sprig-review--line-at)))
    (let ((side (if (eq (plist-get l :kind) 'del) 'old 'new)))
      (list (plist-get l :file) side
            (plist-get l (sprig-review--side-key side))
            (current-column)
            (plist-get l :text)))))

(defun sprig-review--diff-lines ()
  "Return ((POSITION . LINE) ...) for every rendered diff line, in order."
  (let ((pos (point-min)) out)
    (while pos
      (when-let ((l (get-text-property pos 'sprig-review-line)))
        (push (cons pos l) out))
      (setq pos (next-single-property-change pos 'sprig-review-line)))
    (nreverse out)))

(defun sprig-review--goto-place (place fallback)
  "Put point back on PLACE, falling back to buffer position FALLBACK.
PLACE is matched on its text first and its number second, the way a draft
is re-anchored (`sprig-review--reanchor\='): a refresh after the agent has
worked is exactly the case where the number moved and the line did not.
Where that text now appears more than once the nearest to the old number
wins, and when it has gone the old number is the last guess before the
offset."
  (pcase-let ((`(,file ,side ,n ,col ,text) place))
    (let ((key (and place (sprig-review--side-key side)))
          by-text by-number)
      (pcase-dolist (`(,pos . ,l) (and place (sprig-review--diff-lines)))
        (when-let* (((equal (plist-get l :file) file))
                    (num (plist-get l key)))
          (when (and (equal (plist-get l :text) text)
                     (or (null by-text)
                         (< (abs (- num n)) (abs (- (cdr by-text) n)))))
            (setq by-text (cons pos num)))
          (when (and (eql num n) (null by-number))
            (setq by-number (cons pos num)))))
      (cond ((or by-text by-number)
             (goto-char (car (or by-text by-number)))
             (move-to-column col))
            (fallback (goto-char (min fallback (point-max))))))))

(defun sprig-review--place-at (pos)
  "Return the place (see `sprig-review--place\=') read at POS."
  (save-excursion (goto-char pos) (sprig-review--place)))

(defun sprig-review--relocate (place fallback)
  "Return where PLACE is now, or FALLBACK, without moving point."
  (save-excursion (sprig-review--goto-place place fallback) (point)))

(defun sprig-review--render-in-place (&optional redraw)
  "Run REDRAW (default `sprig-review--render\='), keeping the reading position.
A redraw erases the buffer, so `sprig-review--render\=' leaves point at the
top.  That is right for a fresh review and wrong for an edit made while
reading one: filing a comment should not cost you your place.  Each
window showing the review is put back by its own point and start as
well, since the erase collapses those independently of the buffer\='s own
point, and the window you are reading in need not be the selected one."
  (let ((place (sprig-review--place))
        (pos (point))
        (windows (mapcar (lambda (win)
                           (list win
                                 (sprig-review--place-at (window-point win))
                                 (window-point win)
                                 (sprig-review--place-at (window-start win))
                                 (window-start win)))
                         (get-buffer-window-list nil nil t))))
    (funcall (or redraw #'sprig-review--render))
    (sprig-review--goto-place place pos)
    (pcase-dolist (`(,win ,point-place ,point-pos ,start-place ,start-pos)
                   windows)
      (when (window-live-p win)
        (set-window-point win (sprig-review--relocate point-place point-pos))
        ;; NOFORCE, so a start that would now put point off screen is
        ;; recomputed rather than obeyed.
        (set-window-start win (sprig-review--relocate start-place start-pos)
                          t)))))

(defun sprig-review--reload (&optional keep-point)
  "Re-read the diff, re-anchor the drafts, and redraw.
KEEP-POINT holds the reading position across the redraw: the same diff
line under point, and the same files open (see `sprig-review--expanded\=')."
  (let ((redraw
         (lambda ()
           ;; The wide re-reads describe the tree as it was; it has moved.
           (setq sprig-review--wide-cache nil)
           (setq sprig-review--changes
                 (sprig-parse-diff (sprig-review--git sprig-review--remote
                                                      sprig-review--root))
                 sprig-review--drafts
                 (sprig-review--reanchor sprig-review--drafts
                                         sprig-review--changes))
           (sprig-review--render))))
    (if keep-point
        (sprig-review--render-in-place redraw)
      (funcall redraw))))

;;;; Writing a comment

(defvar-local sprig-review--comment-target nil
  "Review buffer a comment buffer files its draft in.")
(defvar-local sprig-review--comment-draft nil
  "The draft plist being written, complete but for its `:text'.")

(defvar sprig-review-comment-mode-map (make-sparse-keymap)
  "Keymap for `sprig-review-comment-mode'.
Bound below, for the reason `sprig-review-mode-map' gives.")

(define-key sprig-review-comment-mode-map (kbd "C-c C-c")
            #'sprig-review-comment-save)
(define-key sprig-review-comment-mode-map (kbd "C-c C-k")
            #'sprig-review-comment-abort)

(define-derived-mode sprig-review-comment-mode text-mode "Sprig-Comment"
  "Major mode for writing one draft review comment.
\\<sprig-review-comment-mode-map>
`\\[sprig-review-comment-save]' files the draft,
`\\[sprig-review-comment-abort]' throws it away.
Nothing reaches the agent until the review is published."
  :group 'sprig)

(defun sprig-review--edit-comment (draft &optional existing)
  "Pop a buffer to write DRAFT's text; EXISTING non-nil is a re-edit."
  (let ((review (current-buffer))
        (buf (get-buffer-create "*sprig-comment*")))
    (with-current-buffer buf
      (sprig-review-comment-mode)
      (erase-buffer)
      (when-let ((text (plist-get draft :text))) (insert text))
      (setq sprig-review--comment-target review
            sprig-review--comment-draft draft)
      (goto-char (point-max)))
    (pop-to-buffer buf)
    (message "%s %s:%s.  C-c C-c to file the draft, C-c C-k to discard"
             (if existing "Editing comment on" "Comment on")
             (file-name-nondirectory (plist-get draft :file))
             (if (= (plist-get draft :start) (plist-get draft :end))
                 (plist-get draft :start)
               (format "%d-%d" (plist-get draft :start) (plist-get draft :end))))))

(defun sprig-review-comment-save ()
  "File the comment being written as a draft on its review buffer."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (review sprig-review--comment-target)
        (draft sprig-review--comment-draft))
    (when (string-empty-p text) (user-error "Empty comment"))
    (unless (buffer-live-p review) (user-error "The review buffer is gone"))
    (plist-put draft :text text)
    (with-current-buffer review
      (setq sprig-review--drafts
            (append (seq-remove (lambda (d) (eq (plist-get d :id)
                                                (plist-get draft :id)))
                                sprig-review--drafts)
                    (list draft)))
      (sprig-review--render-in-place))
    (quit-window t)
    (message "sprig: draft comment filed; `c p' publishes the review")))

(defun sprig-review-comment-abort ()
  "Discard the comment being written."
  (interactive)
  (quit-window t)
  (message "sprig: comment discarded"))

(defun sprig-review-comment ()
  "Comment on the line at point, or on the region (`c c').
The draft records the file, the side, the line range, and the text of
those lines, so a later refresh can find it again even if the agent has
moved things.  It goes nowhere until you publish."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (pcase-let ((`(,file ,side ,start ,end ,anchor) (sprig-review--region-lines)))
    (when (use-region-p) (deactivate-mark))
    (sprig-review--edit-comment
     (list :id (prog1 sprig-review--next-id (cl-incf sprig-review--next-id))
           :file file :side side :start start :end end
           :text nil :anchor anchor :orphan nil))))

(defun sprig-review-comment-edit ()
  "Re-open the draft at point for editing (`c e').
A comment re-opens in the comment buffer, an edit in the staging buffer
it was written in, seeded with what you wrote last time."
  (interactive)
  (let ((draft (or (sprig-review--draft-at-point)
                   (user-error "Point is not on a draft"))))
    (if (plist-get draft :edit)
        (sprig-review--open-stage
         (plist-get draft :file)
         (mapconcat #'identity (plist-get draft :anchor) "\n")
         (plist-get draft :start)
         (plist-get draft :id)
         (plist-get draft :edit))
      (sprig-review--edit-comment (copy-sequence draft) t))))

(defun sprig-review-comment-delete ()
  "Take back the draft at point, comment or edit (`k').
The same take-it-back gesture that unstages a queued message: a draft is
another thing point can sit on, and nothing has been sent."
  (interactive)
  (let ((draft (or (sprig-review--draft-at-point)
                   (user-error "Point is not on a draft"))))
    (setq sprig-review--drafts
          (seq-remove (lambda (d) (eq (plist-get d :id) (plist-get draft :id)))
                      sprig-review--drafts))
    (sprig-review--render-in-place)
    (message "sprig: %s taken back"
             (if (plist-get draft :edit) "edit" "comment"))))

(defun sprig-review-discard-drafts ()
  "Discard every draft in this review, comments and edits alike (`c Q')."
  (interactive)
  (let ((n (length sprig-review--drafts)))
    (when (zerop n) (user-error "No drafts to discard"))
    (when (yes-or-no-p (format "Discard %s? "
                               (sprig-review--count-label
                                sprig-review--drafts)))
      (setq sprig-review--drafts nil)
      (sprig-review--render-in-place)
      (message "sprig: %d draft%s discarded" n (if (= n 1) "" "s")))))

;;;; Publishing

(defun sprig-review--quote (draft)
  "Return DRAFT's anchored lines as quoted text, truncated for length."
  (let* ((all (plist-get draft :anchor))
         (shown (seq-take all sprig-review-quote-lines))
         (more (- (length all) (length shown))))
    (concat (mapconcat (lambda (l) (concat "> " l)) shown "\n")
            (if (> more 0) (format "\n> … (%d more line%s)"
                                   more (if (= more 1) "" "s"))
              ""))))

(defun sprig-review--publish-blocks (d)
  "Return D's old and new text as two fenced blocks, for an edit to apply.
The old block is the anchor in full, never the elided quote a comment
gets: it is what the agent has to match, so eliding it would break it."
  (format "Replace these lines, exactly as they stand:

```
%s
```

with mine, character for character:

```
%s
```
"
          (mapconcat #'identity (plist-get d :anchor) "\n")
          (plist-get d :edit)))

(defun sprig-review--publish-draft (d)
  "Return the published body of draft D: a comment, or an edit to apply."
  (if (plist-get d :edit)
      (sprig-review--publish-blocks d)
    (format "%s\n\n%s\n" (sprig-review--quote d) (plist-get d :text))))

(defun sprig-review--publish-file (file drafts)
  "Return the published section for FILE's DRAFTS."
  (concat
   (format "## %s\n" file)
   (mapconcat
    (lambda (d)
      (let ((start (plist-get d :start)) (end (plist-get d :end)))
        (format "\n### %s%s\n\n%s"
                (if (= start end) (format "Line %d" start)
                  (format "Lines %d-%d" start end))
                (cond ((plist-get d :edit) " (an edit I wrote by hand)")
                      ((eq (plist-get d :side) 'old)
                       " (a removed line, numbered in the pre-image)")
                      (t ""))
                (sprig-review--publish-draft d))))
    drafts "")))

(defun sprig-review--publish-text (drafts)
  "Return the review body for DRAFTS: every comment, grouped by file, in order.
Orphans go in a section of their own at the end, named as such, since a
comment whose lines have moved out from under it is still worth reading
but should not claim a line number it no longer owns."
  (let* ((live (seq-remove (lambda (d) (plist-get d :orphan)) drafts))
         (orphans (seq-filter (lambda (d) (plist-get d :orphan)) drafts))
         (files (seq-uniq (mapcar (lambda (d) (plist-get d :file)) live))))
    (concat
     (mapconcat
      (lambda (f)
        (sprig-review--publish-file
         f (seq-sort-by (lambda (d) (plist-get d :start)) #'<
                        (seq-filter (lambda (d) (equal (plist-get d :file) f))
                                    live))))
      files "\n")
     (when orphans
       (concat
        "\n## Comments whose lines have since moved\n\n"
        "These were written against text that is no longer where it was, so "
        "they carry the text rather than a line number:\n"
        (mapconcat (lambda (d)
                     (format "\n- In `%s`%s:\n\n%s\n"
                             (plist-get d :file)
                             (if (plist-get d :edit)
                                 ", an edit of mine whose lines have gone; \
check where it belongs before applying it, or tell me it no longer fits"
                               "")
                             (sprig-review--publish-draft d)))
                   orphans ""))))))

(defun sprig-review--publish-format (text body &optional edits)
  "Frame a published review: covering note TEXT over the draft BODY.
EDITS, when it counts any, says some entries are text I wrote myself, so
the framing asks for those verbatim rather than for a judgement about
them."
  (format "I have reviewed the current changes and left %s on specific \
lines. Address each one, then tell me briefly what you changed for each. \
Where you disagree with a comment, say so rather than changing the code.%s

%s

---

%s"
          (if (and edits (> edits 0)) "comments and edits" "comments")
          (if (and edits (> edits 0))
              "

The entries marked as an edit I wrote by hand are not suggestions to \
interpret: apply each with a single Edit on that file, reproducing my \
text character for character, and do not reformat, re-indent, correct, \
or improve any of it. Where one no longer matches the file, say so \
rather than guessing where it should go."
            "")
          text body))

(defun sprig-review--count-label (drafts)
  "Return a phrase counting DRAFTS, telling comments and edits apart."
  (let* ((edits (seq-count (lambda (d) (plist-get d :edit)) drafts))
         (comments (- (length drafts) edits))
         (say (lambda (n word)
                (and (> n 0) (format "%d %s%s" n word (if (= n 1) "" "s"))))))
    (string-join (delq nil (list (funcall say comments "comment")
                                 (funcall say edits "edit")))
                 " and ")))

(defun sprig-review-publish ()
  "Publish this review: every draft, in one turn, to the session (`c p').
The comments you wrote and the edits you wrote by hand go out together,
since they are one review.  Opens the ordinary compose buffer with them
attached, so you write the covering note and see exactly what goes out
before it does.  Sending clears the drafts, since they are then the
agent's problem rather than yours."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (unless sprig-review--drafts
    (user-error "No drafts; `c c' comments on a line, `e' writes the code \
yourself, `c m' sends a plain message"))
  (unless (buffer-live-p sprig-review--session)
    (user-error "The session this review belongs to is gone"))
  (let* ((drafts sprig-review--drafts)
         (edits (seq-count (lambda (d) (plist-get d :edit)) drafts))
         (label (sprig-review--count-label drafts))
         (body (sprig-review--publish-text drafts))
         (review (current-buffer)))
    (sprig-session--compose
     sprig-review--session body nil nil
     (lambda (text ctx)
       ;; Clearing on send, not on compose: an aborted compose must leave
       ;; the review exactly as it was, drafts and all.
       (when (buffer-live-p review)
         (with-current-buffer review
           (setq sprig-review--drafts nil)
           (sprig-review--render-in-place)))
       (sprig-review--publish-format text ctx edits))
     label)
    (with-current-buffer "*sprig-message*"
      (when (= (buffer-size) 0)
        (insert (format "%s on the changes below." label))))))

;;;; The block around point
;;
;; `e b' stages more code than the diff shows, which needs more code than
;; the diff shows.  It gets it the way the review gets everything else: by
;; running `git diff' again, for that one file, with a wide `-U'.  Not by
;; reading the file, which would need a second transport for a remote tree
;; and a second answer to the question of what Sprig is allowed to touch.
;; The wider read comes back through the same parser with the same
;; new-side line numbers, so nothing downstream can tell the difference.
;;
;; What bounds the block is indentation, and nothing else: no major mode,
;; no defun motion, no parser.  That is honest about what it is (a block,
;; not a claim about syntax) and it works the same in every language that
;; indents conventionally.  You see the block in the staging buffer before
;; you touch it, which is the check on the heuristic.

(defun sprig-review--wide-change (file)
  "Return FILE's change, re-read with `sprig-review-block-context' context.
Nil when the wider read no longer shows the file at all.  Memoised in
`sprig-review--wide-cache'."
  (unless sprig-review--wide-cache
    (setq sprig-review--wide-cache (make-hash-table :test 'equal)))
  (let* ((key (cons file sprig-review-base))
         (hit (gethash key sprig-review--wide-cache 'miss)))
    (when (eq hit 'miss)
      (setq hit (sprig-review--change-for
                 file
                 (sprig-parse-diff
                  (sprig-review--run-git
                   sprig-review--remote sprig-review--root
                   (append (sprig-review--diff-args sprig-review-base)
                           (list (format "-U%d" sprig-review-block-context)
                                 "--" file))))))
      (puthash key hit sprig-review--wide-cache))
    hit))

(defun sprig-review--runs (lines)
  "Split LINES into runs consecutive on the new side, in order.
A wide read still comes back in pieces when a file changes in two places
further apart than the context reaches, and a piece is all the block rule
may look at: the lines between two pieces were never read, so nothing
here knows them."
  (let (runs cur)
    (dolist (l lines)
      (if (and cur (= (plist-get l :new) (1+ (plist-get (car cur) :new))))
          (push l cur)
        (when cur (push (nreverse cur) runs))
        (setq cur (list l)))) 
    (when cur (push (nreverse cur) runs))
    (nreverse runs)))

(defun sprig-review--indent (text)
  "Return TEXT's indentation in columns, or nil when TEXT is blank.
A tab counts to the next multiple of eight, so a tab-indented file
measures the same as a space-indented one and the two can be compared."
  (let ((col 0) (i 0) (n (length text)) (code nil))
    (while (and (not code) (< i n))
      (pcase (aref text i)
        (?\s (setq col (1+ col)) (setq i (1+ i)))
        (?\t (setq col (* 8 (1+ (/ col 8)))) (setq i (1+ i)))
        (_ (setq code t))))
    (and code col)))

(defun sprig-review--closer-p (text)
  "Non-nil when TEXT is nothing but closing delimiters.
A C-like language shuts a block with a brace back at the *opening* line's
indentation, so the line that would end the block by indentation alone is
the last line of it.  Matching bare closers catches that without
pretending to parse the language."
  (string-match-p "\\`[ \t]*\\(?:[]})]+[ \t]*[;,]?\\|end\\)[ \t]*\\'" text))

(defun sprig-review--code-line (texts k step)
  "Return the index of the first non-blank line from K along STEP, or nil."
  (let ((n (length texts)) (hit nil))
    (while (and (null hit) (>= k 0) (< k n))
      (if (sprig-review--indent (aref texts k))
          (setq hit k)
        (setq k (+ k step))))
    hit))

(defun sprig-review--walk-up (texts start)
  "Return the nearest index above START indented less than it, or nil."
  (let ((col (or (sprig-review--indent (aref texts start)) 0))
        (k (1- start))
        (hit nil))
    (while (and (>= k 0) (null hit))
      (let ((c (sprig-review--indent (aref texts k))))
        (when (and c (< c col)) (setq hit k)))
      (setq k (1- k)))
    hit))

(defun sprig-review--block-bounds (texts i &optional levels)
  "Return (START END EDGE), indices into TEXTS, bounding the block around I.
The block starts at the nearest line indented less than I, or at I itself
when I opens a block of its own, which is what puts point on a `defun'
line inside that defun rather than inside its parent.  It ends before the
next line back at the starting indentation, or at that line when the line
is nothing but closing delimiters.  Trailing blank lines belong to
whatever comes next, so they are trimmed.

LEVELS, default 1, is how many indentation levels to climb.  Nesting is
what indentation measures, so in a deeply nested language the first level
is the innermost enclosing form rather than the whole function; climbing
another level is how you say you meant the function.

EDGE is non-nil when a boundary was the end of TEXTS rather than a line
of code: the block runs past what was read, so the caller has been handed
less of it than there is."
  (let* ((n (length texts))
         (i (or (sprig-review--code-line texts i 1)
                (sprig-review--code-line texts i -1)
                i))
         (col (or (sprig-review--indent (aref texts i)) 0))
         (below (sprig-review--code-line texts (1+ i) 1))
         (opens (and below (> (sprig-review--indent (aref texts below)) col)))
         (start i)
         (open-found opens))
    (unless opens
      (when-let ((up (sprig-review--walk-up texts i)))
        (setq start up open-found t)))
    ;; Every level after the first climbs from where the last one landed.
    (dotimes (_ (max 0 (1- (or levels 1))))
      (if-let ((up (sprig-review--walk-up texts start)))
          (setq start up)
        (setq open-found nil)))
    (let* ((bcol (or (sprig-review--indent (aref texts start)) 0))
           (end (1- n))
           (close-found nil)
           (k (1+ start)))
      (while (and (< k n) (not close-found))
        (let ((c (sprig-review--indent (aref texts k))))
          (when (and c (<= c bcol))
            (setq end (if (sprig-review--closer-p (aref texts k)) k (1- k))
                  close-found t)))
        (setq k (1+ k)))
      (while (and (> end start)
                  (null (sprig-review--indent (aref texts end))))
        (setq end (1- end)))
      (list start end (not (and open-found close-found))))))

(defun sprig-review--defun-bounds (texts i file)
  "Return (START . END), indices into TEXTS, for the defun around line I.
Nil when FILE's major mode has no notion of one, or when the defun it
finds does not contain I after all.  The mode is the one thing here that
can tell a string from structure, which is exactly what the indentation
rule cannot do: a docstring line at column zero looks like the start of a
block to it, and in Lisp that is most functions.  So this is what `e d'
uses and `e b' is the fallback, rather than the other way round.

The mode runs over the reconstructed text in a temp buffer with its hooks
delayed and file-local variables off: this is a measurement, not a visit."
  (with-temp-buffer
    (insert (mapconcat #'identity texts "\n"))
    (let ((buffer-file-name file)
          (enable-local-variables nil))
      (delay-mode-hooks (ignore-errors (set-auto-mode t))))
    (unless (eq major-mode 'fundamental-mode)
      (goto-char (point-min))
      (forward-line i)
      (let (start end)
        (ignore-errors
          (end-of-defun)
          ;; `end-of-defun' lands on the line after; step back off it.
          (setq end (line-number-at-pos (if (bolp) (max 1 (1- (point))) (point))))
          (beginning-of-defun)
          (setq start (line-number-at-pos)))
        (when (and start end (<= start (1+ i)) (>= end (1+ i)))
          (cons (1- start) (1- end)))))))

(defun sprig-review--block-line ()
  "Return (FILE . LINE) naming the new-side line `e b' bounds a block from.
A removed line is in no file, so it stands for the first line of its hunk
that is."
  (let* ((l (or (sprig-review--line-at)
                (user-error "Point is not on a line of the diff")))
         (file (plist-get l :file))
         (n (or (plist-get l :new)
                (car (delq nil
                           (mapcar (lambda (x) (plist-get x :new))
                                   (plist-get (sprig-review--hunk-at
                                               (magit-current-section))
                                              :lines))))
                (user-error "Nothing on this line is in the file to edit"))))
    (cons file n)))

(defun sprig-review--stage-block-target (&optional levels defun)
  "Return (FILE TEXT LINE EDGE) for the block around point, LEVELS out.
Re-reads FILE with wide context, keeps the run of lines that read gave
around point, and bounds the block within it.  With DEFUN, the file's own
major mode bounds it instead (see `sprig-review--defun-bounds'), falling
back to indentation when the mode has nothing to say.

EDGE means the block reaches the end of what was read rather than a line
of code, so there may be more of it than you were handed."
  (pcase-let* ((`(,file . ,n) (sprig-review--block-line))
               (change (or (sprig-review--wide-change file)
                           (user-error "A wider read no longer shows %s" file)))
               (run (or (seq-find
                         (lambda (r)
                           (and (<= (plist-get (car r) :new) n)
                                (>= (plist-get (car (last r)) :new) n)))
                         (sprig-review--runs
                          (sprig-review--change-lines change 'new)))
                        (user-error "The wider read does not cover line %d" n)))
               (texts (vconcat (mapcar (lambda (l) (plist-get l :text)) run)))
               (i (- n (plist-get (car run) :new)))
               (`(,start ,end ,edge)
                 (or (and defun
                          (when-let ((b (sprig-review--defun-bounds
                                         texts i file)))
                            (list (car b) (cdr b)
                                  (or (and (= (car b) 0)
                                           (> (plist-get (car run) :new) 1))
                                      (= (cdr b) (1- (length texts)))))))
                     (sprig-review--block-bounds texts i levels))))
    (list file
          (mapconcat #'identity (seq-subseq texts start (1+ end)) "\n")
          (plist-get (nth start run) :new)
          edge)))

;;;; Plain messages, and hand-authoring

(defun sprig-review-message (&optional queue)
  "Send a plain message about the marked hunks to the session (`c m').
The escape hatch from the comment loop: some feedback is about the change
as a whole rather than a line of it.  With QUEUE non-nil, hold it until
the running turn ends."
  (interactive)
  (unless (buffer-live-p sprig-review--session)
    (user-error "The session this review belongs to is gone"))
  (sprig-session--compose sprig-review--session (sprig--marked-context)
                          nil queue))

(defun sprig-review-message-queue ()
  "Send a plain message about the marked hunks, queued (`c M')."
  (interactive)
  (sprig-review-message t))

(defun sprig-review--line-at-first (section)
  "Return the diff-line plist of SECTION's first rendered line, or nil."
  (save-excursion
    (goto-char (oref section start))
    (or (sprig-review--line-at)
        (progn (forward-line 1) (sprig-review--line-at)))))

(defun sprig-review--stage-anchor (lines)
  "Return (TEXT . LINE) for the disk-side text of LINES, or nil when it has none.
Only the lines the file still holds count, the context and added ones, so
a removal contributes nothing: the anchor has to be bytes an `Edit' can
match.  LINE is where the run starts in the new file, which is what tells
the agent which occurrence to change when the text is not unique.  Signals
a `user-error' when the kept lines are not one contiguous run, since two
spans with a gap between them are not one `old_string'."
  (let* ((kept (seq-filter (lambda (l)
                             (and (memq (plist-get l :kind) '(context add))
                                  (plist-get l :new)))
                           lines))
         (ns (mapcar (lambda (l) (plist-get l :new)) kept)))
    (when kept
      (unless (equal ns (number-sequence (car ns) (car (last ns))))
        (user-error "That selection skips a gap the diff never showed; \
take one hunk at a time, or `e b' to read across it"))
      (cons (mapconcat (lambda (l) (plist-get l :text)) kept "\n")
            (car ns)))))

(defun sprig-review--hunk-of (section)
  "Return the unified hunk SECTION stands for, or nil when it stands for none.
A hunk section is its own hunk; a file section is its hunk when it has
exactly one, since a file of several has not said which."
  (pcase (and section (oref section type))
    ('sprig-review-hunk (oref section value))
    ('sprig-change
     (let ((us (plist-get (oref section value) :unified)))
       (cond ((null us) (user-error "This file has no hunk to edit"))
             ((cdr us)
              (user-error "%s has %d hunks; open it with TAB and put point on one"
                          (plist-get (oref section value) :file) (length us)))
             (t (car us)))))
    (_ nil)))

(defun sprig-review--hunk-at (section)
  "Return the hunk SECTION is in, walking out through its parents, or nil."
  (let ((hunk nil))
    (while (and section (not (setq hunk (sprig-review--hunk-of section))))
      (setq section (oref section parent)))
    hunk))

(defun sprig-review--file-of (section)
  "Return the path of the file SECTION sits under, or nil."
  (while (and section (not (eq (oref section type) 'sprig-change)))
    (setq section (oref section parent)))
  (and section (plist-get (oref section value) :file)))

(defun sprig-review--marked-hunk-sections ()
  "Return the marked hunk and file sections, with no section-at-point fallback.
Only real marks: `e' falls back to point itself, and it needs to know the
difference."
  (when sprig--marks
    (seq-filter (lambda (s)
                  (memq (oref s type) '(sprig-review-hunk sprig-change)))
                (sprig--marked-sections))))

(defun sprig-review--stage-line-target ()
  "Return (FILE TEXT LINE) for the one line point is on, or nil.
Nil off the diff, on a hunk or file heading, and on a removed line: that
line is not in the file, so it has no bytes to hand back and the caller
widens to the hunk instead."
  (when-let* ((l (sprig-review--line-at))
              (anchor (sprig-review--stage-anchor (list l))))
    (list (plist-get l :file) (car anchor) (cdr anchor))))

(defun sprig-review--stage-hunk-target (section)
  "Return (FILE TEXT LINE) for the whole hunk SECTION is in."
  (let* ((hunk (or (sprig-review--hunk-at section)
                   (user-error "Point is not on a hunk; open a file with \
TAB, or mark the hunk you mean with SPC")))
         (file (or (sprig-review--file-of section)
                   (plist-get (sprig-review--line-at-first section) :file)
                   (user-error "No file here to edit")))
         (anchor (or (sprig-review--stage-anchor (plist-get hunk :lines))
                     (user-error "This hunk is a pure deletion; there is \
nothing to edit"))))
    (list file (car anchor) (cdr anchor))))

(defun sprig-review--stage-target ()
  "Return (FILE TEXT LINE) naming what `e' hands you to edit.
The active region when there is one; else the one hunk you marked, since
marking a chunk is naming it; else the single line point is on, which is
the grain most hand-authored feedback wants.  Failing all three, the hunk
around point: on its `@@' heading, on a file heading, or on a removed
line, which has no bytes in the file to edit.  TEXT is always the new
side, what the file holds now."
  (if (use-region-p)
      (let* ((lines (sprig-review--lines-between
                     (region-beginning) (region-end)))
             (file (plist-get (car lines) :file))
             (lines (seq-filter (lambda (l) (equal (plist-get l :file) file))
                                lines))
             (anchor (and lines (sprig-review--stage-anchor lines))))
        (unless lines (user-error "That region covers no line of the diff"))
        (unless anchor
          (user-error "That region is all removals; there is nothing on disk \
to edit"))
        (list file (car anchor) (cdr anchor)))
    (let* ((marked (sprig-review--marked-hunk-sections))
           (section
            (cond ((cdr marked)
                   (user-error "%d sections are marked; `e' edits one, so \
mark just the one (`U' clears them)" (length marked)))
                  (marked (car marked))
                  (t (magit-current-section)))))
      ;; A mark names a chunk outright, so it outranks whatever line point
      ;; happens to be resting on.
      (or (and (null marked) (sprig-review--stage-line-target))
          (sprig-review--stage-hunk-target section)))))

(defun sprig-review--file-edit (review id file line anchor new)
  "File NEW as a draft edit of FILE on REVIEW, replacing ANCHOR at LINE.
ID re-files an existing draft, so re-editing one does not leave two; nil
takes a fresh id.  The draft records ANCHOR the way a comment records the
lines it was written against, and re-anchors with them, so an edit whose
lines the agent has since moved is floated as orphaned rather than
applied somewhere it no longer fits."
  (unless (buffer-live-p review) (user-error "The review buffer is gone"))
  (with-current-buffer review
    (let* ((lines (split-string anchor "\n"))
           (draft (list :id (or id (prog1 sprig-review--next-id
                                     (cl-incf sprig-review--next-id)))
                        :file file :side 'new
                        :start line :end (+ line (1- (length lines)))
                        :text nil :edit new :anchor lines :orphan nil)))
      (setq sprig-review--drafts
            (append (seq-remove (lambda (d) (eq (plist-get d :id)
                                                (plist-get draft :id)))
                                sprig-review--drafts)
                    (list draft)))
      (sprig-review--render-in-place)))
  (message "sprig: edit filed as a draft; `c p' publishes the review"))

(defun sprig-review--stage-guard ()
  "Signal a `user-error' unless this buffer can stage an edit."
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (unless (buffer-live-p sprig-review--session)
    (user-error "The session this review belongs to is gone")))

(defun sprig-review--open-stage (file anchor line &optional id seed)
  "Open the staging buffer on ANCHOR of FILE at LINE, filing back as draft ID.
SEED, when given, is put in the buffer instead of ANCHOR: re-editing a
draft starts from what you wrote last time, not from the file again."
  (let* ((review (current-buffer))
         (buf (sprig-session--open-stage-buffer
               sprig-review--session file anchor line
               (lambda (new)
                 (sprig-review--file-edit review id file line anchor new)))))
    (when seed
      (with-current-buffer buf
        (erase-buffer)
        (insert seed)
        (goto-char (point-min))))
    buf))

(defun sprig-review-stage ()
  "Hand-author the code you are looking at instead of describing it (`e').
Opens the staging buffer in the file's own major mode, so you edit with
the highlighting and the keys you write that language in, seeded with the
*new* side: the context and added lines exactly as they stand on disk, so
your edit replaces exactly that.  It takes the region when one is active,
else the hunk you marked with \\`SPC', else the one line point is on, and
failing those the hunk around point.

`C-c C-c' files what you wrote as a draft, next to your comments, and
`C-c C-k' throws it away.  Nothing reaches the agent until you publish:
an edit is a review comment you were too impatient to phrase, so it is
composed with the rest of the review rather than sent on its own."
  (interactive)
  (sprig-review--stage-guard)
  (pcase-let ((`(,file ,text ,line) (sprig-review--stage-target)))
    (when (use-region-p) (deactivate-mark))
    (sprig-review--open-stage file text line)))

(defun sprig-review-stage-hunk ()
  "Hand-author the whole hunk point is in (`e h').
The widest thing the diff itself can give you, and the one `e' used to
take by default; `e b' goes wider by reading wider."
  (interactive)
  (sprig-review--stage-guard)
  (pcase-let ((`(,file ,text ,line)
               (sprig-review--stage-hunk-target (magit-current-section))))
    (sprig-review--open-stage file text line)))

(defun sprig-review--report-block (text line edge)
  "Say how much TEXT was staged, from LINE, and whether EDGE cut it short.
How much you were handed is the check on a heuristic, so it is said out
loud rather than left for you to count."
  (let ((n (1+ (cl-count ?\n text))))
    (message "sprig: %d line%s from line %d%s"
             n (if (= n 1) "" "s") line
             (if edge
                 "; runs to the end of what was read, so there may be more"
               ""))))

(defun sprig-review-stage-block (&optional levels)
  "Hand-author the block of code around point (`e b').
The diff shows three lines of context, so the hunk you are reading is
usually part of a function rather than one.  This re-reads that one file
with `sprig-review-block-context' lines of context, the same `git diff'
over the same transport, and hands you the block point sits in, bounded
by indentation: the nearest line indented less than point, down to the
next line back at that indentation.

Indentation measures nesting, so in a language that nests deeply the
block is the innermost form around point rather than the whole function.
A numeric argument climbs that many levels instead of one, for when the
innermost form is not the unit you meant.  To ask for a whole function,
though, `e d' is the better verb: it reads the file's own major mode
rather than counting columns, so a docstring cannot mislead it.

It is a heuristic and says so.  You see the block in the staging buffer
before you touch it, which is the check; if it looks cut off at the top or
bottom, raise `sprig-review-block-context'."
  (interactive "p")
  (sprig-review--stage-guard)
  (pcase-let ((`(,file ,text ,line ,edge)
               (sprig-review--stage-block-target levels)))
    (sprig-review--open-stage file text line)
    (sprig-review--report-block text line edge)))

(defun sprig-review-stage-defun ()
  "Hand-author the whole function around point (`e d').
Like `e b', but the file's own major mode decides where the function
starts and ends, so a docstring or a comment at column zero does not
mislead it the way indentation alone does.  Falls back to `e b'\='s rule
when the mode has no notion of a defun."
  (interactive)
  (sprig-review--stage-guard)
  (pcase-let ((`(,file ,text ,line ,edge)
               (sprig-review--stage-block-target 1 t)))
    (sprig-review--open-stage file text line)
    (sprig-review--report-block text line edge)))

(transient-define-prefix sprig-review-stage-dispatch ()
  "Write a piece of the change yourself, instead of describing it.
Every route fills the same staging buffer, in the file's own major mode,
and `C-c C-c' there files what you wrote as a draft alongside your
comments.  They differ only in how much they hand you."
  [["Write it yourself"
    ("e" "what you are pointing at (region, mark, or line)"
     sprig-review-stage)
    ("h" "the whole hunk" sprig-review-stage-hunk)
    ("b" "the block around point (C-u N climbs N levels out)"
     sprig-review-stage-block)
    ("d" "the whole function around point (asks the file's mode)"
     sprig-review-stage-defun)]])

;;;; Visiting and refreshing

(defun sprig-review-visit ()
  "Visit the file at point, at the line under point where there is one (`RET')."
  (interactive)
  (let* ((line (sprig-review--line-at))
         (file (or (and line (plist-get line :file))
                   (sprig--section-file (magit-current-section))
                   (user-error "Nothing to visit here")))
         (path (expand-file-name file default-directory)))
    (find-file-other-window path)
    (when-let ((n (and line (plist-get line :new))))
      (goto-char (point-min))
      (forward-line (1- n)))))

(defun sprig-review-refresh (&rest _)
  "Re-run `git diff', re-anchor the drafts, and redraw (`g')."
  (interactive)
  (unless (derived-mode-p 'sprig-review-mode)
    (user-error "Not in a sprig review buffer"))
  (sprig-review--reload t)
  (let ((orphans (seq-count (lambda (d) (plist-get d :orphan))
                            sprig-review--drafts)))
    (message "sprig: review refreshed%s"
             (if (zerop orphans) ""
               (format "; %d comment%s no longer match their lines"
                       orphans (if (= orphans 1) "" "s"))))))

;;;; The mode

(defvar sprig-review-mode-map (make-sparse-keymap)
  "Keymap for `sprig-review-mode'.

Bound below rather than inside this form, so `sprig-reload' can reach it:
a `defvar' whose variable is already bound does nothing, which would
leave a buffer on the keys it started with.  The `define-key' calls below
mutate the very map those buffers use, so an edited binding takes effect
on the next reload without reopening anything.")

(set-keymap-parent sprig-review-mode-map magit-section-mode-map)
(define-key sprig-review-mode-map (kbd "SPC")     #'sprig-toggle-mark)
(define-key sprig-review-mode-map (kbd "m")       #'sprig-toggle-mark)
(define-key sprig-review-mode-map (kbd "U")       #'sprig-unmark-all)
(define-key sprig-review-mode-map (kbd "c")       #'sprig-review-dispatch)
(define-key sprig-review-mode-map (kbd "C-c C-c") #'sprig-review-publish)
(define-key sprig-review-mode-map (kbd "k")       #'sprig-review-comment-delete)
(define-key sprig-review-mode-map (kbd "e")       #'sprig-review-stage-dispatch)
(define-key sprig-review-mode-map (kbd "b")       #'sprig-review-set-base)
(define-key sprig-review-mode-map (kbd "Q")       #'sprig-quiz)
(define-key sprig-review-mode-map (kbd "g")       #'sprig-review-refresh)
(define-key sprig-review-mode-map (kbd "RET")     #'sprig-review-visit)
(define-key sprig-review-mode-map (kbd "q")       #'quit-window)

(define-derived-mode sprig-review-mode magit-section-mode "Sprig-Review"
  "Major mode for reviewing a changeset and annotating it line by line.

Files open folded, so the buffer starts as the list of what changed.
\\`TAB' opens the file at point, \\`S-TAB' cycles the whole buffer, and a
file you open stays open when the diff is re-read.

Move with \\`n' / \\`p', \\`g' re-reads the diff, and
\\`RET' visits the file at the line under point.  The verbs live on the
\\`c' transient:

  c c   comment on the line at point, or on the region
  c e   re-edit the draft at point, comment or edit (\\`k' takes it back)
  c p   publish every draft to the session, as one turn
  c Q   discard every draft
  c m   plain message about the marked hunks (\\`SPC' marks)

\\`b' changes what the review diffs against, carrying the drafts across.

\\`e' hand-authors the code instead of describing it, opened in the
file's own major mode and filed as a draft like a comment: \\`e e' takes
what point names, \\`e h' the hunk, and \\`e b' / \\`e d' the block or
function around point, which are read wider than the diff shows.  \\`C-c C-c' publishes, the way
it sends everywhere else in sprig.

Nothing here writes to the repository: publishing is an instruction to the
agent, like every other sprig verb."
  :group 'sprig
  (setq-local revert-buffer-function #'sprig-review-refresh)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (sprig--suppress-section-highlight))

(transient-define-prefix sprig-review-dispatch ()
  "Review the changes, then hand the whole review back in one turn."
  [["Comment"
    ("c" "on the line or region" sprig-review-comment)
    ("e" "re-edit the draft at point" sprig-review-comment-edit)
    ("k" "take back the draft at point" sprig-review-comment-delete)]
   ["Publish"
    ("p" "publish the review (comments and edits)" sprig-review-publish)
    ("Q" "discard every draft" sprig-review-discard-drafts)]
   ["Plain message"
    ("m" "about the marked hunks" sprig-review-message)
    ("M" "…queued for after this turn" sprig-review-message-queue)]])

(defun sprig-review--session-root ()
  "Return (REMOTE . ROOT) for the session buffer point is in.
Signals a `user-error' when there is no session, no working directory, or
no git repository around it."
  (unless (derived-mode-p 'sprig-session-mode)
    (user-error "Not in a sprig session buffer"))
  (let* ((remote (sprig--remote))
         (dir (or (sprig--directory)
                  (and (not remote) default-directory)
                  (user-error "This session has no working directory")))
         (root (or (sprig-review--toplevel remote dir)
                   (user-error "Not inside a git repository: %s" dir))))
    (cons remote root)))

;;;###autoload
(defun sprig-session-review (&optional base)
  "Open the changeset review for this session's working tree (`d d').
Every change in the tree against BASE (default `sprig-review-base') as one
navigable diff you annotate line by line and publish in a single turn.
BASE is held buffer-locally, so two reviews of the same session can sit at
different scopes and `g' keeps each where you put it.  Reads the diff
itself, which the invariant permits, over the session's own SSH transport
when the tree is remote.

A review you already have open is shown as you left it: the same folds,
the same place, the same drafts, and no re-read.  `d' is how you get back
to a review, and getting back to one should not cost you your position in
it; `g' is the key that means re-read.  Only a fresh buffer, or a `d' that
changes the scope, reads the tree."
  (interactive)
  (pcase-let* ((`(,remote . ,root) (sprig-review--session-root))
               (session (current-buffer))
               (buf (get-buffer-create
                     (format "*sprig-review: %s*" (buffer-name session))))
               (fresh (with-current-buffer buf
                        (not (derived-mode-p 'sprig-review-mode)))))
    (with-current-buffer buf
      (when fresh (sprig-review-mode))
      (setq sprig-review--session session
            sprig-review--remote remote
            sprig-review--root root
            ;; `default-directory' anchors a `RET' file visit: a TRAMP name
            ;; on the host for a remote session, the plain root locally.
            ;; The bulk diff read does not use it.
            default-directory (file-name-as-directory
                               (if remote (format "/ssh:%s:%s" remote root) root)))
      (let ((rescope (and base (not (equal base sprig-review-base)))))
        (when base (setq-local sprig-review-base base))
        (cond ((or fresh rescope) (sprig-review--reload))
              (t (message "sprig: the review you left, against %s; `g' \
re-reads the tree" sprig-review-base)))))
    (pop-to-buffer buf)))

(defun sprig-session-review-uncommitted ()
  "Review the uncommitted changes: the working tree against HEAD (`d d')."
  (interactive)
  (sprig-session-review "HEAD"))

(defun sprig-session-review-branch ()
  "Review the whole branch, against main or master (`d m').
Everything your branch has done to the default branch (`main', `master',\nor whatever `sprig-review-default-branches' names), commits and
uncommitted work together, from where the two diverged: the scope a pull
request would show.  What the base gained since you branched is excluded,
which a plain `git diff main' would show inverted as reversions you never
made."
  (interactive)
  (pcase-let ((`(,remote . ,root) (sprig-review--session-root)))
    (if-let ((branch (sprig-review--default-branch remote root)))
        (sprig-session-review branch)
      ;; Undetectable is not a dead end: ask, rather than send you off to
      ;; find another key.
      (message "sprig: no default branch found; name one")
      (sprig-session-review (sprig-review--read-base remote root
                                                     sprig-review-base)))))

(defun sprig-review--decorations (remote root)
  "Ref names decorating each first-parent commit from HEAD, newest first.
One line per commit, `%D\=' style, blanks kept so an undecorated commit is
not silently merged into its neighbour."
  (split-string
   (sprig-review--run-git remote root
                          '("log" "--first-parent" "--format=%D" "HEAD"))
   "\n"))

(defun sprig-review--parent-branch (remote root)
  "The branch this one was branched off at ROOT on REMOTE, or nil.

Git records no parent branch, so this reads the one thing that does say:
walk back along first-parent history and take the first commit carrying a
branch other than this one.  On a stack of branches, each sitting on the
last, that is the branch immediately below, which is what `d m\=' cannot
tell you (it goes all the way to main and shows you the whole stack).

It is inference, not a record.  A parent that has been merged and deleted
leaves its commits with no ref on them, so the walk carries on past it to
whatever is next, and a branch taken straight off main answers `main\=',
which is correct and makes `d p\=' the same view as `d m\='."
  (let* ((current (string-trim
                   (sprig-review--run-git
                    remote root '("rev-parse" "--abbrev-ref" "HEAD"))))
         (mine (concat "/" current)))
    (catch 'found
      (dolist (line (sprig-review--decorations remote root))
        (let ((cands
               (seq-remove
                (lambda (ref)
                  (or (string-prefix-p "tag: " ref)
                      (equal ref "HEAD")
                      (equal ref current)
                      ;; The remote-tracking side of this same branch.
                      (string-suffix-p mine ref)))
                (mapcar (lambda (ref)
                          ;; "HEAD -> foo" names the checked-out branch.
                          (replace-regexp-in-string "\\`HEAD -> " "" ref))
                        (split-string line ", " t "[ \t]+")))))
          (when cands
            ;; A commit usually carries both `foo\=' and `origin/foo\='; take the
            ;; local one, which is what you would type and what diffs without
            ;; a fetch (`sprig-review--default-branch\=' prefers it for the same
            ;; reason).  A remote-tracking ref alone is a perfectly good base.
            (throw 'found
                   (or (seq-find
                        (lambda (c)
                          (seq-some (lambda (o) (string-suffix-p
                                                 (concat "/" c) o))
                                    cands))
                        cands)
                       (car cands))))))
      nil)))

(defun sprig-review--read-base (remote root current)
  "Read a review base for the repo at ROOT on REMOTE, defaulting to CURRENT.
Offers the default branch first, since reviewing the whole branch is the
common reason to want anything but HEAD."
  (let* ((branch (sprig-review--default-branch remote root))
         (parent (ignore-errors (sprig-review--parent-branch remote root)))
         (cands (delete-dups
                 (delq nil (list branch parent "HEAD" current
                                 (and branch (format "%s...HEAD" branch)))))))
    (completing-read
     (format "Review against (currently %s): " current)
     cands nil nil nil nil current)))

(defun sprig-session-review-base (base)
  "Review against a BASE you name (`d b').
Anything with `..' goes to `git diff' verbatim; a plain branch name
reviews from where it and HEAD diverged (see `sprig-review--diff-args')."
  (interactive
   (pcase-let ((`(,remote . ,root) (sprig-review--session-root)))
     (list (sprig-review--read-base remote root sprig-review-base))))
  (sprig-session-review base))

(defun sprig-session-review-parent ()
  "Review against the branch this one was branched off (`d p').
The scope for a stacked branch: what *this* branch adds, rather than what
the whole stack beneath it does, which is what `d m' would show.  See
`sprig-review--parent-branch' for how the parent is found, and for why it
is inference rather than something git records."
  (interactive)
  (pcase-let ((`(,remote . ,root) (sprig-review--session-root)))
    (if-let ((parent (sprig-review--parent-branch remote root)))
        (progn (message "sprig: reviewing against %s" parent)
               (sprig-session-review parent))
      ;; Nothing below but main, or a parent that has been deleted: say so
      ;; rather than quietly reviewing a scope that is not the one asked for.
      (message "sprig: no branch below this one; `d m' reviews the branch")
      (sprig-session-review (sprig-review--read-base remote root
                                                     sprig-review-base)))))

(transient-define-prefix sprig-session-review-dispatch ()
  "Review the changes in this session's working tree."
  [["Review"
    ("d" "uncommitted changes (against HEAD)" sprig-session-review-uncommitted)
    ("m" "the whole branch (against main, master, …)" sprig-session-review-branch)
    ("p" "against the branch this one was branched off" sprig-session-review-parent)
    ("b" "against a base you name" sprig-session-review-base)]])

(defun sprig-review-set-base (base)
  "Change what this review diffs against, and re-read it (`b').
The drafts come across: they re-anchor by their recorded text the way `g'
re-anchors them, so widening the scope mid-review keeps the comments you
have already written."
  (interactive
   (progn
     (unless (derived-mode-p 'sprig-review-mode)
       (user-error "Not in a sprig review buffer"))
     (list (sprig-review--read-base sprig-review--remote sprig-review--root
                                    sprig-review-base))))
  (setq-local sprig-review-base base)
  (sprig-review--reload)
  (message "sprig: reviewing against %s" base))

(provide 'sprig-review)
;;; sprig-review.el ends here
