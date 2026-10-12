# sprig-llama

A client layer between sprig and an OpenAI/Anthropic-style server such as
llama.cpp, so a session can run on a local model.

Sprig drives the `claude` CLI over stdio: it writes user-message JSON lines to
stdin and reads stream-json records back, and the CLI owns the conversation.
llama.cpp is an HTTP server instead, and it is stateless. This script bridges
the two and **owns the conversation itself**, so nothing about sprig's
transport changes and Emacs holds no message history.

Sprig drives it behind `sprig-backend`: a `llama` session runs this script in
place of `claude`, with the same wrapping (SSH, broker) as any other session,
because both programs speak the same protocol over the same stdio.

## Why a separate process

The alternative was keeping the message list in Emacs and posting it each turn.
A client layer is better on four counts:

- **No new state in Emacs.** It owns the history exactly as the CLI does, so
  `sprig--spawn`, `sprig--send-user` and the parser are untouched.
- **Resume and replay come free.** It writes `<id>.jsonl` in the CLI's own
  record shape, under `sprig-llama-projects-directory`, which is where sprig
  already looks (`sprig--session-log-file`). `sprig-session-record-events`
  reads it with no special case.
- **It composes with the broker**, which takes `--program` and an argv after
  `--` and so holds either backend without knowing which.
- **Tool execution can live here**, not in elisp, if it is ever added.

## Protocol

It speaks the subset of the CLI's wire format that sprig actually reads.

```
in   {"type": "user", "message": {...}}
     {"type": "control_request", "request_id": ..., "request": {...}}

out  {"type": "system", "subtype": "init", "session_id":, "cwd":, "model":}
     {"type": "stream_event", "event": {...}}        one per SSE frame
     {"type": "result", "total_cost_usd":, "is_error":}
     {"type": "system", "subtype": "error", "message":}
     {"type": "control_response", "request_id":, "response": {...}}
```

The relay is a rewrap rather than a translation: llama.cpp's `/v1/messages`
route already emits Anthropic-shaped streaming events (`message_start`,
`content_block_start`, `content_block_delta`, `message_delta`, `message_stop`),
and sprig's parser already reads those under a `stream_event` envelope
(`sprig.el`, the `stream_event` branch of `sprig--claude-parse-line`). So each
SSE frame is wrapped and passed on.

## Use

```sh
# One turn, by hand.
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}' \
  | ./sprig-llama --base-url http://127.0.0.1:8080 --max-tokens 60

./sprig-llama --resume "$id"              # rebuild history from the log
./sprig-llama --resume "$id" --fork-session   # carry it into an id of its own
./sprig-llama --version                   # protocol version
```

It accepts and ignores the CLI flags sprig passes for `claude`'s benefit
(`-p`, `--input-format`, `--output-format`, `--include-partial-messages`,
`--verbose`, `--permission-prompt-tool`), so the argv sprig builds needs no
special case.

Stdlib only, like the broker: it needs nothing but `python3`.

## What a llama session cannot do

**There are no tools.** The server will *request* tool calls perfectly well
(llama.cpp returns proper `tool_use` blocks with `stop_reason: "tool_use"`),
but nothing here executes them. The `claude` CLI is what runs `Read`, `Edit`
and `Bash` today.

So sprig's diff review, its verbs, and plan mode do not apply to a llama
session: an accept, reject or commit is an instruction to an agent that edits
files, and there is no such agent on this path. A llama session is a
conversation in a Markdown buffer. Tool calls still *render*, because the
parser emits them as events either way.

`control_request` records are acknowledged rather than acted on, for the same
reason: there is no agent to interrupt or to put into plan mode, and sprig only
needs the receipt to settle its own state.
