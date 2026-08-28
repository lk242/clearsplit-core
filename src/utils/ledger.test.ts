import { describe, expect, it } from 'vitest'
import { defaultExpenses, defaultParticipants } from '../data'
import type { Expense, Participant } from '../types'
import { calculateExpenseLedgers, calculateMemberAccounts } from './ledger'

describe('calculateExpenseLedgers', () => {
  it('keeps every repayment attached to its original expense and payer', () => {
    const ledgers = calculateExpenseLedgers(defaultParticipants, defaultExpenses)

    expect(ledgers[0].shares.map((share) => ({ member: share.participant.name, amount: share.amount }))).toEqual([
      { member: '阿哲', amount: 620 },
      { member: '美玲', amount: 620 },
      { member: '小宇', amount: 620 },
    ])
    expect(ledgers[0].obligations.map((item) => ({ expense: item.expenseId, from: item.from.name, to: item.to.name, amount: item.amount }))).toEqual([
      { expense: 'expense-dinner', from: '美玲', to: '阿哲', amount: 620 },
      { expense: 'expense-dinner', from: '小宇', to: '阿哲', amount: 620 },
    ])
    expect(ledgers[1].obligations.map((item) => ({ expense: item.expenseId, from: item.from.name, to: item.to.name, amount: item.amount }))).toEqual([
      { expense: 'expense-taxi', from: '阿哲', to: '美玲', amount: 180 },
      { expense: 'expense-taxi', from: '小宇', to: '美玲', amount: 180 },
    ])
  })

  it('preserves money for every expense, including indivisible amounts', () => {
    const participants = [member('a', 'A'), member('b', 'B'), member('c', 'C')]
    const expense = record({ amount: 100, paidById: 'a', participantIds: ['a', 'b', 'c'] })
    const [ledger] = calculateExpenseLedgers(participants, [expense])

    expect(ledger.shares.map((share) => share.amount)).toEqual([34, 33, 33])
    expect(ledger.allocatedTotal).toBe(100)
    expect(ledger.obligations.map((item) => item.amount)).toEqual([33, 33])
    expect(ledger.isBalanced).toBe(true)
  })

  it('rejects malformed records instead of silently calculating them', () => {
    const participants = [member('a', 'A'), member('b', 'B')]
    const malformed = record({ amount: 10.5, paidById: 'missing', participantIds: ['a', 'a', 'unknown'] })
    const [ledger] = calculateExpenseLedgers(participants, [malformed])

    expect(ledger.isBalanced).toBe(false)
    expect(ledger.shares).toEqual([])
    expect(ledger.obligations).toEqual([])
    expect(ledger.issues).toEqual(['invalid_amount', 'missing_payer', 'duplicate_participant', 'unknown_participant'])
  })

  it('uses custom shares and preserves each receipt on the original expense', () => {
    const participants = [member('a', '牛'), member('b', '小美'), member('c', '小明')]
    const expense = record({
      amount: 240,
      paidById: 'a',
      participantIds: ['a', 'b', 'c'],
      splitMode: 'custom',
      shares: [
        { participantId: 'a', amount: 80, receivedAt: null },
        { participantId: 'b', amount: 100, paidAt: '2026-08-09T00:55:00Z', receivedAt: '2026-08-09T01:00:00Z' },
        { participantId: 'c', amount: 60, receivedAt: null },
      ],
    })
    const [ledger] = calculateExpenseLedgers(participants, [expense])

    expect(ledger.shares.map((share) => share.amount)).toEqual([80, 100, 60])
    expect(ledger.obligations.map((item) => ({ from: item.from.name, amount: item.amount, paidAt: item.paidAt, receivedAt: item.receivedAt }))).toEqual([
      { from: '小美', amount: 100, paidAt: '2026-08-09T00:55:00Z', receivedAt: '2026-08-09T01:00:00Z' },
      { from: '小明', amount: 60, paidAt: null, receivedAt: null },
    ])
  })

  it('rejects custom shares that do not equal the expense total', () => {
    const participants = [member('a', 'A'), member('b', 'B')]
    const expense = record({
      splitMode: 'custom',
      shares: [
        { participantId: 'a', amount: 40, receivedAt: null },
        { participantId: 'b', amount: 40, receivedAt: null },
      ],
    })

    expect(calculateExpenseLedgers(participants, [expense])[0].issues).toEqual(['unbalanced_shares'])
  })
})

describe('calculateMemberAccounts', () => {
  it('reports receivables and payables without cross-expense netting', () => {
    const accounts = calculateMemberAccounts(defaultParticipants, calculateExpenseLedgers(defaultParticipants, defaultExpenses))

    expect(accounts.map((account) => ({
      member: account.participant.name,
      advanced: account.advanced,
      ownShare: account.ownShare,
      receivable: account.receivable,
      payable: account.payable,
    }))).toEqual([
      { member: '阿哲', advanced: 1860, ownShare: 800, receivable: 1240, payable: 180 },
      { member: '美玲', advanced: 540, ownShare: 800, receivable: 360, payable: 620 },
      { member: '小宇', advanced: 0, ownShare: 800, receivable: 0, payable: 800 },
    ])
  })
})

function member(id: string, name: string): Participant {
  return { id, name, color: '#587561', createdAt: '2026-08-08T00:00:00.000Z' }
}

function record(overrides: Partial<Expense>): Expense {
  return {
    id: 'expense-test', title: 'Test', amount: 100, category: 'other', paidById: 'a',
    participantIds: ['a', 'b'], date: '2026-08-08', note: '', createdAt: '2026-08-08T00:00:00.000Z',
    ...overrides,
  }
}
