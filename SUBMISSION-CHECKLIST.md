# OpenAI MCP directory — pre-resubmission checklist (v2.0.4)

## Problem statement

OpenAI rejected the Mnemom ChatGPT app (v2.0.3) with "We're unable to complete
your sign-in or OAuth flow". Tracked on MNE-7770
(https://linear.app/mnemom-dev/issue/MNE-7770).

- **Not the cause: client registration.** ChatGPT's own redirect URIs
  (`chatgpt.com`) always registered successfully.
  https://github.com/mnemom/mnemom-api/pull/3404 (merged 2026-09-27) reopened
  registration to any host, and
  https://github.com/mnemom/mnemom-api/pull/3409 (merged the same day)
  restored the redirect-host allowlist as a security fix. The allowlist stays;
  the probe below checks that it rejects an unknown host.
- **Causes found in the 2026-09-30 audit:**
  1. An unauthenticated call to a sign-in tool with empty or partial arguments
     returned a validation error (HTTP 200) instead of the OAuth challenge. A
     client that probes with `{}` never saw the sign-in prompt.
  2. The OAuth resource metadata names `https://api.mnemom.ai/mcp`, but the app
     is registered at `https://api.mnemom.ai/mcp?profile=directory`. RFC 9728
     requires them to be identical.
  3. The consent page showed `[email protected]` in place of the account email.
  4. The test cases depended on running order, and the protection-card prompt
     left out fields the server requires.
  5. `claim_agent` is marked not destructive, yet a re-claim overwrites the
     agent's organization.
  6. The OpenID configuration names a different issuer (`id-us2`) than the
     authorization server (`api.mnemom.ai`).

## How we are solving it

Each cause has its own PR in mnemom-api. Every one except the docs PR needs
Shraddha's merge (auth, MCP runtime or security class):

| Cause | PR | What it does |
|---|---|---|
| 1, 2, 3 | https://github.com/mnemom/mnemom-api/pull/3460 | challenges unauthenticated sign-in tools before argument handling; serves the directory tools at `/mcp/directory` with its own resource metadata; fixes the consent email |
| 4 (schema), 5 | https://github.com/mnemom/mnemom-api/pull/3457 | protection-card schema matches the enforced spec; plain tool descriptions; `claim_agent` marked destructive |
| — | https://github.com/mnemom/mnemom-api/pull/3459 | misfire reports filed by the review test account are closed on arrival, so nobody triages them |
| 4 (records) | https://github.com/mnemom/mnemom-api/pull/3456 | v2.0.4 submission record, order-independent test cases, `FORM-FILL.md` with a live submit gate |
| 6 | none yet | needs an owner decision; the form keeps OIDC off, but the `FORM-FILL.md` submit gate blocks until it is resolved |

Plain `/mcp` (Claude.ai, VS Code, Gemini, Perplexity) is unchanged by all of
these.

## Before resubmitting — in order

1. **Merge the records PR**, https://github.com/mnemom/mnemom-api/pull/3456.
   It adds the generator flags used below and `FORM-FILL.md`; neither exists
   on main before it merges.
2. **Merge and deploy** 3460, 3457 and 3459 in a watchable window. Get an
   owner decision on cause 6.
3. **Regenerate the record against the new address**, on a fresh branch off
   mnemom-api main (the resource check needs 3460's `/mcp/directory`
   metadata in the source):
   ```
   node scripts/regenerate-openai-submission.mjs --mcp-url=https://api.mnemom.ai/mcp/directory --require-submittable
   ```
   It must exit 0. Before that, move the `claim_agent` entry from
   `NOT_DESTRUCTIVE_EXCEPTIONS` into `DESTRUCTIVE`; the generator refuses to
   run until you do. Open the result as a PR and merge it.
4. **Run the live probe** after deploy, against the address being submitted:
   `/Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh` (it probes
   `https://api.mnemom.ai/mcp/directory` by default; set `MCP_URL` to probe
   another). Every check must pass. It checks that:
   - unauthenticated writes return `401` with `WWW-Authenticate`, with both
     empty and well-formed arguments;
   - the resource metadata names exactly that address;
   - ChatGPT's redirect URI registers;
   - an unknown redirect host is rejected. If this check fails, the allowlist
     is off: treat it as a security regression, never as something to relax;
   - `/authorize` accepts the new client.

   As of 2026-09-30, `MCP_URL=https://api.mnemom.ai/mcp` passes everything
   except the empty-arguments write, which is the bug 3460 fixes.
5. **Work through the submit gate** in mnemom-api
   `submissions/openai/FORM-FILL.md`. It checks the live server, the claim
   targets, a real-browser sign-in with the test account (the consent page
   shows the real email) and every test case. Do not submit until every box
   is ticked.
6. **Fill the form from `FORM-FILL.md`**, field by field. Take the password
   from the JSON `test_credentials`; it is never copied into any doc.

## Reference

- Submission record, FORM-FILL and reviewer instructions:
  https://github.com/mnemom/mnemom-api/tree/main/submissions/openai
- Generator:
  https://github.com/mnemom/mnemom-api/blob/main/scripts/regenerate-openai-submission.mjs
- Probe script: https://github.com/mnemom/mcp/blob/main/scripts/probe-oauth-flow.sh
  (local: `/Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh`)
