;;; sprig-quiz-tests.el --- ERT tests for the changeset quiz -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers the quiz: which files it aims at, the one structured contract
;; (numbered headings, parsed in both directions), the worksheet's
;; read-only/editable split, and the slot machinery that keeps the cold
;; read above the author's answer however the two forks race.  Runs
;; offline: every fork is stubbed and no process is started.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'sprig-change)
(require 'sprig-review)
(require 'sprig-quiz)

(defconst sprig-quiz-tests--diff
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

(defvar sprig-quiz-tests--asked nil
  "Every `sprig-quiz--ask' the body made, newest last.
Each is a plist (:name NAME :prompt PROMPT :callback FN).")

(defmacro sprig-quiz-tests--with-forks (&rest body)
  "Run BODY with every quiz fork stubbed.
Each call is recorded in `sprig-quiz-tests--asked' instead of spawning."
  (declare (indent 0))
  `(let ((sprig-quiz-tests--asked nil))
     (cl-letf (((symbol-function 'sprig-quiz--ask)
                (lambda (_command _dir _remote name prompt callback)
                  (setq sprig-quiz-tests--asked
                        (append sprig-quiz-tests--asked
                                (list (list :name name :prompt prompt
                                            :callback callback))))
                  nil)))
       ,@body)))

(defmacro sprig-quiz-tests--echoing (&rest body)
  "Run BODY and return the last line it passed to `message'.
`current-message' is nil under batch, so the function itself is captured."
  (declare (indent 0))
  `(let (said)
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args) (setq said (apply #'format fmt args)))))
       ,@body)
     said))

(defun sprig-quiz-tests--answer-all ()
  "Write a throwaway answer under every question, so a submit takes them all."
  (dolist (q sprig-quiz--questions)
    (goto-char (point-min))
    (re-search-forward (format "^## %d\\." (car q)))
    (forward-line 1)
    (insert (format "answer to %d" (car q)))))

(defun sprig-quiz-tests--fork (name)
  "The recorded fork called NAME, or nil."
  (seq-find (lambda (f) (equal (plist-get f :name) name))
            sprig-quiz-tests--asked))

(defmacro sprig-quiz-tests--worksheet (questions &rest body)
  "Run BODY in a worksheet buffer holding QUESTIONS, forks stubbed."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "*sprig-quiz-test*")))
     (unwind-protect
         (sprig-quiz-tests--with-forks
           (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
             (sprig-quiz--start buf ,questions "DIFF" "sid" "/tmp" nil))
           (with-current-buffer buf ,@body))
       (kill-buffer buf))))

;;;; The one structured contract

(ert-deftest sprig-quiz-test-split-reads-numbered-headings ()
  "Questions and answers travel as `## N.' headings, and nothing else."
  (should (equal (sprig-quiz--split "## 1. First?\n## 2. Second?")
                 '((1 . "First?") (2 . "Second?")))))

(ert-deftest sprig-quiz-test-split-is-loose-about-the-markup ()
  "A chatty preamble, another heading level, and other punctuation all parse.
The contract is deliberately loose: a strict parser would turn a model's
stylistic drift into a failed quiz."
  (let ((got (sprig-quiz--split
              "Here you go:\n\n### 1) First?\n\n#2: Second?\n more\n")))
    (should (equal (mapcar #'car got) '(1 2)))
    (should (equal (alist-get 1 got) "First?"))
    (should (equal (alist-get 2 got) "Second?\n more"))))

(ert-deftest sprig-quiz-test-split-survives-a-bare-heading-and-a-long-body ()
  "The shape a real reply actually has: a bare `## N.' with the answer
starting on the next line.  Regression for reading the heading number out of
the match data *after* `string-trim' had already overwritten it, which lost
every heading past the first and took the whole delivery down with it."
  (let ((got (sprig-quiz--split
              (concat "## 1.\n\nFirst answer, over\nseveral lines.\n\n"
                      "## 2.\n\nSecond answer.\n\n"
                      "## 3.\n\nThird answer."))))
    (should (equal (mapcar #'car got) '(1 2 3)))
    (should (equal (alist-get 1 got) "First answer, over\nseveral lines."))
    (should (equal (alist-get 3 got) "Third answer."))))

(ert-deftest sprig-quiz-test-split-of-nothing-is-nothing ()
  "No headings means no questions, which the caller reports rather than
opening an empty worksheet."
  (should-not (sprig-quiz--split "I would rather not."))
  (should-not (sprig-quiz--split nil)))

;;;; How many questions

(ert-deftest sprig-quiz-test-count-scales-with-the-change ()
  "Three questions is a thorough pass over a small change and a spot check
on a big one, so the ceiling grows with the changed lines."
  (let ((sprig-quiz-questions '(3 . 6))
        (sprig-quiz-lines-per-question 100))
    (cl-flet ((n (lines) (sprig-quiz--count
                          (list (list :file "f" :unified
                                      (list (list :lines
                                                  (make-list lines
                                                             '(:kind add)))))))))
      (should (= 3 (n 1)))
      (should (= 3 (n 250)))
      (should (= 4 (n 350)))
      (should (= 6 (n 600)))
      ;; And it never runs past the ceiling, however big the change.
      (should (= 6 (n 50000))))))

(ert-deftest sprig-quiz-test-context-lines-are-not-the-change ()
  "Context is what the change is written against, not the change, so it
does not earn questions.  A one-line edit in a large hunk is a one-line
edit."
  (let ((changes (sprig-parse-diff sprig-quiz-tests--diff)))
    ;; The fixture changes three lines: -bar +baz, and +hello.
    (should (= 3 (sprig-quiz--changed-lines changes)))))

(ert-deftest sprig-quiz-test-diff-text-carries-the-change ()
  "The prompt gets the files and both sides of every hunk."
  (let ((text (sprig-quiz--diff-text (sprig-parse-diff sprig-quiz-tests--diff))))
    (should (string-match-p "--- foo.el$" text))
    (should (string-match-p "--- new.txt$" text))
    (should (string-match-p "^-  (bar))$" text))
    (should (string-match-p "^\\+  (baz))$" text))
    ;; Nothing tells the generator what the reader did or did not open: that
    ;; weighting was Goodhart, and the reader could game it by unfolding.
    (should-not (string-match-p "OPENING\\|unread\\|never opened" text))))

(ert-deftest sprig-quiz-test-diff-text-says-what-it-dropped ()
  "A capped diff reports the omission rather than reading as the whole change."
  (let* ((changes (sprig-parse-diff sprig-quiz-tests--diff))
         (sprig-quiz-max-diff-lines 3)
         (text (sprig-quiz--diff-text changes)))
    (should (string-match-p "further diff lines omitted" text))))

;;;; The generation prompt

(ert-deftest sprig-quiz-test-generate-prompt-rules-out-trivia ()
  "The prompt spends itself ruling out lookup questions, which is the
default a model reaches for and the failure that discredits the practice."
  (let ((p (sprig-quiz--generate-prompt "DIFF" 4)))
    (should (string-match-p "ENTAILED by the code, not CONTAINED" p))
    (should (string-match-p "What does function F return" p))
    (should (string-match-p "DIFF" p))))

(ert-deftest sprig-quiz-test-the-count-is-a-ceiling-not-a-quota ()
  "Told to ask N, a model pads to N.  A thousand-line rename holds one
idea, so the prompt has to say outright that fewer is a right answer."
  (let ((p (sprig-quiz--generate-prompt "DIFF" 6)))
    (should (string-match-p "AT MOST 6 questions" p))
    (should (string-match-p "ceiling, not a quota" p))
    (should (string-match-p "may honestly deserve one question" p))
    (should (string-match-p "most consequential" p))))

;;;; The worksheet

(ert-deftest sprig-quiz-test-worksheet-questions-are-read-only ()
  "You cannot edit the question, and you can type under it.  The split is
the staging buffer's own: read-only headers, editable bodies."
  (sprig-quiz-tests--worksheet '((1 . "What breaks if it were a Dict?"))
    (goto-char (point-min))
    (search-forward "What breaks")
    (should (get-text-property (match-beginning 0) 'read-only))
    (should-error (save-excursion (goto-char (match-beginning 0))
                                  (insert "x"))
                  :type 'text-read-only)
    ;; The gap under it takes text.
    (goto-char (point-max))
    (insert "Ordering is lost.")
    (should (string-match-p "Ordering is lost" (buffer-string)))))

(ert-deftest sprig-quiz-test-worksheet-sends-nothing-until-you-hand-it-in ()
  "Opening the worksheet fires the generator and nothing else: the other
two answers are the reward for having answered first."
  (sprig-quiz-tests--worksheet '((1 . "Why?"))
    (should-not (sprig-quiz-tests--fork "sprig-quiz-cold"))
    (should-not (sprig-quiz-tests--fork "sprig-quiz-author"))))

;;;; Handing it in

(ert-deftest sprig-quiz-test-submit-asks-both-and-shows-neither-your-answer ()
  "Submitting fires a cold reader and the author at once, and neither is
shown what you wrote: they answer independently or it is not a comparison."
  (sprig-quiz-tests--worksheet '((1 . "Why not a Dict?"))
    (goto-char (point-max))
    (insert "Because ordering is load-bearing.")
    (sprig-quiz-submit)
    (let ((cold (sprig-quiz-tests--fork "sprig-quiz-cold"))
          (author (sprig-quiz-tests--fork "sprig-quiz-author")))
      (should cold)
      (should author)
      (should (string-match-p "Why not a Dict?" (plist-get cold :prompt)))
      (should (string-match-p "reading the code cold"
                              (plist-get cold :prompt)))
      (should-not (string-match-p "load-bearing" (plist-get cold :prompt)))
      (should-not (string-match-p "load-bearing" (plist-get author :prompt))))))

(ert-deftest sprig-quiz-test-a-question-is-handed-in-once ()
  "The same question cannot be handed in twice, which would fire a second
pair of forks into slots already filled."
  (sprig-quiz-tests--worksheet '((1 . "Why?"))
    (goto-char (point-max)) (insert "An answer.")
    (sprig-quiz-submit)
    (should-error (sprig-quiz-submit) :type 'user-error)))

(ert-deftest sprig-quiz-test-blanks-are-not-spent ()
  "A question is spent the moment its answers appear, so handing in what
you wrote must not spend what you did not: a long worksheet is answered in
the sittings you have."
  (sprig-quiz-tests--worksheet '((1 . "First?") (2 . "Second?"))
    ;; Answer only the first.
    (goto-char (point-min))
    (search-forward "## 1. First?")
    (forward-line 1)
    (insert "Only this one.")
    (sprig-quiz-submit)
    (should (equal '(1) sprig-quiz--submitted))
    (let ((asked (plist-get (sprig-quiz-tests--fork "sprig-quiz-cold")
                            :prompt)))
      (should (string-match-p "First?" asked))
      (should-not (string-match-p "Second?" asked)))
    ;; The second question has no slot waiting, so nothing can land in it.
    (should (= 1 (length (seq-filter
                          (lambda (s) (eq (plist-get s :source) 'cold))
                          sprig-quiz--slots))))
    (should-not (string-match-p "Second\\?\n+ +cold read" (buffer-string)))))

(ert-deftest sprig-quiz-test-the-blanks-can-be-handed-in-later ()
  "Running it again takes the questions answered since, and only those."
  (sprig-quiz-tests--worksheet '((1 . "First?") (2 . "Second?"))
    (goto-char (point-min)) (search-forward "## 1. First?") (forward-line 1)
    (insert "One.")
    (sprig-quiz-submit)
    (goto-char (point-min)) (search-forward "## 2. Second?") (forward-line 1)
    (insert "Two.")
    (sprig-quiz-submit)
    (should (equal '(1 2) sprig-quiz--submitted))
    ;; The second batch asked about the second question alone.
    (let ((second (car (last (seq-filter
                              (lambda (f) (equal (plist-get f :name)
                                                 "sprig-quiz-cold"))
                              sprig-quiz-tests--asked)))))
      (should (string-match-p "Second?" (plist-get second :prompt)))
      (should-not (string-match-p "First?" (plist-get second :prompt))))))

(ert-deftest sprig-quiz-test-an-unanswered-worksheet-is-not-handed-in ()
  "Submitting with nothing written would spend every question at once."
  (sprig-quiz-tests--worksheet '((1 . "Why?"))
    (should-error (sprig-quiz-submit) :type 'user-error)
    (should-not sprig-quiz-tests--asked)))

(ert-deftest sprig-quiz-test-a-handed-in-answer-freezes ()
  "What you handed in is the record, so it cannot be edited afterwards,
while a blank question stays open to write in."
  (sprig-quiz-tests--worksheet '((1 . "First?") (2 . "Second?"))
    (goto-char (point-min)) (search-forward "## 1. First?") (forward-line 1)
    (insert "One.")
    (sprig-quiz-submit)
    (goto-char (point-min))
    (should (search-forward "One." nil t))
    ;; Inside the frozen text: neither editable nor deletable.  (Its very
    ;; first character is not a wall, which is how a `read-only' text
    ;; property behaves everywhere in Emacs and is not worth fighting.)
    (should-error (save-excursion (goto-char (1+ (match-beginning 0)))
                                  (insert "x"))
                  :type 'text-read-only)
    (should-error (save-excursion (delete-region (match-beginning 0)
                                                 (match-end 0)))
                  :type 'text-read-only)
    ;; The blank one still takes text.
    (goto-char (point-min)) (search-forward "## 2. Second?") (forward-line 1)
    (insert "Two.")
    (should (string-match-p "Two\\." (buffer-string)))))

(ert-deftest sprig-quiz-test-cold-read-sits-above-the-author ()
  "Whichever fork lands first, the cold read is above the author's answer:
the peer is the comparison, the author only the adjudicator."
  (sprig-quiz-tests--worksheet '((1 . "Why?") (2 . "And?"))
    (sprig-quiz-tests--answer-all)
    (sprig-quiz-submit)
    ;; The author answers first, to prove the order is not arrival order.
    (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-author") :callback)
             "## 1. Intent one.\n## 2. Intent two.")
    (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-cold") :callback)
             "## 1. Cold one.\n## 2. Cold two.")
    (let ((s (buffer-string)))
      (should (< (string-match "cold read" s)
                 (string-match "what the author says" s)))
      (should (string-match-p "Cold one" s))
      (should (string-match-p "Intent one" s)))))

(ert-deftest sprig-quiz-test-each-answer-lands-under-its-own-question ()
  "The heading number is what routes an answer, not its position."
  (sprig-quiz-tests--worksheet '((1 . "First?") (2 . "Second?"))
    (sprig-quiz-tests--answer-all)
    (sprig-quiz-submit)
    (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-cold") :callback)
             "## 2. Answer to the second.\n## 1. Answer to the first.")
    (let ((s (buffer-string)))
      (should (< (string-match "Answer to the first" s)
                 (string-match "Answer to the second" s))))))

(ert-deftest sprig-quiz-test-an-echoed-question-is-dropped ()
  "Asked for a numbered heading, a model restates the question under it.
Left in, every answer is half quotation, under a heading that already says
it."
  (should (equal "Because ordering is load-bearing."
                 (sprig-quiz--strip-echo
                  "Why not a Dict?\n\nBecause ordering is load-bearing."
                  "Why not a Dict?")))
  ;; An answer that merely opens on similar words is left alone.
  (should (equal "Why not a Dict? Good question."
                 (sprig-quiz--strip-echo "Why not a Dict? Good question."
                                         "Why not a Dict?")))
  (should (equal "Plain." (sprig-quiz--strip-echo "Plain." "Why?")))
  (should (equal "" (sprig-quiz--strip-echo nil "Why?"))))

(ert-deftest sprig-quiz-test-a-slot-starts-on-its-own-line ()
  "The last question's body ends wherever you stopped typing, so the slot
label must not weld itself to the end of your own answer."
  (sprig-quiz-tests--worksheet '((1 . "Why?"))
    (goto-char (point-max))
    (insert "I have no idea, honestly.")
    (sprig-quiz-submit)
    (should (string-match-p "I have no idea, honestly\\.\n" (buffer-string)))
    (should-not (string-match-p "honestly\\. *cold read" (buffer-string)))))

(ert-deftest sprig-quiz-test-the-author-is-folded-until-you-ask ()
  "The author's answer is inserted hidden: it is the adjudicator you reach
for once you and the cold reader differ, not a verdict handed down."
  (sprig-quiz-tests--worksheet '((1 . "Why?"))
    (sprig-quiz-tests--answer-all)
    (sprig-quiz-submit)
    (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-author") :callback)
             "## 1. Because of the ordering.")
    (goto-char (point-min))
    (should (search-forward "▸ what the author says" nil t))
    (goto-char (line-beginning-position))
    (let ((ov (sprig-quiz--fold-at-point)))
      (should (overlayp ov))
      (should (overlay-get ov 'invisible))
      ;; TAB opens it and turns the arrow, and again shuts it.
      (sprig-quiz-toggle)
      (should-not (overlay-get ov 'invisible))
      (should (string-match-p "▾ what the author says" (buffer-string)))
      (sprig-quiz-toggle)
      (should (overlay-get ov 'invisible))
      (should (string-match-p "▸ what the author says" (buffer-string))))))

(ert-deftest sprig-quiz-test-toggling-does-not-drag-the-slots ()
  "Flipping the arrow must leave the slot markers on their own text, or a
second answer lands in the middle of the first."
  (sprig-quiz-tests--worksheet '((1 . "Why?"))
    (sprig-quiz-tests--answer-all)
    (sprig-quiz-submit)
    (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-author") :callback)
             "## 1. Intent.")
    (goto-char (point-min))
    (search-forward "▸ what the author says")
    (goto-char (line-beginning-position))
    (sprig-quiz-toggle)
    (sprig-quiz-toggle)
    ;; The cold read lands afterwards and still finds its own slot.
    (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-cold") :callback)
             "## 1. Cold.")
    (let ((s (buffer-string)))
      (should (string-match-p "    Cold\\." s))
      (should (string-match-p "    Intent\\." s))
      (should (< (string-match "Cold\\." s) (string-match "Intent\\." s))))))

(ert-deftest sprig-quiz-test-a-failed-fork-says-so-in-place ()
  "A fork that dies marks its own slots rather than leaving an ellipsis
that never resolves."
  (sprig-quiz-tests--worksheet '((1 . "Why?"))
    (sprig-quiz-tests--answer-all)
    (sprig-quiz-submit)
    (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-cold") :callback)
             nil)
    (should (string-match-p "this one failed" (buffer-string)))))

(ert-deftest sprig-quiz-test-a-sessionless-review-still-quizzes ()
  "With no session there is no author to adjudicate, and the cold reader
carries the whole comparison rather than the quiz refusing to open."
  (let ((buf (generate-new-buffer "*sprig-quiz-test*")))
    (unwind-protect
        (sprig-quiz-tests--with-forks
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (sprig-quiz--start buf '((1 . "Why?")) "DIFF" nil "/tmp" nil))
          (with-current-buffer buf
            (sprig-quiz-tests--answer-all)
            (sprig-quiz-submit)
            (should (sprig-quiz-tests--fork "sprig-quiz-cold"))
            (should-not (sprig-quiz-tests--fork "sprig-quiz-author"))
            (should-not (string-match-p "the author says" (buffer-string)))))
      (kill-buffer buf))))

;;;; Findings

(defmacro sprig-quiz-tests--answered (&rest body)
  "A worksheet on two questions, both answered and both come back."
  (declare (indent 0))
  `(sprig-quiz-tests--worksheet '((1 . "Why not a Dict?") (2 . "And then?"))
     (sprig-quiz-tests--answer-all)
     (sprig-quiz-submit)
     (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-cold") :callback)
              "## 1.\nOrdering is load-bearing.\n## 2.\nIt is rebuilt.")
     (funcall (plist-get (sprig-quiz-tests--fork "sprig-quiz-author") :callback)
              "## 1.\nBecause of the tie-break.\n## 2.\nRebuilt lazily.")
     ,@body))

(ert-deftest sprig-quiz-test-flagging-opens-a-note ()
  "Flagging is the start of writing what the exchange showed, so it puts
you in the note rather than leaving you to find it."
  (sprig-quiz-tests--answered
    (goto-char (point-min))
    (search-forward "## 1.")
    (sprig-quiz-flag)
    (should (= 1 (length sprig-quiz--findings)))
    (should (string-match-p "⚑ what this shows" (buffer-string)))
    (insert "The ordering invariant is written down nowhere.")
    (should (equal "The ordering invariant is written down nowhere."
                   (sprig-quiz--note (sprig-quiz--finding 1))))))

(ert-deftest sprig-quiz-test-flagging-again-takes-it-back ()
  "A finding you thought better of leaves nothing behind."
  (sprig-quiz-tests--answered
    (goto-char (point-min))
    (search-forward "## 1.")
    (sprig-quiz-flag)
    (sprig-quiz-flag)
    (should-not sprig-quiz--findings)
    (should-not (string-match-p "what this shows" (buffer-string)))))

(ert-deftest sprig-quiz-test-a-finding-carries-the-whole-exchange ()
  "The note alone cannot say what the gap was, so the question, your answer
and the cold read all go.  The author's own answer does not: the session
being sent to already has it."
  (sprig-quiz-tests--answered
    (goto-char (point-min))
    (search-forward "## 1.")
    (sprig-quiz-flag)
    (insert "Nowhere does the code say this.")
    (let ((text (sprig-quiz--findings-text sprig-quiz--findings)))
      (should (string-match-p "Why not a Dict?" text))
      (should (string-match-p "answer to 1" text))
      (should (string-match-p "Ordering is load-bearing" text))
      (should (string-match-p "Nowhere does the code say this" text))
      (should-not (string-match-p "Because of the tie-break" text)))))

(ert-deftest sprig-quiz-test-only-flagged-questions-are-published ()
  "The quiz is mostly about you; only the part that is about the code is
the agent's business."
  (sprig-quiz-tests--answered
    (goto-char (point-min))
    (search-forward "## 2.")
    (sprig-quiz-flag)
    (insert "This one is the code's fault.")
    (let ((text (sprig-quiz--findings-text sprig-quiz--findings)))
      (should (string-match-p "And then?" text))
      (should-not (string-match-p "Why not a Dict?" text)))))

(ert-deftest sprig-quiz-test-publish-asks-for-fixes-not-explanations ()
  "The failure mode is an agent that explains a gap the code should have
closed, so the covering instruction names the two cases and asks which."
  (let ((framed (sprig-quiz--publish-format "My note." "THE FINDINGS")))
    (should (string-match-p "comprehension quiz" framed))
    (should (string-match-p "Where the gap is mine" framed))
    (should (string-match-p "Fix those rather than explaining them" framed))
    (should (string-match-p "My note\\." framed))
    (should (string-match-p "THE FINDINGS" framed))))

(ert-deftest sprig-quiz-test-publish-refuses-with-nothing-flagged ()
  "Publishing an empty set would send the agent a covering note about
nothing."
  (sprig-quiz-tests--answered
    (should-error (sprig-quiz-publish) :type 'user-error)))

;;;; Entry

(ert-deftest sprig-quiz-test-nothing-to-compare-against-says-so ()
  "With the cold reader off and no session there is no answer coming, and
the line says that rather than naming someone who is not answering.  The
retrieval still happened, which was most of the value."
  (let ((buf (generate-new-buffer "*sprig-quiz-test*"))
        (sprig-quiz-cold-read nil))
    (unwind-protect
        (sprig-quiz-tests--with-forks
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (sprig-quiz--start buf '((1 . "Why?")) "DIFF" nil "/tmp" nil))
          (with-current-buffer buf
            (sprig-quiz-tests--answer-all)
            (should (equal "sprig: handed in 1; nothing to compare against"
                           (sprig-quiz-tests--echoing (sprig-quiz-submit))))
            (should-not sprig-quiz-tests--asked)))
      (kill-buffer buf))))

(ert-deftest sprig-quiz-test-refuses-outside-a-review ()
  "`Q' is a verb of the review buffer, and says so rather than guessing."
  (with-temp-buffer
    (should-error (sprig-quiz) :type 'user-error)))

(ert-deftest sprig-quiz-test-refuses-an-empty-changeset ()
  "Nothing changed is nothing to be quizzed on."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig-review--changes nil)
    (should-error (sprig-quiz) :type 'user-error)))

(ert-deftest sprig-quiz-test-entry-scales-the-ask-to-the-diff ()
  "`Q' sizes the ask from the change in front of it, and asks about the
change rather than about the reader."
  (with-temp-buffer
    (sprig-review-mode)
    (setq sprig-review--changes (sprig-parse-diff sprig-quiz-tests--diff))
    (setq sprig-review--expanded '("foo.el"))
    (let ((sprig-quiz-questions '(2 . 5))
          (sprig-quiz-lines-per-question 1))
      (sprig-quiz-tests--with-forks
        (sprig-quiz)
        (let ((p (plist-get (sprig-quiz-tests--fork "sprig-quiz-set") :prompt)))
          (should p)
          ;; Three changed lines, one question each, floor 2 and ceiling 5.
          (should (string-match-p "AT MOST 3 questions" p))
          ;; Which files were unfolded is none of the generator's business.
          (should-not (string-match-p "foo.el is\\|never opened\\|OPENING" p)))))))

(provide 'sprig-quiz-tests)
;;; sprig-quiz-tests.el ends here
