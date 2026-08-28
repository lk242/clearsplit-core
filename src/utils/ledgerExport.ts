import type { PortableLedgerBackup } from '../lib/cloudLedger'

export type LedgerExportFile = {
  fileName: string
  content: string
  type: string
}

export function downloadLedgerJson(backup: PortableLedgerBackup) {
  downloadLedgerFile(prepareLedgerJson(backup))
}

export function prepareLedgerJson(backup: PortableLedgerBackup): LedgerExportFile {
  return {
    fileName: `${backupFileStem(backup)}.json`,
    content: JSON.stringify(backup, null, 2),
    type: 'application/json;charset=utf-8',
  }
}

export function prepareLedgerCsv(backup: PortableLedgerBackup): LedgerExportFile {
  return {
    fileName: `${backupFileStem(backup)}-reconciliation.csv`,
    content: `\uFEFF${buildLedgerCsv(backup)}`,
    type: 'text/csv;charset=utf-8',
  }
}

export function downloadLedgerFile(file: LedgerExportFile) {
  downloadText(
    file.fileName,
    file.content,
    file.type,
  )
}

export function downloadLedgerCsv(backup: PortableLedgerBackup) {
  downloadLedgerFile(prepareLedgerCsv(backup))
}

export function supportsLedgerFileShare(file: LedgerExportFile) {
  if (typeof navigator === 'undefined' || typeof File === 'undefined'
    || typeof navigator.share !== 'function' || typeof navigator.canShare !== 'function') return false
  try {
    return navigator.canShare({ files: [toFile(file)] })
  } catch {
    return false
  }
}

export async function shareLedgerFile(file: LedgerExportFile) {
  if (!supportsLedgerFileShare(file)) return false
  await navigator.share({
    files: [toFile(file)],
    title: 'ClearSplit 帳本備份',
  })
  return true
}

export function buildLedgerCsv(backup: PortableLedgerBackup) {
  const rows: unknown[][] = [
    ['ClearSplit 對帳匯出', backup.ledger.name],
    ['帳本 ID', backup.ledger.id],
    ['匯出時間', backup.exportedAt],
    ['資料庫版本', backup.schemaVersion],
    [],
    ['核對項目', '結果'],
    ['整體守恆', backup.reconciliation.isHealthy ? '通過' : '異常'],
    ['私人帳分攤異常筆數', backup.reconciliation.invalidPrivateShareCount],
    ['私人帳狀態異常筆數', backup.reconciliation.invalidPrivateStatusCount],
    ['公費餘額差異', backup.reconciliation.fundBalanceDifference],
    ['公費分錄異常筆數', backup.reconciliation.invalidFundTransactionCount],
    [],
    ['成員 ID', '成員名稱', '帳務負責人'],
    ...backup.members.map((member) => [member.id, member.name, member.isResponsible ? '是' : '否']),
    [],
    ['私人帳目 ID', '日期', '項目', '總額', '付款人', '分攤成員', '分攤額', '付款確認時間', '收款確認時間', '狀態'],
  ]

  backup.privateExpenses.forEach((expense) => {
    const shares = Array.isArray(expense.shares) ? expense.shares.filter(isRecord) : []
    if (shares.length === 0) {
      rows.push([expense.id, expense.date, expense.title, expense.amount, expense.payerName, '', '', '', '', expense.status])
      return
    }
    shares.forEach((share) => rows.push([
      expense.id, expense.date, expense.title, expense.amount, expense.payerName,
      share.memberName, share.amount, share.paidAt, share.receivedAt, expense.status,
    ]))
  })

  rows.push([], ['公費交易 ID', '期別', '日期', '類型', '項目', '總額變動', '成員', '成員變動', '交易後淨部位'])
  const transactions = isRecord(backup.publicFund) && Array.isArray(backup.publicFund.transactions)
    ? backup.publicFund.transactions.filter(isRecord)
    : []
  transactions.forEach((transaction) => {
    const lines = Array.isArray(transaction.lines) ? transaction.lines.filter(isRecord) : []
    if (lines.length === 0) {
      rows.push([transaction.id, transaction.cycleNumber, transaction.effectiveDate, transaction.type, transaction.title, transaction.amountDelta, '', '', transaction.balanceAfter])
      return
    }
    lines.forEach((line) => rows.push([
      transaction.id, transaction.cycleNumber, transaction.effectiveDate, transaction.type,
      transaction.title, transaction.amountDelta, line.memberName, line.amountDelta,
      transaction.balanceAfter,
    ]))
  })

  return rows.map((row) => row.map(csvCell).join(',')).join('\r\n')
}

function csvCell(value: unknown) {
  let text = value === null || value === undefined ? '' : String(value)
  if (typeof value === 'string' && /^[=+\-@]/.test(text)) text = `'${text}`
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
}

function backupFileStem(backup: PortableLedgerBackup) {
  const normalizedName = backup.ledger.name.normalize('NFKC').replace(/[\\/:*?"<>|]/g, '-')
  const safeName = Array.from(normalizedName, (character) => character.charCodeAt(0) < 32 ? '-' : character).join('').trim().slice(0, 60) || 'ledger'
  return `clearsplit-${safeName}-${backup.exportedAt.slice(0, 10)}`
}

function downloadText(fileName: string, content: string, type: string) {
  const url = URL.createObjectURL(new Blob([content], { type }))
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = fileName
  anchor.rel = 'noopener'
  anchor.target = '_blank'
  document.body.append(anchor)
  anchor.click()
  anchor.remove()
  // iOS and LINE's in-app browser may start the navigation after the click
  // task finishes. Revoking immediately makes the download silently vanish.
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

function toFile(file: LedgerExportFile) {
  return new File([file.content], file.fileName, { type: file.type })
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
