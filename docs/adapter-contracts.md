# Adapter contracts

## Messaging adapter

A provider adapter has three responsibilities:

1. Verify the raw request before parsing it.
2. Normalize a supported message into `IncomingMessage`.
3. Deliver the processor's localized reply through the provider API.

The shared contract is in `supabase/functions/_shared/messaging/types.ts`. The shared processor depends only on `MessagingRepository`; it contains no provider SDK and no Supabase import. Unit tests use an in-memory repository.

Required normalized fields:

| Field | Meaning |
| --- | --- |
| `provider` | Stable provider namespace |
| `eventId` | Provider retry identity |
| `messageId` | Source message identity |
| `conversationId` | Group/channel identity; blank for unsupported direct messages |
| `userId` | Verified provider sender identity |
| `userDisplayName` | Display-only metadata, never an authorization key |
| `text` | Normalized command input |
| `locale` | `en` or `zh-TW` reply locale |
| `timestamp` | Source event time in milliseconds |

To add a provider, extend `MessagingProvider`, database provider checks, locale selection, source-type checks, deployment configuration, and both unit and SQL provider-isolation tests.

## Backend boundary

`MessagingRepository` is a working backend seam for chat intake. The included implementation targets Supabase.

The rest of the reference web client currently calls Supabase RPCs through `src/lib/cloudLedger.ts`. A replacement backend must preserve at least:

- authenticated group membership and one responsible member;
- atomic expense/share writes and exact amount conservation;
- separate payer and debtor confirmations;
- nonnegative public-fund balance with explicit member advances;
- immutable journal/audit attribution;
- duplicate-draft review rather than silent insertion;
- idempotent webhook leases and one-time binding codes;
- archived-ledger database-level read-only behavior;
- cascade-safe ledger deletion and portable export semantics.

An adapter that only matches HTTP response shapes is not compatible if it weakens these behaviors.

## Frontend boundary

The React application is a reference client, not a requirement. Another web, mobile, or desktop client may call the same authenticated RPCs. Keep service-role credentials server-side and treat RPC errors as authoritative; never simulate a successful mutation locally after a failed server request.
