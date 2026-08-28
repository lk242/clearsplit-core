import { useEffect, useMemo, useState } from 'react'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import {
  completeGroupFundCloseout,
  fetchCloudLedgerAccess,
  fetchGroupFund,
  reassignGroupFundAdvance,
  recordGroupFundAdvanceConfirmation,
  recordGroupFundSettlementConfirmation,
  recordPrivateExpenseConfirmation,
  startGroupFundCloseout,
  startNextGroupFundCycle,
  type CloudLedgerAccess,
  type FundAdvance,
  type FundSettlement,
  type GroupFund,
} from '../lib/cloudLedger'
import type { CloudLedgerState, Expense, Participant } from '../types'
import { formatCurrency, formatDate } from '../utils/format'
import { calculateExpenseLedgers, type ExpenseLedger } from '../utils/ledger'
import './SettlementView.css'

type SettlementTab = 'fund' | 'private'

type SettlementViewProps = {
  participants: Participant[]
  expenses: Expense[]
  cloudLedger: CloudLedgerState | null
  onExpenseUpdated: (expense: Expense) => void
  readOnly?: boolean
}

export function SettlementView({ participants, expenses, cloudLedger, onExpenseUpdated, readOnly = false }: SettlementViewProps) {
  const [tab, setTab] = useState<SettlementTab>('fund')
  const [fund, setFund] = useState<GroupFund | null>(null)
  const [access, setAccess] = useState<CloudLedgerAccess | null>(null)
  const [loading, setLoading] = useState(false)
  const [busyKey, setBusyKey] = useState<string | null>(null)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')

  useEffect(() => {
    let active = true
    if (!cloudLedger || cloudLedger.setupToken) {
      setFund(null)
      setAccess(null)
      return
    }
    const load = async (initial = false) => {
      if (initial) setLoading(true)
      try {
        const [nextFund, nextAccess] = await Promise.all([
          fetchGroupFund(cloudLedger.groupId),
          fetchCloudLedgerAccess(cloudLedger.groupId),
        ])
        if (!active) return
        setFund(nextFund)
        setAccess(nextAccess)
        setError('')
      } catch (reason) {
        if (active) setError(toMessage(reason))
      } finally {
        if (active && initial) setLoading(false)
      }
    }
    void load(true)
    const refresh = () => { if (document.visibilityState === 'visible') void load() }
    const timer = window.setInterval(refresh, 15_000)
    document.addEventListener('visibilitychange', refresh)
    window.addEventListener('focus', refresh)
    return () => {
      active = false
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', refresh)
      window.removeEventListener('focus', refresh)
    }
  }, [cloudLedger])

  const runFundAction = async (key: string, action: () => Promise<GroupFund>, successMessage: string) => {
    setBusyKey(key)
    setError('')
    setNotice('')
    try {
      setFund(await action())
      setNotice(successMessage)
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusyKey(null)
    }
  }

  const toggleAdvance = (advance: FundAdvance, actorRole: 'member' | 'responsible', confirmed: boolean) => {
    if (!cloudLedger || readOnly) return
    const otherConfirmed = actorRole === 'member' ? Boolean(advance.responsibleConfirmedAt) : Boolean(advance.memberConfirmedAt)
    void runFundAction(
      `advance:${advance.id}:${actorRole}`,
      () => recordGroupFundAdvanceConfirmation(cloudLedger.groupId, { advanceId: advance.id, actorRole, confirm: !confirmed }),
      confirmed ? '已撤銷代墊確認。' : otherConfirmed ? '雙方確認完成，這筆公費代墊已償還。' : '已記錄確認，另一方確認後才會完成。',
    )
  }

  const reassignAdvance = (advance: FundAdvance, newMemberId: string) => {
    if (!cloudLedger || newMemberId === advance.memberId) return
    const nextMember = participants.find((member) => member.id === newMemberId)
    if (!nextMember || !window.confirm(`確定將這筆 ${formatCurrency(advance.amount)} 代墊人由「${advance.memberName}」更正為「${nextMember.name}」？\n\n這項變更會保留在財務稽核紀錄中。`)) return
    void runFundAction(
      `advance:${advance.id}:reassign`,
      () => reassignGroupFundAdvance(cloudLedger.groupId, {
        advanceId: advance.id,
        expectedMemberId: advance.memberId,
        newMemberId,
      }),
      `已將這筆代墊更正為 ${nextMember.name}。`,
    )
  }

  const toggleFundSettlement = (settlement: FundSettlement, actorRole: 'member' | 'responsible', confirmed: boolean) => {
    if (!cloudLedger || readOnly) return
    const otherConfirmed = actorRole === 'member' ? Boolean(settlement.responsibleConfirmedAt) : Boolean(settlement.memberConfirmedAt)
    void runFundAction(
      `fund:${settlement.memberId}:${actorRole}`,
      () => recordGroupFundSettlementConfirmation(cloudLedger.groupId, { memberId: settlement.memberId, actorRole, confirm: !confirmed }),
      confirmed ? '已撤銷結清確認。' : otherConfirmed ? '雙方確認完成，這筆補退款已入帳。' : '已記錄確認，另一方確認後才會入帳。',
    )
  }

  const togglePrivateConfirmation = async (expense: Expense, debtorMemberId: string, actorRole: 'debtor' | 'payer', confirmed: boolean) => {
    if (!cloudLedger || readOnly) return
    const key = `private:${expense.id}:${debtorMemberId}:${actorRole}`
    setBusyKey(key)
    setError('')
    setNotice('')
    try {
      const next = await recordPrivateExpenseConfirmation(cloudLedger.groupId, {
        expenseId: expense.id,
        debtorMemberId,
        actorRole,
        confirm: !confirmed,
      })
      onExpenseUpdated(next)
      setNotice(next.status === 'resolved'
        ? `「${next.title}」的付款與收款都已逐筆確認完成。`
        : confirmed ? '已撤銷這一方的確認。' : '已記錄確認，另一方確認後才會完成。')
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusyKey(null)
    }
  }

  return (
    <div className="settlement-page">
      <div className="settlement-tabs" role="tablist" aria-label="結算類型">
        <button type="button" role="tab" aria-selected={tab === 'fund'} className={tab === 'fund' ? 'is-active' : ''} onClick={() => setTab('fund')}><Icon name="wallet" size={17} />公費結清</button>
        <button type="button" role="tab" aria-selected={tab === 'private'} className={tab === 'private' ? 'is-active' : ''} onClick={() => setTab('private')}><Icon name="receipt" size={17} />成員分帳</button>
      </div>

      {error && <div className="settlement-alert is-error" role="alert"><Icon name="alert-circle" size={17} />{error}</div>}
      {notice && <div className="settlement-alert"><Icon name="check" size={17} />{notice}</div>}

      {tab === 'fund' ? (
        <PublicFundSettlement
          cloudLedger={cloudLedger}
          fund={fund}
          access={access}
          participants={participants}
          loading={loading}
          busyKey={busyKey}
          onToggleAdvance={toggleAdvance}
          onReassignAdvance={reassignAdvance}
          onToggleSettlement={toggleFundSettlement}
          onStart={() => {
            if (!cloudLedger || !window.confirm('開始結清後會暫停公費支出與收款，確定繼續？')) return
            void runFundAction('start', () => startGroupFundCloseout(cloudLedger.groupId), '已開始公費結清。')
          }}
          onComplete={() => {
            if (!cloudLedger) return
            void runFundAction('complete', () => completeGroupFundCloseout(cloudLedger.groupId), '本期公費已完成結清。')
          }}
          onNextCycle={() => {
            if (!cloudLedger || !fund?.configured || !window.confirm(`確定開始第 ${fund.cycleNumber + 1} 期公費？上一期資料會保留為唯讀歷史。`)) return
            void runFundAction('next-cycle', () => startNextGroupFundCycle(cloudLedger.groupId), `第 ${fund.cycleNumber + 1} 期公費已開始。`)
          }}
          readOnly={readOnly}
        />
      ) : (
        <PrivateExpenseSettlement
          participants={participants}
          expenses={expenses}
          currentMemberId={access?.currentMemberId ?? null}
          cloudEnabled={Boolean(cloudLedger && !cloudLedger.setupToken && !readOnly)}
          busyKey={busyKey}
          onToggleConfirmation={togglePrivateConfirmation}
        />
      )}
    </div>
  )
}

function PublicFundSettlement({ cloudLedger, fund, access, participants, loading, busyKey, onToggleAdvance, onReassignAdvance, onToggleSettlement, onStart, onComplete, onNextCycle, readOnly = false }: {
  cloudLedger: CloudLedgerState | null
  fund: GroupFund | null
  access: CloudLedgerAccess | null
  participants: Participant[]
  loading: boolean
  busyKey: string | null
  onToggleAdvance: (advance: FundAdvance, actorRole: 'member' | 'responsible', confirmed: boolean) => void
  onReassignAdvance: (advance: FundAdvance, newMemberId: string) => void
  onToggleSettlement: (settlement: FundSettlement, actorRole: 'member' | 'responsible', confirmed: boolean) => void
  onStart: () => void
  onComplete: () => void
  onNextCycle: () => void
  readOnly?: boolean
}) {
  if (!cloudLedger) return <SettlementEmpty icon="cloud" title="公費結清需要雲端帳本" detail="建立並交接帳本後，所有成員才會看到同一份確認狀態。" />
  if (cloudLedger.setupToken) return <SettlementEmpty icon="users" title="請先指定帳務負責人" detail="完成帳本交接後才能操作公費。" />
  if (loading) return <div className="settlement-loading">正在讀取公費狀態…</div>
  if (!fund?.configured) return <SettlementEmpty icon="wallet" title="尚未建立公費" detail="請先到公費頁設定期初餘額。" />

  const openAdvances = fund.advances.filter((advance) => advance.status === 'open')
  const accountsById = new Map(fund.accounts.map((account) => [account.memberId, account]))
  const closeoutReady = openAdvances.length === 0 && fund.settlements.length === 0

  return (
    <div className="public-settlement">
      <section className="settlement-balance-band">
        <div><span>可用公費</span><strong>{formatCurrency(fund.balance)}</strong></div>
        <dl><div><dt>淨部位</dt><dd>{formatCurrency(fund.netBalance)}</dd></div><div><dt>代墊未還</dt><dd>{formatCurrency(openAdvances.reduce((sum, item) => sum + item.remainingAmount, 0))}</dd></div></dl>
        <span className={`fund-cycle-status is-${fund.status}`}>第 {fund.cycleNumber} 期 · {fund.status === 'active' ? '使用中' : fund.status === 'closing' ? '結清中' : '已結清'}</span>
      </section>

      {fund.status === 'active' && openAdvances.length > 0 && (
        <section className="section-block">
          <div className="section-heading"><div><p className="eyebrow">FUND ADVANCES</p><h2>公費代墊</h2></div><span className="section-caption">雙向確認償還</span></div>
          <div className="settlement-task-list">
            {openAdvances.map((advance) => {
              const cashReady = fund.balance >= advance.remainingAmount
              const canReassign = !readOnly && fund.isOwner && advance.settledAmount === 0 && !advance.memberConfirmedAt && !advance.responsibleConfirmedAt
              return (
                <article className="settlement-task-card" key={advance.id}>
                  <header><div><strong>{advance.memberName}</strong><span>{advance.settledAmount > 0 ? `原代墊 ${formatCurrency(advance.amount)} · 已折抵 ${formatCurrency(advance.settledAmount)}` : advance.isOnBehalf && advance.recordedByName ? `由 ${advance.recordedByName} 代記 · 實際代墊人 ${advance.memberName}` : advance.sourceType === 'line' ? '由本人透過 LINE 回報' : advance.sourceType === 'discord' ? '由本人透過 Discord 回報' : advance.sourceType === 'telegram' ? '由本人透過 Telegram 回報' : '由本人於網頁記錄'}</span></div><strong>{formatCurrency(advance.remainingAmount)}</strong></header>
                  {canReassign && (
                    <label className="advance-member-correction">
                      <span>實際代墊人 <small>更正會留下稽核紀錄</small></span>
                      <select
                        className="text-input"
                        value={advance.memberId}
                        disabled={busyKey !== null}
                        onChange={(event) => onReassignAdvance(advance, event.target.value)}
                      >
                        {participants.map((member) => <option key={member.id} value={member.id}>{member.name}</option>)}
                      </select>
                    </label>
                  )}
                  {!cashReady && <p className="task-warning">可用公費不足，請先完成公費收款或結清補款。</p>}
                  <div className="dual-confirmation-grid">
                    <ConfirmationButton tone="receipt" label="代墊人已收款" confirmedAt={advance.memberConfirmedAt} disabled={readOnly || !cashReady || fund.currentMemberId !== advance.memberId || busyKey !== null} busy={busyKey === `advance:${advance.id}:member`} unavailable={fund.currentMemberId === advance.memberId ? '等待公費到位' : '由代墊人確認'} onClick={() => onToggleAdvance(advance, 'member', Boolean(advance.memberConfirmedAt))} />
                    <ConfirmationButton tone="payment" label="負責人已付款" confirmedAt={advance.responsibleConfirmedAt} disabled={readOnly || !cashReady || !fund.isOwner || busyKey !== null} busy={busyKey === `advance:${advance.id}:responsible`} unavailable={fund.isOwner ? '等待公費到位' : '由負責人確認'} onClick={() => onToggleAdvance(advance, 'responsible', Boolean(advance.responsibleConfirmedAt))} />
                  </div>
                </article>
              )
            })}
          </div>
        </section>
      )}

      {fund.status === 'active' && (
        <section className="closeout-start-panel">
          <div><strong>本期仍在使用中</strong><span>中途收公費與代墊償還都可繼續進行。</span></div>
          {access?.isOwner ? <button className="secondary-button" type="button" disabled={readOnly || busyKey !== null} onClick={onStart}>{busyKey === 'start' ? '啟動中…' : '開始本期結清'}</button> : <small>由帳務負責人發起最終結清</small>}
        </section>
      )}

      {fund.status === 'closing' && (
        <section className="section-block">
          <div className="section-heading"><div><p className="eyebrow">FINAL CLOSE-OUT</p><h2>多退少補</h2></div><span className="section-caption">公費操作已凍結</span></div>
          {fund.settlements.length > 0 ? (
            <div className="settlement-task-list">
              {fund.settlements.map((settlement) => {
                const account = accountsById.get(settlement.memberId)
                if (!account) return null
                const isTopUp = settlement.direction === 'top_up'
                const isOffsetOnly = settlement.direction === 'offset'
                const cashReady = isTopUp || isOffsetOnly || fund.balance >= settlement.cashAmount
                return (
                  <article className="settlement-task-card" key={settlement.memberId}>
                    <header><div><strong>{account.name}</strong><span>{isTopUp ? '實際應付' : isOffsetOnly ? '帳內完全互抵' : '實際應收'}</span></div><strong>{isTopUp ? '付 ' : isOffsetOnly ? '' : '收 '}{isOffsetOnly ? '無需轉帳' : formatCurrency(settlement.cashAmount)}</strong></header>
                    <dl className="closeout-breakdown">
                      {settlement.accountTopUp > 0 && <div><dt>帳戶應補</dt><dd>{formatCurrency(settlement.accountTopUp)}</dd></div>}
                      {settlement.accountRefund > 0 && <div><dt>帳戶應退</dt><dd>{formatCurrency(settlement.accountRefund)}</dd></div>}
                      {settlement.advanceAmount > 0 && <div><dt>未還代墊</dt><dd>{formatCurrency(settlement.advanceAmount)}</dd></div>}
                      {settlement.advanceOffsetAmount > 0 && <div><dt>帳內互抵</dt><dd>{formatCurrency(settlement.advanceOffsetAmount)}</dd></div>}
                      <div className="is-net"><dt>實際現金</dt><dd>{isOffsetOnly ? formatCurrency(0) : `${isTopUp ? '成員支付 ' : '成員收取 '}${formatCurrency(settlement.cashAmount)}`}</dd></div>
                    </dl>
                    {!cashReady && <p className="task-warning">請先完成其他成員的必要補款，公費現金到位後再退款。</p>}
                    {settlement.hasStaleConfirmation && <p className="task-warning">金額已變更，請依目前金額重新確認。</p>}
                    <div className="dual-confirmation-grid">
                      <ConfirmationButton tone={isOffsetOnly ? 'neutral' : isTopUp ? 'payment' : 'receipt'} label={isTopUp ? '成員已付款' : isOffsetOnly ? '成員同意互抵' : '成員已收款'} confirmedAt={settlement.memberConfirmedAt} disabled={readOnly || !cashReady || fund.currentMemberId !== settlement.memberId || busyKey !== null} busy={busyKey === `fund:${settlement.memberId}:member`} unavailable={fund.currentMemberId === settlement.memberId ? '等待前置款項' : '由成員本人確認'} onClick={() => onToggleSettlement(settlement, 'member', Boolean(settlement.memberConfirmedAt))} />
                      <ConfirmationButton tone={isOffsetOnly ? 'neutral' : isTopUp ? 'receipt' : 'payment'} label={isTopUp ? '負責人已收款' : isOffsetOnly ? '負責人確認互抵' : '負責人已退款'} confirmedAt={settlement.responsibleConfirmedAt} disabled={readOnly || !cashReady || !fund.isOwner || busyKey !== null} busy={busyKey === `fund:${settlement.memberId}:responsible`} unavailable={fund.isOwner ? '等待前置款項' : '由負責人確認'} onClick={() => onToggleSettlement(settlement, 'responsible', Boolean(settlement.responsibleConfirmedAt))} />
                    </div>
                  </article>
                )
              })}
            </div>
          ) : openAdvances.length === 0 ? <div className="settlement-complete-state"><Icon name="check" size={20} />所有成員額度已歸零</div> : null}
          <button className="primary-button full-width" type="button" disabled={readOnly || !closeoutReady || !fund.isOwner || busyKey !== null} onClick={onComplete}>{busyKey === 'complete' ? '完成中…' : closeoutReady ? '完成本期公費結清' : '尚有款項待處理'}</button>
        </section>
      )}

      {fund.status === 'closed' && <div className="settlement-complete-state large"><Icon name="check" size={24} /><div><strong>第 {fund.cycleNumber} 期公費已結清</strong><span>所有代墊、補款與退款均已完成，歷史帳目不會被下一期覆寫。</span></div>{access?.isOwner && <button className="primary-button" type="button" disabled={readOnly || busyKey !== null} onClick={onNextCycle}>{busyKey === 'next-cycle' ? '建立中…' : `開始第 ${fund.cycleNumber + 1} 期`}</button>}</div>}
    </div>
  )
}

function PrivateExpenseSettlement({ participants, expenses, currentMemberId, cloudEnabled, busyKey, onToggleConfirmation }: {
  participants: Participant[]
  expenses: Expense[]
  currentMemberId: string | null
  cloudEnabled: boolean
  busyKey: string | null
  onToggleConfirmation: (expense: Expense, debtorMemberId: string, actorRole: 'debtor' | 'payer', confirmed: boolean) => void
}) {
  const ledgers = useMemo(() => calculateExpenseLedgers(participants, expenses), [participants, expenses])
  const activeLedgers = ledgers.filter((ledger) => ledger.isBalanced && (ledger.expense.status ?? 'active') === 'active')
  const resolvedLedgers = ledgers.filter((ledger) => ledger.isBalanced && ledger.expense.status === 'resolved')

  if (participants.length === 0) return <SettlementEmpty icon="users" title="目前沒有成員分帳" detail="新增成員與帳目後，每一筆款項會在這裡獨立處理。" />

  return (
    <div className="private-settlement">
      <section className="private-settlement-summary"><div><span>待處理帳目</span><strong>{activeLedgers.length}</strong></div><p>每筆帳獨立完成，不與其他帳目互相抵銷。</p></section>
      <div className="private-expense-list">
        {activeLedgers.map((ledger) => <PrivateExpenseCard key={ledger.expense.id} ledger={ledger} currentMemberId={currentMemberId} cloudEnabled={cloudEnabled} busyKey={busyKey} onToggleConfirmation={onToggleConfirmation} />)}
        {activeLedgers.length === 0 && <div className="settlement-complete-state"><Icon name="check" size={20} />目前沒有待收款的成員分帳</div>}
      </div>
      {resolvedLedgers.length > 0 && <details className="resolved-expense-history"><summary>已完成帳目 <span>{resolvedLedgers.length} 筆</span></summary><div>{resolvedLedgers.map((ledger) => <PrivateExpenseCard key={ledger.expense.id} ledger={ledger} currentMemberId={currentMemberId} cloudEnabled={cloudEnabled} busyKey={busyKey} onToggleConfirmation={onToggleConfirmation} resolved />)}</div></details>}
    </div>
  )
}

function PrivateExpenseCard({ ledger, currentMemberId, cloudEnabled, busyKey, onToggleConfirmation, resolved = false }: {
  ledger: ExpenseLedger
  currentMemberId: string | null
  cloudEnabled: boolean
  busyKey: string | null
  onToggleConfirmation: (expense: Expense, debtorMemberId: string, actorRole: 'debtor' | 'payer', confirmed: boolean) => void
  resolved?: boolean
}) {
  const debts = ledger.shares.filter((share) => !share.isPayer && share.amount > 0)
  const completedCount = debts.filter((share) => Boolean(share.paidAt && share.receivedAt)).length

  return (
    <article className={`private-expense-card ${resolved ? 'is-resolved' : ''}`}>
      <header><div><strong>{ledger.expense.title}</strong><span>{formatDate(ledger.expense.date)} · {ledger.payer?.name}先付 · {ledger.expense.splitMode === 'custom' ? '自訂' : '平分'}</span></div><strong>{formatCurrency(ledger.expense.amount)}</strong></header>
      <div className="private-progress"><span style={{ width: `${debts.length === 0 ? 100 : completedCount / debts.length * 100}%` }} /></div>
      <div className="private-share-list">
        {ledger.shares.map((share) => {
          const paid = share.isPayer || Boolean(share.paidAt)
          const received = share.isPayer || Boolean(share.receivedAt)
          const debtorCanConfirm = cloudEnabled && currentMemberId === share.participant.id && !resolved
          const payerCanConfirm = cloudEnabled && currentMemberId === ledger.payer?.id && !resolved
          const debtorKey = `private:${ledger.expense.id}:${share.participant.id}:debtor`
          const payerKey = `private:${ledger.expense.id}:${share.participant.id}:payer`
          return (
            <div className="private-share-row" key={share.participant.id}>
              <Avatar participant={share.participant} size="small" />
              <div><strong>{share.participant.name}</strong><span>{share.isPayer ? '付款人本人份額' : `${share.participant.name} 欠 ${ledger.payer?.name}`}</span></div>
              <strong>{formatCurrency(share.amount)}</strong>
              {share.isPayer ? <span className="share-state is-done"><Icon name="check" size={13} />本人</span> : <div className="private-obligation-confirmations">
                <button className={paid ? 'receipt-toggle is-received' : 'receipt-toggle'} type="button" disabled={!debtorCanConfirm || busyKey !== null} onClick={() => onToggleConfirmation(ledger.expense, share.participant.id, 'debtor', paid)} aria-pressed={paid}>
                  <Icon name={paid ? 'check' : 'receipt'} size={14} />{busyKey === debtorKey ? '處理中' : paid ? '已付款' : debtorCanConfirm ? '確認付款' : '待成員'}
                </button>
                <button className={received ? 'receipt-toggle is-received' : 'receipt-toggle'} type="button" disabled={!payerCanConfirm || busyKey !== null} onClick={() => onToggleConfirmation(ledger.expense, share.participant.id, 'payer', received)} aria-pressed={received}>
                  <Icon name={received ? 'check' : 'receipt'} size={14} />{busyKey === payerKey ? '處理中' : received ? '已收款' : payerCanConfirm ? '確認收款' : '待付款人'}
                </button>
              </div>}
            </div>
          )
        })}
      </div>
      <footer><span>{resolved ? '已完成' : `${completedCount} / ${debts.length} 筆雙向確認`}</span><small>付款與收款分開記錄</small></footer>
    </article>
  )
}

function ConfirmationButton({ tone, label, confirmedAt, disabled, busy, unavailable, onClick }: {
  tone: 'payment' | 'receipt' | 'neutral'
  label: string
  confirmedAt: string | null
  disabled: boolean
  busy: boolean
  unavailable: string
  onClick: () => void
}) {
  return <button className={`settlement-confirm-button is-${tone}${confirmedAt ? ' is-confirmed' : ''}`} type="button" disabled={disabled} onClick={onClick} aria-pressed={Boolean(confirmedAt)}><span>{label}<Icon name={confirmedAt ? 'check' : 'receipt'} size={14} /></span><small>{busy ? '處理中…' : confirmedAt ? `已於 ${formatConfirmationTime(confirmedAt)} 確認` : disabled ? unavailable : '點擊確認'}</small></button>
}

function SettlementEmpty({ icon, title, detail }: { icon: 'cloud' | 'users' | 'wallet'; title: string; detail: string }) {
  return <section className="empty-state large"><span className="empty-icon"><Icon name={icon} size={28} /></span><strong>{title}</strong><p>{detail}</p></section>
}

function formatConfirmationTime(value: string) {
  return new Intl.DateTimeFormat('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(value))
}

function toMessage(reason: unknown) {
  return reason instanceof Error ? reason.message : '發生未預期錯誤'
}
