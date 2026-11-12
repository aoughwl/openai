## openai — a nimony client for the OpenAI Chat Completions API.
## =============================================================================
## A typed client over <baseUrl>/chat/completions: system prompt, multi-turn
## messages, function/tool calling, and (best-effort) streaming. JSON is handled
## with jsonref (error-as-value); HTTP with the aoughwl `requests` nimony port
## (never raises — transport failure surfaces as `Reply.error`).
##
## Part of the aoughwl stack; sibling of `anthropic`. Both are the LLM front
## ends the `code` substrate agent drives.
##
##   let c = newOpenAI()                          # OPENAI_API_KEY from env
##   let r = c.chat("gpt-4.1-mini", @[user("hi")])
##   echo r.text

import requests
import jsonref
import std/[os, envvars, base64, syncio]

const
  DefaultBaseUrl* = "https://api.openai.com/v1"
  DefaultModel*   = "gpt-4.1-mini"

type
  Role* = enum
    roleSystem, roleUser, roleAssistant, roleTool

  Message* = object
    role*: Role
    content*: string
    toolCallId*: string    ## role=tool: the id of the call being answered
    name*: string          ## optional author name
    images*: seq[string]   ## role=user: image URLs or data: URIs sent with the text (vision)
    imageDetail*: string   ## "low" | "high" | "auto" ("" = auto)
    toolCalls*: seq[ToolCall]
      ## role=assistant: the calls the model asked for, replayed back.
      ##
      ## Required, not optional. The API refuses a `tool` message that does not
      ## follow an assistant message carrying the matching `tool_calls`
      ## ("messages with role 'tool' must be a response to a preceding message
      ## with 'tool_calls'"), so without this field a tool LOOP is
      ## inexpressible: the first result can be sent and the second round trip
      ## is a 400. `Reply.toolCalls` gives them to you; `assistantCalls` puts
      ## them back.

  Tool* = object
    name*: string
    description*: string
    schema*: JsonValue     ## JSON-schema object for the function parameters

  ToolCall* = object
    id*: string
    name*: string
    arguments*: string     ## raw JSON string (as OpenAI returns it)

  Usage* = object
    promptTokens*: int
    completionTokens*: int

  Reply* = object
    ok*: bool
    error*: string
    status*: int
    text*: string          ## the assistant message content
    toolCalls*: seq[ToolCall]
    finishReason*: string
    usage*: Usage
    raw*: string

  OpenAI* = object
    apiKey*: string
    baseUrl*: string
    org*: string
    profile*: string
    verifyTls*: bool
    timeoutMs*: int

  StreamEventKind* = enum
    evText, evToolCall, evDone, evError

  StreamEvent* = object
    kind*: StreamEventKind
    text*: string
    toolName*: string
    error*: string

# --- constructors -----------------------------------------------------------

proc newOpenAI*(apiKey = ""; baseUrl = ""; org = "";
                profile = ""; verifyTls = true;
                timeoutMs = 120000): OpenAI =
  ## Build a client. Empty `apiKey`/`baseUrl` fall back to the env
  ## (`OPENAI_API_KEY`, `OPENAI_BASE_URL`) then the defaults.
  var key = apiKey
  if key.len == 0: key = getEnv("OPENAI_API_KEY")
  var url = baseUrl
  if url.len == 0: url = getEnv("OPENAI_BASE_URL")
  if url.len == 0: url = DefaultBaseUrl
  var o = org
  if o.len == 0: o = getEnv("OPENAI_ORG")
  result = OpenAI(apiKey: key, baseUrl: url, org: o,
                  profile: profile, verifyTls: verifyTls, timeoutMs: timeoutMs)

# --- message / tool helpers -------------------------------------------------

proc system*(s: string): Message =
  Message(role: roleSystem, content: s)

proc user*(s: string): Message =
  Message(role: roleUser, content: s)

proc userWithImages*(s: string; images: seq[string]; detail = "auto"): Message =
  ## A user turn with images: each entry is an http(s) URL or a `data:image/...` URI
  ## (see `imageDataUri` for local files).
  Message(role: roleUser, content: s, images: images, imageDetail: detail)

proc imageMime(b: string): string =
  ## Sniff the image type from magic bytes ("" if it is not PNG/JPEG/GIF/WebP).
  if b.len >= 8 and ord(b[0]) == 0x89 and b[1] == 'P' and b[2] == 'N' and b[3] == 'G': return "image/png"
  if b.len >= 3 and ord(b[0]) == 0xFF and ord(b[1]) == 0xD8: return "image/jpeg"
  if b.len >= 4 and b[0] == 'G' and b[1] == 'I' and b[2] == 'F': return "image/gif"
  if b.len >= 12 and b[0] == 'R' and b[1] == 'I' and b[2] == 'F' and b[3] == 'F' and
     b[8] == 'W' and b[9] == 'E' and b[10] == 'B' and b[11] == 'P': return "image/webp"
  ""

proc imageDataUri*(path: string; err: var string): string =
  ## Read a local PNG/JPEG/GIF/WebP file into a `data:` URI for `userWithImages`.
  ## Returns "" and sets `err` when the file cannot be read, is over 20 MB, or is not an image.
  var data = ""
  try:
    data = readFile(path)
  except:
    err = "cannot read image file: " & path
    return ""
  if data.len > 20 * 1024 * 1024:
    err = path & " is over the 20 MB image limit"
    return ""
  let mime = imageMime(data)
  if mime.len == 0:
    err = path & " is not a PNG, JPEG, GIF or WebP image"
    return ""
  "data:" & mime & ";base64," & encode(data)

proc assistant*(s: string): Message =
  Message(role: roleAssistant, content: s)

proc assistantCalls*(toolCalls: seq[ToolCall]; content = ""): Message =
  ## The assistant turn in which the model ASKED for those calls, put back into
  ## the transcript. Every `toolResult` must be preceded by one of these
  ## carrying the id it answers, or the request is rejected.
  Message(role: roleAssistant, content: content, toolCalls: toolCalls)

proc toolResult*(toolCallId, content: string): Message =
  ## A tool turn feeding a function result back to the model.
  Message(role: roleTool, content: content, toolCallId: toolCallId)

proc tool*(name, description: string; schema: JsonValue): Tool =
  Tool(name: name, description: description, schema: schema)

# --- JSON serialisation -----------------------------------------------------

proc roleStr(r: Role): string =
  case r
  of roleSystem: "system"
  of roleUser: "user"
  of roleAssistant: "assistant"
  of roleTool: "tool"

proc messageToJson(m: Message): JsonValue =
  result = newJObject()
  result["role"] = newJString(roleStr(m.role))
  # NULL, not "", when the assistant only asked for tools. An empty string is a
  # message with no text; null is a message that had none, and that is what the
  # API round-trips.
  if m.toolCalls.len > 0 and m.content.len == 0:
    result["content"] = newJNull()
  elif m.images.len > 0:
    # vision: content becomes an array of parts, text first
    let parts = newJArray()
    let t = newJObject()
    t["type"] = newJString("text")
    t["text"] = newJString(m.content)
    parts.add t
    for img in m.images:
      let p = newJObject()
      p["type"] = newJString("image_url")
      let u = newJObject()
      u["url"] = newJString(img)
      u["detail"] = newJString(if m.imageDetail.len > 0: m.imageDetail else: "auto")
      p["image_url"] = u
      parts.add p
    result["content"] = parts
  else:
    result["content"] = newJString(m.content)
  if m.toolCalls.len > 0:
    let tcs = newJArray()
    for c in m.toolCalls:
      let one = newJObject()
      one["id"] = newJString(c.id)
      one["type"] = newJString("function")
      let fn = newJObject()
      fn["name"] = newJString(c.name)
      # VERBATIM. `arguments` is a JSON string on the wire in both directions --
      # re-encoding it as an object here would change the bytes the model sees
      # and, for a malformed argument set, would fail locally instead of letting
      # the model see its own mistake.
      fn["arguments"] = newJString(c.arguments)
      one["function"] = fn
      tcs.add one
    result["tool_calls"] = tcs
  if m.role == roleTool and m.toolCallId.len > 0:
    result["tool_call_id"] = newJString(m.toolCallId)
  if m.name.len > 0:
    result["name"] = newJString(m.name)

proc toolToJson(t: Tool): JsonValue =
  result = newJObject()
  result["type"] = newJString("function")
  let fn = newJObject()
  fn["name"] = newJString(t.name)
  if t.description.len > 0:
    fn["description"] = newJString(t.description)
  if t.schema != nil:
    fn["parameters"] = t.schema
  else:
    fn["parameters"] = newJObject()
  result["function"] = fn

proc buildBody(model: string; msgs: seq[Message]; tools: seq[Tool];
               maxTokens: int; temperature: float; stream: bool;
               maxCompletionTokens = -1; reasoningEffort = ""): string =
  let root = newJObject()
  root["model"] = newJString(model)
  let ms = newJArray()
  for m in msgs:
    ms.add messageToJson(m)
  root["messages"] = ms
  if tools.len > 0:
    let ts = newJArray()
    for t in tools:
      ts.add toolToJson(t)
    root["tools"] = ts
  if maxTokens > 0:
    root["max_tokens"] = newJInt(int64(maxTokens))
  if maxCompletionTokens > 0:
    root["max_completion_tokens"] = newJInt(int64(maxCompletionTokens))
  if reasoningEffort.len > 0:
    root["reasoning_effort"] = newJString(reasoningEffort)
  if temperature >= 0.0:
    root["temperature"] = newJRawNumber($temperature)
  if stream:
    root["stream"] = newJBool(true)
  result = $root

# --- response parsing -------------------------------------------------------

proc parseReply(status: int; body: string): Reply =
  result = Reply(ok: false, status: status, raw: body)
  var err = ""
  let doc = parseJson(body, err)
  if err.len > 0:
    result.error = "malformed JSON response: " & err
    return
  if doc.hasKey("error"):
    let msg = doc{"error"}{"message"}.getStr("unknown API error")
    result.error = "API error: " & msg
    return
  if status < 200 or status >= 300:
    result.error = "HTTP " & $status
    return
  result.usage = Usage(
    promptTokens: int(doc{"usage"}{"prompt_tokens"}.getInt(0)),
    completionTokens: int(doc{"usage"}{"completion_tokens"}.getInt(0)))
  let choice = doc{"choices"}.at(0)
  result.finishReason = choice{"finish_reason"}.getStr("")
  let msg = choice{"message"}
  result.text = msg{"content"}.getStr("")
  for call in msg{"tool_calls"}:
    result.toolCalls.add ToolCall(
      id: call{"id"}.getStr(""),
      name: call{"function"}{"name"}.getStr(""),
      arguments: call{"function"}{"arguments"}.getStr(""))
  result.ok = true

# --- the call ---------------------------------------------------------------

proc post(c: OpenAI; body: string): Reply =
  if c.apiKey.len == 0:
    return Reply(ok: false, error: "no API key (set OPENAI_API_KEY)")
  let s = newSession(c.profile, "", c.verifyTls, c.timeoutMs)
  var hdrs = @[
    ("authorization", "Bearer " & c.apiKey),
    ("content-type", "application/json")]
  if c.org.len > 0:
    hdrs.add ("openai-organization", c.org)
  let r = s.post(c.baseUrl & "/chat/completions", body, hdrs)
  s.close()
  if r.error.len > 0:
    return Reply(ok: false, error: "transport: " & r.error, status: r.status)
  result = parseReply(r.status, r.body)

proc chat*(c: OpenAI; model: string; msgs: seq[Message];
           tools: seq[Tool] = @[]; maxTokens = -1;
           temperature = -1.0; maxCompletionTokens = -1;
           reasoningEffort = ""): Reply =
  ## Send a Chat Completions request and return the parsed reply. Never raises;
  ## check `.ok` / `.error`. gpt-5 / o-series models reject `max_tokens` and
  ## `temperature`: use `maxCompletionTokens` (counts reasoning too) and `reasoningEffort`.
  let body = buildBody(model, msgs, tools, maxTokens, temperature, false,
                       maxCompletionTokens, reasoningEffort)
  result = c.post(body)

# --- streaming (best-effort) ------------------------------------------------
#
# NOTE: the nimony `requests` port exposes no streaming-POST verb (its only
# byte-callback sink, `download`, is GET-only and there is no SSE frame parser).
# True incremental streaming is therefore blocked at the transport layer. Until
# `requests` grows a POST-with-DataCb verb, `stream` performs one blocking
# request and yields the completed text as a single `evText` event followed by
# `evDone`. The iterator API is stable, so callers keep working unchanged once
# real streaming lands. (Filed as a requests improvement.)

iterator stream*(c: OpenAI; model: string; msgs: seq[Message];
                 tools: seq[Tool] = @[]): StreamEvent {.sideEffect.} =
  let r = c.chat(model, msgs, tools)
  if not r.ok:
    yield StreamEvent(kind: evError, error: r.error)
  else:
    if r.text.len > 0:
      yield StreamEvent(kind: evText, text: r.text)
    for call in r.toolCalls:
      yield StreamEvent(kind: evToolCall, toolName: call.name)
    yield StreamEvent(kind: evDone)
