import type { MessagingCommand } from './types.ts'

const codePattern = '[0-9a-f]{32}'
const amountPattern = '(?:NT\\$|NTD|TWD|USD|\\$)?([1-9]\\d{0,2}(?:,?\\d{3})*|[1-9]\\d{0,8})(?:元)?'

export function parseMessagingCommand(input: string): MessagingCommand {
  const text = normalizeText(input)
  if (!text) return { kind: 'ignore' }
  if (/^(?:help|\/help|#說明)$/i.test(text)) return { kind: 'help' }

  const bind = text.match(new RegExp(`^(?:bind|/bind|#綁定) (${codePattern})$`, 'i'))
  if (bind) return { kind: 'bind', code: bind[1].toLowerCase() }
  if (/^(?:bind|\/bind|#綁定)(?: |$)/i.test(text)) return { kind: 'invalid' }

  const link = text.match(new RegExp(`^(?:link|/link|#連結) (${codePattern})$`, 'i'))
  if (link) return { kind: 'link', code: link[1].toLowerCase() }
  if (/^(?:link|\/link|#連結)(?: |$)/i.test(text)) return { kind: 'invalid' }

  const expense = text.match(new RegExp(`^(?:expense|/expense|#記帳) (.+?) ${amountPattern}$`, 'i'))
  if (expense) {
    const title = expense[1].trim()
    const amount = Number(expense[2].replace(/,/g, ''))
    if (title.length <= 120 && Number.isSafeInteger(amount) && amount > 0 && amount <= 999_999_999) {
      return { kind: 'fund_expense', title, amount }
    }
  }
  if (/^(?:expense|\/expense|#記帳)(?: |$)/i.test(text)) return { kind: 'invalid' }
  return { kind: 'ignore' }
}

function normalizeText(input: string) {
  return input
    .trim()
    .replace(/^[＃﹟]/, '#')
    .replace(/^\/(bind|link|expense|help)@[a-z0-9_]+/i, '/$1')
    .replace(/\s+/g, ' ')
}
