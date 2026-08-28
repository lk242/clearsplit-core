import type { CloudLedgerState, Expense, ExpenseCategory, LedgerHandoffReceipt, Participant, TextScale, Theme } from '../types'

const expenseCategories = new Set<ExpenseCategory>(['food', 'transport', 'shopping', 'other'])

export function isParticipantArray(value: unknown): value is Participant[] {
  if (!Array.isArray(value) || !value.every(isParticipant)) return false
  return new Set(value.map((participant) => participant.id)).size === value.length
}

export function isExpenseArray(value: unknown): value is Expense[] {
  if (!Array.isArray(value) || !value.every(isExpense)) return false
  return new Set(value.map((expense) => expense.id)).size === value.length
}

export function isTheme(value: unknown): value is Theme {
  return value === 'light' || value === 'dark'
}

export function isTextScale(value: unknown): value is TextScale {
  return value === 'normal' || value === 'large' || value === 'xlarge'
}

export function isCloudLedgerState(value: unknown): value is CloudLedgerState {
  if (!isRecord(value)) return false
  if (!isUuid(value.groupId) || !nonEmptyString(value.groupName)) return false
  if (value.status !== undefined && value.status !== 'active' && value.status !== 'archived') return false
  if (value.archivedAt !== undefined && value.archivedAt !== null && typeof value.archivedAt !== 'string') return false
  if (value.isCreator !== undefined && typeof value.isCreator !== 'boolean') return false
  if (value.isOwner !== undefined && typeof value.isOwner !== 'boolean') return false
  const hasSetupToken = value.setupToken !== undefined
  const hasSetupExpiry = value.setupExpiresAt !== undefined
  if (hasSetupToken !== hasSetupExpiry) return false
  if (!hasSetupToken) return true
  return typeof value.setupToken === 'string'
    && /^[0-9a-f]{32}$/.test(value.setupToken)
    && nonEmptyString(value.setupExpiresAt)
}

export function isLedgerHandoffReceipt(value: unknown): value is LedgerHandoffReceipt {
  return isRecord(value)
    && isUuid(value.groupId)
    && nonEmptyString(value.groupName)
    && nonEmptyString(value.responsibleMemberId)
    && nonEmptyString(value.responsibleMemberName)
    && nonEmptyString(value.completedAt)
}

function isUuid(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

function isParticipant(value: unknown): value is Participant {
  if (!isRecord(value)) return false
  return nonEmptyString(value.id) && nonEmptyString(value.name) && nonEmptyString(value.color) && typeof value.createdAt === 'string'
}

function isExpense(value: unknown): value is Expense {
  if (!isRecord(value)) return false
  return nonEmptyString(value.id)
    && nonEmptyString(value.title)
    && typeof value.amount === 'number'
    && Number.isFinite(value.amount)
    && typeof value.category === 'string'
    && expenseCategories.has(value.category as ExpenseCategory)
    && nonEmptyString(value.paidById)
    && Array.isArray(value.participantIds)
    && value.participantIds.every(nonEmptyString)
    && (value.splitMode === undefined || value.splitMode === 'equal' || value.splitMode === 'custom')
    && (value.status === undefined || value.status === 'active' || value.status === 'resolved')
    && (value.resolvedAt === undefined || value.resolvedAt === null || typeof value.resolvedAt === 'string')
    && (value.shares === undefined || (Array.isArray(value.shares) && value.shares.every((share) => isRecord(share)
      && nonEmptyString(share.participantId)
      && typeof share.amount === 'number'
      && Number.isSafeInteger(share.amount)
      && share.amount >= 0
      && (share.paidAt === undefined || share.paidAt === null || typeof share.paidAt === 'string')
      && (share.receivedAt === null || typeof share.receivedAt === 'string'))))
    && typeof value.date === 'string'
    && typeof value.note === 'string'
    && typeof value.createdAt === 'string'
    && (value.version === undefined || (typeof value.version === 'number' && Number.isSafeInteger(value.version) && value.version > 0))
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}
