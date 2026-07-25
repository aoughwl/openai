## Offline unit test — no network. Exercises the value-level API.
## Build with the CLI's paths (see build.sh) and run.

import "../src/openai"

proc main() =
  var fails = 0

  # message helpers
  let s = system("sys")
  if s.role != roleSystem or s.content != "sys": echo "FAIL: system()"; inc fails
  let u = user("hi")
  if u.role != roleUser or u.content != "hi": echo "FAIL: user()"; inc fails
  let tr = toolResult("call_1", "42")
  if tr.role != roleTool or tr.toolCallId != "call_1": echo "FAIL: toolResult()"; inc fails

  # no key -> error, no network
  let c = newOpenAI(apiKey = "")
  let res = c.chat("gpt-4.1-mini", @[user("x")])
  if res.ok or res.error.len == 0: echo "FAIL: expected no-key error"; inc fails

  if fails == 0: echo "ok — all openai value tests passed"
  else: echo fails, " test(s) failed"; quit(1)

main()
