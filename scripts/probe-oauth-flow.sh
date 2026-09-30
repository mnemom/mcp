#!/usr/bin/env bash
# probe-oauth-flow.sh — live OAuth/DCR probe against REAL production
# (https://api.mnemom.ai). No mocks, no localhost, no pre-provisioned
# credentials. It reproduces what the OpenAI MCP directory reviewer's client
# does against the MCP server URL entered in the submission form: probe a tool
# unauthenticated, follow the challenge to the resource metadata, discover the
# authorization server, self-register (RFC 7591) with ChatGPT's redirect URI,
# and start a PKCE authorization_code flow.
#
# Run it from SUBMISSION-CHECKLIST.md before every resubmission (MNE-7770).
#
# Usage:
#   ./scripts/probe-oauth-flow.sh                     # probes https://api.mnemom.ai/mcp/directory
#   MCP_URL=https://api.mnemom.ai/mcp ./scripts/probe-oauth-flow.sh
#
# MCP_URL must be the exact MCP server URL entered in the form (the `mcp_url`
# in mnemom-api's regenerated submissions/openai/chatgpt-app-submission.json).
#
# Run it for BOTH addresses after a deploy: the directory address ChatGPT uses,
# and plain /mcp, which Claude.ai, VS Code, Gemini and Perplexity use.
#
# Side effect: step 5a registers one throwaway OAuth client per redirect URI,
# exactly as any client would (5b is rejected, so it registers nothing).
# Exits non-zero if any check fails.

set -uo pipefail

API="https://api.mnemom.ai"
MCP_URL="${MCP_URL:-$API/mcp/directory}"
# Client redirect URIs registration must accept: ChatGPT's production redirect
# and the OpenAI platform's (both used in OpenAI's app review), plus one on each
# allowlisted host Claude.ai, Perplexity and VS Code use. The allowlist matches
# hosts, so the path only has to look like the client's. The loopback URI
# covers native clients (VS Code desktop, Gemini CLI; RFC 8252 §7.3).
CHATGPT_REDIRECT="https://chatgpt.com/connector_platform_oauth_redirect"
CLIENT_REDIRECTS="$CHATGPT_REDIRECT https://platform.openai.com/apps-manage/oauth https://claude.ai/api/mcp/auth_callback https://www.perplexity.ai/rest/connectors/oauth/callback https://vscode.dev/redirect http://127.0.0.1:33418/callback"
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case "$MCP_URL" in
  "$API"/*) ;;
  *) echo "MCP_URL must be on $API (got $MCP_URL)"; exit 2 ;;
esac
case "$MCP_URL" in
  *\?*|*\#*) echo "MCP_URL must not carry a query or fragment: RFC 8707 §2 forbids a fragment and advises against a query, and RFC 9728 §3.3 needs an exact match"; exit 2 ;;
esac
MCP_PATH="${MCP_URL#"$API"}"
PRM_URL="$API/.well-known/oauth-protected-resource$MCP_PATH"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
json_field() { python3 -c 'import json,sys
try: v=json.load(sys.stdin).get(sys.argv[1])
except Exception: v=None
print("" if v is None else (v if isinstance(v,str) else json.dumps(v)))' "$1"; }

echo "Probing MCP server URL: $MCP_URL"

# ── 1. Anonymous read works ─────────────────────────────────────────────────
step "1. Anonymous read (get_started, no auth)"
READ_BODY=$(curl -sS -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_started","arguments":{}}}')
if echo "$READ_BODY" | grep -q '"result"' && ! echo "$READ_BODY" | grep -q '"isError":true'; then
  pass "anonymous get_started returned a result (reads stay zero-auth)"
else
  fail "anonymous get_started did not return a result: $(echo "$READ_BODY" | head -c 400)"
fi

# ── 2. Unauthenticated write -> 401 + WWW-Authenticate, whatever the args ───
# A client may probe a sign-in tool with empty arguments. It must get the OAuth
# challenge, never a validation error, or it never shows the sign-in prompt.
probe_write() { # $1 label, $2 arguments JSON
  local hdr="$TMP/h" body="$TMP/b" status www
  curl -sS -D "$hdr" -o "$body" -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"claim_agent\",\"arguments\":$2}}"
  status=$(head -1 "$hdr" | tr -d '\r' | awk '{print $2}')
  www=$(grep -i '^www-authenticate:' "$hdr" | tr -d '\r')
  if [ "$status" = "401" ] && echo "$www" | grep -qF "resource_metadata=\"$PRM_URL\""; then
    pass "$1: 401 + WWW-Authenticate pointing at $PRM_URL"
  else
    fail "$1: HTTP $status, WWW-Authenticate='${www:-none}' (expected 401 with resource_metadata=\"$PRM_URL\"). Body: $(head -c 400 "$body")"
  fi
}
step "2. Unauthenticated write (claim_agent, no auth) -> expect 401 + WWW-Authenticate"
probe_write "empty arguments" '{}'
probe_write "well-formed arguments" '{"agent_id":"mnm-probe-nonexistent-agent","hash_proof":"0123456789abcdef0123456789abcdef"}'

# ── 3. RFC 9728 Protected Resource Metadata for THIS server URL ─────────────
step "3. Protected Resource Metadata ($PRM_URL)"
PRM=$(curl -sS "$PRM_URL")
PRM_RESOURCE=$(echo "$PRM" | json_field resource)
PRM_AS=$(echo "$PRM" | json_field authorization_servers)
if [ "$PRM_RESOURCE" = "$MCP_URL" ] && echo "$PRM_AS" | grep -qF "\"$API\""; then
  pass "resource is exactly $MCP_URL (RFC 9728 §3.3); authorization_servers=$PRM_AS"
else
  fail "resource='$PRM_RESOURCE' (must equal '$MCP_URL' exactly), authorization_servers='$PRM_AS'. Body: $(echo "$PRM" | head -c 400)"
fi

# ── 4. RFC 8414 Authorization Server Metadata ───────────────────────────────
step "4. Authorization Server Metadata ($API/.well-known/oauth-authorization-server)"
ASM=$(curl -sS "$API/.well-known/oauth-authorization-server")
REG_ENDPOINT=$(echo "$ASM" | json_field registration_endpoint)
TOKEN_ENDPOINT=$(echo "$ASM" | json_field token_endpoint)
AUTHZ_ENDPOINT=$(echo "$ASM" | json_field authorization_endpoint)
ASM_ISSUER=$(echo "$ASM" | json_field issuer)
if [ -n "$REG_ENDPOINT" ] && [ -n "$TOKEN_ENDPOINT" ] && [ -n "$AUTHZ_ENDPOINT" ] && [ "$ASM_ISSUER" = "$API" ]; then
  pass "issuer=$ASM_ISSUER registration=$REG_ENDPOINT token=$TOKEN_ENDPOINT authorize=$AUTHZ_ENDPOINT"
else
  fail "AS metadata incomplete or issuer != $API: $(echo "$ASM" | head -c 400)"
fi

# ── 5. RFC 7591 Dynamic Client Registration ─────────────────────────────────
# ChatGPT registers with its own chatgpt.com redirect URI: that must succeed
# with zero manual steps. An arbitrary HTTPS host must be REJECTED: the
# redirect-host allowlist is a deliberate security control (mnemom-api #3409,
# pentest fix). Never "fix" a 5b failure by reopening registration.
register() { # $1 redirect_uri -> prints "<body>\n<status>"
  curl -sS -w '\n%{http_code}' -X POST "$REG_ENDPOINT" \
    -H 'Content-Type: application/json' \
    -d "{\"client_name\":\"OpenAI-Reviewer-Probe\",\"redirect_uris\":[\"$1\"],\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\"}"
}
CLIENT_ID=""
step "5a. Dynamic Client Registration with each client's redirect URI -> expect 201"
if [ -n "$REG_ENDPOINT" ]; then
  for REDIRECT in $CLIENT_REDIRECTS; do
    DCR_RESP=$(register "$REDIRECT")
    DCR_STATUS=$(echo "$DCR_RESP" | tail -1)
    DCR_BODY=$(echo "$DCR_RESP" | sed '$d')
    if [ "$DCR_STATUS" = "201" ]; then
      ID=$(echo "$DCR_BODY" | json_field client_id)
      [ "$REDIRECT" = "$CHATGPT_REDIRECT" ] && CLIENT_ID="$ID"
      pass "$REDIRECT registered with zero manual approval (201), client_id=$ID"
    else
      fail "registration with $REDIRECT returned $DCR_STATUS (expected 201). Body: $DCR_BODY"
    fi
  done
else
  fail "skipped: no registration_endpoint from step 4"
fi

step "5b. Dynamic Client Registration with an unknown host -> expect 400 invalid_redirect_uri"
if [ -n "$REG_ENDPOINT" ]; then
  # A plain unknown host, and a lookalike that only a suffix match would pass.
  for BAD in "https://probe-$(date +%s).example.invalid/oauth/callback" "https://chatgpt.com.example.invalid/connector_platform_oauth_redirect"; do
    UNK_RESP=$(register "$BAD")
    UNK_STATUS=$(echo "$UNK_RESP" | tail -1)
    UNK_BODY=$(echo "$UNK_RESP" | sed '$d')
    if [ "$UNK_STATUS" = "400" ] && echo "$UNK_BODY" | grep -q 'invalid_redirect_uri'; then
      pass "$BAD rejected (400 invalid_redirect_uri): allowlist in force"
    else
      fail "$BAD returned $UNK_STATUS (expected 400 invalid_redirect_uri; the allowlist is a security control). Body: $UNK_BODY"
    fi
  done
else
  fail "skipped: no registration_endpoint from step 4"
fi

# ── 6. /authorize accepts the registered client (PKCE shape, pre-login) ─────
# A real token needs a signed-in human to click Allow, which curl cannot do.
# This confirms /authorize accepts ChatGPT's client, redirect, PKCE and scope
# and sends the browser to Mnemom sign-in. Once the client and redirect check
# out, /authorize reports any other error as a 302 back to the client's
# redirect with ?error=, so a bare 302 proves nothing: the Location must be
# the sign-in page. `resource` is sent the way ChatGPT sends it; /authorize
# does not read it today, so this step does not check it.
step "6. /authorize sends the registered client to sign-in (PKCE S256, pre-login)"
if [ -n "$CLIENT_ID" ] && [ -n "$AUTHZ_ENDPOINT" ]; then
  CHALLENGE=$(python3 -c 'import hashlib,base64,secrets;print(base64.urlsafe_b64encode(hashlib.sha256(secrets.token_urlsafe(48).encode()).digest()).rstrip(b"=").decode())')
  Q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.urlencode({"client_id":sys.argv[1],"redirect_uri":sys.argv[2],"response_type":"code","code_challenge":sys.argv[3],"code_challenge_method":"S256","state":"probe","scope":"mcp:read mcp:write","resource":sys.argv[4]}))' "$CLIENT_ID" "$CHATGPT_REDIRECT" "$CHALLENGE" "$MCP_URL")
  AUTHZ_HDR=$(curl -sS -D - -o /dev/null "$AUTHZ_ENDPOINT?$Q" | tr -d '\r')
  AUTHZ_STATUS=$(echo "$AUTHZ_HDR" | head -1 | awk '{print $2}')
  AUTHZ_LOC=$(echo "$AUTHZ_HDR" | grep -i '^location:' | sed 's/^[Ll]ocation: *//')
  LOC_HOST=$(echo "$AUTHZ_LOC" | sed -E 's#^https://([^/?]*).*#\1#')
  case "$LOC_HOST" in
    mnemom.ai|*.mnemom.ai) LOC_OK=1 ;;
    *) LOC_OK=0 ;;
  esac
  case "$AUTHZ_LOC" in
    "https://$LOC_HOST/login?return_to="*) ;;
    *) LOC_OK=0 ;;
  esac
  if [ "$AUTHZ_STATUS" = "302" ] && [ "$LOC_OK" = 1 ]; then
    pass "authorize accepted client, redirect, PKCE and scope and sent the browser to sign-in"
  else
    fail "authorize returned $AUTHZ_STATUS to '${AUTHZ_LOC:-no Location}' (expected 302 to https://…mnemom.ai/login?return_to=…; a redirect back to the client with ?error= is a failure)"
  fi
else
  fail "skipped: no ChatGPT client_id from step 5a"
fi

step "Summary"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mAll checks passed\033[0m for %s.\n' "$MCP_URL"
else
  printf '\033[31mOne or more checks FAILED.\033[0m Do not resubmit to OpenAI until every check above passes.\n'
fi
exit "$FAIL"
