# Deployment guide

This repository contains no production project reference, domain, webhook credential, or service-role key. Create separate infrastructure for every environment.

## 1. Supabase

Create a Supabase project, link the CLI, and apply every migration in order:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase test db
```

Copy `supabase/.env.example` to `supabase/.env`, replace every placeholder, and keep that file untracked. Upload secrets and deploy functions:

```bash
supabase secrets set --env-file supabase/.env
supabase functions deploy line-member
supabase functions deploy line-webhook
supabase functions deploy discord-webhook
supabase functions deploy telegram-webhook
```

The three webhook functions have `verify_jwt = false` by design. Each rejects unauthenticated provider requests using its own signature or secret. `line-member` validates LINE access tokens itself. Do not weaken those checks.

## 2. Web client

Copy `.env.example` to `.env.local`. Set only browser-safe values:

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
VITE_LIFF_ID=YOUR_LIFF_ID
```

The optional provider URLs only render convenient “add bot” links. They are not credentials.

Run the release gate before deploying to any static host:

```bash
corepack pnpm install --frozen-lockfile
corepack pnpm check
```

The PWA service worker caches only same-origin static assets. Supabase and provider APIs remain network-only.

## 3. Provider callbacks

Assuming the project reference is `YOUR_PROJECT_REF`:

- LINE webhook: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/line-webhook`
- Discord interactions endpoint: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/discord-webhook`
- Telegram webhook: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/telegram-webhook`
- LINE LIFF member exchange: `https://YOUR_PROJECT_REF.supabase.co/functions/v1/line-member`

Complete provider-specific setup in [messaging-providers.md](messaging-providers.md).

## 4. Post-deployment checks

Use a non-production ledger and verify each provider end to end:

1. Invalid signatures or secrets return `401`.
2. A bind code cannot be used twice or by another provider.
3. An unlinked sender cannot create a draft.
4. A valid expense command creates exactly one pending draft even after webhook retry.
5. A non-responsible member cannot confirm or cancel the draft.
6. Confirmation creates one balanced public-fund transaction with the correct provider and member attribution.
7. Archived ledgers reject new drafts at the database layer.

Build success is not a substitute for these runtime checks.
