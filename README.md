# Mnemom — Trust Ratings for AI Agents (MCP server)

Canonical home for the **Mnemom** Model Context Protocol (MCP) server — trust
infrastructure for the agent internet. Look up a verifiable **Trust Rating** for
an AI agent, **scan a website's** AI-trust-readiness, **verify** signed
scorecards in‑band, claim an agent identity, and publish an alignment card.

This repo is the public, canonical source of truth for the server's connection
details and manifest. The server implementation runs on Mnemom's platform; this
repo is its metadata + documentation home.

- **Website:** https://www.mnemom.ai · for agents: https://www.mnemom.ai/for-agents
- **Docs:** https://docs.mnemom.ai
- **Rubric (isittrustready):** https://www.isittrustready.ai/rubric
- **Official MCP registry:** `io.github.mnemom/mnemom`
- **Maintainer:** support@mnemom.ai

## Connect

Streamable‑HTTP MCP endpoint (curated directory profile, 16 tools):

```
https://api.mnemom.ai/mcp?profile=directory
```

The full manifest is in [`server.json`](./server.json).

### In Claude / ChatGPT / any MCP client

Add a custom connector pointing at the URL above. **Reads are anonymous** — you
can list tools and call the reputation, search, scan, verify, and get‑started
tools with no account. **Writes** (claiming an agent, publishing an alignment
card) require authentication.

## Authentication

- **Reads:** zero‑auth. No key, no login.
- **Writes:** OAuth 2.0 with **Dynamic Client Registration (RFC 7591)** + **PKCE**.
  Discovery follows **RFC 9728** — an unauthenticated write returns `401` with a
  `WWW‑Authenticate` header pointing at the Protected Resource Metadata, so a
  compliant client can self‑configure:
  - Protected Resource Metadata: `https://api.mnemom.ai/.well-known/oauth-protected-resource/mcp`
  - Authorization Server Metadata: `https://api.mnemom.ai/.well-known/oauth-authorization-server`
- An `X-Mnemom-Api-Key` header is accepted as an alternative to OAuth.

## What's in the directory profile

A curated 16‑tool surface, grouped:

- **Reputation** — `get_reputation`, `get_reputation_badge`,
  `search_reputation_directory`, `verify_reputation`, `list_agents`, `get_agent`
  (agent risk history is authenticated — see `get_risk_history` on the full surface)
- **Website trust scanning** — `scan_trust`, `verify_scan`
- **Identity & protection** — `claim_agent`, `verify_agent_binding`,
  `preview_compose_alignment_by_agent`, `put_alignment_by_agent`,
  `preview_compose_protection_by_agent`, `put_protection_by_agent`,
  `report_recipe_fn_fp`
- **Orientation** — `get_started`

The default endpoint (`/mcp`, no profile) exposes the full power‑user tool
surface; `?profile=directory` is the curated face used for directory listings.

## Verify, don't trust

Scan scorecards are **Ed25519‑signed**. Verify any scorecard in‑band with the
`verify_scan` tool, or check the signature yourself against the published key:

- Scanner JWKS: `mnemom://iitr/jwks` (also at the isittrustready surface)
- The scorecard carries a self‑describing `verification` block (algorithm, key
  id, canonicalization rule) so a holder can reconstruct and check the signature.

## Links

| | |
|---|---|
| Website | https://www.mnemom.ai |
| For agents | https://www.mnemom.ai/for-agents |
| Documentation | https://docs.mnemom.ai |
| Trust‑readiness rubric | https://www.isittrustready.ai/rubric |
| Contact | support@mnemom.ai |

---

© Mnemom. The server implementation is operated by Mnemom; this repository is its
public manifest and documentation home.
