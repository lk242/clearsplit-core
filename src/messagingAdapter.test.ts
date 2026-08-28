import { describe, expect, it } from 'vitest'
import { parseMessagingCommand } from '../supabase/functions/_shared/messaging/command.ts'
import { dateInTimeZone, processIncomingMessage } from '../supabase/functions/_shared/messaging/processor.ts'
import type { MessagingProvider, MessagingRepository } from '../supabase/functions/_shared/messaging/types.ts'

describe('messaging command contract', () => {
  it.each([
    ['#綁定 0123456789abcdef0123456789abcdef', { kind: 'bind', code: '0123456789abcdef0123456789abcdef' }],
    ['/bind@ClearSplitBot 0123456789ABCDEF0123456789ABCDEF', { kind: 'bind', code: '0123456789abcdef0123456789abcdef' }],
    ['/link 0123456789abcdef0123456789abcdef', { kind: 'link', code: '0123456789abcdef0123456789abcdef' }],
    ['#連結 0123456789abcdef0123456789abcdef', { kind: 'link', code: '0123456789abcdef0123456789abcdef' }],
    ['#記帳 晚餐 1,240', { kind: 'fund_expense', title: '晚餐', amount: 1240 }],
    ['/expense train tickets USD89', { kind: 'fund_expense', title: 'train tickets', amount: 89 }],
    ['expense hotel TWD3200', { kind: 'fund_expense', title: 'hotel', amount: 3200 }],
    ['/help', { kind: 'help' }],
  ])('normalizes %s', (input, expected) => {
    expect(parseMessagingCommand(input)).toEqual(expected)
  })

  it.each(['/expense dinner 0', '/expense dinner 1000000000', '/bind short', '#記帳 400'])('rejects malformed commands: %s', (input) => {
    expect(parseMessagingCommand(input)).toEqual({ kind: 'invalid' })
  })

  it('ignores ordinary conversation', () => {
    expect(parseMessagingCommand('see you at dinner')).toEqual({ kind: 'ignore' })
  })
})

describe('provider-neutral message processing', () => {
  it('creates an auditable draft only after conversation and identity lookup', async () => {
    const repository = fakeRepository()
    const result = await processIncomingMessage(event('/expense Dinner 450', 'telegram'), repository)
    expect(result.groupId).toBe('group-1')
    expect(result.reply).toContain('Draft created')
    expect(repository.created).toMatchObject({
      provider: 'telegram', groupId: 'group-1', memberId: 'member-1', title: 'Dinner', amount: 450,
    })
    expect(repository.completions).toEqual([{ provider: 'telegram', eventId: 'event-1', success: true, groupId: 'group-1', error: undefined }])
  })

  it('does not create a draft for an unbound conversation', async () => {
    const repository = fakeRepository({ conversation: null })
    const result = await processIncomingMessage(event('/expense Dinner 450', 'discord'), repository)
    expect(result.reply).toContain('not connected')
    expect(repository.created).toBeNull()
  })

  it('does not create a draft for an unlinked sender', async () => {
    const repository = fakeRepository({ identity: null })
    const result = await processIncomingMessage(event('#記帳 晚餐 450', 'line'), repository)
    expect(result.reply).toContain('找不到你的帳本成員身分')
    expect(repository.created).toBeNull()
  })

  it('redeems provider-scoped group binding codes', async () => {
    const repository = fakeRepository()
    const result = await processIncomingMessage(event('/bind 0123456789abcdef0123456789abcdef', 'discord'), repository)
    expect(result.reply).toContain('Connected to “Trip”')
    expect(repository.redeemedProvider).toBe('discord')
  })

  it('redeems personal identity codes separately from group binding', async () => {
    const repository = fakeRepository()
    const result = await processIncomingMessage(event('/link 0123456789abcdef0123456789abcdef', 'telegram'), repository)
    expect(result.reply).toContain('Linked Alex')
    expect(repository.linkedProvider).toBe('telegram')
  })

  it('does not repeat side effects for a duplicate webhook event', async () => {
    const repository = fakeRepository({ shouldProcess: false })
    const result = await processIncomingMessage(event('/expense Dinner 450', 'discord'), repository)
    expect(result.duplicate).toBe(true)
    expect(repository.created).toBeNull()
    expect(repository.completions).toEqual([])
  })

  it('marks leased events as failed when draft storage fails', async () => {
    const repository = fakeRepository({ createError: new Error('database unavailable') })
    await expect(processIncomingMessage(event('/expense Dinner 450', 'telegram'), repository)).rejects.toThrow('database unavailable')
    expect(repository.completions).toEqual([{ provider: 'telegram', eventId: 'event-1', success: false, groupId: 'group-1', error: 'database unavailable' }])
  })

  it('uses Taipei accounting date at the UTC boundary', () => {
    expect(dateInTimeZone(Date.parse('2026-08-28T16:30:00Z'), 'Asia/Taipei')).toBe('2026-08-29')
  })
})

type FakeOptions = {
  shouldProcess?: boolean
  conversation?: { groupId: string } | null
  identity?: { memberId: string; displayName: string } | null
  createError?: Error
}

function fakeRepository(options: FakeOptions = {}) {
  const state = {
    created: null as Record<string, unknown> | null,
    completions: [] as Array<Record<string, unknown>>,
    redeemedProvider: null as MessagingProvider | null,
    linkedProvider: null as MessagingProvider | null,
  }
  const repository: MessagingRepository & typeof state = Object.assign(state, {
    async beginEvent() { return options.shouldProcess ?? true },
    async completeEvent(provider: MessagingProvider, eventId: string, success: boolean, groupId: string | null, error?: string) {
      state.completions.push({ provider, eventId, success, groupId, error })
    },
    async redeemConversationCode(provider: MessagingProvider) {
      state.redeemedProvider = provider
      return { groupId: 'group-1', groupName: 'Trip' }
    },
    async redeemIdentityCode(provider: MessagingProvider) {
      state.linkedProvider = provider
      return { groupId: 'group-1', groupName: 'Trip', memberName: 'Alex' }
    },
    async findConversation() { return options.conversation === undefined ? { groupId: 'group-1' } : options.conversation },
    async findIdentity() { return options.identity === undefined ? { memberId: 'member-1', displayName: 'Alex' } : options.identity },
    async createDraft(input: Record<string, unknown>) {
      if (options.createError) throw options.createError
      state.created = input
      return { id: '12345678-0000-4000-8000-000000000001', groupId: 'group-1' }
    },
    async cancelDraftByMessage() { return 'group-1' },
  })
  return repository
}

function event(text: string, provider: MessagingProvider) {
  return {
    provider,
    eventId: 'event-1',
    messageId: 'message-1',
    conversationId: 'conversation-1',
    userId: 'user-1',
    userDisplayName: 'Alex',
    text,
    locale: provider === 'line' ? 'zh-TW' as const : 'en' as const,
    timestamp: Date.parse('2026-08-28T12:00:00Z'),
  }
}
