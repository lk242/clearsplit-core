# Architecture

ClearSplit separates untrusted chat input from trusted financial state.

```text
Provider request
  ├─ LINE HMAC verification
  ├─ Discord Ed25519 verification
  └─ Telegram webhook-secret verification
             │
             ▼
      IncomingMessage contract
             │
             ▼
  provider-neutral processor
  ├─ durable event lease
  ├─ strict command parser
  ├─ conversation binding
  ├─ member identity link
  └─ pending draft insert
             │
             ▼
 authenticated web review
             │
             ▼
 PostgreSQL RPC transaction
  ├─ responsible-member permission
  ├─ duplicate candidate check
  ├─ public-fund availability / advance
  ├─ balanced journal lines
  ├─ input member + provider attribution
  └─ draft state transition
```

## Trust boundaries

The browser receives a Supabase publishable key. It never receives provider secrets or the Supabase service-role key.

Webhook functions run with service-role access only after verifying the provider request. Their table grants allow the intake path, but confirmation functions require an authenticated ledger owner. The separation is deliberate: signature verification proves that a message came through the provider; it does not authorize a financial transaction.

## Idempotency

`messaging_webhook_events` uses `(provider, webhook_event_id)` as its primary key. A new event gets a processing lease. Failed or abandoned leases can be retried; processed events cannot repeat their side effects. Drafts also enforce unique provider-scoped event and source-message keys.

## Identity

Two relations are intentionally separate:

- `messaging_conversation_bindings`: which external group or channel maps to a ledger.
- `messaging_identities`: which external sender maps to which ledger member.

Both links use provider-scoped, SHA-256-hashed, one-time codes. A group binding alone never guesses the sender's member identity.

## Accounting ownership

The React application formats and collects input, but PostgreSQL owns the accounting contract. Tables, constraints, triggers, row-level security, and security-definer RPCs protect the ledger from another client that bypasses the UI.

The reference backend is therefore more than persistence. Replacing it requires porting the behavior described in [adapter-contracts.md](adapter-contracts.md) and [accounting.md](accounting.md).
