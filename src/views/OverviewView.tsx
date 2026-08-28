import { useEffect, useState } from 'react'
import { Icon } from '../components/Icon'
import { fetchGroupFund, type GroupFund } from '../lib/cloudLedger'
import type { CloudLedgerState, Expense, Participant } from '../types'
import { formatCurrency, formatDate } from '../utils/format'
import { calculateExpenseLedgers } from '../utils/ledger'
import './OverviewView.css'

type OverviewViewProps = {
  participants: Participant[]
  expenses: Expense[]
  onShowExpenses: () => void
  onShowFund: () => void
  onShowSettlement: () => void
  onAddExpense: () => void
  cloudLedger: CloudLedgerState | null
}

export function OverviewView({ participants, expenses, onShowExpenses, onShowFund, onShowSettlement, onAddExpense, cloudLedger }: OverviewViewProps) {
  const [fund, setFund] = useState<GroupFund | null>(null)
  useEffect(() => {
    let active = true
    if (!cloudLedger || cloudLedger.setupToken) { setFund(null); return }
    const load = () => fetchGroupFund(cloudLedger.groupId).then((next) => { if (active) setFund(next) }).catch(() => undefined)
    void load()
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
  const ledgers = calculateExpenseLedgers(participants, expenses)
  const validLedgers = ledgers.filter((ledger) => ledger.isBalanced && (ledger.expense.status ?? 'active') === 'active')
  const invalidLedgers = ledgers.filter((ledger) => !ledger.isBalanced)
  const total = validLedgers.reduce((sum, ledger) => sum + ledger.expense.amount, 0)
  const transferTotal = validLedgers.reduce(
    (sum, ledger) => sum + ledger.obligations.reduce((expenseSum, obligation) => expenseSum + (obligation.receivedAt ? 0 : obligation.amount), 0),
    0,
  )
  const recentExpenses = [...validLedgers]
    .sort((a, b) => b.expense.date.localeCompare(a.expense.date) || b.expense.createdAt.localeCompare(a.expense.createdAt))
    .slice(0, 3)

  return (
    <div className="content-stack">
      <section className="summary-card">
        <div className="summary-copy">
          <span className="card-label">目前可用公費</span>
          <strong className="summary-amount">{fund?.configured ? formatCurrency(fund.balance) : '尚未設定'}</strong>
          <span className="summary-meta"><Icon name="sparkles" size={15} /> {fund?.configured ? `淨部位 ${formatCurrency(fund.netBalance)} · ${fund.status === 'active' ? '使用中' : fund.status === 'closing' ? '結清中' : '已結清'}` : cloudLedger ? '前往公費頁完成設定' : '先建立雲端帳本'}</span>
          <button className="summary-fund-link" type="button" onClick={onShowFund}>查看公費 <Icon name="chevron-right" size={14} /></button>
        </div>
        <div className="summary-art" aria-hidden="true">
          <span className="coin coin-one">$</span>
          <span className="coin coin-two">$</span>
          <span className="wallet-art"><Icon name="wallet" size={28} /></span>
        </div>
      </section>

      {invalidLedgers.length > 0 && (
        <div className="integrity-alert" role="alert"><Icon name="alert-circle" size={18} /><span><strong>{invalidLedgers.length} 筆資料未通過帳務檢查</strong>請到支出頁確認每位成員的分攤金額。</span></div>
      )}

      <section className="metric-grid" aria-label="成員分帳摘要">
        <article className="metric-card"><span className="metric-icon mint"><Icon name="receipt" size={19} /></span><div><span>成員分帳</span><strong>{formatCurrency(total)}</strong></div></article>
        <article className="metric-card"><span className="metric-icon peach"><Icon name="arrow-down" size={19} /></span><div><span>尚待收款</span><strong>{formatCurrency(transferTotal)}</strong></div></article>
      </section>

      <button className="settlement-overview-link" type="button" onClick={onShowSettlement}>
        <span className="settlement-link-icon"><Icon name="check" size={21} /></span>
        <span className="settlement-link-copy"><strong>結算與確認</strong><small>公費優先，成員分帳逐筆完成</small></span>
        <Icon name="chevron-right" size={18} />
      </button>

      <section className="section-block">
        <div className="section-heading">
          <div><p className="eyebrow">ACTIVITY</p><h2>最近支出</h2></div>
          {expenses.length > 0 && <button className="text-button" type="button" onClick={onShowExpenses}>查看全部 <Icon name="chevron-right" size={16} /></button>}
        </div>
        {recentExpenses.length > 0 ? (
          <div className="recent-list">
            {recentExpenses.map((ledger) => (
              <button className="recent-row" type="button" key={ledger.expense.id} onClick={onShowExpenses}>
                <span className={`recent-icon category-${ledger.expense.category}`}><Icon name="receipt" size={18} /></span>
                <div><strong>{ledger.expense.title}</strong><span>{formatDate(ledger.expense.date)} · {ledger.payer?.name ?? '未知付款人'}先付</span></div>
                <strong>{formatCurrency(ledger.expense.amount)}</strong>
              </button>
            ))}
          </div>
        ) : (
          <button className="empty-state compact overview-empty" type="button" onClick={onAddExpense}>
            <span className="empty-icon"><Icon name="receipt" size={26} /></span>
            <span><strong>還沒有任何支出</strong><small>新增第一筆支出，系統會逐項計算分攤。</small></span>
          </button>
        )}
      </section>
    </div>
  )
}
