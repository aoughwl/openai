#!/usr/bin/env bash
# Build the `openai` CLI (and type-check the library) with nimony.
#
# Deps are resolved by path (nimony has no package manager here):
#   aowljson  — https://github.com/aoughwl/aowljson   ($AOWLJSON or ~/aowljson)
#   requests  — https://github.com/aoughwl/requests   ($AOWL_REQUESTS or ~/aoughwl-requests)
#              (nimony PORT lives under <requests>/nimony, not src/)
set -euo pipefail
cd "$(dirname "$0")"

NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
AOWLJSON="${AOWLJSON:-$HOME/aowljson}"
REQ="${AOWL_REQUESTS:-$HOME/aoughwl-requests}"
CURL_LIB="$REQ/vendor/curl-impersonate/lib"

mkdir -p bin

"$NIMONY" c \
  --path:"$AOWLJSON/src" \
  --path:"$REQ/nimony" \
  --passl:-L"$CURL_LIB" \
  --passl:-Wl,-rpath,"$CURL_LIB" \
  -o:bin/openai \
  bin/openai.nim

echo "built bin/openai"
