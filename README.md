# openai

A [nimony](https://github.com/aoughwl/nimony) client for the **OpenAI API**
(Chat Completions + Responses), plus a small headless CLI wrapper (`openai -p "…"`) in
the spirit of `codex -p` / `claude -p`.

Part of the [aoughwl](https://github.com/aoughwl) stack. Its sibling is
[`aoughwl/anthropic`](https://github.com/aoughwl/anthropic) (same shape, Anthropic API),
and both are the LLM front ends that
[`aoughwl/code`](https://github.com/aoughwl/code) — the substrate-native coding agent —
talks to when it needs a model to *propose* meaning.

## What it is

Two things in one repo:

1. **A library** (`import openai`) — a typed client over
   [Chat Completions](https://platform.openai.com/docs/api-reference/chat) (and the newer
   [Responses](https://platform.openai.com/docs/api-reference/responses) endpoint): system
   prompt, multi-turn messages, function/tool calling, and streaming (SSE). JSON is handled
   with [`aowljson`](https://github.com/aoughwl/aowljson), error-as-value throughout.

2. **A CLI** (`bin/openai`) — a one-shot, pipe-friendly wrapper:

   ```sh
   openai -p "explain this diff" < patch.txt        # headless, prints the answer
   openai -p "hello" --model gpt-4.1-mini            # pick a cheap model
   openai -p "count to 5" --stream                   # stream tokens as they arrive
   echo "summarize" | openai -p -                    # prompt from stdin
   ```

   `-p` is the *print* (headless) flag: read a prompt, print the model's text, exit. This
   is the `-p` equivalence the aoughwl agent drives, identical in spirit to the OpenAI
   Codex CLI's non-interactive mode.

## Library API (sketch)

```nim
import openai

let c = newOpenAI()                         # reads OPENAI_API_KEY from env
# or: newOpenAI(apiKey = "...", baseUrl = "https://api.openai.com/v1")

# --- one-shot ---
let reply = c.chat(
  model    = "gpt-4.1-mini",
  messages = @[system("You are terse."), user("What is 2+2?")])
echo reply.text                             # "4"
echo reply.usage.promptTokens, reply.usage.completionTokens

# --- streaming ---
for ev in c.stream("gpt-4.1-mini", @[user("count to 5")]):
  if ev.kind == evText: stdout.write ev.text

# --- function / tool calling ---
let tools = @[tool("get_weather", "look up weather",
                   schema = %*{"type":"object",
                               "properties":{"city":{"type":"string"}}})]
let r = c.chat("gpt-4.1-mini", @[user("weather in Paris?")], tools = tools)
for call in r.toolCalls:
  echo call.name, " ", call.arguments       # dispatch, then feed a toolResult back
```

Key types:

| type | what it is |
|------|-----------|
| `OpenAI` | the client: api key, base url, org, timeout |
| `Message` | one turn: `role` (`system`/`user`/`assistant`/`tool`) + content |
| `Reply` | a full non-streaming completion: `choices`, `.text` helper, `usage`, `toolCalls` |
| `StreamEvent` | `evText` / `evToolCall` / `evDone` / `evError` from the SSE stream |
| `Tool` | a function/tool definition (name, description, JSON-schema params) |
| `Usage` | `promptTokens`, `completionTokens` — for the agent's token accounting |

Helpers `system(...)`, `user(...)`, `assistant(...)`, `tool(...)`, `toolResult(...)`
build the common shapes without hand-writing JSON.

## Build

```sh
./build.sh          # builds bin/openai
#   nimony c -p:$AOWLJSON/src -p:$REQUESTS/src -o:bin/openai bin/openai.nim
```

`build.sh` locates [`aowljson`](https://github.com/aoughwl/aowljson) and the
[`requests`](https://github.com/aoughwl/requests) HTTP client either next to this
checkout or via `$AOWLJSON` / `$AOWL_REQUESTS`.

## Config

| env | meaning |
|-----|---------|
| `OPENAI_API_KEY` | credential (required unless passed to `newOpenAI`) |
| `OPENAI_BASE_URL` | override the endpoint (Azure, proxies, gateways, local models) |
| `OPENAI_MODEL` | default model for the CLI when `--model` is omitted |

## Status

Client + CLI. Streaming via SSE. Function/tool round-trips. See `tests/` for wire-shape
fixtures and `examples/` for runnable snippets.

## Licence

MIT — see [LICENSE](LICENSE).
