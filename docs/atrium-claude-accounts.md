# Claude accounts managed by Atrium

The personal fork discovers active accounts from version 1 of
`~/.atrium/claude-accounts-stores.json` at startup, in addition to ordinary
Claude Code profiles. Accounts already represented by a native profile are
excluded by case-insensitive email address. Names derive from the email domain;
existing same-domain collision handling uses the full address.

Each additional profile reads its own existing keychain service. Discovery
requires a keychain item, validates the service against the existing Claude Code
path hash, and accepts paths only beneath `~/.atrium/claude-accounts/`.
No credentials are copied, refreshed, or written by this integration. An expired
credential retains the existing expired-state behavior; reconnect it in Atrium.
The shared CLI usage estimate is disabled when multiple profiles are present,
so the same usage cannot be shown as both accounts. Desktop cache readings still
require a matching organization ID.

Restart Codenotch after adding or removing an Atrium account. ChatGPT/Codex
visibility and settings are unchanged. Registry metadata and service naming were
checked against this Mac's installed Atrium registry on 2026-11-04; no new remote
API was introduced (the existing Claude OAuth usage provider is reused).
