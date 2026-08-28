import { useCallback, useEffect, useState } from 'react'
import {
  cancelMessagingFundExpenseDraft,
  confirmMessagingFundExpenseDraft,
  type DuplicateFundTransactionCandidate,
  fetchMessagingFundExpenseDrafts,
  type GroupFund,
  type MessagingFundExpenseDraft,
} from '../lib/cloudLedger'
import type { CloudLedgerState, Participant } from '../types'
import { formatCurrency, formatDate } from '../utils/format'
import { Icon } from './Icon'
import { Modal } from './Modal'
import './LineDraftsCard.css'

type Props = {
  cloudLedger: CloudLedgerState
  fund: Extract<GroupFund, { configured: true }>
  participants: Participant[]
  isOwner: boolean
  onFundUpdated: (fund: GroupFund) => void
  readOnly?: boolean
}

type DuplicatePrompt = {
  draft: MessagingFundExpenseDraft
  candidate: DuplicateFundTransactionCandidate
  advanceMemberId: string | null
}

export function MessagingFundDraftsCard({ cloudLedger, fund, participants, isOwner, onFundUpdated, readOnly = false }: Props) {
  const [drafts, setDrafts] = useState<MessagingFundExpenseDraft[]>([])
  const [advanceMembers, setAdvanceMembers] = useState<Record<string, string>>({})
  const [loadingId, setLoadingId] = useState<string | null>(null)
  const [error, setError] = useState('')
  const [duplicatePrompt, setDuplicatePrompt] = useState<DuplicatePrompt | null>(null)

  const refresh = useCallback(async () => {
    try {
      setDrafts(await fetchMessagingFundExpenseDrafts(cloudLedger.groupId))
      setError('')
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : '無法讀取通訊公帳草稿')
    }
  }, [cloudLedger.groupId])

  useEffect(() => {
    void refresh()
    const timer = window.setInterval(() => void refresh(), 10_000)
    return () => window.clearInterval(timer)
  }, [refresh])

  const confirm = async (draft: MessagingFundExpenseDraft, allowDuplicate = false, fixedAdvanceMemberId?: string | null) => {
    const needsAdvance = draft.amount > fund.balance
    const advanceMemberId = fixedAdvanceMemberId ?? advanceMembers[draft.id] ?? draft.submittedMemberId
    if (needsAdvance && !advanceMemberId) {
      setError('這筆支出超過目前可用公費，請先選擇代墊成員')
      return
    }
    setLoadingId(draft.id)
    setError('')
    try {
      const result = await confirmMessagingFundExpenseDraft({
        draftId: draft.id,
        advanceMemberId,
        allowDuplicate,
      })
      if (result.status === 'duplicate') {
        setDuplicatePrompt({ draft, candidate: result.candidate, advanceMemberId })
        return
      }
      setDuplicatePrompt(null)
      onFundUpdated(result.fund)
      await refresh()
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : '通訊公帳草稿無法入帳')
    } finally {
      setLoadingId(null)
    }
  }

  const cancel = async (draft: MessagingFundExpenseDraft) => {
    if (!window.confirm(`確定取消「${draft.title}」的 ${providerLabel(draft.provider)} 公帳草稿？這不會刪除已入帳資料。`)) return
    setLoadingId(draft.id)
    setError('')
    try {
      await cancelMessagingFundExpenseDraft(draft.id)
      await refresh()
    } catch (nextError) {
      setError(nextError instanceof Error ? nextError.message : '通訊公帳草稿無法取消')
    } finally {
      setLoadingId(null)
    }
  }

  if (drafts.length === 0 && !error) return null

  return (
    <>
      <section className="line-drafts-card" aria-label="通訊服務公帳待確認草稿">
        <div className="line-drafts-heading">
          <div><span className="line-badge">CHAT</span><strong>公帳待確認草稿</strong></div>
          <button type="button" onClick={() => void refresh()} aria-label="重新整理通訊公帳草稿"><Icon name="refresh" size={16} /></button>
        </div>
        <p>Bot 只建立公帳草稿，不會新增私人代墊；由帳務負責人核對後才正式入帳。</p>
        {error && <div className="line-draft-error" role="alert">{error}</div>}
        <div className="line-draft-list">
          {drafts.map((draft) => {
            const needsAdvance = draft.amount > fund.balance
            const selectedAdvanceMember = advanceMembers[draft.id] ?? draft.submittedMemberId
            const canConfirm = isOwner && fund.status === 'active' && (!needsAdvance || selectedAdvanceMember !== '')
            return (
              <article className={needsAdvance ? 'line-draft-row has-duplicate-warning' : 'line-draft-row'} key={draft.id}>
                <div className="line-draft-main">
                  <strong><span className="line-badge">{providerLabel(draft.provider)}</span> {draft.title}</strong>
                  <span>{formatDate(draft.effectiveDate)} · {formatCurrency(draft.amount)} · {draft.submittedDisplayName} 回報</span>
                  {needsAdvance && <small className="duplicate-hint"><Icon name="alert-circle" size={13} />超過可用公費 {formatCurrency(fund.balance)}，差額將列為成員代墊</small>}
                  {needsAdvance && isOwner && (
                    <label className="field-label">代墊成員
                      <select className="text-input" value={selectedAdvanceMember} onChange={(event) => setAdvanceMembers((current) => ({ ...current, [draft.id]: event.target.value }))}>
                        {participants.map((member) => <option key={member.id} value={member.id}>{member.name}</option>)}
                      </select>
                      <small>預設為訊息回報者；入帳前請確認實際代墊人。</small>
                    </label>
                  )}
                </div>
                <div className="line-draft-actions">
                  {isOwner ? (
                    <>
                      <button className="primary-button" type="button" disabled={readOnly || !canConfirm || loadingId === draft.id} onClick={() => void confirm(draft)}>{loadingId === draft.id ? '處理中…' : '核對並入帳'}</button>
                      <button className="secondary-button" type="button" disabled={readOnly || loadingId === draft.id} onClick={() => void cancel(draft)}>取消草稿</button>
                    </>
                  ) : <small>等待帳務負責人核對</small>}
                </div>
              </article>
            )
          })}
        </div>
      </section>

      <Modal
        open={duplicatePrompt !== null}
        title="可能重複入帳"
        description="同一期、同一天與同金額已有一筆公費支出。請核對後再決定。"
        onClose={() => loadingId === null && setDuplicatePrompt(null)}
        compact
      >
        {duplicatePrompt && (
          <div className="duplicate-review">
            <div className="duplicate-review-row"><span>{providerLabel(duplicatePrompt.draft.provider)} 草稿</span><strong>{duplicatePrompt.draft.title}</strong><b>{formatCurrency(duplicatePrompt.draft.amount)}</b></div>
            <div className="duplicate-review-row is-existing"><span>既有公帳</span><strong>{duplicatePrompt.candidate.title}</strong><b>{formatCurrency(duplicatePrompt.candidate.amount)}</b><small>第 {duplicatePrompt.candidate.cycleNumber} 期 · {formatDate(duplicatePrompt.candidate.date)}</small></div>
            <p><Icon name="alert-circle" size={16} />{duplicatePrompt.candidate.reason === 'exact_match' ? '名稱也相同，高度可能是同一筆。' : '名稱不同，但日期與金額相同。'}</p>
            <div className="modal-actions">
              <button className="secondary-button grow" type="button" disabled={loadingId !== null} onClick={() => setDuplicatePrompt(null)}>先不入帳</button>
              <button className="danger-button grow" type="button" disabled={loadingId !== null} onClick={() => void confirm(duplicatePrompt.draft, true, duplicatePrompt.advanceMemberId)}>{loadingId ? '處理中…' : '確認不是重複，仍要入帳'}</button>
            </div>
          </div>
        )}
      </Modal>
    </>
  )
}

function providerLabel(provider: MessagingFundExpenseDraft['provider']) {
  return provider === 'line' ? 'LINE' : provider === 'discord' ? 'Discord' : 'Telegram'
}
