import type { Expense, Participant } from '../types'

export type LedgerIssue =
  | 'invalid_amount'
  | 'missing_payer'
  | 'no_participants'
  | 'duplicate_participant'
  | 'unknown_participant'
  | 'invalid_shares'
  | 'unbalanced_shares'

export type ExpenseShare = {
  participant: Participant
  amount: number
  isPayer: boolean
  paidAt: string | null
  receivedAt: string | null
}

export type ExpenseObligation = {
  expenseId: string
  expenseTitle: string
  expenseDate: string
  from: Participant
  to: Participant
  amount: number
  paidAt: string | null
  receivedAt: string | null
}

export type ExpenseLedger = {
  expense: Expense
  payer: Participant | null
  shares: ExpenseShare[]
  obligations: ExpenseObligation[]
  allocatedTotal: number
  issues: LedgerIssue[]
  isBalanced: boolean
}

export type MemberAccount = {
  participant: Participant
  advanced: number
  ownShare: number
  receivable: number
  payable: number
}

/**
 * Builds an independent ledger for every expense. Money is never netted across
 * expense IDs: each obligation always points back to its original expense.
 */
export function calculateExpenseLedgers(participants: Participant[], expenses: Expense[]): ExpenseLedger[] {
  const participantsById = new Map(participants.map((participant) => [participant.id, participant]))

  return expenses.map((expense) => {
    const issues = validateExpense(expense, participantsById)
    const payer = participantsById.get(expense.paidById) ?? null
    if (issues.length > 0 || !payer) return invalidLedger(expense, payer, issues)

    const splitParticipants = expense.participantIds.map((id) => participantsById.get(id) as Participant)
    const savedShares = expense.shares && expense.shares.length > 0
      ? new Map(expense.shares.map((share) => [share.participantId, share]))
      : null
    const baseShare = Math.floor(expense.amount / splitParticipants.length)
    const remainder = expense.amount % splitParticipants.length
    const shares = splitParticipants.map((participant, index) => ({
      participant,
      amount: savedShares?.get(participant.id)?.amount ?? baseShare + (index < remainder ? 1 : 0),
      isPayer: participant.id === payer.id,
      paidAt: savedShares?.get(participant.id)?.paidAt ?? null,
      receivedAt: savedShares?.get(participant.id)?.receivedAt ?? null,
    }))
    const obligations = shares
      .filter((share) => !share.isPayer && share.amount > 0)
      .map((share) => ({
        expenseId: expense.id,
        expenseTitle: expense.title,
        expenseDate: expense.date,
        from: share.participant,
        to: payer,
        amount: share.amount,
        paidAt: share.paidAt,
        receivedAt: share.receivedAt,
      }))
    const allocatedTotal = shares.reduce((sum, share) => sum + share.amount, 0)

    return {
      expense,
      payer,
      shares,
      obligations,
      allocatedTotal,
      issues: [],
      isBalanced: allocatedTotal === expense.amount,
    }
  })
}

export function calculateMemberAccounts(participants: Participant[], ledgers: ExpenseLedger[]): MemberAccount[] {
  const accounts = new Map(participants.map((participant) => [participant.id, {
    participant,
    advanced: 0,
    ownShare: 0,
    receivable: 0,
    payable: 0,
  }]))

  ledgers.filter((ledger) => ledger.isBalanced && ledger.issues.length === 0).forEach((ledger) => {
    if (ledger.payer) {
      const payerAccount = accounts.get(ledger.payer.id)
      if (payerAccount) payerAccount.advanced += ledger.expense.amount
    }
    ledger.shares.forEach((share) => {
      const account = accounts.get(share.participant.id)
      if (account) account.ownShare += share.amount
    })
    ledger.obligations.forEach((obligation) => {
      const fromAccount = accounts.get(obligation.from.id)
      const toAccount = accounts.get(obligation.to.id)
      if (fromAccount) fromAccount.payable += obligation.amount
      if (toAccount) toAccount.receivable += obligation.amount
    })
  })

  return [...accounts.values()]
}

function validateExpense(expense: Expense, participantsById: Map<string, Participant>): LedgerIssue[] {
  const issues: LedgerIssue[] = []
  if (!Number.isSafeInteger(expense.amount) || expense.amount <= 0) issues.push('invalid_amount')
  if (!participantsById.has(expense.paidById)) issues.push('missing_payer')
  if (expense.participantIds.length === 0) issues.push('no_participants')
  if (new Set(expense.participantIds).size !== expense.participantIds.length) issues.push('duplicate_participant')
  if (expense.participantIds.some((id) => !participantsById.has(id))) issues.push('unknown_participant')
  if (expense.shares !== undefined) {
    const shareIds = expense.shares.map((share) => share.participantId)
    if (expense.shares.length !== expense.participantIds.length
      || new Set(shareIds).size !== shareIds.length
      || shareIds.some((id) => !expense.participantIds.includes(id))
      || expense.shares.some((share) => !Number.isSafeInteger(share.amount) || share.amount < 0)) {
      issues.push('invalid_shares')
    } else if (expense.shares.reduce((sum, share) => sum + share.amount, 0) !== expense.amount) {
      issues.push('unbalanced_shares')
    }
  } else if (expense.splitMode === 'custom') {
    issues.push('invalid_shares')
  }
  return issues
}

function invalidLedger(expense: Expense, payer: Participant | null, issues: LedgerIssue[]): ExpenseLedger {
  return { expense, payer, shares: [], obligations: [], allocatedTotal: 0, issues, isBalanced: false }
}
