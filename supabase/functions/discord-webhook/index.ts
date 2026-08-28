import { normalizeLocale } from '../_shared/messaging/locales.ts'
import { processIncomingMessage } from '../_shared/messaging/processor.ts'
import { createServerRepository, errorMessage } from '../_shared/messaging/runtime.ts'
import { verifyEd25519Hex } from '../_shared/messaging/security.ts'

type DiscordOption = { name: string; type: number; value?: string | number; options?: DiscordOption[] }
type DiscordInteraction = {
  id: string
  type: number
  channel_id?: string
  guild_id?: string
  locale?: string
  guild_locale?: string
  member?: { user?: { id: string; username: string; global_name?: string } }
  user?: { id: string; username: string; global_name?: string }
  data?: { name?: string; options?: DiscordOption[] }
}

const publicKey = Deno.env.get('DISCORD_PUBLIC_KEY')
const repository = createServerRepository()

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  if (!publicKey) return new Response('Discord is not configured', { status: 503 })
  const body = await request.text()
  const signature = request.headers.get('x-signature-ed25519') ?? ''
  const timestamp = request.headers.get('x-signature-timestamp') ?? ''
  if (!signature || !timestamp || !await verifyEd25519Hex(body, timestamp, signature, publicKey)) {
    return new Response('Invalid signature', { status: 401 })
  }

  let interaction: DiscordInteraction
  try {
    interaction = JSON.parse(body)
  } catch {
    return new Response('Invalid JSON', { status: 400 })
  }
  if (interaction.type === 1) return Response.json({ type: 1 })
  if (interaction.type !== 2) return discordReply('Unsupported interaction.')

  const user = interaction.member?.user ?? interaction.user
  const text = commandText(interaction.data)
  if (!user || !text) return discordReply('Use /clearsplit help to see the supported commands.')
  try {
    const result = await processIncomingMessage({
      provider: 'discord',
      eventId: interaction.id,
      messageId: interaction.id,
      conversationId: interaction.guild_id && interaction.channel_id ? interaction.channel_id : '',
      userId: user.id,
      userDisplayName: (user.global_name || user.username).slice(0, 80),
      text,
      locale: normalizeLocale(interaction.locale ?? interaction.guild_locale, 'discord'),
      timestamp: discordSnowflakeTimestamp(interaction.id),
    }, repository)
    return discordReply(result.reply ?? 'OK')
  } catch (error) {
    console.error('Discord interaction processing failed', { interactionId: interaction.id, error: errorMessage(error) })
    return discordReply('ClearSplit could not process this command. Please retry.')
  }
})

function commandText(data: DiscordInteraction['data']) {
  if (data?.name !== 'clearsplit') return null
  const subcommand = data.options?.find((option) => option.type === 1)
  if (!subcommand) return '/help'
  const value = (name: string) => subcommand.options?.find((option) => option.name === name)?.value
  if (subcommand.name === 'help') return '/help'
  if (subcommand.name === 'bind' || subcommand.name === 'link') return `/${subcommand.name} ${String(value('code') ?? '')}`
  if (subcommand.name === 'expense') return `/expense ${String(value('title') ?? '')} ${String(value('amount') ?? '')}`
  return null
}

function discordReply(content: string, status = 200) {
  return Response.json({ type: 4, data: { content, flags: 64 } }, { status })
}

function discordSnowflakeTimestamp(id: string) {
  try {
    return Number((BigInt(id) >> 22n) + 1_420_070_400_000n)
  } catch {
    return Date.now()
  }
}
