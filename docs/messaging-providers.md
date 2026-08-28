# Messaging provider setup

All providers are draft-only and use the same three concepts: group bind code, personal identity code, and expense command. Codes expire after 30 minutes and can be used once.

## LINE

1. Create a LINE Messaging API channel and LIFF app.
2. Store `LINE_CHANNEL_SECRET`, `LINE_CHANNEL_ACCESS_TOKEN`, and `LINE_LIFF_ID` as Supabase secrets.
3. Set the provider webhook to the deployed `line-webhook` URL and enable webhooks.
4. Add the official account to the target group.
5. In ClearSplit, select LINE and create a group bind code. Send `#綁定 CODE` in that group.
6. Generate a personal code for each member. That person sends `#連結 CODE`.
7. Create drafts with `#記帳 晚餐 400`.

LINE message deletion events cancel the matching pending draft and clear its raw text. Already-confirmed transactions are never deleted by an unsend event.

## Discord

1. Create an application and bot in the Discord Developer Portal.
2. Store the application's public key as `DISCORD_PUBLIC_KEY` in Supabase secrets.
3. Deploy `discord-webhook`, then set its URL as the application's Interactions Endpoint URL. Discord validates the Ed25519 handler with a ping.
4. Register the `/clearsplit` command:

```bash
DISCORD_APPLICATION_ID=... DISCORD_BOT_TOKEN=... corepack pnpm bot:discord:register
```

5. Add the application to a server with the `applications.commands` scope.
6. In ClearSplit, select Discord and generate the two codes. Run `/clearsplit bind` in the target channel and `/clearsplit link` as the selected member.
7. Run `/clearsplit expense` to create a draft.

Discord replies are ephemeral, while the resulting draft remains visible to authorized ledger members.

## Telegram

1. Create a bot with BotFather and store its token as `TELEGRAM_BOT_TOKEN`.
2. Generate a long random `TELEGRAM_WEBHOOK_SECRET`, store it in Supabase secrets, and configure the callback:

```bash
TELEGRAM_BOT_TOKEN=... TELEGRAM_WEBHOOK_SECRET=... \
TELEGRAM_WEBHOOK_URL=https://YOUR_PROJECT_REF.supabase.co/functions/v1/telegram-webhook \
corepack pnpm bot:telegram:webhook
```

3. Add the bot to a group. Telegram privacy mode may remain enabled because ClearSplit uses slash commands.
4. Run `/bind CODE`, `/link CODE`, and `/expense 晚餐 400`.

Telegram may append the bot username, such as `/expense@YourBot`; the parser removes that suffix safely.

## Command limits

- Code: exactly 32 hexadecimal characters.
- Title: 1–120 characters.
- Amount: positive integer, maximum `999999999`; commas and `NT$`, `NTD`, `TWD`, `USD`, or `$` prefixes are accepted.
- Direct messages cannot bind a ledger. Use a LINE group, Discord server channel, or Telegram group/supergroup.
