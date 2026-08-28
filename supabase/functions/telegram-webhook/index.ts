import { normalizeLocale } from '../_shared/messaging/locales.ts'
import { processIncomingMessage } from '../_shared/messaging/processor.ts'
import { createServerRepository, errorMessage } from '../_shared/messaging/runtime.ts'
import { timingSafeEqual } from '../_shared/messaging/security.ts'

type TelegramUpdate = {
  update_id: number
  message?: {
    message_id: number
    date: number
    text?: string
    chat: { id: number; type: string }
    from?: { id: number; first_name: string; last_name?: string; username?: string; language_code?: string }
  }
}

const botToken = Deno.env.get('TELEGRAM_BOT_TOKEN')
const webhookSecret = Deno.env.get('TELEGRAM_WEBHOOK_SECRET')
const repository = createServerRepository()

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  if (!botToken || !webhookSecret) return new Response('Telegram is not configured', { status: 503 })
  const suppliedSecret = request.headers.get('x-telegram-bot-api-secret-token') ?? ''
  if (!safeSecretEquals(suppliedSecret, webhookSecret)) return new Response('Invalid secret', { status: 401 })

  let update: TelegramUpdate
  try {
    update = await request.json()
  } catch {
    return new Response('Invalid JSON', { status: 400 })
  }

  const message = update.message
  if (!message?.text || !message.from) return Response.json({ ok: true })
  try {
    const result = await processIncomingMessage({
      provider: 'telegram',
      eventId: String(update.update_id),
      messageId: String(message.message_id),
      conversationId: message.chat.type === 'group' || message.chat.type === 'supergroup' ? String(message.chat.id) : '',
      userId: String(message.from.id),
      userDisplayName: [message.from.first_name, message.from.last_name].filter(Boolean).join(' ').slice(0, 80),
      text: message.text,
      locale: normalizeLocale(message.from.language_code, 'telegram'),
      timestamp: message.date * 1000,
    }, repository)
    if (result.reply) await sendMessage(message.chat.id, result.reply)
    return Response.json({ ok: true })
  } catch (error) {
    console.error('Telegram webhook processing failed', { updateId: update.update_id, error: errorMessage(error) })
    return Response.json({ ok: false, retry: true }, { status: 500 })
  }
})

async function sendMessage(chatId: number, text: string) {
  const response = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text }),
  })
  if (!response.ok) throw new Error(`Telegram reply failed: ${response.status}`)
}

function safeSecretEquals(left: string, right: string) {
  return timingSafeEqual(new TextEncoder().encode(left), new TextEncoder().encode(right))
}
