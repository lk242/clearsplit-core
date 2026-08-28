# Security policy

Please do not open a public issue for a vulnerability that could expose ledger data, authentication material, webhook secrets, or financial integrity.

Use GitHub's private vulnerability reporting for this repository. Include the affected revision, deployment topology, reproduction steps, impact, and any suggested mitigation. Do not include real access tokens or personal ledger data.

Only the latest `main` revision receives security fixes. No hosted ClearSplit instance is implied by this source repository; operators are responsible for their own Supabase, LINE, Discord, Telegram, and web-hosting configuration.

Webhook endpoints must remain unauthenticated at the Supabase JWT layer because each provider performs its own request verification. LINE uses HMAC-SHA256, Discord uses Ed25519, and Telegram uses its webhook secret header. Never expose `SUPABASE_SERVICE_ROLE_KEY` or provider secrets to Vite variables or browser code.
