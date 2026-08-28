import { useEffect, useState, type FormEvent } from 'react'
import type { LedgerDirectory, LedgerSummary } from '../types'
import { Icon } from './Icon'
import { Modal } from './Modal'
import './LedgerSwitcher.css'

type Props = {
  directory: LedgerDirectory | null
  activeGroupId?: string
  open: boolean
  busy: boolean
  error: string
  onOpen: () => void
  onClose: () => void
  onSelect: (ledger: LedgerSummary) => Promise<void>
  onCreate: (name: string) => Promise<void>
  onArchive: (ledger: LedgerSummary) => Promise<void>
  onRestore: (ledger: LedgerSummary) => Promise<void>
}

export function LedgerSwitcher({ directory, activeGroupId, open, busy, error, onOpen, onClose, onSelect, onCreate, onArchive, onRestore }: Props) {
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')

  useEffect(() => {
    if (!open) {
      setCreating(false)
      setName('')
    }
  }, [open])

  const activeLedger = directory?.ledgers.find((ledger) => ledger.groupId === activeGroupId)
  const canCreate = Boolean(directory) && directory!.usage.activeOwned < directory!.limits.activeOwned
    && directory!.usage.totalOwned < directory!.limits.totalOwned
  const canRestore = Boolean(directory) && directory!.usage.activeOwned < directory!.limits.activeOwned
  const createLabel = !directory ? '請先用 LINE 登入'
    : directory.usage.activeOwned >= directory.limits.activeOwned ? '已達進行中帳本上限'
      : directory.usage.totalOwned >= directory.limits.totalOwned ? '已達建立帳本總上限' : '建立新帳本'

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    const trimmed = name.trim()
    if (!trimmed) return
    try {
      await onCreate(trimmed)
      setName('')
      setCreating(false)
    } catch {
      // The parent keeps the user-facing error in this modal.
    }
  }

  return (
    <>
      <button className="ledger-switch-button" type="button" onClick={onOpen} aria-label="切換或管理帳本">
        <Icon name="wallet" size={17} />
        <span>{activeLedger?.groupName ?? '選擇帳本'}</span>
        <Icon name="chevron-down" size={15} />
      </button>
      <Modal open={open} title="我的帳本" description="建立者是歷史紀錄；只有目前負責人具有管理權限。" onClose={onClose}>
        {directory && (
          <div className="ledger-quota" aria-label="帳本配額">
            <span>負責中 <strong>{directory.usage.activeOwned}/{directory.limits.activeOwned}</strong></span>
            <span>建立總數 <strong>{directory.usage.totalOwned}/{directory.limits.totalOwned}</strong></span>
            <span>受邀加入 <strong>{directory.usage.activeJoined}/{directory.limits.activeJoined}</strong></span>
          </div>
        )}
        {error && <div className="form-error" role="alert"><Icon name="alert-circle" size={17} />{error}</div>}
        <div className="ledger-list">
          {directory?.ledgers.map((ledger) => (
            <article className={ledger.groupId === activeGroupId ? 'ledger-option is-active' : 'ledger-option'} key={ledger.groupId}>
              <button type="button" disabled={busy} onClick={() => void onSelect(ledger).catch(() => undefined)}>
                <span className="ledger-option-title"><strong>{ledger.groupName}</strong>{ledger.groupId === activeGroupId && <em>目前</em>}</span>
                <span className="ledger-option-meta">
                  {ledger.isCreator ? '建立者' : '非建立者'} · {ledger.isOwner ? '目前負責人' : '受邀加入者'} · {ledger.memberCount} 人
                </span>
              </button>
              <span className={ledger.status === 'archived' ? 'ledger-state is-archived' : 'ledger-state'}>{ledger.status === 'archived' ? '已封存' : '進行中'}</span>
              {ledger.isOwner && (ledger.status === 'active'
                ? <button className="ledger-text-action" type="button" disabled={busy} onClick={() => void onArchive(ledger).catch(() => undefined)}>封存</button>
                : <button className="ledger-text-action" type="button" disabled={busy || !canRestore} onClick={() => void onRestore(ledger).catch(() => undefined)}>恢復</button>)}
            </article>
          ))}
          {directory?.ledgers.length === 0 && <div className="ledger-empty">這個 LINE 帳號還沒有帳本。</div>}
        </div>
        {creating ? (
          <form className="ledger-create-form" onSubmit={(event) => void submit(event)}>
            <label className="field-label" htmlFor="new-ledger-name">新帳本名稱</label>
            <input id="new-ledger-name" className="text-input" value={name} onChange={(event) => setName(event.target.value)} maxLength={80} autoFocus placeholder="例如：北海道家族旅行" />
            <div className="modal-actions">
              <button className="secondary-button grow" type="button" disabled={busy} onClick={() => setCreating(false)}>取消</button>
              <button className="primary-button grow no-margin" type="submit" disabled={busy || !name.trim()}>{busy ? '建立中…' : '建立帳本'}</button>
            </div>
          </form>
        ) : (
          <button className="primary-button full-width" type="button" disabled={busy || !canCreate} onClick={() => setCreating(true)}>
            <Icon name="plus" size={18} /> {createLabel}
          </button>
        )}
      </Modal>
    </>
  )
}
