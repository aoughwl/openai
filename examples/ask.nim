## examples/ask.nim — minimal library usage.
##
## Build with the same paths as the CLI:
##   nimony c -r \
##     --path:$HOME/aowljson/src --path:$HOME/aoughwl-requests/nimony \
##     --passl:-L$HOME/aoughwl-requests/vendor/curl-impersonate/lib \
##     --passl:-Wl,-rpath,$HOME/aoughwl-requests/vendor/curl-impersonate/lib \
##     examples/ask.nim
##
## Needs OPENAI_API_KEY in the environment.

import "../src/openai"

proc main() =
  let c = newOpenAI()
  let r = c.chat("gpt-4.1-mini",
                 @[system("You answer in exactly one word."),
                   user("In one word: the color of the sky?")])
  if r.ok:
    echo "answer: ", r.text
    echo "tokens: prompt=", r.usage.promptTokens, " completion=", r.usage.completionTokens
  else:
    echo "error: ", r.error

main()
