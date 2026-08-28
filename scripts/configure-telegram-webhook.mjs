const token = process.env.TELEGRAM_BOT_TOKEN
const secret = process.env.TELEGRAM_WEBHOOK_SECRET
const webhookUrl = process.env.TELEGRAM_WEBHOOK_URL

if (!token || !secret || !webhookUrl) throw new Error('TELEGRAM_BOT_TOKEN, TELEGRAM_WEBHOOK_SECRET and TELEGRAM_WEBHOOK_URL are required')
const url = new URL(webhookUrl)
if (url.protocol !== 'https:') throw new Error('TELEGRAM_WEBHOOK_URL must use HTTPS')
if (secret.length < 32 || secret.length > 256 || !/^[A-Za-z0-9_-]+$/.test(secret)) throw new Error('TELEGRAM_WEBHOOK_SECRET must be 32–256 URL-safe characters')

const response = await fetch(`https://api.telegram.org/bot${token}/setWebhook`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ url: url.toString(), secret_token: secret, allowed_updates: ['message'], drop_pending_updates: false }),
})
const result = await response.json()
if (!response.ok || result.ok !== true) throw new Error(`Telegram webhook setup failed (${response.status}): ${JSON.stringify(result)}`)
console.log('Telegram webhook configured successfully')
