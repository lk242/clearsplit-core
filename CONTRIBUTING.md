# Contributing

ClearSplit welcomes focused fixes, tests, documentation, translations, and messaging adapters.

Before opening a pull request:

1. Create a branch from `main`.
2. Keep financial invariants in PostgreSQL, not only in the UI.
3. Keep messaging adapters draft-only. A webhook must never post directly to the ledger.
4. Add tests for parser boundaries, event idempotency, provider isolation, permissions, and any changed accounting rule.
5. Run `corepack pnpm check` and `supabase test db`.
6. Do not commit `.env` files, production URLs, project references, tokens, user identifiers, or real ledger exports.

New providers should normalize their signed payload into `IncomingMessage`, use `processIncomingMessage`, and implement replies in the provider adapter. Provider-specific accounting logic belongs in neither the webhook nor the UI.

By submitting a contribution, you agree that it is licensed under Apache-2.0.
