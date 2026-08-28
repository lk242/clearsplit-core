export type Participant = {
  id: string
  name: string
  color: string
  createdAt: string
  avatarUrl?: string | null
  isResponsible?: boolean
}

export type ExpenseCategory = 'food' | 'transport' | 'shopping' | 'other'

export type ExpenseSplitMode = 'equal' | 'custom'

export type ExpenseStatus = 'active' | 'resolved'

export type ExpenseShare = {
  participantId: string
  amount: number
  paidAt?: string | null
  receivedAt: string | null
}

export type Expense = {
  id: string
  title: string
  amount: number
  category: ExpenseCategory
  paidById: string
  participantIds: string[]
  splitMode?: ExpenseSplitMode
  shares?: ExpenseShare[]
  status?: ExpenseStatus
  resolvedAt?: string | null
  date: string
  note: string
  createdAt: string
  version?: number
  canEdit?: boolean
}

export type Theme = 'light' | 'dark'

export type TextScale = 'normal' | 'large' | 'xlarge'

export type LedgerStatus = 'active' | 'archived'

export type CloudLedgerState = {
  groupId: string
  groupName: string
  status?: LedgerStatus
  archivedAt?: string | null
  isCreator?: boolean
  isOwner?: boolean
  setupToken?: string
  setupExpiresAt?: string
}

export type LedgerSummary = {
  groupId: string
  groupName: string
  status: LedgerStatus
  archivedAt: string | null
  createdAt: string
  updatedAt: string
  isCreator: boolean
  isOwner: boolean
  memberId: string | null
  memberCount: number
  expenseCount: number
}

export type LedgerQuota = {
  activeOwned: number
  totalOwned: number
  activeJoined: number
  membersPerLedger: number
}

export type LedgerDirectory = {
  ledgers: LedgerSummary[]
  usage: Omit<LedgerQuota, 'membersPerLedger'>
  limits: LedgerQuota
}

export type LedgerHandoffReceipt = {
  groupId: string
  groupName: string
  responsibleMemberId: string
  responsibleMemberName: string
  completedAt: string
}
