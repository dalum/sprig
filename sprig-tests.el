;;; sprig-tests.el --- ERT tests for sprig  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the process-free layers of sprig: frontmatter, turn
;; parsing, the claude CLI transport (raw stream-json lines -> events),
;; the sink (events -> buffer), decoration parity, and the string and
;; command-construction helpers.  Nothing here starts a real session, so
;; the whole suite runs offline.
;;
;; Run with:
;;
;;   emacs -Q --batch -L . -l sprig.el -l sprig-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'sprig)

;;;; Helpers

(defmacro sprig-tests--with-buffer (content &rest body)
  "Run BODY in a temp buffer holding CONTENT with `sprig-mode' on.
Point starts at `point-min'."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (insert ,content)
     (sprig-mode 1)
     (goto-char (point-min))
     ,@body))

(defun sprig-tests--feed (&rest lines)
  "Parse and dispatch each raw stream-json LINE in the current buffer."
  (dolist (line lines)
    (dolist (event (sprig--claude-parse-line line))
      (sprig--dispatch event))))

;; Small constructors for the CLI's stream-json line shapes.

(defun sprig-tests--init (id)
  (json-serialize (list :type "system" :subtype "init" :session_id id)))

(defun sprig-tests--text (s)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_delta" :index 0
                      :delta (list :type "text_delta" :text s)))))

(defun sprig-tests--text-block-start ()
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_start" :index 2
                      :content_block (list :type "text")))))

(defun sprig-tests--tool-start (index id name)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_start" :index index
                      :content_block (list :type "tool_use" :id id :name name)))))

(defun sprig-tests--tool-delta (index fragment)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_delta" :index index
                      :delta (list :type "input_json_delta"
                                   :partial_json fragment)))))

(defun sprig-tests--tool-stop (index)
  (json-serialize
   (list :type "stream_event"
         :event (list :type "content_block_stop" :index index))))

(defun sprig-tests--result-msg (id text &optional error)
  (json-serialize
   (list :type "user"
         :message (list :content
                        (vector (list :type "tool_result" :tool_use_id id
                                      :content text
                                      :is_error (if error t :false)))))))

(defun sprig-tests--done (&optional cost error)
  (json-serialize (list :type "result"
                        :total_cost_usd (or cost 0.0)
                        :is_error (if error t :false))))

(defun sprig-tests--chrome ()
  "Snapshot the buffer's chrome overlays as sorted (START END LABELED)."
  (sort (delq nil
              (mapcar (lambda (o)
                        (when (overlay-get o 'sprig-chrome)
                          (list (overlay-start o) (overlay-end o)
                                (and (overlay-get o 'before-string) t))))
                      (overlays-in (point-min) (point-max))))
        (lambda (a b) (or (< (car a) (car b))
                          (and (= (car a) (car b)) (< (nth 1 a) (nth 1 b)))))))

(defun sprig-tests--decoration-parity-p ()
  "Non-nil if the current chrome equals a full rebuild's chrome."
  (let ((incremental (sprig-tests--chrome)))
    (remove-overlays (point-min) (point-max) 'sprig-chrome t)
    (sprig--decorate)
    (equal incremental (sprig-tests--chrome))))

;;;; Frontmatter

(ert-deftest sprig-test-frontmatter-get ()
  (sprig-tests--with-buffer "---\ntitle: Hi there\nclaude_session: abc\n---\n\nbody\n"
    (should (equal (sprig--frontmatter-get "title") "Hi there"))
    (should (equal (sprig--frontmatter-get "claude_session") "abc"))
    (should-not (sprig--frontmatter-get "missing"))))

(ert-deftest sprig-test-frontmatter-get-none ()
  (sprig-tests--with-buffer "no frontmatter here\n"
    (should-not (sprig--frontmatter-get "title"))
    (should-not (sprig--frontmatter-end))))

(ert-deftest sprig-test-frontmatter-set-updates-in-place ()
  (sprig-tests--with-buffer "---\ntitle: Old\n---\n\nbody\n"
    (sprig--frontmatter-set "title" "New")
    (should (equal (sprig--frontmatter-get "title") "New"))
    ;; No duplicate key added.
    (should (= 1 (how-many "^title:" (point-min) (point-max))))))

(ert-deftest sprig-test-frontmatter-set-creates-block ()
  (sprig-tests--with-buffer "just body\n"
    (sprig--frontmatter-set "claude_session" "xyz")
    (should (sprig--frontmatter-end))
    (should (equal (sprig--frontmatter-get "claude_session") "xyz"))
    (should (string-prefix-p "---\n" (buffer-string)))))

(ert-deftest sprig-test-frontmatter-remove ()
  (sprig-tests--with-buffer "---\ntitle: T\nclaude_session: s\n---\n\nbody\n"
    (sprig--frontmatter-remove "claude_session")
    (should-not (sprig--frontmatter-get "claude_session"))
    (should (equal (sprig--frontmatter-get "title") "T"))))

(ert-deftest sprig-test-body-start ()
  (sprig-tests--with-buffer "---\ntitle: T\n---\n\nhello\n"
    (should (equal (buffer-substring-no-properties
                    (sprig--body-start) (point-max))
                   "\nhello\n")))
  (sprig-tests--with-buffer "no frontmatter\n"
    (should (= (sprig--body-start) (point-min)))))

;;;; Turn parsing

(ert-deftest sprig-test-turns-basic ()
  (sprig-tests--with-buffer
      (concat "---\nclaude_session: s\n---\n\n"
              "first question\n\n"
              "<!-- sprig:reply id=r1 -->\n\nan answer\n\n<!-- sprig:end id=r1 -->\n\n"
              "second question\n")
    (should (equal (sprig--turns)
                   '((user . "first question")
                     (assistant . "an answer")
                     (user . "second question"))))))

(ert-deftest sprig-test-turns-skips-blank-user ()
  (sprig-tests--with-buffer
      (concat "---\n---\n\n"
              "<!-- sprig:reply id=r1 -->\n\nonly a reply\n\n<!-- sprig:end id=r1 -->\n")
    (should (equal (sprig--turns) '((assistant . "only a reply"))))))

(ert-deftest sprig-test-turns-strips-tool-blocks ()
  (sprig-tests--with-buffer
      (concat "---\n---\n\nq\n\n<!-- sprig:reply id=r1 -->\n\n"
              "before\n\n"
              "<!-- sprig:tool id=t1 name=Bash -->\n```bash\nls\n```\n<!-- sprig:tool-end id=t1 -->\n\n"
              "<!-- sprig:result id=t1 -->\n```\nout\n```\n<!-- sprig:result-end id=t1 -->\n\n"
              "after\n\n<!-- sprig:end id=r1 -->\n")
    (should (equal (cdr (assq 'assistant (sprig--turns)))
                   "before\n\nafter"))))

(ert-deftest sprig-test-turns-unterminated-reply ()
  (sprig-tests--with-buffer
      (concat "---\n---\n\nq\n\n<!-- sprig:reply id=r1 -->\n\nstill streaming")
    (should (equal (sprig--turns)
                   '((user . "q") (assistant . "still streaming"))))))

(ert-deftest sprig-test-pending-user-text ()
  (sprig-tests--with-buffer
      (concat "---\n---\n\n<!-- sprig:reply id=r1 -->\n\na\n\n<!-- sprig:end id=r1 -->\n\n"
              "pending message\n")
    (should (equal (sprig--pending-user-text) "pending message")))
  (sprig-tests--with-buffer
      "---\n---\n\n<!-- sprig:reply id=r1 -->\n\na\n\n<!-- sprig:end id=r1 -->\n"
    (should-not (sprig--pending-user-text))))

;;;; Transport: claude stream-json -> events

(ert-deftest sprig-test-parse-session ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--init "sess-1"))
                   '((session "sess-1"))))))

(ert-deftest sprig-test-parse-text ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--text "hi"))
                   '((text "hi"))))))

(ert-deftest sprig-test-parse-text-block-start ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--text-block-start))
                   '((text-block))))))

(ert-deftest sprig-test-parse-done ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--done 0.5 nil))
                   '((done 0.5 nil))))
    (should (equal (sprig--claude-parse-line (sprig-tests--done 0.5 t))
                   '((done 0.5 t))))))

(ert-deftest sprig-test-parse-error ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line
                    (json-serialize (list :type "system" :subtype "error"
                                          :message "boom")))
                   '((error "boom"))))))

(ert-deftest sprig-test-parse-junk-and-unknown ()
  (with-temp-buffer
    (should-not (sprig--claude-parse-line "not json at all"))
    (should-not (sprig--claude-parse-line
                 (json-serialize (list :type "system" :subtype "whatever"))))))

(ert-deftest sprig-test-parse-tool-call-reassembly ()
  ;; Fragmented input JSON is reassembled across three parse calls.
  (with-temp-buffer
    (should-not (sprig--claude-parse-line (sprig-tests--tool-start 1 "tu1" "Bash")))
    (should-not (sprig--claude-parse-line (sprig-tests--tool-delta 1 "{\"command\":")))
    (should-not (sprig--claude-parse-line (sprig-tests--tool-delta 1 "\"ls -l\"}")))
    (should (equal (sprig--claude-parse-line (sprig-tests--tool-stop 1))
                   '((tool-call "tu1" "Bash" "{\"command\":\"ls -l\"}"))))))

(ert-deftest sprig-test-parse-tool-results ()
  (with-temp-buffer
    (should (equal (sprig--claude-parse-line (sprig-tests--result-msg "tu1" "output"))
                   '((tool-result "tu1" nil "output"))))
    (should (equal (sprig--claude-parse-line (sprig-tests--result-msg "tu2" "bad" t))
                   '((tool-result "tu2" t "bad"))))))

(ert-deftest sprig-test-parse-string-message-does-not-crash ()
  ;; Regression: `let-alist' used to bind `.message.content' eagerly, so a
  ;; user/system message whose `message' is a bare string crashed.
  (with-temp-buffer
    (should-not (sprig--claude-parse-line
                 (json-serialize (list :type "user" :message "hi"))))))

;;;; Sink and full-turn integration

(ert-deftest sprig-test-full-turn-render ()
  (let ((sprig-render-tools 'full) (sprig-auto-title nil))
    (sprig-tests--with-buffer "---\n---\n\nlist files\n"
      (setq sprig--busy t)
      (sprig--start-reply)
      (sprig-tests--feed
       (sprig-tests--init "sess-xyz")
       (sprig-tests--text "Sure.")
       (sprig-tests--tool-start 1 "tu9" "Bash")
       (sprig-tests--tool-delta 1 "{\"command\":\"ls\"}")
       (sprig-tests--tool-stop 1)
       (sprig-tests--result-msg "tu9" "a.txt")
       (sprig-tests--text-block-start)
       (sprig-tests--text "Done.")
       (sprig-tests--done 0.01 nil))
      (should (equal sprig--session-id "sess-xyz"))
      (should (equal (sprig--frontmatter-get "claude_session") "sess-xyz"))
      (should-not sprig--busy)
      (should (string-match-p "sprig:tool id=tu9 name=Bash" (buffer-string)))
      (should (string-match-p "sprig:result id=tu9" (buffer-string)))
      (should (equal (cdr (assq 'assistant (sprig--turns))) "Sure.\n\nDone."))
      (should (sprig-tests--decoration-parity-p)))))

(ert-deftest sprig-test-tool-display-levels ()
  (dolist (case '((none . nil) (calls . tool) (full . both)))
    (let ((sprig-render-tools (car case)) (sprig-auto-title nil))
      (sprig-tests--with-buffer "---\n---\n\nq\n"
        (setq sprig--busy t)
        (sprig--start-reply)
        (sprig-tests--feed
         (sprig-tests--tool-start 1 "t1" "Bash")
         (sprig-tests--tool-delta 1 "{\"command\":\"ls\"}")
         (sprig-tests--tool-stop 1)
         (sprig-tests--result-msg "t1" "out")
         (sprig-tests--done 0.0 nil))
        (let ((has-tool (string-match-p "sprig:tool " (buffer-string)))
              (has-result (string-match-p "sprig:result" (buffer-string))))
          (pcase (cdr case)
            ('nil  (should-not has-tool) (should-not has-result))
            ('tool (should has-tool)     (should-not has-result))
            ('both (should has-tool)     (should has-result))))))))

(ert-deftest sprig-test-interrupt-marks-partial ()
  (let ((sprig-auto-title nil))
    (sprig-tests--with-buffer "---\n---\n\nq\n"
      (setq sprig--busy t)
      (sprig--start-reply)
      (sprig-tests--feed (sprig-tests--text "half an ans"))
      (sprig--close-reply t)
      (should (sprig--last-reply-interrupted-p))
      (should (string-match-p "interrupted" (buffer-string)))
      (should (sprig-tests--decoration-parity-p)))))

;;;; Decoration parity across shapes

(ert-deftest sprig-test-decoration-parity-multi-tool ()
  (let ((sprig-render-tools 'full) (sprig-auto-title nil))
    (sprig-tests--with-buffer "---\n---\n\nq\n"
      (setq sprig--busy t)
      (sprig--start-reply)
      (dotimes (i 3)
        (sprig-tests--feed
         (sprig-tests--tool-start (1+ i) (format "t%d" i) "Bash")
         (sprig-tests--tool-delta (1+ i) "{\"command\":\"ls\"}")
         (sprig-tests--tool-stop (1+ i))
         (sprig-tests--result-msg (format "t%d" i) "out")))
      (sprig-tests--feed (sprig-tests--text-block-start)
                         (sprig-tests--text "All done.")
                         (sprig-tests--done 0.0 nil))
      (should (sprig-tests--decoration-parity-p)))))

;;;; Reply-id and interrupted detection

(ert-deftest sprig-test-next-reply-id ()
  (sprig-tests--with-buffer "---\n---\n\nnothing yet\n"
    (should (equal (sprig--next-reply-id) "r1")))
  (sprig-tests--with-buffer
      (concat "---\n---\n\n<!-- sprig:reply id=r1 -->\nx\n<!-- sprig:end id=r1 -->\n"
              "<!-- sprig:reply id=r2 -->\ny\n<!-- sprig:end id=r2 -->\n")
    (should (equal (sprig--next-reply-id) "r3"))))

(ert-deftest sprig-test-last-reply-interrupted-p ()
  (sprig-tests--with-buffer
      "---\n---\n\n<!-- sprig:reply id=r1 interrupted -->\n\npartial\n"
    (should (sprig--last-reply-interrupted-p)))
  (sprig-tests--with-buffer
      "---\n---\n\n<!-- sprig:reply id=r1 -->\n\nwhole\n<!-- sprig:end id=r1 -->\n"
    (should-not (sprig--last-reply-interrupted-p))))

;;;; String helpers

(ert-deftest sprig-test-clean-title ()
  (should (equal (sprig--clean-title "\"Fix the parser\"") "fix the parser"))
  (should (equal (sprig--clean-title "`Cache lookup`.") "cache lookup"))
  (should (equal (sprig--clean-title "first line\nsecond") "first line"))
  (should (equal (sprig--clean-title "  \n  Real label  ") "real label"))
  (should-not (sprig--clean-title "   "))
  (should-not (sprig--clean-title "!!!"))
  (should-not (sprig--clean-title nil)))

(ert-deftest sprig-test-clean-title-caps-length ()
  (let ((label (sprig--clean-title (make-string 60 ?a))))
    (should (<= (length label) 40))))

(ert-deftest sprig-test-title-slug ()
  (should (equal (sprig--title-slug "Fix the Parser!") "fix-the-parser"))
  (should (equal (sprig--title-slug "  Multiple   spaces  ") "multiple-spaces"))
  (should-not (sprig--title-slug "!!!"))
  (should-not (sprig--title-slug nil)))

(ert-deftest sprig-test-truncate-words ()
  (should (equal (sprig--truncate-words "short" 20) "short"))
  ;; Cut lands inside "foobar", so back off to the previous word.
  (should (equal (sprig--truncate-words "hello world foobar" 13) "hello world"))
  ;; Cut lands exactly on a space, so keep the whole prefix word.
  (should (equal (sprig--truncate-words "hello world" 5) "hello")))

;;;; Tool-input rendering

(ert-deftest sprig-test-tool-input ()
  (should (equal (sprig--tool-input "Bash" "{\"command\":\"ls -l\"}")
                 '("bash" . "ls -l")))
  (should (equal (sprig--tool-input "Read" "{\"file_path\":\"/tmp/x\"}")
                 '("" . "/tmp/x")))
  (should (equal (car (sprig--tool-input "Grep" "{\"pattern\":\"foo\"}")) "json"))
  (should (equal (sprig--tool-input "Bash" "") '("json" . "{}"))))

(ert-deftest sprig-test-pretty-json ()
  (should (string-match-p "\n" (sprig--pretty-json "{\"a\":1,\"b\":2}")))
  (should (equal (sprig--pretty-json "") "{}"))
  ;; Unparseable input comes back trimmed, not signalling.
  (should (equal (sprig--pretty-json "  not json  ") "not json")))

;;;; Command construction

(ert-deftest sprig-test-base-args ()
  (with-temp-buffer
    (let ((sprig-model "claude-x")
          (sprig-system-prompt "be brief")
          (sprig-extra-args '("--foo"))
          (sprig--session-id "sess-1"))
      (let ((args (sprig--base-args)))
        (should (member "--model" args))
        (should (member "claude-x" args))
        (should (member "--append-system-prompt" args))
        (should (member "be brief" args))
        (should (member "--resume" args))
        (should (member "sess-1" args))
        (should (member "--foo" args))))
    (let ((sprig-model nil) (sprig-system-prompt nil)
          (sprig-extra-args nil) (sprig--session-id nil))
      (let ((args (sprig--base-args)))
        (should-not (member "--model" args))
        (should-not (member "--append-system-prompt" args))
        (should-not (member "--resume" args))))))

(ert-deftest sprig-test-command-local ()
  (with-temp-buffer
    (let ((sprig-remote nil) (sprig-program "claude") (sprig-directory nil))
      (let ((cmd (sprig--command)))
        (should (equal (car cmd) "claude"))
        (should (member "--input-format" cmd))))))

(ert-deftest sprig-test-command-remote ()
  (with-temp-buffer
    (let ((sprig-remote "me@host") (sprig-program "claude")
          (sprig-ssh-program "ssh") (sprig-ssh-args '("-T" "-A"))
          (sprig-directory "~/proj"))
      (let ((cmd (sprig--command)))
        (should (equal (car cmd) "ssh"))
        (should (member "-T" cmd))
        (should (member "me@host" cmd))
        ;; The remote payload cds into the (tilde-preserving) dir then execs.
        (let ((payload (car (last cmd))))
          (should (string-prefix-p "cd ~/proj && exec claude" payload)))))))

(ert-deftest sprig-test-remote-dir-arg ()
  (should (equal (sprig--remote-dir-arg "~") "~"))
  (should (string-prefix-p "~/" (sprig--remote-dir-arg "~/plain")))
  ;; A tilde path with a space keeps the tilde but quotes the rest.
  (should (string-prefix-p "~" (sprig--remote-dir-arg "~/a b")))
  ;; A non-tilde path is shell-quoted whole.
  (should (equal (sprig--remote-dir-arg "/a b") (shell-quote-argument "/a b"))))

(ert-deftest sprig-test-tool-display-frontmatter-override ()
  (sprig-tests--with-buffer "---\nsprig_tools: calls\n---\n\nbody\n"
    (let ((sprig-render-tools 'none))
      (should (eq (sprig--tool-display) 'calls))))
  (sprig-tests--with-buffer "---\n---\n\nbody\n"
    (let ((sprig-render-tools 'full))
      (should (eq (sprig--tool-display) 'full)))))

(provide 'sprig-tests)
;;; sprig-tests.el ends here
