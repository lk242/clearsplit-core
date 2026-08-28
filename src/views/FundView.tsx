import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import { MessagingFundDraftsCard } from '../components/LineFundDraftsCard'
import { Modal } from '../components/Modal'
import {
  cancelGroupFundCollectionRound,
  createGroupFundCollectionRound,
  fetchCloudLedgerAccess,
  fetchGroupFund,
  fetchGroupFundCollections,
  initializeGroupFund,
  recordGroupFundCollectionConfirmation,
  recordGroupFundExpense,
  type FundCollectionEntry,
  type FundCollectionRound,
  type FundCollections,
  type GroupFund,
} from '../lib/cloudLedger'
import type { CloudLedgerState, Participant } from '../types'
import { allocateFundEqually, previewFundCollectionOffsets } from '../utils/fund'
import { formatCurrency, formatDate } from '../utils/format'
import './FundView.css'

type Props = {
  cloudLedger: CloudLedgerState | null
  participants: Participant[]
  onShowPeople: () => void
  readOnly?: boolean
}

export function FundView({ cloudLedger, participants, onShowPeople, readOnly = false }: Props) {
  const [fund, setFund] = useState<GroupFund | null>(null)
  const [isOwner, setIsOwner] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [setupOpen, setSetupOpen] = useState(false)
  const [expenseOpen, setExpenseOpen] = useState(false)
  const [collectionOpen, setCollectionOpen] = useState(false)
  const [collections, setCollections] = useState<FundCollections | null>(null)
  const [collectionBusy, setCollectionBusy] = useState<string | null>(null)
  const [collectionNotice, setCollectionNotice] = useState('')

  useEffect(() => {
    let active = true
    if (!cloudLedger || cloudLedger.setupToken) { setLoading(false); setFund(null); setCollections(null); setIsOwner(false); return }
    const load = async (initial = false) => {
      if (initial) setLoading(true)
      try {
        const [nextFund, access, nextCollections] = await Promise.all([
          fetchGroupFund(cloudLedger.groupId),
          fetchCloudLedgerAccess(cloudLedger.groupId),
          fetchGroupFundCollections(cloudLedger.groupId),
        ])
        if (active) {
          setFund(nextFund)
          setCollections(nextCollections)
          setIsOwner(access.isOwner)
          setError('')
        }
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

  if (!cloudLedger) return <FundUnavailable onShowPeople={onShowPeople} />
  if (cloudLedger.setupToken) return <section className="fund-onboarding"><span><Icon name="wallet" size={28} /></span><h2>先指定帳務負責人</h2><p>公費屬於正式帳務操作，開帳碼不能直接建立或更動公費。</p><button className="primary-button" type="button" onClick={onShowPeople}>前往成員設定</button></section>
  if (loading) return <section className="fund-loading">正在核對公費帳本…</section>
  if (error && !fund) return <section className="fund-error" role="alert">{error}</section>
  if (!fund?.configured) {
    return (
      <section className="fund-onboarding">
        <span><Icon name="wallet" size={28} /></span>
        <h2>設定目前公費結餘</h2>
        <p>輸入切帳日的實際餘額，系統會平均分配給目前 {participants.length} 位成員，且總額精確一致。</p>
        {isOwner && !readOnly ? <button className="primary-button" type="button" onClick={() => setSetupOpen(true)}>設定期初公費</button> : <small>{readOnly ? '已封存帳本僅供檢視。' : '請由帳本管理者完成期初設定。'}</small>}
        <FundSetupModal open={setupOpen} participants={participants} groupId={cloudLedger.groupId} onClose={() => setSetupOpen(false)} onSaved={(next) => { setFund(next); setSetupOpen(false) }} />
      </section>
    )
  }

  const toggleCollectionConfirmation = async (round: FundCollectionRound, entry: FundCollectionEntry, actorRole: 'member' | 'responsible', isConfirmed: boolean) => {
    if (!cloudLedger) return
    const key = `${round.id}:${entry.memberId}:${actorRole}`
    const otherSideConfirmed = actorRole === 'member' ? Boolean(entry.responsibleConfirmedAt) : Boolean(entry.memberConfirmedAt)
    setCollectionBusy(key)
    setCollectionNotice('')
    setError('')
    try {
      const nextCollections = await recordGroupFundCollectionConfirmation(cloudLedger.groupId, {
        roundId: round.id,
        memberId: entry.memberId,
        actorRole,
        confirm: !isConfirmed,
      })
      setCollections(nextCollections)
      setFund(await fetchGroupFund(cloudLedger.groupId))
      setCollectionNotice(isConfirmed ? '已撤銷這一方的確認。' : otherSideConfirmed ? `${entry.name} 的公費已由雙方確認並正式入帳。` : '已記錄確認；另一方確認後才會正式入帳。')
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setCollectionBusy(null)
    }
  }

  const cancelCollection = async (round: FundCollectionRound) => {
    if (!cloudLedger || !window.confirm(`確定取消「${round.title}」？尚未入帳的確認紀錄會一併失效。`)) return
    setCollectionBusy(`cancel:${round.id}`)
    setCollectionNotice('')
    setError('')
    try {
      setCollections(await cancelGroupFundCollectionRound(cloudLedger.groupId, round.id))
      setCollectionNotice(`已取消「${round.title}」。`)
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setCollectionBusy(null)
    }
  }

  const hasOpenCollection = Boolean(collections?.rounds.some((round) => round.status === 'open'))
  const fundIsActive = fund.status === 'active'
  const openAdvances = fund.advances.filter((advance) => advance.status === 'open')

  return (
    <div className="fund-page">
      <section className="fund-balance-card">
        <span>第 {fund.cycleNumber} 期 · 目前可用公費</span>
        <strong>{formatCurrency(fund.balance)}</strong>
        <small>公費淨部位 {formatCurrency(fund.netBalance)}{openAdvances.length > 0 ? ` · 待還代墊 ${formatCurrency(openAdvances.reduce((sum, advance) => sum + advance.remainingAmount, 0))}` : ''}</small>
      </section>
      {!fundIsActive && <div className="fund-cycle-banner"><Icon name={fund.status === 'closed' ? 'check' : 'alert-circle'} size={17} />{fund.status === 'closing' ? `第 ${fund.cycleNumber} 期公費結清進行中，支出與收款已暫停。` : `第 ${fund.cycleNumber} 期公費已完成結清，請到結算頁開始下一期。`}</div>}
      <div className="fund-action-grid">
        <button className="primary-button" type="button" disabled={!fundIsActive || readOnly} onClick={() => setExpenseOpen(true)}><Icon name="receipt" size={18} />公費支出</button>
        {isOwner && <button className="secondary-button" type="button" disabled={!fundIsActive || hasOpenCollection || readOnly} onClick={() => setCollectionOpen(true)}><Icon name="plus" size={18} />{hasOpenCollection ? '目前收款中' : '發起收公費'}</button>}
      </div>
      {error && <div className="fund-error" role="alert">{error}</div>}
      {collectionNotice && <div className="fund-collection-notice"><Icon name="check" size={16} />{collectionNotice}</div>}

      <MessagingFundDraftsCard
        cloudLedger={cloudLedger}
        fund={fund}
        participants={participants}
        isOwner={isOwner && !readOnly}
        readOnly={readOnly}
        onFundUpdated={(next) => { if (next.configured) setFund(next) }}
      />

      {openAdvances.length > 0 && <div className="fund-advance-summary"><Icon name="receipt" size={17} /><div><strong>{openAdvances.length} 筆公費代墊待處理</strong><span>代墊屬於公費負債，請在結算中心完成雙向確認。</span></div></div>}

      <FundCollectionSection
        collections={collections}
        isOwner={isOwner && !readOnly}
        readOnly={readOnly}
        busyKey={collectionBusy}
        onToggle={toggleCollectionConfirmation}
        onCancel={cancelCollection}
      />

      <section className="section-block">
        <div className="section-heading"><div><p className="eyebrow">MEMBER CREDIT</p><h2>成員公費額度</h2></div><span className="section-caption">合計等於淨部位</span></div>
        <div className="fund-account-list">
          {fund.accounts.map((account) => (
            <article key={account.memberId}>
              <Avatar participant={{ id: account.memberId, name: account.name, color: account.color, createdAt: '' }} size="medium" />
              <div><strong>{account.name}</strong><span>已使用 {formatCurrency(account.consumedTotal)} · 後續繳款 {formatCurrency(account.contributedTotal)}</span></div>
              <strong>{formatCurrency(account.balance)}</strong>
            </article>
          ))}
        </div>
      </section>

      <section className="section-block">
        <div className="section-heading"><div><p className="eyebrow">FUND LEDGER</p><h2>公費明細</h2></div><span className="section-caption">最近 50 筆</span></div>
        <div className="fund-transaction-list">
          {fund.transactions.map((transaction) => (
            <article key={transaction.id}>
              <span className={transaction.amountDelta > 0 ? 'fund-delta-icon income' : 'fund-delta-icon expense'}><Icon name={transaction.amountDelta > 0 ? 'arrow-down' : 'arrow-up'} size={16} /></span>
              <div><strong>{transaction.title}</strong><span>第 {transaction.cycleNumber} 期 · {formatDate(transaction.effectiveDate)} · 淨部位 {formatCurrency(transaction.balanceAfter)}{transaction.sourceName ? ` · ${sourceLabel(transaction.sourceType)}由 ${transaction.sourceName} 記錄` : ''}</span></div>
              <strong className={transaction.amountDelta > 0 ? 'income' : 'expense'}>{transaction.amountDelta > 0 ? '+' : '−'}{formatCurrency(Math.abs(transaction.amountDelta))}</strong>
            </article>
          ))}
        </div>
      </section>

      <FundExpenseModal
        open={expenseOpen}
        groupId={cloudLedger.groupId}
        participants={participants}
        balance={fund.balance}
        defaultAdvanceMemberId={fund.currentMemberId}
        onClose={() => setExpenseOpen(false)}
        onSaved={(next) => { setFund(next); setExpenseOpen(false); setError('') }}
        onError={setError}
      />
      <FundCollectionRoundModal
        open={collectionOpen}
        groupId={cloudLedger.groupId}
        participants={participants}
        fund={fund}
        onClose={() => setCollectionOpen(false)}
        onSaved={(next) => { setCollections(next); setCollectionOpen(false); setCollectionNotice('新的公費收款已建立，請成員與負責人分別確認。'); setError('') }}
        onError={setError}
      />
    </div>
  )
}

function FundCollectionSection({ collections, isOwner, busyKey, onToggle, onCancel, readOnly = false }: {
  collections: FundCollections | null
  isOwner: boolean
  busyKey: string | null
  onToggle: (round: FundCollectionRound, entry: FundCollectionEntry, actorRole: 'member' | 'responsible', isConfirmed: boolean) => void
  onCancel: (round: FundCollectionRound) => void
  readOnly?: boolean
}) {
  const openRound = collections?.rounds.find((round) => round.status === 'open')
  const completedRounds = collections?.rounds.filter((round) => round.status === 'completed') ?? []

  return (
    <section className="section-block fund-collection-section">
      <div className="section-heading">
        <div><p className="eyebrow">TRIP COLLECTION</p><h2>每次出遊收公費</h2></div>
        <span className="section-caption">逐人雙向確認</span>
      </div>
      <p className="fund-collection-help">每次出遊建立一個收款批次；上次剩餘公費會保留，新繳款在雙方確認後才累加。</p>
      {!openRound && completedRounds.length === 0 && (
        <div className="fund-collection-empty"><Icon name="wallet" size={18} />尚未建立出遊公費收款</div>
      )}
      {openRound && (
        <FundCollectionRoundCard
          round={openRound}
          currentMemberId={collections?.currentMemberId ?? ''}
          isOwner={isOwner}
          busyKey={busyKey}
          onToggle={onToggle}
          onCancel={onCancel}
          readOnly={readOnly}
        />
      )}
      {completedRounds.length > 0 && (
        <details className="fund-collection-history">
          <summary>已完成收款 <span>{completedRounds.length} 次</span></summary>
          <div className="fund-collection-history-list">
            {completedRounds.map((round) => (
              <FundCollectionRoundCard
                key={round.id}
                round={round}
                currentMemberId={collections?.currentMemberId ?? ''}
                isOwner={isOwner}
                busyKey={busyKey}
                onToggle={onToggle}
                onCancel={onCancel}
                readOnly={readOnly}
              />
            ))}
          </div>
        </details>
      )}
    </section>
  )
}

function FundCollectionRoundCard({ round, currentMemberId, isOwner, busyKey, onToggle, onCancel, readOnly = false }: {
  round: FundCollectionRound
  currentMemberId: string
  isOwner: boolean
  busyKey: string | null
  onToggle: (round: FundCollectionRound, entry: FundCollectionEntry, actorRole: 'member' | 'responsible', isConfirmed: boolean) => void
  onCancel: (round: FundCollectionRound) => void
  readOnly?: boolean
}) {
  const completedCount = round.entries.filter((entry) => entry.status === 'completed').length
  const isComplete = round.status === 'completed'
  const canCancel = !isComplete && completedCount === 0 && isOwner

  return (
    <article className={`fund-collection-round ${isComplete ? 'is-complete' : 'is-open'}`}>
      <header className="fund-collection-round-header">
        <div>
          <span className="fund-collection-status">{isComplete ? '已完成' : '收款中'}</span>
          <h3>{round.title}</h3>
          <small>第 {round.cycleNumber} 期 · {formatDate(round.effectiveDate)} · 每人 {formatCurrency(round.amountPerMember)}</small>
        </div>
        <strong>{completedCount}/{round.entries.length}</strong>
      </header>
      <div className="fund-collection-progress" aria-label={`已完成 ${completedCount} 位，共 ${round.entries.length} 位`}>
        <span style={{ width: `${round.entries.length > 0 ? completedCount / round.entries.length * 100 : 0}%` }} />
      </div>
      <div className="fund-collection-entry-list">
        {round.entries.map((entry) => {
          const entryComplete = entry.status === 'completed'
          const memberKey = `${round.id}:${entry.memberId}:member`
          const responsibleKey = `${round.id}:${entry.memberId}:responsible`
          return (
            <article className={entryComplete ? 'fund-collection-entry is-complete' : 'fund-collection-entry'} key={entry.memberId}>
              <header>
                <Avatar participant={{ id: entry.memberId, name: entry.name, color: entry.color, avatarUrl: entry.avatarUrl, createdAt: '' }} size="medium" />
                <div><strong>{entry.name}</strong><span>{entryComplete ? `已於 ${formatConfirmationTime(entry.completedAt)} 入帳` : entry.offsetAmount > 0 ? `代墊抵 ${formatCurrency(entry.offsetAmount)} · 現金 ${formatCurrency(entry.cashAmount)}` : `待收現金 ${formatCurrency(entry.cashAmount)}`}</span></div>
                <strong>{formatCurrency(entry.amount)}</strong>
              </header>
              {entry.offsetAmount > 0 && (
                <dl className="fund-collection-breakdown">
                  <div><dt>本次應繳</dt><dd>{formatCurrency(entry.amount)}</dd></div>
                  <div><dt>代墊折抵</dt><dd>− {formatCurrency(entry.offsetAmount)}</dd></div>
                  <div className="is-cash"><dt>實際付款</dt><dd>{formatCurrency(entry.cashAmount)}</dd></div>
                </dl>
              )}
              <div className="fund-confirmation-grid">
                <FundConfirmationButton
                  label={entry.offsetAmount > 0 ? entry.cashAmount > 0 ? '成員已付款並同意折抵' : '成員同意全額折抵' : '成員已付款'}
                  confirmedAt={entry.memberConfirmedAt}
                  disabled={readOnly || entryComplete || currentMemberId !== entry.memberId || busyKey !== null}
                  busy={busyKey === memberKey}
                  unavailableLabel={entryComplete ? '已完成入帳' : currentMemberId === entry.memberId ? '等待處理' : '由成員本人確認'}
                  onClick={() => onToggle(round, entry, 'member', Boolean(entry.memberConfirmedAt))}
                />
                <FundConfirmationButton
                  label={entry.offsetAmount > 0 ? entry.cashAmount > 0 ? '負責人已收款並確認折抵' : '負責人確認全額折抵' : '負責人已收款'}
                  confirmedAt={entry.responsibleConfirmedAt}
                  disabled={readOnly || entryComplete || !isOwner || busyKey !== null}
                  busy={busyKey === responsibleKey}
                  unavailableLabel={entryComplete ? '已完成入帳' : isOwner ? '等待處理' : '由帳務負責人確認'}
                  onClick={() => onToggle(round, entry, 'responsible', Boolean(entry.responsibleConfirmedAt))}
                />
              </div>
            </article>
          )
        })}
      </div>
      {canCancel && <button className="fund-collection-cancel" type="button" disabled={busyKey !== null} onClick={() => onCancel(round)}><Icon name="x" size={14} />{busyKey === `cancel:${round.id}` ? '取消中…' : '取消這次收款'}</button>}
    </article>
  )
}

function FundConfirmationButton({ label, confirmedAt, disabled, busy, unavailableLabel, onClick }: {
  label: string
  confirmedAt: string | null
  disabled: boolean
  busy: boolean
  unavailableLabel: string
  onClick: () => void
}) {
  return (
    <button className={confirmedAt ? 'fund-confirmation-button is-confirmed' : 'fund-confirmation-button'} type="button" disabled={disabled} onClick={onClick} aria-pressed={Boolean(confirmedAt)}>
      <span>{label}<Icon name={confirmedAt ? 'check' : 'receipt'} size={14} /></span>
      <small>{busy ? '處理中…' : confirmedAt ? `已於 ${formatConfirmationTime(confirmedAt)} 確認` : disabled ? unavailableLabel : '點擊確認'}</small>
    </button>
  )
}

function FundSetupModal({ open, participants, groupId, onClose, onSaved }: { open: boolean; participants: Participant[]; groupId: string; onClose: () => void; onSaved: (fund: GroupFund) => void }) {
  const [amount, setAmount] = useState('')
  const [date, setDate] = useState(today)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const numericAmount = Number(amount)
  const allocation = useMemo(() => Number.isSafeInteger(numericAmount) && numericAmount > 0 && participants.length > 0 ? allocateFundEqually(numericAmount, participants.map((member) => member.id)) : [], [numericAmount, participants])
  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!Number.isSafeInteger(numericAmount) || numericAmount < 0) return setError('請輸入 0 或正整數公費餘額')
    setBusy(true); setError('')
    try { onSaved(await initializeGroupFund(groupId, numericAmount, date)) } catch (reason) { setError(toMessage(reason)); setBusy(false) }
  }
  return <Modal open={open} title="設定期初公費" description="這是切帳日實際剩餘的公費；全新公費可填 0，再發起第一次收款。" onClose={() => !busy && onClose()}>
    <form className="fund-form" onSubmit={submit}>
      <label className="field-label" htmlFor="fund-opening">目前實際餘額</label><input id="fund-opening" className="text-input" type="number" inputMode="numeric" min="0" value={amount} onChange={(event) => { setAmount(event.target.value); setError('') }} placeholder="0" />
      <label className="field-label" htmlFor="fund-opening-date">切帳日</label><input id="fund-opening-date" className="text-input" type="date" value={date} onChange={(event) => setDate(event.target.value)} />
      {allocation.length > 0 && <div className="fund-allocation-preview">{allocation.map((item) => <span key={item.participantId}>{participants.find((member) => member.id === item.participantId)?.name}<strong>{formatCurrency(item.amount)}</strong></span>)}</div>}
      {error && <div className="form-error">{error}</div>}<button className="primary-button full-width" type="submit" disabled={busy}>{busy ? '正在建立…' : '確認期初餘額'}</button>
    </form>
  </Modal>
}

function FundCollectionRoundModal({ open, groupId, participants, fund, onClose, onSaved, onError }: {
  open: boolean
  groupId: string
  participants: Participant[]
  fund: Extract<GroupFund, { configured: true }>
  onClose: () => void
  onSaved: (collections: FundCollections) => void
  onError: (message: string) => void
}) {
  const [title, setTitle] = useState('本次出遊公費')
  const [amount, setAmount] = useState('')
  const [date, setDate] = useState(today)
  const [applyAdvanceOffsets, setApplyAdvanceOffsets] = useState(true)
  const [busy, setBusy] = useState(false)
  const numericAmount = Number(amount)

  useEffect(() => {
    if (!open) return
    setBusy(false)
    setApplyAdvanceOffsets(true)
  }, [open, participants])

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    onError('')
    if (!title.trim() || !Number.isSafeInteger(numericAmount) || numericAmount <= 0 || participants.length === 0) {
      return onError('請確認批次名稱、每人金額與成員名單')
    }
    setBusy(true)
    try {
      onSaved(await createGroupFundCollectionRound(groupId, {
        title: title.trim(),
        amountPerMember: numericAmount,
        effectiveDate: date,
        applyAdvanceOffsets,
      }))
      setTitle('本次出遊公費')
      setAmount('')
    } catch (reason) {
      onError(toMessage(reason))
      setBusy(false)
    }
  }

  const total = Number.isSafeInteger(numericAmount) && numericAmount > 0 ? numericAmount * participants.length : 0
  const offsetPreview = Number.isSafeInteger(numericAmount) && numericAmount > 0 && participants.length > 0
    ? previewFundCollectionOffsets(
        numericAmount,
        participants.map((member) => member.id),
        fund.advances.filter((advance) => advance.status === 'open' && !advance.memberConfirmedAt && !advance.responsibleConfirmedAt),
        applyAdvanceOffsets,
      )
    : []
  const totalOffset = offsetPreview.reduce((sum, item) => sum + item.offsetAmount, 0)
  const totalCash = offsetPreview.reduce((sum, item) => sum + item.cashAmount, 0)
  return <Modal open={open} title="發起收取公費" description="公費固定由目前所有成員繳交相同金額，雙方確認後才會進入可用餘額。" onClose={() => !busy && onClose()}>
    <form className="fund-form" onSubmit={submit}>
      <label className="field-label" htmlFor="fund-collection-title">批次名稱</label><input id="fund-collection-title" className="text-input" value={title} onChange={(event) => setTitle(event.target.value)} maxLength={120} />
      <label className="field-label" htmlFor="fund-collection-amount">每人繳費金額</label><input id="fund-collection-amount" className="text-input" type="number" inputMode="numeric" min="1" value={amount} onChange={(event) => setAmount(event.target.value)} placeholder="例如 2000" />
      <div className="fund-fixed-members"><span>全員參與</span><strong>{participants.map((member) => member.name).join('、')}</strong></div>
      {fund.advances.some((advance) => advance.status === 'open') && (
        <label className="fund-offset-choice">
          <input type="checkbox" checked={applyAdvanceOffsets} onChange={(event) => setApplyAdvanceOffsets(event.target.checked)} />
          <span><strong>優先折抵未還代墊</strong><small>建議開啟；避免成員先繳款、帳本再把代墊款還給同一人。</small></span>
        </label>
      )}
      <div className="fund-collection-total"><span>{participants.length} 位成員 · 應繳 {formatCurrency(total)}</span><strong>實收現金 {formatCurrency(totalCash)}</strong></div>
      {totalOffset > 0 && <div className="fund-offset-preview">
        <div><span>代墊折抵合計</span><strong>{formatCurrency(totalOffset)}</strong></div>
        {offsetPreview.filter((item) => item.offsetAmount > 0).map((item) => <p key={item.participantId}><span>{participants.find((member) => member.id === item.participantId)?.name}</span><span>應繳 {formatCurrency(item.grossAmount)} · 折抵 {formatCurrency(item.offsetAmount)} · 現金 {formatCurrency(item.cashAmount)}</span></p>)}
      </div>}
      <label className="field-label" htmlFor="fund-collection-date">收款日期</label><input id="fund-collection-date" className="text-input" type="date" value={date} onChange={(event) => setDate(event.target.value)} />
      <button className="primary-button full-width" type="submit" disabled={busy}>{busy ? '正在建立…' : '建立收款批次'}</button>
    </form>
  </Modal>
}

function FundExpenseModal({ open, groupId, participants, balance, defaultAdvanceMemberId, onClose, onSaved, onError }: {
  open: boolean
  groupId: string
  participants: Participant[]
  balance: number
  defaultAdvanceMemberId: string
  onClose: () => void
  onSaved: (fund: GroupFund) => void
  onError: (message: string) => void
}) {
  const [title, setTitle] = useState('')
  const [amount, setAmount] = useState('')
  const [date, setDate] = useState(today)
  const [note, setNote] = useState('')
  const [advanceMemberId, setAdvanceMemberId] = useState('')
  const [recordingForOther, setRecordingForOther] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const numericAmount = Number(amount)
  const isValidAmount = Number.isSafeInteger(numericAmount) && numericAmount > 0
  const deficit = isValidAmount && numericAmount > balance ? numericAmount - balance : 0
  const allocation = Number.isSafeInteger(numericAmount) && numericAmount > 0 && participants.length > 0 ? allocateFundEqually(numericAmount, participants.map((member) => member.id)) : []
  const defaultAdvanceMember = participants.find((member) => member.id === defaultAdvanceMemberId) ?? null
  const advanceMember = recordingForOther
    ? participants.find((member) => member.id === advanceMemberId) ?? null
    : defaultAdvanceMember

  useEffect(() => {
    if (!open) return
    setError('')
    setBusy(false)
    setRecordingForOther(false)
    setAdvanceMemberId(defaultAdvanceMember?.id ?? '')
  }, [open, defaultAdvanceMember?.id])

  const save = async (useAvailableFund: boolean) => {
    onError('')
    setError('')
    if (!title.trim()) return setError('請輸入支出項目')
    if (!isValidAmount) return setError('請輸入正整數金額')
    if (participants.length === 0) return setError('公費支出需要至少一位成員')
    if (deficit > 0 && !defaultAdvanceMember) return setError('目前登入者未連結成員身分，無法登記代墊')
    if (deficit > 0 && !advanceMember) return setError('請選擇實際代墊人')
    setBusy(true)
    try {
      onSaved(await recordGroupFundExpense(groupId, {
        title: title.trim(),
        amount: numericAmount,
        effectiveDate: date,
        note: note.trim(),
        advanceMemberId: deficit > 0 ? advanceMember?.id : null,
        useAvailableFund,
      }))
    } catch (reason) {
      const message = toMessage(reason)
      setError(message)
      onError(message)
      setBusy(false)
    }
  }

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    await save(true)
  }

  return <Modal open={open} title="記錄公費支出" description={`目前可用 ${formatCurrency(balance)}；公費固定由 ${participants.length} 位成員平均分攤。`} onClose={() => !busy && onClose()}>
    <form className="fund-form" onSubmit={submit} noValidate>
      <label className="field-label" htmlFor="fund-expense-title">項目</label><input id="fund-expense-title" className="text-input" value={title} onChange={(event) => { setTitle(event.target.value); setError('') }} maxLength={120} />
      <label className="field-label" htmlFor="fund-expense-amount">金額</label><input id="fund-expense-amount" className="text-input" type="number" inputMode="numeric" min="1" value={amount} onChange={(event) => { setAmount(event.target.value); setError('') }} />
      {deficit > 0 && <div className="fund-deficit-warning">公費不足 {formatCurrency(deficit)}。這筆仍是公費支出，差額會登記為代墊，之後由公費償還。</div>}
      <div className="fund-fixed-members"><span>固定規則</span><strong>全員參與 · 平均分攤</strong></div>
      {allocation.length > 0 && <div className="fund-split-preview">{allocation.map((item) => <span key={item.participantId}>{participants.find((member) => member.id === item.participantId)?.name} {formatCurrency(item.amount)}</span>)}</div>}
      {deficit > 0 && <>
        <div className="fund-inputter-default"><span>預設實際代墊人</span><strong>{defaultAdvanceMember?.name ?? '未連結成員'}（目前輸入者）</strong></div>
        <label className="fund-offset-choice">
          <input type="checkbox" checked={recordingForOther} onChange={(event) => { setRecordingForOther(event.target.checked); setAdvanceMemberId(event.target.checked ? participants.find((member) => member.id !== defaultAdvanceMemberId)?.id ?? '' : defaultAdvanceMemberId) }} />
          <span><strong>替其他成員代記</strong><small>只有實際付款者不是你時才開啟；系統會同時保留輸入者與代墊人。</small></span>
        </label>
        {recordingForOther && <><label className="field-label" htmlFor="fund-advance-member">實際代墊人</label><select id="fund-advance-member" className="text-input" value={advanceMemberId} onChange={(event) => setAdvanceMemberId(event.target.value)}><option value="">請選擇</option>{participants.filter((member) => member.id !== defaultAdvanceMemberId).map((member) => <option key={member.id} value={member.id}>{member.name}{member.isResponsible ? '（帳務負責人）' : ''}</option>)}</select></>}
      </>}
      <label className="field-label" htmlFor="fund-expense-date">日期</label><input id="fund-expense-date" className="text-input" type="date" value={date} onChange={(event) => setDate(event.target.value)} />
      <label className="field-label" htmlFor="fund-expense-note">備註</label><input id="fund-expense-note" className="text-input" value={note} onChange={(event) => setNote(event.target.value)} maxLength={200} />
      {error && <div className="form-error">{error}</div>}
      {deficit > 0 ? (
        <div className="fund-deficit-actions">
          <button className="primary-button full-width" type="submit" disabled={busy}>{busy ? '正在入帳…' : `使用公費並代墊 ${formatCurrency(deficit)}`}</button>
          {balance > 0 && <button className="secondary-button full-width" type="button" disabled={busy} onClick={() => void save(false)}>{advanceMember?.name ?? '所選成員'}全額代墊，保留公費</button>}
        </div>
      ) : (
        <button className="primary-button full-width" type="submit" disabled={busy}>{busy ? '正在入帳…' : '確認公費支出'}</button>
      )}
    </form>
  </Modal>
}

function FundUnavailable({ onShowPeople }: { onShowPeople: () => void }) { return <section className="empty-state large"><span className="empty-icon"><Icon name="wallet" size={30} /></span><strong>先建立雲端帳本</strong><p>公費錢包需要雲端帳本才能讓所有成員看到相同餘額。</p><button className="primary-button" type="button" onClick={onShowPeople}>前往成員設定</button></section> }
function today() { const date = new Date(); return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 10) }
function formatConfirmationTime(value: string | null) { return value ? new Intl.DateTimeFormat('zh-TW', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(value)) : '—' }
function toMessage(reason: unknown) { return reason instanceof Error ? reason.message : '發生未預期錯誤' }
function sourceLabel(source: string) { return source === 'line' ? 'LINE' : source === 'discord' ? 'Discord' : source === 'telegram' ? 'Telegram' : '網頁' }
