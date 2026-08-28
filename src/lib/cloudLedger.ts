import type { CloudLedgerState, Expense, ExpenseCategory, LedgerDirectory, LedgerSummary, Participant } from '../types'
import { supabase } from './supabase'

export const REQUIRED_BACKEND_SCHEMA_VERSION = 48

let verifiedBackendUserId: string | null = null

type CloudMember = {
  id: string
  name: string
  color: string
  createdAt: string
  linked: boolean
  clientId?: string
}

type BootstrapResult = CloudLedgerState & {
  members: CloudMember[]
  setupToken?: string
  setupExpiresAt?: string
}

export type MessagingProvider = 'line' | 'discord' | 'telegram'

export type MessagingFundExpenseDraft = {
  id: string
  provider: MessagingProvider
  title: string
  amount: number
  submittedMemberId: string
  submittedDisplayName: string
  effectiveDate: string
  createdAt: string
}

export type DuplicateFundTransactionCandidate = {
  id: string
  title: string
  amount: number
  date: string
  cycleNumber: number
  reason: 'exact_match' | 'same_amount_date'
}

export type ConfirmMessagingFundDraftResult =
  | { status: 'confirmed'; transactionId: string; fund: GroupFund }
  | { status: 'duplicate'; candidate: DuplicateFundTransactionCandidate }

export type CloudLedgerAccess = {
  groupId: string
  groupName: string
  isOwner: boolean
  canSetup: boolean
  hasResponsibleMember: boolean
  responsibleMemberId: string | null
  currentMemberId: string | null
  setupExpiresAt: string | null
  memberCount: number
  expenseCount: number
}

export type FundAccount = {
  memberId: string
  name: string
  color: string
  avatarUrl: string | null
  balance: number
  contributedTotal: number
  consumedTotal: number
  refundedTotal: number
}

export type FundTransaction = {
  id: string
  cycleNumber: number
  type: 'opening' | 'contribution' | 'expense' | 'refund' | 'adjustment'
  title: string
  amountDelta: number
  balanceAfter: number
  effectiveDate: string
  note: string | null
  createdAt: string
  sourceMemberId: string | null
  sourceName: string | null
  sourceType: 'legacy' | 'web' | MessagingProvider
  lines: Array<{ memberId: string; amountDelta: number }>
}

export type FundSettlement = {
  memberId: string
  direction: 'top_up' | 'refund' | 'offset'
  amount: number
  cashAmount: number
  accountBalance: number
  accountTopUp: number
  accountRefund: number
  advanceAmount: number
  advanceOffsetAmount: number
  memberConfirmedAt: string | null
  responsibleConfirmedAt: string | null
  hasStaleConfirmation: boolean
}

export type FundAdvance = {
  id: string
  transactionId: string
  memberId: string
  memberName: string
  amount: number
  settledAmount: number
  remainingAmount: number
  recordedByMemberId: string | null
  recordedByName: string | null
  sourceType: 'legacy' | 'web' | MessagingProvider
  isOnBehalf: boolean
  status: 'open' | 'completed'
  memberConfirmedAt: string | null
  responsibleConfirmedAt: string | null
  completedAt: string | null
  createdAt: string
}

export type FundCollectionEntry = {
  memberId: string
  name: string
  color: string
  avatarUrl: string | null
  amount: number
  offsetAmount: number
  cashAmount: number
  offsets: Array<{
    id: string
    advanceId: string
    amount: number
    status: 'pending' | 'completed'
    completedAt: string | null
  }>
  status: 'pending' | 'completed'
  memberConfirmedAt: string | null
  responsibleConfirmedAt: string | null
  completedAt: string | null
}

export type FundCollectionRound = {
  id: string
  cycleNumber: number
  title: string
  amountPerMember: number
  effectiveDate: string
  status: 'open' | 'completed'
  createdAt: string
  completedAt: string | null
  entries: FundCollectionEntry[]
}

export type FundCollections = {
  currentMemberId: string
  rounds: FundCollectionRound[]
}

export type GroupFund =
  | { configured: false }
  | {
      configured: true
      balance: number
      netBalance: number
      version: number
      cycleNumber: number
      status: 'active' | 'closing' | 'closed'
      configuredAt: string
      closingStartedAt: string | null
      closedAt: string | null
      currentMemberId: string
      isOwner: boolean
      accounts: FundAccount[]
      advances: FundAdvance[]
      settlements: FundSettlement[]
      transactions: FundTransaction[]
    }

export type InvitePreview = CloudLedgerState & {
  expiresAt: string
  remainingUses: number
}

export type LineAppSession = {
  accessToken: string
  refreshToken: string
}

export type LineAccountProfile = {
  displayName: string
  avatarUrl: string | null
}

export type RestoredLineAccount = {
  directory: LedgerDirectory
  profile: LineAccountProfile
}

export async function ensureCloudSession() {
  const client = requireClient()
  const { data: sessionData, error: sessionError } = await client.auth.getSession()
  if (sessionError) throw sessionError
  if (sessionData.session) {
    await ensureBackendSchema(client, sessionData.session.user.id)
    return sessionData.session
  }

  const { data, error } = await client.auth.signInAnonymously()
  if (error) throw new Error(`無法建立安全訪客工作階段：${error.message}`)
  if (!data.session) throw new Error('Supabase 沒有回傳有效工作階段')
  await ensureBackendSchema(client, data.session.user.id)
  return data.session
}

export type LedgerReconciliation = {
  checkedAt: string
  isHealthy: boolean
  privateExpenseCount: number
  invalidPrivateShareCount: number
  invalidPrivateStatusCount: number
  openPrivateObligationCount: number
  fundConfigured: boolean
  fundBalance: number
  fundAccountTotal: number
  fundBalanceDifference: number
  invalidFundTransactionCount: number
  openAdvanceCount: number
  openCollectionCount: number
  pendingLineDraftCount: number
}

export type PortableLedgerBackup = {
  format: 'clearsplit-ledger-backup-v1'
  schemaVersion: number
  exportedAt: string
  ledger: { id: string; name: string }
  reconciliation: LedgerReconciliation
  members: Array<Record<string, unknown>>
  privateExpenses: Array<Record<string, unknown>>
  publicFund: Record<string, unknown> | null
  pendingLineFundDrafts: Array<Record<string, unknown>>
  auditTrail: Array<Record<string, unknown>>
}

async function ensureBackendSchema(client: NonNullable<typeof supabase>, userId: string) {
  if (verifiedBackendUserId === userId) return
  const { data, error } = await client.rpc('get_app_schema_version')
  if (error) {
    throw new Error(`資料庫版本無法確認；請先套用最新 Supabase migration：${error.message}`)
  }
  if (!Number.isSafeInteger(data) || data < REQUIRED_BACKEND_SCHEMA_VERSION) {
    throw new Error(`資料庫版本過舊（目前 ${String(data)}，需要 ${REQUIRED_BACKEND_SCHEMA_VERSION}）；請先更新 Supabase 再操作帳務`)
  }
  verifiedBackendUserId = userId
}

export async function bootstrapCloudLedger(groupName: string, participants: Participant[]) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('bootstrap_ledger_group', {
    p_group_name: groupName,
    p_participants: participants.map((participant) => ({
      clientId: participant.id,
      name: participant.name,
      color: participant.color,
    })),
  })
  if (error?.code === '42501') throw new Error('建立帳本前請先用 LINE 登入')
  if (error?.message?.includes('active owned ledger limit')) throw new Error('你已建立 5 本進行中的帳本；請先封存一本再建立')
  if (error?.message?.includes('total owned ledger limit')) throw new Error('你建立的帳本已達總上限 10 本')
  if (error) throw new Error(`無法建立雲端帳本：${error.message}`)
  return parseBootstrapResult(data)
}

export async function listCloudLedgers(): Promise<LedgerDirectory> {
  const client = requireClient()
  await ensureCloudSession()
  return loadLedgerDirectory(client)
}

async function loadLedgerDirectory(client: NonNullable<typeof supabase>): Promise<LedgerDirectory> {
  const { data, error } = await client.rpc('list_my_ledgers')
  if (error) throw new Error(`無法載入帳本清單：${error.message}`)
  return parseLedgerDirectory(data)
}

async function loadLineAccountProfile(client: NonNullable<typeof supabase>): Promise<LineAccountProfile | null> {
  const { data, error } = await client.rpc('get_my_line_profile')
  if (error) throw new Error(`無法載入 LINE 個人資料：${error.message}`)
  return parseLineAccountProfile(data)
}

export async function restorePersistedLineAccount(): Promise<RestoredLineAccount | null> {
  const client = requireClient()
  const { data: sessionData, error: sessionError } = await client.auth.getSession()
  if (sessionError) throw new Error(`無法讀取已儲存的登入狀態：${sessionError.message}`)
  if (!sessionData.session?.user || sessionData.session.user.user_metadata?.clearsplit_line_identity !== true) return null

  // getSession restores and refreshes the locally persisted token; getUser then
  // verifies it with Supabase before any ledger or profile data is accepted.
  const { data: userData, error: userError } = await client.auth.getUser()
  if (userError || !userData.user) throw new Error(`已儲存的登入狀態已失效：${userError?.message ?? '使用者不存在'}`)
  if (userData.user.user_metadata?.clearsplit_line_identity !== true) return null
  await ensureBackendSchema(client, userData.user.id)

  const [directory, profile] = await Promise.all([
    loadLedgerDirectory(client),
    loadLineAccountProfile(client),
  ])
  if (!profile) throw new Error('已登入帳號缺少驗證過的 LINE 個人資料')
  return { directory, profile }
}

export async function archiveCloudLedger(groupId: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { error } = await client.rpc('archive_ledger_group', { p_group_id: groupId })
  if (error?.message?.includes('private expenses')) throw new Error('仍有未完成的私人分帳，全部收付款確認後才能封存')
  if (error?.message?.includes('public fund')) throw new Error('公費尚未結清；請先完成收款、代墊與關帳')
  if (error?.message?.includes('LINE drafts')) throw new Error('仍有待確認的 LINE 記帳草稿，處理後才能封存')
  if (error) throw new Error(`無法封存帳本：${error.message}`)
}

export async function restoreArchivedCloudLedger(groupId: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { error } = await client.rpc('restore_archived_ledger', { p_group_id: groupId })
  if (error?.message?.includes('active owned ledger limit')) throw new Error('你已有 5 本進行中的帳本，請先封存一本')
  if (error) throw new Error(`無法恢復帳本：${error.message}`)
}

export async function recoverIncompleteLedgerSetup(): Promise<CloudLedgerState> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('recover_incomplete_ledger_setup')
  if (error?.code === '42501') {
    throw new Error('這個瀏覽器找不到由它建立的未完成帳本；請回原本開帳的瀏覽器操作')
  }
  if (error) throw new Error(`無法找回未完成帳本：${error.message}`)
  return parseRecoveredSetup(data)
}

export async function createCloudInvite(groupId: string, setupToken?: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('create_group_invite', {
    p_group_id: groupId,
    p_valid_hours: 168,
    p_max_uses: 50,
    p_setup_token: setupToken ?? null,
  })
  if (error) throw new Error(`無法產生邀請：${error.message}`)
  if (!isRecord(data) || typeof data.token !== 'string' || typeof data.expiresAt !== 'string') {
    throw new Error('邀請資料格式不正確')
  }
  return { token: data.token, expiresAt: data.expiresAt }
}

export async function createMessagingBindCode(groupId: string, provider: MessagingProvider) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('create_messaging_bind_code', { p_group_id: groupId, p_provider: provider })
  if (error) throw new Error(`無法產生通訊綁定碼：${error.message}`)
  if (!isRecord(data) || typeof data.code !== 'string' || typeof data.expiresAt !== 'string') {
    throw new Error('通訊綁定資料格式不正確')
  }
  return { command: bindCommand(provider, data.code), expiresAt: data.expiresAt, provider }
}

export async function createMessagingIdentityCode(groupId: string, memberId: string, provider: MessagingProvider) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('create_messaging_identity_code', {
    p_group_id: groupId,
    p_member_id: memberId,
    p_provider: provider,
  })
  if (error) throw new Error(`無法產生成員連結碼：${error.message}`)
  if (!isRecord(data) || typeof data.code !== 'string' || typeof data.expiresAt !== 'string') {
    throw new Error('成員連結資料格式不正確')
  }
  return { command: linkCommand(provider, data.code), expiresAt: data.expiresAt, provider }
}

export async function fetchLedgerReconciliation(groupId: string): Promise<LedgerReconciliation> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('get_ledger_reconciliation', { p_group_id: groupId })
  if (error) throw new Error(`無法執行帳務核對：${error.message}`)
  return parseLedgerReconciliation(data)
}

export async function exportPortableLedgerBackup(groupId: string): Promise<PortableLedgerBackup> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('export_ledger_backup', { p_group_id: groupId })
  if (error) throw new Error(`無法匯出帳本備份：${error.message}`)
  if (!isRecord(data) || data.format !== 'clearsplit-ledger-backup-v1'
    || typeof data.schemaVersion !== 'number' || typeof data.exportedAt !== 'string'
    || !isRecord(data.ledger) || typeof data.ledger.id !== 'string' || typeof data.ledger.name !== 'string'
    || !Array.isArray(data.members) || !Array.isArray(data.privateExpenses)
    || !(data.publicFund === null || isRecord(data.publicFund))
    || !Array.isArray(data.pendingLineFundDrafts) || !Array.isArray(data.auditTrail)) {
    throw new Error('帳本備份格式不正確')
  }
  return {
    format: data.format,
    schemaVersion: data.schemaVersion,
    exportedAt: data.exportedAt,
    ledger: { id: data.ledger.id, name: data.ledger.name },
    reconciliation: parseLedgerReconciliation(data.reconciliation),
    members: data.members.filter(isRecord),
    privateExpenses: data.privateExpenses.filter(isRecord),
    publicFund: data.publicFund,
    pendingLineFundDrafts: data.pendingLineFundDrafts.filter(isRecord),
    auditTrail: data.auditTrail.filter(isRecord),
  }
}

export async function fetchMessagingFundExpenseDrafts(groupId: string): Promise<MessagingFundExpenseDraft[]> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client
    .from('messaging_fund_expense_drafts')
    .select('id, provider, title, amount, submitted_member_id, submitted_display_name, effective_date, created_at')
    .eq('group_id', groupId)
    .eq('status', 'pending')
    .order('created_at', { ascending: false })
  if (error) throw new Error(`無法讀取通訊公帳草稿：${error.message}`)
  return (data ?? []).map((draft) => parseMessagingFundDraft(draft))
}

export async function confirmMessagingFundExpenseDraft(input: {
  draftId: string
  advanceMemberId?: string | null
  allowDuplicate?: boolean
}): Promise<ConfirmMessagingFundDraftResult> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('confirm_messaging_fund_expense_draft', {
    p_draft_id: input.draftId,
    p_advance_member_id: input.advanceMemberId ?? null,
    p_allow_duplicate: input.allowDuplicate ?? false,
  })
  if (error?.message.includes('fund advance member is required')) throw new Error('公費現金不足，請選擇本次先代墊的成員')
  if (error) throw new Error(`通訊公帳草稿無法入帳：${error.message}`)
  if (!isRecord(data) || (data.status !== 'confirmed' && data.status !== 'duplicate')) {
    throw new Error('通訊草稿入帳結果格式不正確')
  }
  if (data.status === 'duplicate') {
    return { status: 'duplicate', candidate: parseDuplicateFundTransactionCandidate(data.candidate) }
  }
  if (typeof data.transactionId !== 'string') throw new Error('通訊草稿入帳結果格式不正確')
  return { status: 'confirmed', transactionId: data.transactionId, fund: parseGroupFund(data.fund) }
}

export async function cancelMessagingFundExpenseDraft(draftId: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { error } = await client.rpc('cancel_messaging_fund_expense_draft', { p_draft_id: draftId })
  if (error) throw new Error(`通訊公帳草稿無法取消：${error.message}`)
}

export async function fetchCloudExpenses(groupId: string): Promise<Expense[]> {
  const client = requireClient()
  await ensureCloudSession()
  const [
    { data: expenseRows, error: expenseError },
    { data: shareRows, error: shareError },
    { data: receiptRows, error: receiptError },
    { data: editableRows, error: editableError },
  ] = await Promise.all([
    client
      .from('expenses')
      .select('id, title, amount, category, payer_member_id, split_mode, status, resolved_at, expense_date, note, version, created_at')
      .eq('group_id', groupId)
      .order('expense_date', { ascending: false })
      .order('created_at', { ascending: false }),
    client
      .from('expense_shares')
      .select('expense_id, member_id, amount, share_order')
      .eq('group_id', groupId)
      .order('share_order', { ascending: true }),
    client
      .from('expense_receipts')
      .select('expense_id, debtor_member_id, paid_at, received_at')
      .eq('group_id', groupId),
    client.rpc('get_editable_private_expense_ids', { p_group_id: groupId }),
  ])
  if (expenseError) throw new Error(`無法讀取雲端帳目：${expenseError.message}`)
  if (shareError) throw new Error(`無法讀取雲端分攤：${shareError.message}`)
  if (receiptError) throw new Error(`無法讀取收款狀態：${receiptError.message}`)
  if (editableError) throw new Error(`無法讀取帳目權限：${editableError.message}`)

  const receiptByShare = new Map<string, { paidAt: string | null; receivedAt: string | null }>()
  for (const receipt of receiptRows ?? []) {
    receiptByShare.set(`${receipt.expense_id}:${receipt.debtor_member_id}`, {
      paidAt: receipt.paid_at ?? null,
      receivedAt: receipt.received_at ?? null,
    })
  }
  const editableIds = new Set(Array.isArray(editableRows)
    ? editableRows.filter((id): id is string => typeof id === 'string')
    : [])
  const sharesByExpense = new Map<string, NonNullable<Expense['shares']>>()
  for (const share of shareRows ?? []) {
    const shares = sharesByExpense.get(share.expense_id) ?? []
    const confirmation = receiptByShare.get(`${share.expense_id}:${share.member_id}`)
    shares.push({
      participantId: share.member_id,
      amount: Number(share.amount),
      paidAt: confirmation?.paidAt ?? null,
      receivedAt: confirmation?.receivedAt ?? null,
    })
    sharesByExpense.set(share.expense_id, shares)
  }

  return (expenseRows ?? []).map((expense) => {
    const shares = sharesByExpense.get(expense.id) ?? []
    return {
      id: expense.id,
      title: expense.title,
      amount: Number(expense.amount),
      category: parseExpenseCategory(expense.category),
      paidById: expense.payer_member_id,
      participantIds: shares.map((share) => share.participantId),
      splitMode: expense.split_mode === 'custom' ? 'custom' : 'equal',
      shares,
      status: expense.status === 'resolved' ? 'resolved' : 'active',
      resolvedAt: expense.resolved_at ?? null,
      date: expense.expense_date,
      note: expense.note ?? '',
      createdAt: expense.created_at,
      version: Number(expense.version),
      canEdit: editableIds.has(expense.id),
    }
  })
}

export async function saveCloudExpense(groupId: string, expense: Expense): Promise<Expense> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('save_private_expense', {
    p_group_id: groupId,
    p_expense_id: expense.id,
    p_title: expense.title,
    p_amount: expense.amount,
    p_category: expense.category,
    p_payer_member_id: expense.paidById,
    p_shares: expense.participantIds.map((participantId) => ({
      participantId,
      amount: expense.shares?.find((share) => share.participantId === participantId)?.amount ?? 0,
    })),
    p_split_mode: expense.splitMode ?? 'equal',
    p_expense_date: expense.date,
    p_note: expense.note,
    p_expected_version: expense.version ?? null,
  })
  if (error?.code === '40001') throw new Error('這筆帳目已被其他裝置更新，請重新整理後再試')
  if (error) throw new Error(`無法儲存雲端帳目：${error.message}`)
  return parseExpenseResult(data, '雲端帳目儲存結果格式不正確')
}

export async function recordPrivateExpenseConfirmation(groupId: string, input: {
  expenseId: string
  debtorMemberId: string
  actorRole: 'debtor' | 'payer'
  confirm: boolean
}): Promise<Expense> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('record_private_expense_confirmation', {
    p_group_id: groupId,
    p_expense_id: input.expenseId,
    p_debtor_member_id: input.debtorMemberId,
    p_actor_role: input.actorRole,
    p_confirm: input.confirm,
  })
  if (error) throw new Error(`無法更新成員分帳確認：${error.message}`)
  return parseExpenseResult(data, '成員分帳確認結果格式不正確')
}

export async function deleteCloudExpense(groupId: string, expense: Expense) {
  const client = requireClient()
  await ensureCloudSession()
  const { error } = await client.rpc('delete_ledger_expense', {
    p_group_id: groupId,
    p_expense_id: expense.id,
    p_expected_version: expense.version ?? null,
  })
  if (error?.code === '40001') throw new Error('這筆帳目已被其他裝置更新或刪除，請重新整理後再試')
  if (error) throw new Error(`無法刪除雲端帳目：${error.message}`)
}

export async function fetchCloudLedgerAccess(groupId: string, setupToken?: string): Promise<CloudLedgerAccess> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('get_ledger_access', {
    p_group_id: groupId,
    p_setup_token: setupToken ?? null,
  })
  if (error) throw new Error(`無法讀取帳本權限：${error.message}`)
  if (!isRecord(data) || typeof data.groupId !== 'string' || typeof data.groupName !== 'string'
    || typeof data.isOwner !== 'boolean' || typeof data.canSetup !== 'boolean'
    || typeof data.hasResponsibleMember !== 'boolean'
    || !(data.responsibleMemberId === null || typeof data.responsibleMemberId === 'string')
    || !(data.currentMemberId === null || typeof data.currentMemberId === 'string')
    || !(data.setupExpiresAt === null || typeof data.setupExpiresAt === 'string')
    || typeof data.memberCount !== 'number'
    || typeof data.expenseCount !== 'number') {
    throw new Error('帳本權限資料格式不正確')
  }
  return data as CloudLedgerAccess
}

export async function deleteCloudLedger(groupId: string, confirmation: string, setupToken?: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('delete_ledger_group', {
    p_group_id: groupId,
    p_confirmation: confirmation,
    p_setup_token: setupToken ?? null,
  })
  if (error) throw new Error(`無法刪除整本帳本：${error.message}`)
  if (!isRecord(data) || typeof data.receiptId !== 'string' || typeof data.deletedGroupId !== 'string') {
    throw new Error('帳本刪除結果格式不正確')
  }
  return data
}

export async function fetchGroupFund(groupId: string): Promise<GroupFund> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('get_group_fund', { p_group_id: groupId })
  if (error) throw new Error(`無法讀取公費錢包：${error.message}`)
  return parseGroupFund(data)
}

export async function initializeGroupFund(groupId: string, openingBalance: number, effectiveDate: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('initialize_group_fund', {
    p_group_id: groupId,
    p_opening_balance: openingBalance,
    p_effective_date: effectiveDate,
  })
  if (error) throw new Error(`無法設定期初公費：${error.message}`)
  return parseGroupFund(data)
}

export async function recordGroupFundExpense(groupId: string, input: {
  title: string
  amount: number
  effectiveDate: string
  note: string
  advanceMemberId?: string | null
  useAvailableFund?: boolean
}) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('record_group_fund_expense_v3', {
    p_group_id: groupId,
    p_title: input.title,
    p_amount: input.amount,
    p_effective_date: input.effectiveDate,
    p_note: input.note,
    p_advance_member_id: input.advanceMemberId ?? null,
    p_use_available_fund: input.useAvailableFund ?? true,
    p_source_member_id: null,
    p_source_type: 'web',
  })
  if (error) throw new Error(`無法記錄公費支出：${error.message}`)
  return parseGroupFund(data)
}

export async function recordGroupFundContribution(groupId: string, input: { memberId: string; amount: number; effectiveDate: string; note: string }) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('record_group_fund_contribution', {
    p_group_id: groupId,
    p_member_id: input.memberId,
    p_amount: input.amount,
    p_effective_date: input.effectiveDate,
    p_note: input.note,
  })
  if (error) throw new Error(`無法記錄公費繳款：${error.message}`)
  return parseGroupFund(data)
}

export async function recordGroupFundSettlementConfirmation(groupId: string, input: { memberId: string; actorRole: 'member' | 'responsible'; confirm: boolean }) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('record_group_fund_settlement_confirmation', {
    p_group_id: groupId,
    p_member_id: input.memberId,
    p_actor_role: input.actorRole,
    p_confirm: input.confirm,
  })
  if (error?.message.includes('complete required top-ups first')) {
    throw new Error('目前公費不足以退款，請先完成所有應補款項')
  }
  if (error) throw new Error(`無法更新公費結清：${error.message}`)
  return parseGroupFund(data)
}

export async function startGroupFundCloseout(groupId: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('start_group_fund_closeout', { p_group_id: groupId })
  if (error?.message.includes('complete or cancel the open collection first')) {
    throw new Error('請先完成或取消目前的公費收款，再開始結清')
  }
  if (error) throw new Error(`無法開始公費結清：${error.message}`)
  return parseGroupFund(data)
}

export async function completeGroupFundCloseout(groupId: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('complete_group_fund_closeout', { p_group_id: groupId })
  if (error) throw new Error(`無法完成公費結清：${error.message}`)
  return parseGroupFund(data)
}

export async function startNextGroupFundCycle(groupId: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('start_next_group_fund_cycle', { p_group_id: groupId })
  if (error) throw new Error(`無法開始下一期公費：${error.message}`)
  return parseGroupFund(data)
}

export async function recordGroupFundAdvanceConfirmation(groupId: string, input: { advanceId: string; actorRole: 'member' | 'responsible'; confirm: boolean }) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('record_group_fund_advance_confirmation', {
    p_group_id: groupId,
    p_advance_id: input.advanceId,
    p_actor_role: input.actorRole,
    p_confirm: input.confirm,
  })
  if (error?.message.includes('cash is insufficient')) throw new Error('目前公費現金不足，請先完成必要補款再償還代墊')
  if (error) throw new Error(`無法更新公費代墊確認：${error.message}`)
  return parseGroupFund(data)
}

export async function reassignGroupFundAdvance(groupId: string, input: {
  advanceId: string
  expectedMemberId: string
  newMemberId: string
}) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('reassign_group_fund_advance', {
    p_group_id: groupId,
    p_advance_id: input.advanceId,
    p_expected_member_id: input.expectedMemberId,
    p_new_member_id: input.newMemberId,
  })
  if (error?.code === '40001') throw new Error('代墊資料已由其他人更新，請重新整理後再試一次')
  if (error?.message.includes('confirmed fund advance')) throw new Error('這筆代墊已有確認紀錄，不能再更換代墊人')
  if (error) throw new Error(`無法更正代墊人：${error.message}`)
  return parseGroupFund(data)
}

export async function fetchGroupFundCollections(groupId: string): Promise<FundCollections> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('get_group_fund_collections', { p_group_id: groupId })
  if (error) throw new Error(`無法讀取公費收款批次：${error.message}`)
  return parseFundCollections(data)
}

export async function createGroupFundCollectionRound(groupId: string, input: { title: string; amountPerMember: number; effectiveDate: string; applyAdvanceOffsets?: boolean }): Promise<FundCollections> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('create_group_fund_collection_round_v3', {
    p_group_id: groupId,
    p_title: input.title,
    p_amount_per_member: input.amountPerMember,
    p_effective_date: input.effectiveDate,
    p_apply_advance_offsets: input.applyAdvanceOffsets ?? true,
  })
  if (error?.code === '23505') throw new Error('目前已有進行中的公費收款，請完成或取消後再建立下一次')
  if (error) throw new Error(`無法建立公費收款：${error.message}`)
  return parseFundCollections(data)
}

export async function recordGroupFundCollectionConfirmation(groupId: string, input: { roundId: string; memberId: string; actorRole: 'member' | 'responsible'; confirm: boolean }): Promise<FundCollections> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('record_group_fund_collection_confirmation', {
    p_group_id: groupId,
    p_round_id: input.roundId,
    p_member_id: input.memberId,
    p_actor_role: input.actorRole,
    p_confirm: input.confirm,
  })
  if (error) throw new Error(`無法更新公費收款確認：${error.message}`)
  return parseFundCollections(data)
}

export async function cancelGroupFundCollectionRound(groupId: string, roundId: string): Promise<FundCollections> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('cancel_group_fund_collection_round', {
    p_group_id: groupId,
    p_round_id: roundId,
  })
  if (error?.message.includes('completed payments cannot be cancelled')) throw new Error('已有成員完成入帳，這次收款不能取消')
  if (error) throw new Error(`無法取消公費收款：${error.message}`)
  return parseFundCollections(data)
}

export async function previewCloudInvite(token: string): Promise<InvitePreview> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('preview_group_invite', { p_token: token })
  if (error) throw new Error('這個邀請已失效、額滿或不存在')
  if (!isRecord(data) || typeof data.groupId !== 'string' || typeof data.groupName !== 'string' || typeof data.expiresAt !== 'string' || typeof data.remainingUses !== 'number') {
    throw new Error('邀請資料格式不正確')
  }
  return data as InvitePreview
}

export async function joinCloudInvite(token: string, name: string, color: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('join_group_invite', {
    p_token: token,
    p_display_name: name,
    p_color: color,
  })
  if (error) throw new Error(`無法加入帳本：${error.message}`)
  if (!isRecord(data) || typeof data.groupId !== 'string' || typeof data.groupName !== 'string') {
    throw new Error('加入結果格式不正確')
  }
  const ledger: CloudLedgerState = { groupId: data.groupId, groupName: data.groupName }
  return { ledger, members: await fetchCloudMembers(ledger.groupId) }
}

export async function joinCloudInviteWithLine(token: string, lineAccessToken: string, color: string, handoffToken?: string | null) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.functions.invoke('line-member', {
    body: { action: 'join', inviteToken: token, lineAccessToken, color, handoffToken: handoffToken ?? undefined },
  })
  if (error) throw new Error(await readFunctionInvokeError(error, data, '無法使用 LINE 加入帳本'))
  await applyLineAppSession(client, data)
  const payload = isRecord(data) && isRecord(data.data) ? data.data : null
  if (!payload || typeof payload.groupId !== 'string' || typeof payload.groupName !== 'string') {
    throw new Error('LINE 加入結果格式不正確')
  }
  const ledger: CloudLedgerState = { groupId: payload.groupId, groupName: payload.groupName }
  return { ledger, members: await fetchCloudMembers(ledger.groupId) }
}

export type LineInviteMembershipStatus = {
  groupId: string
  groupName: string
  isMember: boolean
  isResponsible: boolean
  inviteAvailable: boolean
}

export async function fetchLineInviteMembershipStatus(token: string, lineAccessToken: string): Promise<LineInviteMembershipStatus> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.functions.invoke('line-member', {
    body: { action: 'status', inviteToken: token, lineAccessToken },
  })
  if (error) throw new Error(await readFunctionInvokeError(error, data, '無法確認 LINE 成員狀態'))
  const payload = isRecord(data) && isRecord(data.data) ? data.data : null
  return parseLineInviteMembershipStatus(payload)
}

export async function resumeCloudInviteWithLine(token: string, lineAccessToken: string, handoffToken?: string | null) {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.functions.invoke('line-member', {
    body: { action: 'resume', inviteToken: token, lineAccessToken, handoffToken: handoffToken ?? undefined },
  })
  if (error) throw new Error(await readFunctionInvokeError(error, data, '無法恢復 LINE 成員身分'))
  await applyLineAppSession(client, data)
  const payload = isRecord(data) && isRecord(data.data) ? data.data : null
  const membership = parseLineInviteMembershipStatus(payload)
  if (!membership.isMember) return { membership, ledger: null, members: [] as Participant[] }

  const ledger: CloudLedgerState = { groupId: membership.groupId, groupName: membership.groupName }
  return { membership, ledger, members: await fetchCloudMembers(ledger.groupId) }
}

export async function restoreCloudLedgerWithLine(lineAccessToken: string, handoffToken?: string | null): Promise<RestoredLineAccount> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.functions.invoke('line-member', {
    body: { action: 'restore', lineAccessToken, handoffToken: handoffToken ?? undefined },
  })
  if (error) throw new Error(await readFunctionInvokeError(error, data, '無法用 LINE 恢復正式頁帳本'))
  await applyLineAppSession(client, data)
  const payload = isRecord(data) && isRecord(data.data) ? data.data : null
  if (!payload || typeof payload.found !== 'boolean') throw new Error('LINE 帳本恢復資料格式不正確')
  const [directory, profile] = await Promise.all([
    listCloudLedgers(),
    loadLineAccountProfile(client),
  ])
  if (!profile) throw new Error('LINE 登入成功，但找不到驗證過的個人資料')
  return { directory, profile }
}

export async function exchangeLineAuthHandoff(handoffToken: string): Promise<RestoredLineAccount | null> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.functions.invoke('line-member', {
    body: { action: 'exchange', handoffToken },
  })
  if (error) throw new Error(await readFunctionInvokeError(error, data, '無法接回 LINE 登入狀態'))
  const payload = isRecord(data) && isRecord(data.data) ? data.data : null
  if (!payload || (payload.status !== 'pending' && payload.status !== 'ready')) {
    throw new Error('LINE 登入交接資料格式不正確')
  }
  if (payload.status === 'pending') return null
  await applyLineAppSession(client, data)
  const account = await restorePersistedLineAccount()
  if (!account) throw new Error('LINE 登入交接未建立有效帳務身分')
  return account
}

async function applyLineAppSession(client: NonNullable<typeof supabase>, response: unknown) {
  const session = parseLineAppSession(isRecord(response) ? response.session : null)
  if (!session) return
  const { error } = await client.auth.setSession({
    access_token: session.accessToken,
    refresh_token: session.refreshToken,
  })
  if (error) throw new Error(`無法套用 LINE 帳務登入：${error.message}`)
}

export function parseLineAppSession(value: unknown): LineAppSession | null {
  if (value === null || value === undefined) return null
  if (!isRecord(value) || typeof value.accessToken !== 'string' || value.accessToken.length < 20
    || typeof value.refreshToken !== 'string' || value.refreshToken.length < 8
    || value.accessToken.length > 8192 || value.refreshToken.length > 8192) {
    throw new Error('LINE 帳務登入資料格式不正確')
  }
  return { accessToken: value.accessToken, refreshToken: value.refreshToken }
}

export function parseLineAccountProfile(value: unknown): LineAccountProfile | null {
  if (value === null || value === undefined) return null
  if (!isRecord(value) || Object.keys(value).some((key) => key !== 'displayName' && key !== 'avatarUrl')
    || typeof value.displayName !== 'string'
    || value.displayName.trim().length < 1 || value.displayName.trim().length > 80
    || !(value.avatarUrl === null || (typeof value.avatarUrl === 'string'
      && value.avatarUrl.length <= 2048 && value.avatarUrl.startsWith('https://')))) {
    throw new Error('LINE 個人資料格式不正確')
  }
  return { displayName: value.displayName.trim(), avatarUrl: value.avatarUrl }
}

export function parseLineInviteMembershipStatus(value: unknown): LineInviteMembershipStatus {
  if (!isRecord(value) || typeof value.groupId !== 'string' || typeof value.groupName !== 'string'
    || typeof value.isMember !== 'boolean' || typeof value.isResponsible !== 'boolean'
    || typeof value.inviteAvailable !== 'boolean') {
    throw new Error('LINE 成員狀態資料格式不正確')
  }
  return value as LineInviteMembershipStatus
}

export async function fetchCloudMembers(groupId: string, setupToken?: string): Promise<Participant[]> {
  const client = requireClient()
  await ensureCloudSession()
  const { data, error } = await client.rpc('get_group_members', {
    p_group_id: groupId,
    p_setup_token: setupToken ?? null,
  })
  if (error) throw new Error(`無法同步成員：${error.message}`)
  return parseCloudMembers(data)
}

export function mergeJoinedLedgerAccess(current: CloudLedgerState | null, joined: CloudLedgerState): CloudLedgerState {
  if (current?.groupId !== joined.groupId || !current.setupToken) return joined
  return {
    ...joined,
    setupToken: current.setupToken,
    setupExpiresAt: current.setupExpiresAt,
  }
}

export function markResponsibleMember(participants: Participant[], memberId: string): Participant[] {
  return participants.map((participant) => ({
    ...participant,
    isResponsible: participant.id === memberId,
  }))
}

export function parseCloudMembers(data: unknown): Participant[] {
  if (!Array.isArray(data)) throw new Error('雲端成員資料格式不正確')
  return data.map((member) => {
    if (!isRecord(member) || typeof member.id !== 'string' || typeof member.name !== 'string'
      || typeof member.color !== 'string' || typeof member.createdAt !== 'string'
      || typeof member.isResponsible !== 'boolean'
      || !(member.avatarUrl === null || typeof member.avatarUrl === 'string')) {
      throw new Error('雲端成員資料格式不正確')
    }
    return {
      id: member.id,
      name: member.name,
      color: member.color,
      createdAt: member.createdAt,
      avatarUrl: member.avatarUrl,
      isResponsible: member.isResponsible,
    }
  })
}

export async function assignResponsibleMember(groupId: string, memberId: string, setupToken?: string) {
  const client = requireClient()
  await ensureCloudSession()
  const { error } = await client.rpc('assign_group_responsible_member', {
    p_group_id: groupId,
    p_member_id: memberId,
    p_setup_token: setupToken ?? null,
  })
  if (error) throw new Error(`無法指派帳務負責人：${error.message}`)
}

export async function persistCloudMemberChanges(groupId: string, current: Participant[], next: Participant[]) {
  const client = requireClient()
  await ensureCloudSession()
  const currentById = new Map(current.map((member) => [member.id, member]))
  const nextById = new Map(next.map((member) => [member.id, member]))
  const removedIds = current.filter((member) => !nextById.has(member.id)).map((member) => member.id)
  const added = next.filter((member) => !currentById.has(member.id))
  const changed = next.filter((member) => {
    const previous = currentById.get(member.id)
    return previous && (previous.name !== member.name || previous.color !== member.color)
  })

  if (removedIds.length > 0) {
    for (const memberId of removedIds) {
      const { error } = await client.rpc('remove_group_member', { p_group_id: groupId, p_member_id: memberId })
      if (error) throw new Error(`無法刪除雲端成員：${error.message}`)
    }
  }
  for (const member of changed) {
    const { error } = await client.rpc('update_group_member', {
      p_group_id: groupId, p_member_id: member.id, p_name: member.name, p_color: member.color,
    })
    if (error) throw new Error(`無法更新雲端成員：${error.message}`)
  }
  for (const member of added) {
    const { error } = await client.rpc('create_group_member', {
      p_group_id: groupId, p_member_id: member.id, p_name: member.name, p_color: member.color,
    })
    if (error) throw new Error(`無法新增雲端成員：${error.message}`)
  }
}

export function applyBootstrapMapping(participants: Participant[], expenses: Expense[], result: BootstrapResult) {
  const memberByClientId = new Map(result.members.map((member) => [member.clientId, member]))
  const idByClientId = new Map<string, string>()
  const mappedParticipants = participants.map((participant) => {
    const member = memberByClientId.get(participant.id)
    if (!member) throw new Error(`雲端回應缺少成員：${participant.name}`)
    idByClientId.set(participant.id, member.id)
    return { id: member.id, name: member.name, color: member.color, createdAt: member.createdAt }
  })
  const linkedParticipants = result.members
    .filter((member) => !member.clientId)
    .map((member) => ({
      id: member.id,
      name: member.name,
      color: member.color,
      createdAt: member.createdAt,
      isResponsible: true,
    }))
  const mappedExpenses = expenses.map((expense) => ({
    ...expense,
    id: isUuid(expense.id) ? expense.id : crypto.randomUUID(),
    paidById: requiredMappedId(idByClientId, expense.paidById),
    participantIds: expense.participantIds.map((id) => requiredMappedId(idByClientId, id)),
    shares: expense.shares?.map((share) => ({
      ...share,
      participantId: requiredMappedId(idByClientId, share.participantId),
    })),
  }))
  return { participants: [...linkedParticipants, ...mappedParticipants], expenses: mappedExpenses }
}

function parseBootstrapResult(data: unknown): BootstrapResult {
  if (!isRecord(data) || typeof data.groupId !== 'string' || typeof data.groupName !== 'string'
    || !Array.isArray(data.members)) {
    throw new Error('雲端帳本資料格式不正確')
  }
  const hasSetupToken = data.setupToken !== undefined
  const hasSetupExpiry = data.setupExpiresAt !== undefined
  if (hasSetupToken !== hasSetupExpiry
    || (hasSetupToken && (typeof data.setupToken !== 'string' || !/^[0-9a-f]{32}$/.test(data.setupToken)
      || typeof data.setupExpiresAt !== 'string'))) {
    throw new Error('雲端帳本資料格式不正確')
  }
  const members = data.members.map((member) => {
    if (!isRecord(member) || typeof member.id !== 'string' || typeof member.name !== 'string' || typeof member.color !== 'string' || typeof member.createdAt !== 'string') {
      throw new Error('雲端成員資料格式不正確')
    }
    return {
      id: member.id,
      name: member.name,
      color: member.color,
      createdAt: member.createdAt,
      linked: member.linked === true,
      clientId: typeof member.clientId === 'string' ? member.clientId : undefined,
    }
  })
  return {
    groupId: data.groupId,
    groupName: data.groupName,
    members,
    setupToken: typeof data.setupToken === 'string' ? data.setupToken : undefined,
    setupExpiresAt: typeof data.setupExpiresAt === 'string' ? data.setupExpiresAt : undefined,
  }
}

export function parseLedgerDirectory(data: unknown): LedgerDirectory {
  if (!isRecord(data) || !Array.isArray(data.ledgers) || !isRecord(data.usage) || !isRecord(data.limits)) {
    throw new Error('帳本清單資料格式不正確')
  }
  const ledgers = data.ledgers.map(parseLedgerSummary)
  if (new Set(ledgers.map((ledger) => ledger.groupId)).size !== ledgers.length) {
    throw new Error('帳本清單包含重複資料')
  }
  const usage = {
    activeOwned: parseQuotaNumber(data.usage.activeOwned),
    totalOwned: parseQuotaNumber(data.usage.totalOwned),
    activeJoined: parseQuotaNumber(data.usage.activeJoined),
  }
  const limits = {
    activeOwned: parseQuotaNumber(data.limits.activeOwned),
    totalOwned: parseQuotaNumber(data.limits.totalOwned),
    activeJoined: parseQuotaNumber(data.limits.activeJoined),
    membersPerLedger: parseQuotaNumber(data.limits.membersPerLedger),
  }
  if (usage.activeOwned > limits.activeOwned || usage.totalOwned > limits.totalOwned
    || usage.activeJoined > limits.activeJoined || usage.activeOwned > usage.totalOwned) {
    throw new Error('帳本配額資料不一致')
  }
  return { ledgers, usage, limits }
}

export function selectCloudLedger(directory: LedgerDirectory, preferredGroupId?: string | null): CloudLedgerState | null {
  const preferred = directory.ledgers.find((ledger) => ledger.groupId === preferredGroupId)
  const selected = preferred ?? directory.ledgers.find((ledger) => ledger.status === 'active') ?? directory.ledgers[0]
  return selected ? ledgerSummaryToState(selected) : null
}

export function ledgerSummaryToState(ledger: LedgerSummary): CloudLedgerState {
  return {
    groupId: ledger.groupId,
    groupName: ledger.groupName,
    status: ledger.status,
    archivedAt: ledger.archivedAt,
    isCreator: ledger.isCreator,
    isOwner: ledger.isOwner,
  }
}

function parseLedgerSummary(value: unknown): LedgerSummary {
  if (!isRecord(value) || typeof value.groupId !== 'string' || !isUuid(value.groupId)
    || typeof value.groupName !== 'string' || !value.groupName.trim()
    || (value.status !== 'active' && value.status !== 'archived')
    || !(value.archivedAt === null || typeof value.archivedAt === 'string')
    || typeof value.createdAt !== 'string' || typeof value.updatedAt !== 'string'
    || typeof value.isCreator !== 'boolean' || typeof value.isOwner !== 'boolean'
    || !(value.memberId === null || typeof value.memberId === 'string')) {
    throw new Error('帳本清單資料格式不正確')
  }
  return {
    groupId: value.groupId,
    groupName: value.groupName,
    status: value.status,
    archivedAt: value.archivedAt,
    createdAt: value.createdAt,
    updatedAt: value.updatedAt,
    isCreator: value.isCreator,
    isOwner: value.isOwner,
    memberId: value.memberId,
    memberCount: parseQuotaNumber(value.memberCount),
    expenseCount: parseQuotaNumber(value.expenseCount),
  }
}

function parseQuotaNumber(value: unknown) {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new Error('帳本配額資料格式不正確')
  }
  return value
}

export function parseRecoveredSetup(data: unknown): CloudLedgerState {
  if (!isRecord(data) || typeof data.groupId !== 'string' || !isUuid(data.groupId)
    || typeof data.groupName !== 'string' || !data.groupName.trim()
    || typeof data.setupToken !== 'string' || !/^[0-9a-f]{32}$/.test(data.setupToken)
    || typeof data.setupExpiresAt !== 'string') {
    throw new Error('找回的開帳資料格式不正確')
  }
  return {
    groupId: data.groupId,
    groupName: data.groupName,
    setupToken: data.setupToken,
    setupExpiresAt: data.setupExpiresAt,
  }
}

export function formatLedgerSetupKey(groupId: string, setupToken: string) {
  if (!isUuid(groupId) || !/^[0-9a-f]{32}$/.test(setupToken)) throw new Error('開帳設定碼格式不正確')
  return `${groupId}.${setupToken}`
}

export function parseLedgerSetupKey(value: string) {
  const [groupId, setupToken, extra] = value.trim().toLowerCase().split('.')
  if (extra !== undefined || !isUuid(groupId) || !/^[0-9a-f]{32}$/.test(setupToken ?? '')) {
    throw new Error('開帳設定碼格式不正確')
  }
  return { groupId, setupToken }
}

export async function restoreLedgerSetup(value: string) {
  const { groupId, setupToken } = parseLedgerSetupKey(value)
  const access = await fetchCloudLedgerAccess(groupId, setupToken)
  if (!access.canSetup || !access.setupExpiresAt) throw new Error('開帳設定碼已失效或已使用')
  const ledger: CloudLedgerState = {
    groupId,
    groupName: access.groupName,
    setupToken,
    setupExpiresAt: access.setupExpiresAt,
  }
  return { ledger, members: await fetchCloudMembers(groupId, setupToken) }
}

export function parseGroupFund(data: unknown): GroupFund {
  if (!isRecord(data) || typeof data.configured !== 'boolean') throw new Error('公費資料格式不正確')
  if (!data.configured) return { configured: false }
  if (typeof data.balance !== 'number' || typeof data.netBalance !== 'number'
    || typeof data.version !== 'number' || typeof data.cycleNumber !== 'number' || !Number.isSafeInteger(data.cycleNumber) || data.cycleNumber < 1 || typeof data.configuredAt !== 'string'
    || (data.status !== 'active' && data.status !== 'closing' && data.status !== 'closed')
    || !(data.closingStartedAt === null || typeof data.closingStartedAt === 'string')
    || !(data.closedAt === null || typeof data.closedAt === 'string')
    || typeof data.currentMemberId !== 'string' || typeof data.isOwner !== 'boolean'
    || !Array.isArray(data.accounts) || !Array.isArray(data.advances)
    || !Array.isArray(data.settlements) || !Array.isArray(data.transactions)) throw new Error('公費資料格式不完整')
  const accounts = data.accounts.map((value) => {
    if (!isRecord(value) || typeof value.memberId !== 'string' || typeof value.name !== 'string' || typeof value.color !== 'string'
      || typeof value.balance !== 'number' || typeof value.contributedTotal !== 'number' || typeof value.consumedTotal !== 'number'
      || typeof value.refundedTotal !== 'number') throw new Error('公費成員額度格式不正確')
    return {
      memberId: value.memberId,
      name: value.name,
      color: value.color,
      avatarUrl: typeof value.avatarUrl === 'string' ? value.avatarUrl : null,
      balance: value.balance,
      contributedTotal: value.contributedTotal,
      consumedTotal: value.consumedTotal,
      refundedTotal: value.refundedTotal,
    }
  })
  const transactions = data.transactions.map((value) => {
    if (!isRecord(value) || typeof value.id !== 'string' || typeof value.cycleNumber !== 'number' || !Number.isSafeInteger(value.cycleNumber) || value.cycleNumber < 1 || typeof value.type !== 'string' || typeof value.title !== 'string'
      || typeof value.amountDelta !== 'number' || typeof value.balanceAfter !== 'number' || typeof value.effectiveDate !== 'string'
      || typeof value.createdAt !== 'string'
      || !(value.sourceMemberId === null || typeof value.sourceMemberId === 'string')
      || !(value.sourceName === null || typeof value.sourceName === 'string')
      || (value.sourceType !== 'legacy' && value.sourceType !== 'web' && value.sourceType !== 'line' && value.sourceType !== 'discord' && value.sourceType !== 'telegram')
      || !Array.isArray(value.lines)) throw new Error('公費交易格式不正確')
    return {
      id: value.id,
      cycleNumber: value.cycleNumber,
      type: value.type as FundTransaction['type'],
      title: value.title,
      amountDelta: value.amountDelta,
      balanceAfter: value.balanceAfter,
      effectiveDate: value.effectiveDate,
      note: typeof value.note === 'string' ? value.note : null,
      createdAt: value.createdAt,
      sourceMemberId: value.sourceMemberId,
      sourceName: value.sourceName,
      sourceType: value.sourceType as FundTransaction['sourceType'],
      lines: value.lines.flatMap((line) => isRecord(line) && typeof line.memberId === 'string' && typeof line.amountDelta === 'number'
        ? [{ memberId: line.memberId, amountDelta: line.amountDelta }]
        : []),
    }
  })
  const settlements = data.settlements.map((value) => {
    if (!isRecord(value) || typeof value.memberId !== 'string'
      || (value.direction !== 'top_up' && value.direction !== 'refund' && value.direction !== 'offset')
      || typeof value.amount !== 'number'
      || typeof value.cashAmount !== 'number'
      || typeof value.accountBalance !== 'number'
      || typeof value.accountTopUp !== 'number'
      || typeof value.accountRefund !== 'number'
      || typeof value.advanceAmount !== 'number'
      || typeof value.advanceOffsetAmount !== 'number'
      || value.amount < 0 || value.cashAmount !== value.amount
      || value.accountTopUp !== Math.max(-value.accountBalance, 0)
      || value.accountRefund !== Math.max(value.accountBalance, 0)
      || value.advanceAmount < 0 || value.advanceOffsetAmount < 0
      || value.advanceOffsetAmount > value.advanceAmount
      || value.advanceOffsetAmount > value.accountTopUp
      || value.amount !== Math.abs(value.accountBalance + value.advanceAmount)
      || (value.direction === 'refund' && value.accountBalance + value.advanceAmount <= 0)
      || (value.direction === 'top_up' && value.accountBalance + value.advanceAmount >= 0)
      || (value.direction === 'offset' && value.accountBalance + value.advanceAmount !== 0)
      || !(value.memberConfirmedAt === null || typeof value.memberConfirmedAt === 'string')
      || !(value.responsibleConfirmedAt === null || typeof value.responsibleConfirmedAt === 'string')
      || typeof value.hasStaleConfirmation !== 'boolean') throw new Error('公費結清資料格式不正確')
    return {
      memberId: value.memberId,
      direction: value.direction as FundSettlement['direction'],
      amount: value.amount,
      cashAmount: value.cashAmount,
      accountBalance: value.accountBalance,
      accountTopUp: value.accountTopUp,
      accountRefund: value.accountRefund,
      advanceAmount: value.advanceAmount,
      advanceOffsetAmount: value.advanceOffsetAmount,
      memberConfirmedAt: value.memberConfirmedAt,
      responsibleConfirmedAt: value.responsibleConfirmedAt,
      hasStaleConfirmation: value.hasStaleConfirmation,
    }
  })
  const advances = data.advances.map((value) => {
    if (!isRecord(value) || typeof value.id !== 'string' || typeof value.transactionId !== 'string'
      || typeof value.memberId !== 'string' || typeof value.memberName !== 'string'
      || typeof value.amount !== 'number' || typeof value.settledAmount !== 'number'
      || typeof value.remainingAmount !== 'number'
      || !(value.recordedByMemberId === null || typeof value.recordedByMemberId === 'string')
      || !(value.recordedByName === null || typeof value.recordedByName === 'string')
      || (value.sourceType !== 'legacy' && value.sourceType !== 'web' && value.sourceType !== 'line' && value.sourceType !== 'discord' && value.sourceType !== 'telegram')
      || typeof value.isOnBehalf !== 'boolean'
      || value.settledAmount < 0 || value.remainingAmount < 0
      || value.settledAmount + value.remainingAmount !== value.amount
      || (value.status !== 'open' && value.status !== 'completed')
      || !(value.memberConfirmedAt === null || typeof value.memberConfirmedAt === 'string')
      || !(value.responsibleConfirmedAt === null || typeof value.responsibleConfirmedAt === 'string')
      || !(value.completedAt === null || typeof value.completedAt === 'string')
      || typeof value.createdAt !== 'string') throw new Error('公費代墊資料格式不正確')
    return {
      id: value.id,
      transactionId: value.transactionId,
      memberId: value.memberId,
      memberName: value.memberName,
      amount: value.amount,
      settledAmount: value.settledAmount,
      remainingAmount: value.remainingAmount,
      recordedByMemberId: value.recordedByMemberId,
      recordedByName: value.recordedByName,
      sourceType: value.sourceType as FundAdvance['sourceType'],
      isOnBehalf: value.isOnBehalf,
      status: value.status as FundAdvance['status'],
      memberConfirmedAt: value.memberConfirmedAt,
      responsibleConfirmedAt: value.responsibleConfirmedAt,
      completedAt: value.completedAt,
      createdAt: value.createdAt,
    }
  })
  return {
    configured: true,
    balance: data.balance,
    netBalance: data.netBalance,
    version: data.version,
    cycleNumber: data.cycleNumber,
    status: data.status,
    configuredAt: data.configuredAt,
    closingStartedAt: data.closingStartedAt,
    closedAt: data.closedAt,
    currentMemberId: data.currentMemberId,
    isOwner: data.isOwner,
    accounts,
    advances,
    settlements,
    transactions,
  }
}

export function parseFundCollections(data: unknown): FundCollections {
  if (!isRecord(data) || typeof data.currentMemberId !== 'string' || !Array.isArray(data.rounds)) {
    throw new Error('公費收款資料格式不正確')
  }
  const rounds = data.rounds.map((value) => {
    if (!isRecord(value) || typeof value.id !== 'string' || typeof value.cycleNumber !== 'number' || !Number.isSafeInteger(value.cycleNumber) || value.cycleNumber < 1 || typeof value.title !== 'string'
      || typeof value.amountPerMember !== 'number' || typeof value.effectiveDate !== 'string'
      || (value.status !== 'open' && value.status !== 'completed') || typeof value.createdAt !== 'string'
      || !(value.completedAt === null || typeof value.completedAt === 'string') || !Array.isArray(value.entries)) {
      throw new Error('公費收款批次格式不正確')
    }
    const entries = value.entries.map((entry) => {
      if (!isRecord(entry) || typeof entry.memberId !== 'string' || typeof entry.name !== 'string'
        || typeof entry.color !== 'string' || !(entry.avatarUrl === null || typeof entry.avatarUrl === 'string')
        || typeof entry.amount !== 'number' || typeof entry.offsetAmount !== 'number'
        || typeof entry.cashAmount !== 'number' || !Array.isArray(entry.offsets)
        || entry.offsetAmount < 0 || entry.cashAmount < 0
        || entry.offsetAmount + entry.cashAmount !== entry.amount
        || (entry.status !== 'pending' && entry.status !== 'completed')
        || !(entry.memberConfirmedAt === null || typeof entry.memberConfirmedAt === 'string')
        || !(entry.responsibleConfirmedAt === null || typeof entry.responsibleConfirmedAt === 'string')
        || !(entry.completedAt === null || typeof entry.completedAt === 'string')) {
        throw new Error('公費收款成員格式不正確')
      }
      const offsets = entry.offsets.map((offset) => {
        if (!isRecord(offset) || typeof offset.id !== 'string'
          || typeof offset.advanceId !== 'string' || typeof offset.amount !== 'number'
          || offset.amount <= 0 || (offset.status !== 'pending' && offset.status !== 'completed')
          || !(offset.completedAt === null || typeof offset.completedAt === 'string')) {
          throw new Error('公費收款折抵格式不正確')
        }
        return {
          id: offset.id,
          advanceId: offset.advanceId,
          amount: offset.amount,
          status: offset.status as 'pending' | 'completed',
          completedAt: offset.completedAt,
        }
      })
      if (offsets.reduce((sum, offset) => sum + offset.amount, 0) !== entry.offsetAmount) {
        throw new Error('公費收款折抵金額不守恆')
      }
      return {
        memberId: entry.memberId,
        name: entry.name,
        color: entry.color,
        avatarUrl: entry.avatarUrl,
        amount: entry.amount,
        offsetAmount: entry.offsetAmount,
        cashAmount: entry.cashAmount,
        offsets,
        status: entry.status as FundCollectionEntry['status'],
        memberConfirmedAt: entry.memberConfirmedAt,
        responsibleConfirmedAt: entry.responsibleConfirmedAt,
        completedAt: entry.completedAt,
      }
    })
    return {
      id: value.id,
      cycleNumber: value.cycleNumber,
      title: value.title,
      amountPerMember: value.amountPerMember,
      effectiveDate: value.effectiveDate,
      status: value.status as FundCollectionRound['status'],
      createdAt: value.createdAt,
      completedAt: value.completedAt,
      entries,
    }
  })
  return { currentMemberId: data.currentMemberId, rounds }
}

function requiredMappedId(mapping: Map<string, string>, id: string) {
  const mappedId = mapping.get(id)
  if (!mappedId) throw new Error(`帳目引用未知成員：${id}`)
  return mappedId
}

function parseExpenseResult(data: unknown, errorMessage: string): Expense {
  if (!isRecord(data) || typeof data.id !== 'string' || typeof data.title !== 'string'
    || typeof data.amount !== 'number' || typeof data.category !== 'string'
    || typeof data.paidById !== 'string' || !Array.isArray(data.participantIds)
    || typeof data.date !== 'string' || typeof data.createdAt !== 'string'
    || typeof data.version !== 'number') {
    throw new Error(errorMessage)
  }
  const participantIds = data.participantIds.filter((id): id is string => typeof id === 'string')
  const shares = Array.isArray(data.shares)
    ? data.shares.flatMap((value) => isRecord(value) && typeof value.participantId === 'string'
      && typeof value.amount === 'number'
      && (value.paidAt === null || typeof value.paidAt === 'string')
      && (value.receivedAt === null || typeof value.receivedAt === 'string')
      ? [{ participantId: value.participantId, amount: value.amount, paidAt: value.paidAt, receivedAt: value.receivedAt }]
      : [])
    : allocateEqualExpenseShares(data.amount, participantIds)
  if (shares.length !== participantIds.length) throw new Error(errorMessage)
  return {
    id: data.id,
    title: data.title,
    amount: data.amount,
    category: parseExpenseCategory(data.category),
    paidById: data.paidById,
    participantIds,
    splitMode: data.splitMode === 'custom' ? 'custom' : 'equal',
    shares,
    status: data.status === 'resolved' ? 'resolved' : 'active',
    resolvedAt: typeof data.resolvedAt === 'string' ? data.resolvedAt : null,
    date: data.date,
    note: typeof data.note === 'string' ? data.note : '',
    createdAt: data.createdAt,
    version: data.version,
    canEdit: typeof data.canEdit === 'boolean' ? data.canEdit : undefined,
  }
}

function allocateEqualExpenseShares(total: number, participantIds: string[]) {
  if (participantIds.length === 0) return []
  const base = Math.floor(total / participantIds.length)
  const remainder = total % participantIds.length
  return participantIds.map((participantId, index) => ({
    participantId,
    amount: base + (index < remainder ? 1 : 0),
    paidAt: null,
    receivedAt: null,
  }))
}

function bindCommand(provider: MessagingProvider, code: string) {
  return provider === 'line' ? `#綁定 ${code}` : provider === 'discord' ? `/clearsplit bind code:${code}` : `/bind ${code}`
}

function linkCommand(provider: MessagingProvider, code: string) {
  return provider === 'line' ? `#連結 ${code}` : provider === 'discord' ? `/clearsplit link code:${code}` : `/link ${code}`
}

function parseMessagingFundDraft(data: unknown): MessagingFundExpenseDraft {
  if (!isRecord(data) || typeof data.id !== 'string' || typeof data.title !== 'string'
    || (data.provider !== 'line' && data.provider !== 'discord' && data.provider !== 'telegram')
    || typeof data.amount !== 'number' || !Number.isSafeInteger(data.amount) || data.amount <= 0
    || typeof data.submitted_member_id !== 'string' || typeof data.submitted_display_name !== 'string'
    || typeof data.effective_date !== 'string' || typeof data.created_at !== 'string') {
    throw new Error('通訊公帳草稿格式不正確')
  }
  return {
    id: data.id,
    provider: data.provider,
    title: data.title,
    amount: data.amount,
    submittedMemberId: data.submitted_member_id,
    submittedDisplayName: data.submitted_display_name,
    effectiveDate: data.effective_date,
    createdAt: data.created_at,
  }
}

function parseDuplicateFundTransactionCandidate(data: unknown): DuplicateFundTransactionCandidate {
  if (!isRecord(data) || typeof data.id !== 'string' || typeof data.title !== 'string'
    || typeof data.amount !== 'number' || typeof data.date !== 'string'
    || typeof data.cycleNumber !== 'number' || !Number.isSafeInteger(data.cycleNumber) || data.cycleNumber < 1
    || (data.reason !== 'exact_match' && data.reason !== 'same_amount_date')) {
    throw new Error('通訊草稿重複候選資料格式不正確')
  }
  return {
    id: data.id,
    title: data.title,
    amount: data.amount,
    date: data.date,
    cycleNumber: data.cycleNumber,
    reason: data.reason,
  }
}

function parseLedgerReconciliation(data: unknown): LedgerReconciliation {
  const numericKeys = [
    'privateExpenseCount', 'invalidPrivateShareCount', 'invalidPrivateStatusCount',
    'openPrivateObligationCount', 'fundBalance', 'fundAccountTotal',
    'fundBalanceDifference', 'invalidFundTransactionCount', 'openAdvanceCount',
    'openCollectionCount', 'pendingLineDraftCount',
  ] as const
  if (!isRecord(data) || typeof data.checkedAt !== 'string' || typeof data.isHealthy !== 'boolean'
    || typeof data.fundConfigured !== 'boolean'
    || numericKeys.some((key) => typeof data[key] !== 'number' || !Number.isSafeInteger(data[key]))) {
    throw new Error('帳務核對結果格式不正確')
  }
  return {
    checkedAt: data.checkedAt,
    isHealthy: data.isHealthy,
    privateExpenseCount: data.privateExpenseCount as number,
    invalidPrivateShareCount: data.invalidPrivateShareCount as number,
    invalidPrivateStatusCount: data.invalidPrivateStatusCount as number,
    openPrivateObligationCount: data.openPrivateObligationCount as number,
    fundConfigured: data.fundConfigured,
    fundBalance: data.fundBalance as number,
    fundAccountTotal: data.fundAccountTotal as number,
    fundBalanceDifference: data.fundBalanceDifference as number,
    invalidFundTransactionCount: data.invalidFundTransactionCount as number,
    openAdvanceCount: data.openAdvanceCount as number,
    openCollectionCount: data.openCollectionCount as number,
    pendingLineDraftCount: data.pendingLineDraftCount as number,
  }
}

function parseExpenseCategory(value: string): ExpenseCategory {
  if (value === 'food' || value === 'transport' || value === 'shopping' || value === 'other') return value
  return 'other'
}

function isUuid(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

function requireClient() {
  if (!supabase) throw new Error('這個部署尚未設定 Supabase')
  return supabase
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function readFunctionError(data: unknown) {
  return isRecord(data) && typeof data.error === 'string' ? data.error : null
}

async function readFunctionInvokeError(error: unknown, data: unknown, fallback: string) {
  const directMessage = readFunctionError(data)
  if (directMessage) return directMessage

  if (isRecord(error) && isRecord(error.context) && typeof error.context.json === 'function') {
    try {
      const responseBody = await error.context.json()
      const responseMessage = readFunctionError(responseBody)
      if (responseMessage) return responseMessage
    } catch {
      // The function response is not always JSON (for example, a gateway failure).
    }
  }

  return `${fallback}：${error instanceof Error ? error.message : '未知錯誤'}`
}
