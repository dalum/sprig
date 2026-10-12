;;; sprig-live.el --- Live, steerable writing into a buffer  -*- lexical-binding: t; -*-

;; Part of sprig.  See README.md.

;;; Commentary:

;; A local model writes into the buffer at point, token by token, and you
;; steer it mid-flight by typing a comment line.  Not turn-based: there is
;; no send, no reply, and no boundary to wait for.
;;
;; This is a sibling of pair mode, not a change to it.  Pair mode is
;; deliberately stepwise, one small change per `.' press, and nothing is
;; ever sent on your behalf.  Live mode is the opposite bargain: it writes
;; continuously, and your control is that you can interrupt it at any
;; moment by typing.
;;
;; How steering works.  The prompt is the buffer itself, up to the point
;; the model writes at.  So a comment line you type is simply more context,
;; which the model reads like any other: there is no separate channel to
;; learn.  Typing stops the stream; when you pause, it starts again with
;; your line included.
;;
;; Why that is fast enough to feel live.  llama.cpp keeps the prompt's KV
;; cache per slot, so a prompt that grows only at its end costs just the
;; new tokens.  Measured on Qwen2.5-Coder-1.5B here: a 4289-token prompt
;; takes 21.8s cold, and appending a steering line to it takes 0.09s,
;; prefilling 7 tokens.  That is why the cold start is paid once, why
;; `sprig-live-context-lines' bounds it, and why `sprig-live-slot' is
;; pinned: a different slot is a different cache and a fresh 21.8s.
;;
;; It executes nothing.  Emacs does the inserting, the model only proposes
;; text, and so there is no tool, no shell, and nothing to approve.

;;; Code:

(require 'json)
(require 'subr-x)

(defgroup sprig-live nil
  "Live, steerable writing into a buffer."
  :group 'sprig
  :prefix "sprig-live-")

(defcustom sprig-live-base-url "http://127.0.0.1:8081"
  "Base URL of the llama.cpp server live mode writes from.
A completion model is what this wants, not an instruct one: the prompt is
raw buffer text with no chat template.  Qwen2.5-Coder is the family that
suits it."
  :type 'string)

(defcustom sprig-live-curl-program "curl"
  "Program used to stream from the server.
Curl rather than `url-retrieve' because the stream must arrive in chunks
as it is generated, which is what a process filter gives us."
  :type 'string)

(defcustom sprig-live-slot 0
  "Server slot live mode pins its session to.
Pinned because the slot holds the prompt's KV cache, and that cache is
the whole reason steering is cheap.  Letting the server choose spreads a
session over slots and pays the cold prefill again on each hop."
  :type 'integer)

(defcustom sprig-live-max-tokens 256
  "Tokens the model may write before it stops on its own.
A ceiling, not a target: the stop strings should end a run well before
this.  At ~18 tok/s it is about the longest you would sit watching."
  :type 'integer)

(defcustom sprig-live-temperature 0.2
  "Sampling temperature.  Low: this is code being written into your file."
  :type 'number)

(defcustom sprig-live-context-lines 400
  "Lines of buffer before point sent as context, or nil for all of it.
This bounds the one cost live mode cannot cache away, the first prefill:
at ~237 tokens/s, 400 lines of source is a few seconds, and the whole of
a long file is not.  Everything after it is free."
  :type '(choice (const :tag "Whole buffer" nil) (integer :tag "Lines")))

(defcustom sprig-live-steer-marker ">>>"
  "Marker that makes a comment line an instruction rather than a comment.
`sprig-live-steer' writes one; the preamble tells the model to obey such
lines and not to echo them.  A marker, rather than any comment at all, so
that the comments already in your file stay comments."
  :type 'string)

(defcustom sprig-live-restart-idle 0.6
  "Seconds of your silence before live mode starts writing again.
Your first keystroke stops the stream; this is how long it waits before
resuming, so that typing a whole sentence is one interruption and not
one per character."
  :type 'number)

(defcustom sprig-live-preamble
  (concat "You are writing code directly into a file, continuing from where it "
          "stops. Emit only the code that comes next: no explanation, no "
          "markdown fences, no repetition of what is already above. A comment "
          "line containing %s is an instruction from the person you are "
          "working with: follow it, and do not copy it into your output.")
  "Instruction placed above the buffer context.
`%s' is replaced by `sprig-live-steer-marker'."
  :type 'string)

;; Declared by `define-minor-mode' below; named here so the functions above
;; it compile without a free-variable warning.
(defvar sprig-live-mode)

(defvar-local sprig-live--process nil
  "The curl process streaming into this buffer, or nil.")

(defvar-local sprig-live--marker nil
  "Where the model writes.  A marker, not a position, so that your own
typing elsewhere in the buffer does not misplace the next token.")

(defvar-local sprig-live--inserting nil
  "Bound while live mode writes, so `sprig-live--after-change' can tell
the model's insertions from yours.  Without it the model's own output
would read as a steer and restart the stream on every token.")

(defvar-local sprig-live--armed nil
  "Non-nil while live mode is engaged, i.e. your pause should resume it.

Typing resumes only what was running.  Without this, editing the buffer
for your own reasons started the model writing again, and `sprig-live-stop'
was undone by your very next keystroke: it cancelled the timer, and the
keystroke armed a new one.  Set by `sprig-live-start' and
`sprig-live-steer', cleared by `sprig-live-stop' and by a run ending of
its own accord, a finished thought being no invitation to continue.")

(defvar-local sprig-live--timer nil
  "Idle timer that resumes the stream after you stop typing.")

(defvar-local sprig-live--acc ""
  "Incomplete tail of the server's SSE stream, awaiting the rest of a line.")

;;;; Pure parts

(defun sprig-live--context (limit-lines)
  "Return the buffer text before point, at most LIMIT-LINES lines of it."
  (let ((beg (if (null limit-lines)
                 (point-min)
               (save-excursion
                 (forward-line (- limit-lines))
                 (line-beginning-position)))))
    (buffer-substring-no-properties beg (point))))

(defun sprig-live--comment (text)
  "Return TEXT as comment lines in the current buffer's language."
  (let ((prefix (or comment-start "# "))
        (suffix (if (and comment-end (not (string-empty-p comment-end)))
                    comment-end
                  "")))
    (mapconcat (lambda (line)
                 (concat (string-trim-right prefix) " " line suffix))
               (split-string text "\n")
               "\n")))

(defun sprig-live--prompt (context)
  "Return the full prompt for CONTEXT.
The preamble is commented in the buffer's own language so that it reads
as part of the file rather than as a second voice above it.  A completion
model continues code; plain prose where code belongs is out of
distribution for one, and it answers in kind."
  (concat (sprig-live--comment
           (format sprig-live-preamble sprig-live-steer-marker))
          "\n\n" context))

(defun sprig-live--sse-content (acc chunk)
  "Split ACC+CHUNK into (CONTENT . REST).
CONTENT is the concatenated text of every complete SSE record in it, REST
the incomplete tail to carry to the next chunk.  Returned rather than
inserted so this can be tested without a server."
  (let* ((text (concat acc chunk))
         (lines (split-string text "\n"))
         (rest (car (last lines)))
         (out ""))
    (dolist (line (butlast lines))
      (setq line (string-trim line))
      (when (string-prefix-p "data:" line)
        (let ((payload (string-trim (substring line 5))))
          (unless (or (string-empty-p payload) (equal payload "[DONE]"))
            (let ((obj (condition-case nil
                           (json-parse-string payload :object-type 'alist
                                              :null-object nil
                                              :false-object nil)
                         (error nil))))
              (when obj
                (setq out (concat out (or (alist-get 'content obj) "")))))))))
    (cons out rest)))

(defcustom sprig-live-stop-alist
  '((emacs-lisp-mode "\n\n(" "\n\n;;;")
    (lisp-interaction-mode "\n\n(")
    (lisp-mode "\n\n(")
    (scheme-mode "\n\n(")
    (clojure-mode "\n\n(")
    (python-mode "\n\ndef " "\n\nclass " "\n\n@" "\n\nif __name__")
    (python-ts-mode "\n\ndef " "\n\nclass " "\n\n@" "\n\nif __name__")
    (sh-mode "\n\nfunction ")
    (rust-mode "\n\nfn " "\n\npub fn " "\n\nimpl " "\n\nstruct ")
    (rust-ts-mode "\n\nfn " "\n\npub fn " "\n\nimpl " "\n\nstruct "))
  "Per-mode strings that end a run, beyond the steer marker.
A run should be one coherent step, as a pair-mode turn is.  Left alone a
model finishes what you asked for and then starts something else
unbidden, which is the thing to catch: each entry marks a *new top-level
form*, so a run ends where your reading would.

The blank line is deliberate.  A bare newline-and-paren would also match
the model's very first token when it opens with an empty line, ending the
run before it wrote anything; a top-level form in these languages follows
a blank line anyway."
  :type '(alist :key-type symbol :value-type (repeat string)))

(defcustom sprig-live-extra-stop-strings nil
  "Stop strings added in every buffer, whatever its mode."
  :type '(repeat string))

(defcustom sprig-live-fallback-stop-strings '("\n\n\n")
  "Stop strings used when `sprig-live-stop-alist' knows nothing of the mode.
Two blank lines: a weaker signal than a named top-level form, but it still
catches a model that has finished and is casting about."
  :type '(repeat string))

(defun sprig-live--stop-strings ()
  "Strings that end a run.

Two kinds.  The steer marker is yours, not the model's: left to itself a
completion model imitates the convention, writing itself a plausible next
instruction, which reads as the model putting words in your mouth.  The
rest mark a new top-level form, because a model that has answered you
will otherwise carry straight on into something you did not ask for.

Stopping hands the turn back, which is the whole bargain of live mode."
  (append (list sprig-live-steer-marker)
          (or (alist-get major-mode sprig-live-stop-alist)
              sprig-live-fallback-stop-strings)
          sprig-live-extra-stop-strings))

(defun sprig-live--request-body (prompt)
  "Return the JSON request body streaming PROMPT."
  (json-serialize
   (list :prompt prompt
         :n_predict sprig-live-max-tokens
         :temperature sprig-live-temperature
         :cache_prompt t
         :id_slot sprig-live-slot
         :stop (vconcat (sprig-live--stop-strings))
         :stream t)))

(defun sprig-live--command ()
  "Return the curl command vector for a streaming completion.
`--no-buffer' is the flag that makes this live at all: without it curl
holds the stream in its own buffer and the text arrives in bursts."
  (list sprig-live-curl-program
        "--silent" "--no-buffer" "--show-error"
        "--max-time" "600"
        "-H" "Content-Type: application/json"
        "--data-binary" "@-"
        (concat (string-remove-suffix "/" sprig-live-base-url) "/completion")))

;;;; Streaming

(defun sprig-live--filter (proc chunk)
  "Insert the text of CHUNK from PROC at this buffer's marker."
  (let ((buf (process-get proc :buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (pcase-let ((`(,content . ,rest)
                     (sprig-live--sse-content sprig-live--acc chunk)))
          (setq sprig-live--acc rest)
          (unless (string-empty-p content)
            (let ((sprig-live--inserting t)
                  (marker sprig-live--marker))
              (when (and marker (marker-position marker))
                (save-excursion
                  (goto-char marker)
                  ;; `insert-before-markers' would drag a point parked at the
                  ;; marker along with the text; this leaves your cursor where
                  ;; you put it and advances only the marker.
                  (insert content)
                  (set-marker marker (point)))))))))))

(defun sprig-live--trim-dangling-comment ()
  "Remove a bare comment opener left at the marker by a stop.
Stopping on the steer marker catches the model mid-comment, just after it
has written the opener it was about to put the marker in, so the buffer is
left with a stray `;; \='.  Only a line that is nothing but an opener and
whitespace is removed, so a real comment the model wrote survives."
  (when (and sprig-live--marker (marker-position sprig-live--marker)
             comment-start)
    (save-excursion
      (goto-char sprig-live--marker)
      (let ((beg (line-beginning-position)))
        (when (string-match-p
               (concat "\\`[[:space:]]*"
                       (regexp-quote (string-trim-right comment-start))
                       "[[:space:]]*\\'")
               (buffer-substring-no-properties beg (point)))
          (let ((sprig-live--inserting t))
            ;; Take the newline before it too: it was ours, not yours.
            (delete-region (max (point-min) (1- beg)) (point))
            (set-marker sprig-live--marker (point))))))))

(defun sprig-live--sentinel (proc _event)
  "Clear PROC when it exits, so a later start is not taken for a running one."
  (unless (process-live-p proc)
    (let ((buf (process-get proc :buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when (eq sprig-live--process proc)
            (setq sprig-live--process nil)
            (sprig-live--trim-dangling-comment)
            ;; Only a run we killed mid-flight is resumed; one that stopped
            ;; by itself has finished, and your next edit is your own.
            (unless (timerp sprig-live--timer)
              (setq sprig-live--armed nil))))))))

(defun sprig-live--stream (prompt)
  "Start streaming PROMPT into this buffer."
  (setq sprig-live--acc "")
  (let ((proc (make-process
               :name "sprig-live"
               :buffer nil
               :command (sprig-live--command)
               :connection-type 'pipe
               :coding 'utf-8-unix
               :noquery t
               :filter #'sprig-live--filter
               :sentinel #'sprig-live--sentinel)))
    (process-put proc :buffer (current-buffer))
    (setq sprig-live--process proc)
    (process-send-string proc (sprig-live--request-body prompt))
    (process-send-eof proc)
    proc))

(defun sprig-live--abort ()
  "Stop the stream, leaving what it has already written in place."
  (when (process-live-p sprig-live--process)
    (delete-process sprig-live--process))
  (setq sprig-live--process nil))

(defun sprig-live--resume ()
  "Start writing again from the marker, with the buffer as it now stands."
  (setq sprig-live--timer nil)
  (when (and sprig-live-mode sprig-live--armed sprig-live--marker
             (marker-position sprig-live--marker)
             (not (process-live-p sprig-live--process)))
    (save-excursion
      (goto-char sprig-live--marker)
      (sprig-live--stream
       (sprig-live--prompt (sprig-live--context sprig-live-context-lines))))))

(defun sprig-live--after-change (_beg _end _len)
  "Stop on your keystroke and arrange to resume once you pause.
The stream is killed at once rather than debounced: leaving it writing
while you type would interleave its text with yours.  Resuming is what
waits, so a sentence typed is one interruption."
  (unless (or sprig-live--inserting (not sprig-live--armed))
    (sprig-live--abort)
    (when (timerp sprig-live--timer) (cancel-timer sprig-live--timer))
    (setq sprig-live--timer
          (run-with-idle-timer sprig-live-restart-idle nil
                               (let ((buf (current-buffer)))
                                 (lambda ()
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (sprig-live--resume)))))))))

;;;; Commands

;;;###autoload
(defun sprig-live-start ()
  "Begin writing at point, and keep writing until you stop it."
  (interactive)
  (unless sprig-live-mode (sprig-live-mode 1))
  (sprig-live--abort)
  (setq sprig-live--armed t)
  (setq sprig-live--marker (copy-marker (point) t))
  (sprig-live--stream
   (sprig-live--prompt (sprig-live--context sprig-live-context-lines)))
  (message "sprig-live: writing (%s to steer, %s to stop)"
           (substitute-command-keys "\\[sprig-live-steer]")
           (substitute-command-keys "\\[sprig-live-stop]")))

;;;###autoload
(defun sprig-live-stop ()
  "Stop writing, and stop resuming."
  (interactive)
  (sprig-live--abort)
  (when (timerp sprig-live--timer) (cancel-timer sprig-live--timer))
  (setq sprig-live--timer nil)
  ;; Disarming is what makes this stick: without it your next keystroke
  ;; would arm a fresh timer and the model would carry on.
  (setq sprig-live--armed nil)
  (message "sprig-live: stopped"))

;;;###autoload
(defun sprig-live-steer ()
  "Open a steering comment where the model is writing, and leave point in it.
Typing is itself the interruption, so nothing else is needed: the stream
stops on the first character and resumes, reading your line, once you
pause.  The comment is ordinary buffer text, which is why the model needs
no separate channel to hear you."
  (interactive)
  (setq sprig-live--armed t)
  (when (and sprig-live--marker (marker-position sprig-live--marker))
    (goto-char sprig-live--marker))
  (unless (bolp) (insert "\n"))
  (insert (or comment-start "# ") " " sprig-live-steer-marker " ")
  (when (and comment-end (not (string-empty-p comment-end)))
    (save-excursion (insert comment-end))))

;;;###autoload (autoload 'sprig-live-command-map "sprig-live" nil t 'keymap)
(defvar-keymap sprig-live-command-map
  :doc "Prefix map for live mode, to bind where you like:

  (keymap-global-set \"C-c C-l\" sprig-live-command-map)

Global rather than in `sprig-live-mode-map' because starting is the one
command you need before the mode is on, and a minor-mode map is not
active until it is: a start key living only there could never reach the
command that enables it."
  "s" #'sprig-live-start
  "q" #'sprig-live-stop
  "." #'sprig-live-steer)

(defvar-keymap sprig-live-mode-map
  :doc "Keymap for `sprig-live-mode', active only while it is on.
Carries the two verbs that mean something mid-flight, so they work in a
live buffer whether or not `sprig-live-command-map' is bound."
  "C-c C-l q" #'sprig-live-stop
  "C-c C-l ." #'sprig-live-steer)

;;;###autoload
(define-minor-mode sprig-live-mode
  "Let a local model write into this buffer, steerable as it goes."
  :lighter " live"
  :keymap sprig-live-mode-map
  (if sprig-live-mode
      (add-hook 'after-change-functions #'sprig-live--after-change nil t)
    (sprig-live-stop)
    (remove-hook 'after-change-functions #'sprig-live--after-change t)
    (when (markerp sprig-live--marker) (set-marker sprig-live--marker nil))
    (setq sprig-live--marker nil)))

(provide 'sprig-live)
;;; sprig-live.el ends here
