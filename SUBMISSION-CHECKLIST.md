# OpenAI MCP directory — pre-resubmission checklist

## Problem statement

OpenAI rejected the mnemom MCP connector (v2.0.3, 2026-08-29 submission):
"We're unable to complete your sign-in or OAuth flow. Please ensure valid,
working credentials are included and that they include no additional setup or
verification to access your service."

Root cause (confirmed live against `https://api.mnemom.ai`, 2026-09-26):
`POST /v1/oauth/register` (RFC 7591 Dynamic Client Registration) rejects any
`redirect_uri` whose host isn't on a hardcoded allowlist, with
`400 invalid_redirect_uri` — `"...contact Mnemom to approve your client's
host."` A generic zero-touch client (exactly how an automated directory
reviewer is shaped) cannot register, so OAuth can never complete without a
human on Mnemom's side approving the host first.

## How we are solving it

`mnemom-api` PR (open, NOT merged — NEVER-AUTO security-class change, needs
Shraddha's review): https://github.com/mnemom/mnemom-api/pull/3404

Reopens registration/authorize to any well-shaped HTTPS or RFC 8252 loopback
redirect_uri (removes the allowlist gate). PKCE S256 (already mandatory,
unchanged) is what protects the authorization code from a stolen/misdirected
redirect — the allowlist survives only as a consent-screen "unrecognized app"
warning, so the anti-phishing control moves to the human clicking Allow
instead of blocking registration outright.

## Before resubmitting to OpenAI — run these, in order

1. **Merge + deploy the fix.**
   PR: https://github.com/mnemom/mnemom-api/pull/3404 — merge only after
   Shraddha's review (security/auth class). Deploy in a watchable window.

2. **Run the live probe script against prod, immediately after deploy:**
   ```
   /Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh
   ```
   All 6 checks must PASS, especially:
   - Step 5 (DCR with a never-seen-before redirect host) → must be `201`,
     not `400 invalid_redirect_uri`. **This is the exact bug** — if this
     still fails, the fix did not deploy or did not work; do not resubmit.
   - Step 2 (unauthenticated write) — see "Known secondary finding" below;
     currently expected to still show a non-401 result even after this fix,
     since it's a separate code path.

3. **Confirm anonymous reads are unaffected** (probe step 1) — the fix only
   touches the write/OAuth path; reads must still work with zero auth.

4. **Regenerate the OpenAI submission JSON from live metadata** (do not hand-
   edit it — it must reflect the deployed server exactly):
   ```
   cd /Users/shraddha/mnemom/mnemom-api && node scripts/regenerate-openai-submission.mjs
   ```
   Confirm the regenerated `submissions/openai/chatgpt-app-submission.json`
   now has `supported_auth[1].allow_http_redirect: false` (it was stale —
   showed `true` — as of 2026-09-26, out of sync with live metadata's
   `false`). A mismatched field here can cause a second, unrelated rejection.

5. **Manually walk the full PKCE flow once with a real browser**, using a
   redirect host that is NOT on the allowlist (e.g. a throwaway
   `https://webhook.site/...` URL), to see the actual consent screen and
   confirm:
   - The "unrecognized app" warning banner renders for the unvetted host.
   - Clicking Allow still delivers a valid authorization code to that host.
   - Exchanging the code (+ PKCE verifier) at `/v1/oauth/token` returns a
     valid access token with zero manual approval step anywhere in the flow.

6. **Confirm the reviewer test credentials still work**, since OpenAI's
   submission includes login creds for a demo account
   (`reviewer-directory@mnemom.ai`, see
   `/Users/shraddha/mnemom/mnemom-api/submissions/openai/README.md`):
   - Log in as that account and confirm it has a non-empty org with
     meaningful tool results (reputation, agents, alignment cards) so a
     reviewer clicking through tools doesn't hit an empty state.

## Known secondary finding — needs its own decision before/alongside resubmission

An unauthenticated write with well-formed arguments (`claim_agent` +
plausible `hash_proof`) returns HTTP `200` with a JSON-RPC
`{"isError":true,"result":{...,"error":{"code":"unauthorized",...}}}` body —
**not** an HTTP-level `401` with `WWW-Authenticate`. Confirmed live
2026-09-26. This does not look like an authorization bypass (the write is
still refused), but it means a spec-compliant MCP client relying on the
documented `401` discovery trigger (per this repo's own README, "Reads:
zero-auth... Writes: ...an unauthenticated write returns 401 with a
WWW-Authenticate header") never receives that signal for a `tools/call`
invocation — only for whatever earlier-layer check currently returns `401`
(confirmed: hitting `/mcp` with **no** `tools/call` body element at all still
401s correctly; it's specifically write-tool invocations that get wrapped
into a 200 JSON-RPC envelope). This is a `mnemom-api` `src/mcp/handler.ts` /
tool-dispatch question, not something this PR's OAuth-allowlist fix touches —
flagging for a decision on whether it also needs fixing before resubmission,
since OpenAI's rejection language ("unable to complete your sign-in or OAuth
flow") could plausibly also be triggered by this if their reviewer relies on
in-band 401 discovery rather than a static "this connector needs auth" flag.

## Reference

- Fix PR (open, not merged): https://github.com/mnemom/mnemom-api/pull/3404
- Probe script: `/Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh`
- OpenAI submission generator: `/Users/shraddha/mnemom/mnemom-api/scripts/regenerate-openai-submission.mjs`
- OpenAI submission record: `/Users/shraddha/mnemom/mnemom-api/submissions/openai/README.md`
