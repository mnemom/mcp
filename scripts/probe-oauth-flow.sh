#!/usr/bin/env bash
# probe-oauth-flow.sh — live end-to-end OAuth/DCR probe against REAL production
# (https://api.mnemom.ai). No mocks, no localhost, no pre-provisioned
# credentials — this is meant to reproduce exactly what an OpenAI MCP
# directory reviewer's automated client does: discover, self-register (RFC
# 7591), and complete a PKCE authorization_code flow with zero manual steps.
#
# Written for MNE OpenAI-rejection remediation (2026-09-26). Reference this
# from SUBMISSION-CHECKLIST.md before every resubmission.
#
# Usage:
#   ./scripts/probe-oauth-flow.sh
#
# Exits non-zero on the first failed check. Prints status codes + relevant
# headers/bodies for each step so a human can eyeball exactly what a reviewer
# would see.

set -euo pipefail

API="https://api.mnemom.ai"
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── 1. Anonymous read is unaffected ─────────────────────────────────────────
step "1. Anonymous read (get_started, no auth)"
READ_BODY=$(curl -sS -X POST "$API/mcp?profile=directory" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_started","arguments":{}}}')
if echo "$READ_BODY" | grep -q '"result"'; then
  pass "anonymous get_started returned a result (reads remain zero-auth)"
else
  fail "anonymous get_started did not return a result: $READ_BODY"
fi

# ── 2. Unauthenticated write still 401s with WWW-Authenticate ──────────────
# NOTE: use a WELL-FORMED payload (valid hash_proof shape) — a malformed one
# returns a spec_validation_failed error before the auth check ever runs, and
# that must NOT be misread as an auth-check regression.
step "2. Unauthenticated write (claim_agent, well-formed args, no auth) -> expect 401 + WWW-Authenticate"
WRITE_HEADERS=$(curl -sS -D - -o /tmp/probe-write-body.json -X POST "$API/mcp?profile=directory" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claim_agent","arguments":{"agent_id":"mnm-probe-nonexistent-agent","hash_proof":"0123456789abcdef0123456789abcdef"}}}')
WRITE_STATUS=$(echo "$WRITE_HEADERS" | head -1 | awk '{print $2}')
if [ "$WRITE_STATUS" = "401" ] && echo "$WRITE_HEADERS" | grep -qi '^www-authenticate:'; then
  pass "unauthenticated write returned 401 + WWW-Authenticate"
else
  fail "unauthenticated write returned HTTP $WRITE_STATUS, not a 401 + WWW-Authenticate (KNOWN ISSUE as of 2026-09-26: tool-call auth failures are wrapped inside a 200 JSON-RPC isError:true envelope instead of an HTTP-level 401 — see SUBMISSION-CHECKLIST.md 'Known secondary finding'). Body: $(cat /tmp/probe-write-body.json)"
fi

# ── 3. RFC 9728 Protected Resource Metadata ─────────────────────────────────
step "3. Protected Resource Metadata (.well-known/oauth-protected-resource/mcp)"
PRM=$(curl -sS "$API/.well-known/oauth-protected-resource/mcp")
PRM_RESOURCE=$(echo "$PRM" | grep -o '"resource":"[^"]*"' || true)
PRM_AS=$(echo "$PRM" | grep -o '"authorization_servers":\[[^]]*\]' || true)
if [ -n "$PRM_RESOURCE" ] && [ -n "$PRM_AS" ]; then
  pass "PRM resolves — $PRM_RESOURCE, $PRM_AS"
else
  fail "PRM missing resource/authorization_servers: $PRM"
fi

# ── 4. RFC 8414 Authorization Server Metadata ───────────────────────────────
step "4. Authorization Server Metadata (.well-known/oauth-authorization-server)"
ASM=$(curl -sS "$API/.well-known/oauth-authorization-server")
REG_ENDPOINT=$(echo "$ASM" | grep -o '"registration_endpoint":"[^"]*"' | sed 's/.*"\(https:[^"]*\)"/\1/' || true)
TOKEN_ENDPOINT=$(echo "$ASM" | grep -o '"token_endpoint":"[^"]*"' | sed 's/.*"\(https:[^"]*\)"/\1/' || true)
AUTHZ_ENDPOINT=$(echo "$ASM" | grep -o '"authorization_endpoint":"[^"]*"' | sed 's/.*"\(https:[^"]*\)"/\1/' || true)
if [ -n "$REG_ENDPOINT" ] && [ -n "$TOKEN_ENDPOINT" ] && [ -n "$AUTHZ_ENDPOINT" ]; then
  pass "AS metadata resolves — registration=$REG_ENDPOINT token=$TOKEN_ENDPOINT authorize=$AUTHZ_ENDPOINT"
else
  fail "AS metadata missing one of registration_endpoint/token_endpoint/authorization_endpoint: $ASM"
fi

# ── 5. THE KEY CHECK — RFC 7591 DCR with a NEVER-SEEN-BEFORE redirect host ──
# This is the exact scenario that broke: OpenAI's reviewer registers from a
# host Mnemom has never pre-approved. Zero pre-provisioned credentials, zero
# manual step. If this comes back anything but 201, the OpenAI rejection is
# NOT fixed regardless of what else passes.
step "5. Dynamic Client Registration — UNKNOWN redirect host, zero pre-provisioning"
UNKNOWN_HOST="https://probe-$(date +%s).example.invalid/oauth/callback"
DCR_RESP=$(curl -sS -w '\n%{http_code}' -X POST "$REG_ENDPOINT" \
  -H 'Content-Type: application/json' \
  -d "{\"client_name\":\"OpenAI-Reviewer-Probe\",\"redirect_uris\":[\"$UNKNOWN_HOST\"],\"grant_types\":[\"authorization_code\"],\"token_endpoint_auth_method\":\"none\"}")
DCR_STATUS=$(echo "$DCR_RESP" | tail -1)
DCR_BODY=$(echo "$DCR_RESP" | sed '$d')
if [ "$DCR_STATUS" = "201" ]; then
  pass "DCR succeeded for a never-before-seen host with ZERO manual approval (201)"
  CLIENT_ID=$(echo "$DCR_BODY" | grep -o '"client_id":"[^"]*"' | sed 's/.*"\(mcp_client_[^"]*\)"/\1/')
else
  fail "DCR for an unknown host returned $DCR_STATUS (expected 201 — this IS the OpenAI-rejection bug if still failing). Body: $DCR_BODY"
fi

# ── 6. Full PKCE authorization_code shape check (up to the human-login wall) ─
# A real end-to-end token requires a logged-in human to click Allow on the
# consent screen, which curl cannot do. This step instead confirms /authorize
# does NOT reject the request for the newly-registered client/redirect before
# hitting the login wall (i.e. it 302s to /login, not 400 invalid_redirect_uri).
step "6. /authorize accepts the newly registered client + redirect (PKCE shape only, pre-login)"
if [ -n "${CLIENT_ID:-}" ]; then
  CODE_VERIFIER_CHALLENGE=$(python3 -c "import hashlib,base64;print(base64.urlsafe_b64encode(hashlib.sha256(b'probe-code-verifier-'+str(__import__('time').time()).encode()).digest()).rstrip(b'=').decode())" 2>/dev/null || echo "$(openssl rand -hex 32 | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=')")
  AUTHZ_URL="$AUTHZ_ENDPOINT?client_id=$CLIENT_ID&redirect_uri=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$UNKNOWN_HOST" 2>/dev/null || echo "$UNKNOWN_HOST")&response_type=code&code_challenge=$CODE_VERIFIER_CHALLENGE&code_challenge_method=S256&state=probe&scope=mcp:read"
  AUTHZ_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-redirs 0 "$AUTHZ_URL" || true)
  # curl with --max-redirs 0 exits nonzero on a redirect but still prints the code via -w before the error in some curl versions; re-check via -D instead for reliability.
  AUTHZ_STATUS=$(curl -sS -D - -o /dev/null "$AUTHZ_URL" | head -1 | awk '{print $2}')
  if [ "$AUTHZ_STATUS" = "302" ]; then
    pass "authorize accepted client+redirect and bounced to login (302) — no invalid_redirect_uri wall"
  else
    fail "authorize returned $AUTHZ_STATUS for the newly registered client (expected 302 to /login, not a 400 invalid_redirect_uri)"
  fi
else
  fail "skipped — no client_id from step 5 (DCR failed)"
fi

step "Summary"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m Zero-touch DCR + PKCE shape verified against production.\n'
else
  printf '\033[31mOne or more checks FAILED.\033[0m Do not resubmit to OpenAI until every check above passes.\n'
fi
exit "$FAIL"
