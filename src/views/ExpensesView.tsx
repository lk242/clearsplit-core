import { useEffect, useState, type FormEvent } from 'react'
import { Avatar } from '../components/Avatar'
import { Icon, type IconName } from '../components/Icon'
import { Modal } from '../components/Modal'
import type { CloudLedgerState, Expense, ExpenseCategory, ExpenseSplitMode, Participant } from '../types'
import { formatCurrency, formatDate } from '../utils/format'
import { calculateExpenseLedgers, type ExpenseLedger } from '../utils/ledger'
import './ExpensesView.css'

type ExpensesViewProps = {
  expenses: Expense[]
  participants: Participant[]
  formOpen: boolean
  editingExpense: Expense | null
  onOpenCreate: () => void
  onOpenEdit: (expense: Expense) => void
  onCloseForm: () => void
  onSaveExpense: (expense: Expense) => Promise<void>
  onDeleteExpense: (expense: Expense) => Promise<void>
  cloudLedger: CloudLedgerState | null
  readOnly?: boolean
}

const categories: Array<{ id: ExpenseCategory; label: string; icon: IconName }> = [
  { id: 'food', label: '餐飲', icon: 'utensils' },
  { id: 'transport', label: '交通', icon: 'car' },
  { id: 'shopping', label: '購物', icon: 'shopping-bag' },
  { id: 'other', label: '其他', icon: 'dots' },
]

const MAX_EXPENSE_AMOUNT = 99_999_999

export function ExpensesView({ expenses, participants, formOpen, editingExpense, onOpenCreate, onOpenEdit, onCloseForm, onSaveExpense, onDeleteExpense, cloudLedger, readOnly = false }: ExpensesViewProps) {
  const [deleteTarget, setDeleteTarget] = useState<Expense | null>(null)
  const [detailTarget, setDetailTarget] = useState<Expense | null>(null)
  const [deleteBusy, setDeleteBusy] = useState(false)
  const [deleteError, setDeleteError] = useState('')
  const sortedExpenses = [...expenses].sort((a, b) => b.date.localeCompare(a.date) || b.createdAt.localeCompare(a.createdAt))
  const total = expenses.reduce((sum, expense) => sum + expense.amount, 0)
  const ledgersByExpenseId = new Map(calculateExpenseLedgers(participants, expenses).map((ledger) => [ledger.expense.id, ledger]))

  const saveExpense = async (expense: Expense) => {
    await onSaveExpense(expense)
    onCloseForm()
  }

  const deleteExpense = async () => {
    if (!deleteTarget) return
    setDeleteBusy(true)
    setDeleteError('')
    try {
      await onDeleteExpense(deleteTarget)
      setDeleteTarget(null)
    } catch (error) {
      setDeleteError(error instanceof Error ? error.message : '無法刪除帳目')
    } finally {
      setDeleteBusy(false)
    }
  }

  if (participants.length === 0) {
    return (
      <section className="empty-state large">
        <span className="empty-icon"><Icon name="users" size={30} /></span>
        <strong>先新增參與成員</strong>
        <p>帳目需要至少一位付款與分攤成員，請先到成員頁建立名單。</p>
      </section>
    )
  }

  return (
    <>
      <section className="expense-summary-strip">
        <div><span>累計支出</span><strong>{formatCurrency(total)}</strong></div>
        <span className="expense-count">{expenses.length} 筆</span>
        {!readOnly && <button className="secondary-button" type="button" onClick={onOpenCreate}><Icon name="plus" size={18} /> 新增</button>}
      </section>

      {sortedExpenses.length > 0 ? (
        <section className="expense-list" aria-label="帳目清單">
          {sortedExpenses.map((expense) => {
            const payer = participants.find((participant) => participant.id === expense.paidById)
            const category = categories.find((item) => item.id === expense.category) ?? categories[3]
            const canEdit = !readOnly && (!cloudLedger || expense.canEdit === true)
            return (
              <article className="expense-row" key={expense.id}>
                <span className={`category-icon category-${expense.category}`}><Icon name={category.icon} size={20} /></span>
                <div className="expense-main">
                  <div className="expense-title-line"><strong>{expense.title}</strong><strong>{formatCurrency(expense.amount)}</strong></div>
                  <div className="expense-detail-line">
                    <span>{formatDate(expense.date)}</span>
                    <span className="detail-dot" />
                    <span>{payer?.name ?? '未知成員'}先付</span>
                    <span className="detail-dot" />
                    <span>{expense.participantIds.length} 人分攤</span>
                  </div>
                  <div className="expense-footer">
                    <div className="avatar-stack compact-stack">
                      {expense.participantIds.slice(0, 4).map((id) => {
                        const participant = participants.find((item) => item.id === id)
                        return participant ? <Avatar key={id} participant={participant} size="small" /> : null
                      })}
                    </div>
                    <div className="row-actions">
                      <button className="row-icon-button detail" type="button" aria-label={`查看帳目 ${expense.title} 分攤明細`} onClick={() => setDetailTarget(expense)}><Icon name="users" size={16} /></button>
                      {canEdit ? <>
                        <button className="row-icon-button" type="button" aria-label={`編輯帳目 ${expense.title}`} onClick={() => onOpenEdit(expense)}><Icon name="pencil" size={16} /></button>
                        <button className="row-icon-button danger" type="button" aria-label={`刪除帳目 ${expense.title}`} onClick={() => setDeleteTarget(expense)}><Icon name="trash" size={16} /></button>
                      </> : <span className="expense-readonly-label">僅檢視</span>}
                    </div>
                  </div>
                </div>
              </article>
            )
          })}
        </section>
      ) : (
        <section className="empty-state large">
          <span className="empty-icon"><Icon name="receipt" size={30} /></span>
          <strong>記下第一筆支出</strong>
          <p>選擇誰先付款、誰要分攤，公帳就會自動整理。</p>
          {!readOnly && <button className="primary-button" type="button" onClick={onOpenCreate}><Icon name="plus" size={18} /> 新增帳目</button>}
        </section>
      )}

      <ExpenseForm open={formOpen && !readOnly} expense={editingExpense} participants={participants} onClose={onCloseForm} onSave={saveExpense} />

      <ExpenseDetailModal ledger={detailTarget ? ledgersByExpenseId.get(detailTarget.id) ?? null : null} onClose={() => setDetailTarget(null)} />

      <Modal open={deleteTarget !== null} title="刪除這筆帳目？" description="刪除後，相關收支與結算會一併更新。" onClose={() => setDeleteTarget(null)} compact>
        {deleteTarget && (
          <div className="delete-expense-preview">
            <span>{deleteTarget.title}</span>
            <strong>{formatCurrency(deleteTarget.amount)}</strong>
          </div>
        )}
        {deleteError && <div className="form-error" role="alert"><Icon name="alert-circle" size={17} />{deleteError}</div>}
        <div className="modal-actions">
          <button className="secondary-button grow" type="button" disabled={deleteBusy} onClick={() => setDeleteTarget(null)}>保留</button>
          <button className="danger-button grow" type="button" disabled={deleteBusy} onClick={() => void deleteExpense()}>{deleteBusy ? '刪除中…' : '刪除'}</button>
        </div>
      </Modal>
    </>
  )
}

function ExpenseDetailModal({ ledger, onClose }: { ledger: ExpenseLedger | null; onClose: () => void }) {
  return (
    <Modal open={ledger !== null} title="逐人分攤明細" description="每一份金額都綁定這筆原始帳目，不與其他帳目抵銷。" onClose={onClose}>
      {ledger && (
        <div className="expense-detail-sheet">
          <section className="detail-summary-card">
            <div><span>{ledger.expense.title}</span><strong>{formatCurrency(ledger.expense.amount)}</strong></div>
            <dl>
              <div><dt>日期</dt><dd>{formatDate(ledger.expense.date)}</dd></div>
              <div><dt>原付款人</dt><dd>{ledger.payer?.name ?? '資料異常'}</dd></div>
              <div><dt>帳目編號</dt><dd>{ledger.expense.id}</dd></div>
            </dl>
          </section>

          {ledger.isBalanced ? (
            <>
              <section>
                <div className="detail-section-title"><span>每人份額</span><small>{ledger.shares.length} 人</small></div>
                <div className="share-detail-list">
                  {ledger.shares.map((share) => (
                    <div className="share-detail-row" key={share.participant.id}>
                      <Avatar participant={share.participant} size="medium" />
                      <div><strong>{share.participant.name}</strong><span>{share.isPayer ? '付款人本人負擔' : `應付給 ${ledger.payer?.name}`}</span></div>
                      <strong>{formatCurrency(share.amount)}</strong>
                    </div>
                  ))}
                </div>
              </section>
              <div className="detail-integrity-check"><span><Icon name="check" size={17} /></span><div><strong>金額核對正確</strong><small>份額合計 {formatCurrency(ledger.allocatedTotal)} ＝ 原始金額 {formatCurrency(ledger.expense.amount)}</small></div></div>
            </>
          ) : (
            <div className="detail-integrity-check is-error"><span><Icon name="alert-circle" size={17} /></span><div><strong>這筆帳目未通過核對</strong><small>請編輯帳目，修正付款人、金額或分攤成員。</small></div></div>
          )}
        </div>
      )}
    </Modal>
  )
}

function ExpenseForm({ open, expense, participants, onClose, onSave }: { open: boolean; expense: Expense | null; participants: Participant[]; onClose: () => void; onSave: (expense: Expense) => Promise<void> }) {
  const [title, setTitle] = useState('')
  const [amount, setAmount] = useState('')
  const [category, setCategory] = useState<ExpenseCategory>('food')
  const [paidById, setPaidById] = useState('')
  const [participantIds, setParticipantIds] = useState<string[]>([])
  const [splitMode, setSplitMode] = useState<ExpenseSplitMode>('equal')
  const [customAmounts, setCustomAmounts] = useState<Record<string, string>>({})
  const [date, setDate] = useState(todayAsInputValue)
  const [note, setNote] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (!open) return
    setTitle(expense?.title ?? '')
    setAmount(expense ? String(expense.amount) : '')
    setCategory(expense?.category ?? 'food')
    setPaidById(expense?.paidById ?? participants[0]?.id ?? '')
    setParticipantIds(expense?.participantIds ?? participants.map((participant) => participant.id))
    setSplitMode(expense?.splitMode ?? 'equal')
    setCustomAmounts(Object.fromEntries((expense?.shares ?? []).map((share) => [share.participantId, String(share.amount)])))
    setDate(expense?.date ?? todayAsInputValue())
    setNote(expense?.note ?? '')
    setError('')
  }, [expense, open, participants])

  const toggleParticipant = (id: string) => {
    setParticipantIds((selected) => selected.includes(id) ? selected.filter((item) => item !== id) : [...selected, id])
    setError('')
  }

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    const numericAmount = Number(amount)
    if (!title.trim()) return setError('請輸入帳目名稱')
    if (!Number.isSafeInteger(numericAmount) || numericAmount <= 0) return setError('金額必須是大於 0 的整數')
    if (numericAmount > MAX_EXPENSE_AMOUNT) return setError(`單筆金額不可超過 ${formatCurrency(MAX_EXPENSE_AMOUNT)}`)
    if (!participants.some((participant) => participant.id === paidById)) return setError('請選擇有效的付款人')
    if (participantIds.length === 0) return setError('請至少選擇一位分攤成員')
    if (new Set(participantIds).size !== participantIds.length) return setError('分攤名單不可包含重複成員')
    if (participantIds.some((id) => !participants.some((participant) => participant.id === id))) return setError('分攤名單包含不存在的成員')
    if (!isValidDate(date)) return setError('請選擇有效日期')
    const shares = splitMode === 'custom'
      ? participantIds.map((participantId) => ({ participantId, amount: Number(customAmounts[participantId]), receivedAt: null }))
      : allocateEqualShares(numericAmount, participantIds)
    if (splitMode === 'custom' && shares.some((share) => !Number.isSafeInteger(share.amount) || share.amount < 0)) {
      return setError('每位成員的自訂份額必須是 0 或正整數')
    }
    if (shares.reduce((sum, share) => sum + share.amount, 0) !== numericAmount) {
      return setError(`自訂份額合計必須等於 ${formatCurrency(numericAmount)}`)
    }
    if (expense?.shares?.some((share) => share.paidAt || share.receivedAt)
      && !window.confirm('這筆帳已有付款或收款確認。修改金額、付款人或分攤後，所有確認都會失效並重新核對，確定繼續？')) return

    setBusy(true)
    try {
      await onSave({
        id: expense?.id ?? createId(),
        title: title.trim(),
        amount: numericAmount,
        category,
        paidById,
        participantIds,
        splitMode,
        shares,
        status: 'active',
        resolvedAt: null,
        date,
        note: note.trim(),
        createdAt: expense?.createdAt ?? new Date().toISOString(),
        version: expense?.version,
      })
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : '無法儲存帳目')
    } finally {
      setBusy(false)
    }
  }

  const allSelected = participantIds.length === participants.length
  const previewAmount = Number(amount)
  const previewLedger = Number.isSafeInteger(previewAmount) && previewAmount > 0 && paidById && participantIds.length > 0
    ? calculateExpenseLedgers(participants, [{
        id: expense?.id ?? 'expense-preview',
        title: title.trim() || '分攤預覽',
        amount: previewAmount,
        category,
        paidById,
        participantIds,
        splitMode,
        shares: splitMode === 'custom'
          ? participantIds.map((participantId) => ({ participantId, amount: Number(customAmounts[participantId]), receivedAt: null }))
          : allocateEqualShares(previewAmount, participantIds),
        status: 'active',
        resolvedAt: null,
        date: date || todayAsInputValue(),
        note: '',
        createdAt: expense?.createdAt ?? new Date().toISOString(),
      }])[0]
    : null

  return (
    <Modal open={open} title={expense ? '編輯帳目' : '新增帳目'} description="記下誰先付款，以及這筆費用由誰一起分攤。" onClose={onClose}>
      <form className="expense-form" onSubmit={(event) => void submit(event)} noValidate>
        <div className="form-grid two-columns">
          <div className="form-field">
            <label className="field-label" htmlFor="expense-title">帳目名稱</label>
            <input id="expense-title" className="text-input" value={title} onChange={(event) => { setTitle(event.target.value); setError('') }} placeholder="例如：週末聚餐" maxLength={40} autoFocus />
          </div>
          <div className="form-field amount-field">
            <label className="field-label" htmlFor="expense-amount">金額</label>
            <span className="input-prefix">NT$</span>
            <input id="expense-amount" className="text-input" type="number" inputMode="numeric" min="1" max={MAX_EXPENSE_AMOUNT} step="1" value={amount} onChange={(event) => { setAmount(event.target.value); setError('') }} placeholder="0" />
          </div>
        </div>

        <fieldset className="expense-fieldset">
          <legend>類別</legend>
          <div className="category-options">
            {categories.map((option) => (
              <button key={option.id} type="button" className={category === option.id ? 'category-option is-selected' : 'category-option'} onClick={() => setCategory(option.id)} aria-pressed={category === option.id}>
                <Icon name={option.icon} size={18} /><span>{option.label}</span>
              </button>
            ))}
          </div>
        </fieldset>

        <fieldset className="expense-fieldset">
          <legend>誰先付款？</legend>
          <div className="member-options">
            {participants.map((participant) => (
              <button key={participant.id} type="button" className={paidById === participant.id ? 'member-option is-selected' : 'member-option'} onClick={() => { setPaidById(participant.id); setError('') }} aria-pressed={paidById === participant.id}>
                <Avatar participant={participant} size="medium" /><span>{participant.name}</span>{paidById === participant.id && <Icon name="check" size={16} />}
              </button>
            ))}
          </div>
        </fieldset>

        <fieldset className="expense-fieldset">
          <div className="legend-row"><legend>誰要分攤？</legend><button type="button" onClick={() => setParticipantIds(allSelected ? [] : participants.map((participant) => participant.id))}>{allSelected ? '取消全選' : '全部選取'}</button></div>
          <div className="split-options">
            {participants.map((participant) => {
              const selected = participantIds.includes(participant.id)
              return (
                <button key={participant.id} type="button" className={selected ? 'split-option is-selected' : 'split-option'} onClick={() => toggleParticipant(participant.id)} aria-pressed={selected}>
                  <Avatar participant={participant} size="medium" />
                  <span>{participant.name}</span>
                  <span className="check-box">{selected && <Icon name="check" size={15} />}</span>
                </button>
              )
            })}
          </div>
        </fieldset>

        <fieldset className="expense-fieldset">
          <legend>分攤方式</legend>
          <div className="split-mode-control" role="group" aria-label="分攤方式">
            <button type="button" className={splitMode === 'equal' ? 'is-selected' : ''} aria-pressed={splitMode === 'equal'} onClick={() => { setSplitMode('equal'); setError('') }}>平均分攤</button>
            <button type="button" className={splitMode === 'custom' ? 'is-selected' : ''} aria-pressed={splitMode === 'custom'} onClick={() => { setSplitMode('custom'); setError('') }}>自訂金額</button>
          </div>
          {splitMode === 'custom' && (
            <div className="custom-share-list">
              {participantIds.map((participantId) => {
                const participant = participants.find((item) => item.id === participantId)
                if (!participant) return null
                return (
                  <label key={participantId}>
                    <span><Avatar participant={participant} size="small" />{participant.name}</span>
                    <span className="custom-share-input"><span>NT$</span><input type="number" inputMode="numeric" min="0" step="1" value={customAmounts[participantId] ?? ''} onChange={(event) => { setCustomAmounts((current) => ({ ...current, [participantId]: event.target.value })); setError('') }} aria-label={`${participant.name}的分攤金額`} /></span>
                  </label>
                )
              })}
              <div className="custom-share-total"><span>目前合計</span><strong>{formatCurrency(participantIds.reduce((sum, id) => sum + (Number(customAmounts[id]) || 0), 0))}</strong></div>
            </div>
          )}
          {previewLedger?.isBalanced && <p className="split-hint">精確份額：{previewLedger.shares.map((share) => `${share.participant.name} ${formatCurrency(share.amount)}`).join('、')}</p>}
        </fieldset>

        <div className="form-grid two-columns">
          <div className="form-field">
            <label className="field-label" htmlFor="expense-date">日期</label>
            <input id="expense-date" className="text-input" type="date" value={date} onChange={(event) => { setDate(event.target.value); setError('') }} required />
          </div>
          <div className="form-field">
            <label className="field-label" htmlFor="expense-note">備註（選填）</label>
            <input id="expense-note" className="text-input" value={note} onChange={(event) => setNote(event.target.value)} placeholder="補充說明" maxLength={80} />
          </div>
        </div>
        {error && <div className="form-error" role="alert"><Icon name="alert-circle" size={17} />{error}</div>}
        <button className="primary-button full-width" type="submit" disabled={busy}><Icon name="check" size={18} /> {busy ? '儲存中…' : expense ? '儲存變更' : '新增帳目'}</button>
      </form>
    </Modal>
  )
}

function todayAsInputValue() {
  const date = new Date()
  const offset = date.getTimezoneOffset() * 60_000
  return new Date(date.getTime() - offset).toISOString().slice(0, 10)
}

function createId() {
  return typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : `expense-${Date.now()}`
}

function isValidDate(value: string) {
  return /^\d{4}-\d{2}-\d{2}$/.test(value) && !Number.isNaN(new Date(`${value}T12:00:00`).getTime())
}

function allocateEqualShares(total: number, participantIds: string[]) {
  if (participantIds.length === 0) return []
  const base = Math.floor(total / participantIds.length)
  const remainder = total % participantIds.length
  return participantIds.map((participantId, index) => ({
    participantId,
    amount: base + (index < remainder ? 1 : 0),
    receivedAt: null,
  }))
}
