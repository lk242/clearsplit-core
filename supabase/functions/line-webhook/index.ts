import { normalizeLocale } from '../_shared/messaging/locales.ts'
import { processDeletedMessage, processIncomingMessage } from '../_shared/messaging/processor.ts'
import { createServerRepository, errorMessage } from '../_shared/messaging/runtime.ts'
import { verifyHmacSha256Base64 } from '../_shared/messaging/security.ts'

type LineSource = { type: 'group' | 'room' | 'user'; groupId?: string; roomId?: string; userId?: string }
type LineEvent = {
  type: string
  webhookEventId: string
  timestamp?: number
  replyToken?: string
  source: LineSource
  message?: { id: string; type: string; text?: string }
  unsend?: { messageId: string }
}

const channelSecret = Deno.env.get('LINE_CHANNEL_SECRET')
const accessToken = Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN')
const repository = createServerRepository()

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  if (!channelSecret) return new Response('LINE channel is not configured', { status: 503 })

  const body = await request.text()
  const signature = request.headers.get('x-line-signature')
  if (!signature || !await verifyHmacSha256Base64(body, signature, channelSecret)) {
    return new Response('Invalid signature', { status: 401 })
  }

  let payload: { events?: LineEvent[] }
  try {
    payload = JSON.parse(body)
  } catch {
    return new Response('Invalid JSON', { status: 400 })
  }

  let failed = false
  for (const event of payload.events ?? []) {
    try {
      if (event.type === 'unsend' && event.unsend?.messageId) {
        await processDeletedMessage({ provider: 'line', eventId: event.webhookEventId, messageId: event.unsend.messageId }, repository)
        continue
      }
      if (event.type !== 'message' || event.message?.type !== 'text' || !event.message.text) continue
      const result = await processIncomingMessage({
        provider: 'line',
        eventId: event.webhookEventId,
        messageId: event.message.id,
        conversationId: event.source.type === 'group' ? event.source.groupId ?? '' : '',
        userId: event.source.userId ?? '',
        userDisplayName: 'LINE user',
        text: event.message.text,
        locale: normalizeLocale(null, 'line'),
        timestamp: event.timestamp ?? Date.now(),
      }, repository)
      if (result.reply) await replyText(event.replyToken, result.reply)
    } catch (error) {
      failed = true
      console.error('LINE webhook processing failed', { eventId: event.webhookEventId, error: errorMessage(error) })
    }
  }

  return Response.json(failed ? { ok: false, retry: true } : { ok: true }, { status: failed ? 500 : 200 })
})

async function replyText(replyToken: string | undefined, text: string) {
  if (!replyToken || !accessToken) return
  const response = await fetch('https://api.line.me/v2/bot/message/reply', {
    method: 'POST',
    headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ replyToken, messages: [{ type: 'text', text }] }),
  })
  if (!response.ok) console.error('LINE reply failed', response.status)
}
