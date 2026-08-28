export const messagingProviders = ['line', 'discord', 'telegram'] as const

export type MessagingProvider = typeof messagingProviders[number]
export type MessageLocale = 'en' | 'zh-TW'

export type IncomingMessage = {
  provider: MessagingProvider
  eventId: string
  messageId: string
  conversationId: string
  userId: string
  userDisplayName: string
  text: string
  locale: MessageLocale
  timestamp: number
}

export type DeleteMessage = Pick<IncomingMessage, 'provider' | 'eventId' | 'messageId'>

export type FundExpenseCommand = {
  kind: 'fund_expense'
  title: string
  amount: number
}

export type MessagingCommand =
  | { kind: 'bind'; code: string }
  | { kind: 'link'; code: string }
  | FundExpenseCommand
  | { kind: 'help' }
  | { kind: 'ignore' }
  | { kind: 'invalid' }

export type MessagingDraft = {
  id: string
  groupId: string
}

export type MessagingRepository = {
  beginEvent(provider: MessagingProvider, eventId: string, messageId: string): Promise<boolean>
  completeEvent(provider: MessagingProvider, eventId: string, success: boolean, groupId: string | null, error?: string): Promise<void>
  redeemConversationCode(provider: MessagingProvider, code: string, conversationId: string, userId: string): Promise<{ groupId: string; groupName: string } | null>
  redeemIdentityCode(provider: MessagingProvider, code: string, userId: string, displayName: string): Promise<{ groupId: string; groupName: string; memberName: string } | null>
  findConversation(provider: MessagingProvider, conversationId: string): Promise<{ groupId: string } | null>
  findIdentity(provider: MessagingProvider, groupId: string, userId: string): Promise<{ memberId: string; displayName: string } | null>
  createDraft(input: {
    provider: MessagingProvider
    eventId: string
    messageId: string
    conversationId: string
    userId: string
    groupId: string
    memberId: string
    displayName: string
    rawText: string
    title: string
    amount: number
    effectiveDate: string
  }): Promise<MessagingDraft>
  cancelDraftByMessage(provider: MessagingProvider, messageId: string): Promise<string | null>
}

export type ProcessingResult = {
  groupId: string | null
  reply: string | null
  duplicate?: boolean
}
