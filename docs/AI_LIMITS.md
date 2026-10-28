# AI limits integration

Macbar displays the existing subscription usage of accounts signed in on this Mac. It does not create conversations, generate model output, redeem reset credits, or manage billing.

## Codex

The installed Codex CLI is started briefly as `codex app-server`. Macbar sends `initialize`, `initialized`, and the read-only `account/rateLimits/read` request over standard input/output, then closes the process. A 20-second deadline bounds the request. No CLI logs or authentication tokens are displayed or retained by Macbar. The CLI manages its own existing authentication.

`rateLimitsByLimitId` takes precedence over the legacy `rateLimits`. Each available primary/secondary window shows its percentage remaining, duration and reset timestamp. The compact summary uses the main `codex` bucket when supplied; additional buckets stay visible in the detail panel. API-key-only accounts do not expose ChatGPT subscription windows.

Source: [official Codex app-server documentation](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).

## Claude

Macbar first checks the existing Claude Code `.credentials.json` in `CLAUDE_CONFIG_DIR`, or `~/.claude`. It can also read the existing `Claude Code-credentials` Keychain entry. It never writes either location or refreshes/replaces Claude Code tokens. Only an unexpired `claudeAiOauth.accessToken` is used. Tokens for MCP servers are not subscription credentials.

The token is sent only to `https://api.anthropic.com/api/oauth/usage`, with the `anthropic-beta: oauth-2025-04-20` header. The ephemeral HTTP session has no persistent cookies or response cache, and refuses redirects. Authentication errors ask the user to renew the Claude Code sign-in. Foreign Keychain payloads are not read until the user first chooses **Allow Claude access…**. After a successful read, that consent is remembered; background reads disable authentication UI. Only the explicit access action permits the operating system to ask for access. User approval remains with the operating system.

Available `five_hour`, `seven_day` and model-specific windows are displayed separately. The compact summary uses the overall session and weekly windows when available, so a depleted model-specific quota does not incorrectly mark all Claude usage exhausted. Missing percentages are unknown, never zero usage. Claude's OAuth usage endpoint is not a stable public API and may change.

Implementation research: [CodexBar Claude provider documentation](https://github.com/steipete/CodexBar/blob/main/docs/claude.md) and [Claude OAuth usage fetcher](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift). Macbar implements a small independent reader rather than bundling CodexBar or copying its credential store.

## Refresh and failure behavior

- Fetches run independently, so one provider can succeed while the other requires sign-in.
- Refresh occurs every three minutes while enabled, and on opening the panel or pressing Refresh.
- Hiding AI Limits or the taskbar stops the refresh timer and rejects cancelled results.
- Offline failures can retain a clearly labeled last-known snapshot in details. The compact label shows a dash for failed or expired data.
- Sign-in/access failures clear previous snapshots. Usage snapshots remain in memory only; restarting Macbar fetches again.
- No browser cookies, usage history, chats or documents are read.
