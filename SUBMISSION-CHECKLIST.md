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
     returned a `not_found` or validation error (HTTP 200) instead of the OAuth
     challenge. A client that probes with `{}` never saw the sign-in prompt.
  2. The OAuth resource metadata names `https://api.mnemom.ai/mcp`, but the app
     is registered at `https://api.mnemom.ai/mcp?profile=directory`. RFC 9728
     requires them to be identical.
  3. The consent page showed `[email protected]` in place of the account email.
  4. The test cases depended on running order, and the protection-card prompt
     left out fields the server requires.
  5. `claim_agent` is marked not destructive, yet every claim, the first one
     included, re-files the agent under the claiming organization.
  6. The OpenID configuration names a different issuer (`id-us2`) than the
     authorization server (`api.mnemom.ai`).

## How we are solving it

Each cause has its own PR in mnemom-api. Every one except the records PR
(3456) needs Shraddha's merge (auth, MCP runtime or security class):

| Cause | PR | What it does |
|---|---|---|
| 1, 2, 3 | https://github.com/mnemom/mnemom-api/pull/3460 | challenges unauthenticated sign-in tools before argument handling; serves the directory tools at `/mcp/directory` with its own resource metadata; fixes the consent email |
| 4 (schema), 5 | https://github.com/mnemom/mnemom-api/pull/3457 | protection-card schema matches the enforced spec; plain tool descriptions; `claim_agent` marked destructive |
| — | https://github.com/mnemom/mnemom-api/pull/3459 | misfire reports filed by the review test account are closed on arrival, so nobody triages them |
| 4 (records) | https://github.com/mnemom/mnemom-api/pull/3456 | v2.0.4 submission record, order-independent test cases, `FORM-FILL.md` with a live submit gate |
| 6 | none yet | needs an owner decision; the form keeps OIDC off, but the `FORM-FILL.md` submit gate blocks until it is resolved |

**Plain `/mcp` changes too.** It is the address Claude.ai, VS Code, Gemini and
Perplexity use:
- 3460's sign-in challenge applies on every address, so an empty-arguments
  write on `/mcp` now gets `401` plus the challenge instead of an error.
- 3457 edits the shared tool catalog, so tool schemas, descriptions and the
  `claim_agent` hint change for every client.

Steps 3 and 5 below therefore probe both addresses, on the preview ring and
then production, and check those clients.

## Before resubmitting — in order

1. **Merge the records PR**, https://github.com/mnemom/mnemom-api/pull/3456.
   It adds the generator flags used below and `FORM-FILL.md`; neither exists
   on main before it merges.
2. **Rebase 3457 onto main.** It also edits
   `submissions/openai/chatgpt-app-submission.json`, so it conflicts once
   3456 merges. Resolve toward 3456's side. In the same rebase, move the
   `claim_agent` entry from `NOT_DESTRUCTIVE_EXCEPTIONS` into `DESTRUCTIVE`
   (3457 makes the tool destructive, and 3456's generator refuses to run
   until the lists agree), and reword it to open "Marked destructive
   because…" like its new neighbours. Then rerun the generator so the record
   matches the merged source.
3. **Merge and deploy** 3460, 3457 and 3459 in a watchable window, preview
   ring first. Plain `/mcp` changes for every client, and mnemom-api deploys
   go to production automatically once the preview ring's own checks pass
   (the mnemom/deploy auto-approve path, MNE-3085). Those checks do not sign
   in from Claude.ai or VS Code, so hold production first:
   - Before the first merge, set the mnemom/deploy repository variable
     `REQUIRE_PROD_APPROVAL=true`. Production then waits for the human
     `approve-production` click. This variable affects every repo's deploys
     for as long as it is set, so it is Shraddha's call and must be cleared
     at the end of this step.
   - Merge the three PRs. Each deploy reaches the preview ring
     (`https://api-us1.mnemom.ai`, sign-in at `https://preview.mnemom.ai`) and
     then waits. Pull `/Users/shraddha/mnemom/mcp` so the local probe is this
     version, then run:
     ```
     API=https://api-us1.mnemom.ai MCP_URL=https://api-us1.mnemom.ai/mcp /Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh
     API=https://api-us1.mnemom.ai MCP_URL=https://api-us1.mnemom.ai/mcp/directory /Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh
     ```
     Both must pass every check. Then connect Claude.ai and VS Code to
     `https://api-us1.mnemom.ai/mcp` and run one read and one write in each.
   - Only then approve production (the latest waiting run), and clear
     `REQUIRE_PROD_APPROVAL`.
   - If production misbehaves, roll the us-2 cell back. Production rollback
     needs Shraddha's explicit go:
     ```
     gh workflow run rollback.yml --repo mnemom/deploy -f service=azure-api -f environment=production -f cell=us-2
     ```

   Get an owner decision on cause 6.
4. **Regenerate the record against the new address**, on a fresh branch off
   mnemom-api main (the resource check needs 3460's `/mcp/directory`
   metadata in the source):
   ```
   node scripts/regenerate-openai-submission.mjs --mcp-url=https://api.mnemom.ai/mcp/directory --require-submittable
   ```
   It must exit 0. Open the result as a PR and merge it.
5. **Run the live probe** after the production deploy, for both addresses:
   ```
   /Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh
   MCP_URL=https://api.mnemom.ai/mcp /Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh
   ```
   The first run probes `https://api.mnemom.ai/mcp/directory`, the address
   being submitted. Every check must pass on both runs. It checks that:
   - unauthenticated writes return `401` with `WWW-Authenticate`, with both
     empty and well-formed arguments;
   - the resource metadata names exactly that address;
   - redirect URIs register for ChatGPT, the OpenAI platform, Claude
     (claude.ai and claude.com), Perplexity, VS Code (web and `127.0.0.1`)
     and Gemini CLI (`localhost`);
   - an unknown redirect host, and the lookalike host
     `chatgpt.com.example.invalid`, are rejected.
     If this check fails, the allowlist
     is off: treat it as a security regression, never as something to relax;
   - `/authorize` sends the new client to that ring's Mnemom sign-in page
     (`www.mnemom.ai` for `api.mnemom.ai`), not back to
     ChatGPT with an error and not to the API host.

   As of 2026-09-30, plain `/mcp` on both production and the preview ring
   passes everything except the empty-arguments write, which is the bug 3460
   fixes.

   Then connect Mnemom from Claude.ai, VS Code, Gemini CLI and Perplexity,
   sign in, and run one read and one write in each. The probe cannot click
   the consent page.

   Also, after deploy: point mnemom-api `scripts/verify-mcp-directory-bar.mjs`
   at `/mcp/directory`, and close the review-account misfire reports filed
   before 3459 (starting with `cand-676b1d13`), which 3459 does not touch.
6. **Work through the submit gate** in mnemom-api
   `submissions/openai/FORM-FILL.md`. It checks the live server, the claim
   targets, a real-browser sign-in with the test account (the consent page
   shows the real email) and every test case. Do not submit until every box
   is ticked.
7. **Fill the form from `FORM-FILL.md`**, field by field. Take the password
   from the JSON `test_credentials`; it is never copied into any doc.

## Reference

- Submission record, FORM-FILL and reviewer instructions:
  https://github.com/mnemom/mnemom-api/tree/main/submissions/openai
- Generator:
  https://github.com/mnemom/mnemom-api/blob/main/scripts/regenerate-openai-submission.mjs
- Probe script: https://github.com/mnemom/mcp/blob/main/scripts/probe-oauth-flow.sh
  (local: `/Users/shraddha/mnemom/mcp/scripts/probe-oauth-flow.sh`)
