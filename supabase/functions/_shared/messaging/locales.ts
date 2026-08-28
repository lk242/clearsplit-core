import type { MessageLocale, MessagingProvider } from './types.ts'

type MessageKey =
  | 'help'
  | 'invalid'
  | 'conversationOnly'
  | 'bound'
  | 'invalidCode'
  | 'identityLinked'
  | 'conversationMissing'
  | 'identityMissing'
  | 'draftCreated'
  | 'alreadyProcessed'

type Variables = Record<string, string | number>

const messages: Record<MessageLocale, Record<MessageKey, string>> = {
  en: {
    help: 'ClearSplit creates reviewable public-fund drafts only.\n/bind CODE — connect this chat\n/link CODE — link your ledger identity\n/expense TITLE AMOUNT — create a draft',
    invalid: 'Invalid format. Use /help to see the supported commands.',
    conversationOnly: 'Run this command inside the group or channel you want to connect.',
    bound: 'Connected to “{groupName}”. Link each sender with /link CODE, then use /expense TITLE AMOUNT.',
    invalidCode: 'This code is invalid, expired, already used, or belongs to another provider.',
    identityLinked: 'Linked {memberName} to “{groupName}”. You can now create auditable drafts in its connected chat.',
    conversationMissing: 'This chat is not connected to a ClearSplit ledger. Ask the responsible member for a new bind code.',
    identityMissing: 'Your chat identity is not linked to a ledger member. Ask for a personal link code; no draft was created.',
    draftCreated: 'Draft created — not posted yet.\nItem: {title}\nAmount: {amount}\nReported by: {displayName}\nDraft: {draftId}\nThe responsible member must review it in ClearSplit.',
    alreadyProcessed: 'This event was already processed.',
  },
  'zh-TW': {
    help: 'ClearSplit Bot 只建立可核對的公帳草稿，不直接入帳。\n/bind 綁定碼 — 綁定群組\n/link 連結碼 — 連結帳本成員\n/expense 項目 金額 — 建立草稿',
    invalid: '指令格式不正確；輸入 /help 查看可用格式。',
    conversationOnly: '請在要綁定的群組或頻道中使用這個指令。',
    bound: '已綁定「{groupName}」。請讓每位回報者用 /link 連結碼完成身分連結，再用 /expense 項目 金額。',
    invalidCode: '綁定碼或連結碼無效、已過期、已使用，或不屬於目前通訊服務。',
    identityLinked: '已把 {memberName} 連結到「{groupName}」，現在可在已綁定的群組建立可稽核草稿。',
    conversationMissing: '這個群組尚未綁定 ClearSplit 帳本，請向帳務負責人索取新的綁定碼。',
    identityMissing: '找不到你的帳本成員身分，請向帳務負責人索取個人連結碼；草稿未建立。',
    draftCreated: '已建立待確認草稿（尚未入帳）\n項目：{title}\n金額：{amount}\n回報人：{displayName}\n草稿：{draftId}\n請由帳務負責人回 ClearSplit 核對後入帳。',
    alreadyProcessed: '這個事件已經處理過。',
  },
}

export function message(locale: MessageLocale, key: MessageKey, variables: Variables = {}) {
  return Object.entries(variables).reduce(
    (result, [name, value]) => result.replaceAll(`{${name}}`, String(value)),
    messages[locale][key],
  )
}

export function normalizeLocale(value: string | null | undefined, provider: MessagingProvider): MessageLocale {
  if (value?.toLowerCase().startsWith('zh')) return 'zh-TW'
  return provider === 'line' ? 'zh-TW' : 'en'
}

export function formatAmount(amount: number, locale: MessageLocale) {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(amount)
}
