import { describe, expect, it } from 'vitest'
import type { PortableLedgerBackup } from '../lib/cloudLedger'
import { buildLedgerCsv, prepareLedgerCsv, prepareLedgerJson } from './ledgerExport'

const backup: PortableLedgerBackup = {
  format: 'clearsplit-ledger-backup-v1',
  schemaVersion: 30,
  exportedAt: '2026-08-09T12:00:00Z',
  ledger: { id: 'ledger-1', name: '白海豚' },
  reconciliation: {
    checkedAt: '2026-08-09T12:00:00Z', isHealthy: true,
    privateExpenseCount: 1, invalidPrivateShareCount: 0, invalidPrivateStatusCount: 0,
    openPrivateObligationCount: 1, fundConfigured: true, fundBalance: 100,
    fundAccountTotal: 100, fundBalanceDifference: 0, invalidFundTransactionCount: 0,
    openAdvanceCount: 0, openCollectionCount: 0, pendingLineDraftCount: 0,
  },
  members: [{ id: 'member-a', name: '=HYPERLINK("bad")', isResponsible: true }],
  privateExpenses: [{
    id: 'expense-1', date: '2026-08-09', title: '晚餐', amount: 300, payerName: '牛', status: 'active',
    shares: [{ memberName: '美玲', amount: 100, paidAt: null, receivedAt: null }],
  }],
  publicFund: { transactions: [{
    id: 'tx-1', cycleNumber: 2, effectiveDate: '2026-08-09', type: 'expense', title: '門票',
    amountDelta: -300, balanceAfter: 100, lines: [{ memberName: '牛', amountDelta: -100 }],
  }] },
  pendingLineFundDrafts: [],
  auditTrail: [],
}

describe('buildLedgerCsv', () => {
  it('prepares durable JSON and CSV files before browser delivery', () => {
    const json = prepareLedgerJson(backup)
    const csv = prepareLedgerCsv(backup)

    expect(json.fileName).toMatch(/^clearsplit-.+-2026-08-09\.json$/)
    expect(json.type).toBe('application/json;charset=utf-8')
    expect(JSON.parse(json.content)).toEqual(backup)
    expect(csv.fileName).toMatch(/^clearsplit-.+-2026-08-09-reconciliation\.csv$/)
    expect(csv.type).toBe('text/csv;charset=utf-8')
    expect(csv.content.startsWith('\uFEFF')).toBe(true)
  })

  it('exports private shares and public-fund journal lines without changing amounts', () => {
    const csv = buildLedgerCsv(backup)
    expect(csv).toContain('expense-1,2026-08-09,晚餐,300,牛,美玲,100')
    expect(csv).toContain('tx-1,2,2026-08-09,expense,門票,-300,牛,-100,100')
  })

  it('neutralizes spreadsheet formulas in user-controlled text', () => {
    expect(buildLedgerCsv(backup)).toContain("member-a,\"'=HYPERLINK(\"\"bad\"\")\",是")
  })
})
