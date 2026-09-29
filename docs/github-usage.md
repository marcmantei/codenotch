# GitHub usage in the personal fork

This fork is https://github.com/marcmantei/codenotch, based on upstream
`vinzdg/codenotch` v1.19.0. The feature branch is `feat/github-usage-accounts`.
The original Copilot display still works. Settings → Accounts → GitHub adds
independent displays for Copilot or GitHub Actions billing at the personal,
organization or enterprise level.

## Set up a display

1. Add a display and give it a recognizable name.
2. Select Copilot or the Actions reporting scope. For Actions, enter the username,
   organization name or enterprise **slug**, not a URL.
3. Keep `github.com`, or use a GitHub Enterprise Cloud data-residency host such as
   `company.ghe.com`. Self-hosted GitHub Enterprise Server is not supported.
4. Choose a separate token (stored only in the macOS login keychain) or a named
   account already authenticated in `gh`. CLI lookup always uses
   `gh auth token --hostname HOST --user USER`, never `auth switch` or `login`.
   Environment token overrides are excluded from the CLI subprocess.
5. Test connection, then Save. Editing the token or reporting target clears the
   previous reading. Removing a display deletes its token and readings, without
   signing out GitHub CLI. Disable a display through the existing Accounts list.

The token is never stored in preferences, committed, logged or put in shell
arguments. The account name in the display comes from its own configuration,
not the active private CLI account. Each display has a separate keychain item.
The default Copilot display intentionally retains upstream behavior.

## Billing access and data

The implementation uses GitHub REST API version `2026-03-10`:

- `/users/{username}/settings/billing/usage/summary`
- `/organizations/{org}/settings/billing/usage/summary`
- `/enterprises/{enterprise}/settings/billing/usage/summary`

It explicitly selects the current UTC year/month and `product=Actions`. The
enterprise summary includes **all cost centers** when no cost-center filter is
supplied. The older enterprise `/usage` endpoint defaults to unallocated usage
and must not replace it.

The account needs the appropriate billing role AND an authorized credential.
Personal reports support fine-grained tokens with **Plan: read**, organization
reports **Administration: read**. Enterprise reports support GitHub App tokens
with **Enterprise billing: read**, or a classic personal access token authorized
for enterprise billing. A normal repository token or enterprise membership alone
is insufficient. Company SSO and token policies also apply. Expiring tokens
must be replaced in the display; this version does not mint GitHub App tokens.

The selected account's existing CLI token may work for Copilot while lacking
billing permission. Use a separate billing token in that case; the private CLI
login does not need to change.

- Runner minutes sum `grossQuantity` only for Actions items with `unitType=minutes`.
- Net USD cost sums Actions `netAmount`, including storage SKUs and discounts.
- Storage quantities are never added to minutes; Copilot and other products are
  excluded. No assumed free-minute allowance, budget percentage or live workflow
  count is shown. Billing data can be delayed.
- Empty valid data reports zero; malformed data, authentication/permission errors,
  and rate limits do not become zero usage.

API references verified 2026-09-30:
https://docs.github.com/en/rest/billing/usage
https://docs.github.com/en/enterprise-cloud@latest/rest/billing/usage

## Updates

This is a source-maintained personal fork, **not** a subscription to the original
binary update feed. `CodenotchForkBuild=true` prevents Sparkle initialization,
automatic checks and manual upstream updates, even when old preferences enable
them. Settings explains this. Do not remove that guard when merging upstream.
No automated signed fork release feed has been configured.

To incorporate a future upstream release without losing the extension:

1. Start from the current fork feature branch (or the maintained fork branch after
   its PR is merged), with a clean working tree.
2. Fetch upstream tags and create an update branch:
   ```sh
   git fetch upstream --tags
   git switch -c update/upstream-VERSION
   git merge --no-ff --no-commit vVERSION
   ```
3. Resolve conflicts, preserving the GitHub usage files and the fork update guard.
   Bump `MARKETING_VERSION` with a new `-marc.N` suffix. Do not use GitHub's
   force-sync/discard-changes operation on the maintained fork branch.
4. Run `make test` with local signing overrides if needed, review the resulting
   diff, commit and open a PR in the fork. The original repository stays the
   `upstream` remote; `origin` is the personal fork.
5. Build `Scripts/build-personal-fork.sh`, quit Codenotch, and replace the installed
   bundle with `build/personal/Build/Products/Release/Codenotch.app`. Keep a backup
   of the previous app for rollback. Launch the new copy yourself.

The build script defaults to ad-hoc signing. For a stable local identity, set
`CODENOTCH_SIGN_IDENTITY` and `CODENOTCH_SIGN_TEAM` to your own signing identity
and team when running it; never use upstream's signing identity. Stable signing
avoids changing the keychain identity on every local update. This local build
is not notarized; distributing a release requires your own notarization and
update-signing setup.
