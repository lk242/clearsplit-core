import { parseMessagingCommand } from './command.ts'
import { formatAmount, message } from './locales.ts'
import type { DeleteMessage, IncomingMessage, MessagingRepository, ProcessingResult } from './types.ts'

export async function processIncomingMessage(event: IncomingMessage, repository: MessagingRepository): Promise<ProcessingResult> {
  const shouldProcess = await repository.beginEvent(event.provider, event.eventId, event.messageId)
  if (!shouldProcess) return { groupId: null, reply: message(event.locale, 'alreadyProcessed'), duplicate: true }

  let groupId: string | null = null
  try {
    const command = parseMessagingCommand(event.text)
    if (command.kind === 'ignore') return await complete({ groupId: null, reply: null })
    if (command.kind === 'help') return await complete({ groupId: null, reply: message(event.locale, 'help') })
    if (command.kind === 'invalid') return await complete({ groupId: null, reply: message(event.locale, 'invalid') })

    if (!event.conversationId) return await complete({ groupId: null, reply: message(event.locale, 'conversationOnly') })

    if (command.kind === 'bind') {
      const binding = await repository.redeemConversationCode(event.provider, command.code, event.conversationId, event.userId)
      groupId = binding?.groupId ?? null
      return await complete({
        groupId,
        reply: binding ? message(event.locale, 'bound', { groupName: binding.groupName }) : message(event.locale, 'invalidCode'),
      })
    }

    if (command.kind === 'link') {
      const identity = await repository.redeemIdentityCode(event.provider, command.code, event.userId, event.userDisplayName)
      groupId = identity?.groupId ?? null
      return await complete({
        groupId,
        reply: identity
          ? message(event.locale, 'identityLinked', { groupName: identity.groupName, memberName: identity.memberName })
          : message(event.locale, 'invalidCode'),
      })
    }

    const binding = await repository.findConversation(event.provider, event.conversationId)
    if (!binding) return await complete({ groupId: null, reply: message(event.locale, 'conversationMissing') })
    groupId = binding.groupId
    const identity = await repository.findIdentity(event.provider, groupId, event.userId)
    if (!identity) return await complete({ groupId, reply: message(event.locale, 'identityMissing') })

    const draft = await repository.createDraft({
      provider: event.provider,
      eventId: event.eventId,
      messageId: event.messageId,
      conversationId: event.conversationId,
      userId: event.userId,
      groupId,
      memberId: identity.memberId,
      displayName: identity.displayName,
      rawText: event.text,
      title: command.title,
      amount: command.amount,
      effectiveDate: dateInTimeZone(event.timestamp, 'Asia/Taipei'),
    })
    return await complete({
      groupId,
      reply: message(event.locale, 'draftCreated', {
        title: command.title,
        amount: formatAmount(command.amount, event.locale),
        displayName: identity.displayName,
        draftId: draft.id.slice(0, 8),
      }),
    })
  } catch (error) {
    await repository.completeEvent(event.provider, event.eventId, false, groupId, errorMessage(error))
    throw error
  }

  async function complete(result: ProcessingResult) {
    await repository.completeEvent(event.provider, event.eventId, true, result.groupId)
    return result
  }
}

export async function processDeletedMessage(event: DeleteMessage, repository: MessagingRepository) {
  const shouldProcess = await repository.beginEvent(event.provider, event.eventId, event.messageId)
  if (!shouldProcess) return null
  try {
    const groupId = await repository.cancelDraftByMessage(event.provider, event.messageId)
    await repository.completeEvent(event.provider, event.eventId, true, groupId)
    return groupId
  } catch (error) {
    await repository.completeEvent(event.provider, event.eventId, false, null, errorMessage(error))
    throw error
  }
}

export function dateInTimeZone(timestamp: number, timeZone: string) {
  const date = Number.isFinite(timestamp) ? new Date(timestamp) : new Date()
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(date)
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${value.year}-${value.month}-${value.day}`
}

function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message
  if (typeof error === 'object' && error !== null && 'message' in error && typeof error.message === 'string') return error.message
  return String(error)
}
