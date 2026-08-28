export type LineCommand =
  | { kind: 'bind'; code: string }
  | { kind: 'fund_expense'; title: string; amount: number }
  | { kind: 'ignore' }
  | { kind: 'invalid'; help: string }

const help = 'ClearSplit Bot 只記錄公帳支出（不記私人代墊）。\n格式：#記帳 項目 金額\n例如：#記帳 晚餐 400'

export function parseLineCommand(input: string): LineCommand {
  const text = normalizeLineText(input)
  if (text.startsWith('#綁定')) {
    const match = text.match(/^#綁定 ([0-9a-f]{32})$/i)
    return match ? { kind: 'bind', code: match[1].toLowerCase() } : { kind: 'invalid', help: '格式：#綁定 32位綁定碼' }
  }
  if (!text.startsWith('#記帳')) return { kind: 'ignore' }

  const match = text.match(/^#記帳 (.+?) (?:NT\$|NTD|\$)?([1-9]\d{0,2}(?:,?\d{3})*|[1-9]\d{0,8})(?:元)?$/i)
  if (!match) return { kind: 'invalid', help }
  const amount = Number(match[2].replace(/,/g, ''))
  const title = match[1].trim()
  if (!Number.isSafeInteger(amount) || amount <= 0 || amount > 999999999 || title.length < 1 || title.length > 120) {
    return { kind: 'invalid', help }
  }
  return { kind: 'fund_expense', title, amount }
}

function normalizeLineText(input: string) {
  return input
    .trim()
    .replace(/^[＃﹟]/, '#')
    .replace(/\s+/g, ' ')
}
