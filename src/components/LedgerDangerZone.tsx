import { useEffect, useState } from 'react'
import type { CloudLedgerState } from '../types'
import { fetchCloudLedgerAccess, type CloudLedgerAccess } from '../lib/cloudLedger'
import { Icon } from './Icon'
import { Modal } from './Modal'
import './LedgerDangerZone.css'

type Props = {
  cloudLedger: CloudLedgerState
  onDelete: (confirmation: string) => Promise<void>
}

export function LedgerDangerZone({ cloudLedger, onDelete }: Props) {
  const [access, setAccess] = useState<CloudLedgerAccess | null>(null)
  const [open, setOpen] = useState(false)
  const [confirmation, setConfirmation] = useState('')
  const [understood, setUnderstood] = useState(false)
  const [backupHandled, setBackupHandled] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    let active = true
    fetchCloudLedgerAccess(cloudLedger.groupId, cloudLedger.setupToken)
      .then((result) => { if (active) setAccess(result) })
      .catch((reason) => { if (active) setError(toMessage(reason)) })
    return () => { active = false }
  }, [cloudLedger.groupId, cloudLedger.setupToken])

  if (!access || (!access.isOwner && !access.canSetup)) return null

  const exactMatch = confirmation === access.groupName
  const close = () => {
    if (busy) return
    setOpen(false)
    setConfirmation('')
    setUnderstood(false)
    setBackupHandled(false)
    setError('')
  }
  const remove = async () => {
    if (!exactMatch || !understood || !backupHandled) return
    setBusy(true)
    setError('')
    try {
      await onDelete(confirmation)
    } catch (reason) {
      setError(toMessage(reason))
      setBusy(false)
    }
  }

  return (
    <>
      <section className="ledger-danger-zone">
        <div>
          <span>資料管理</span>
          <strong>刪除整本帳本</strong>
          <small>{access.canSetup ? '開帳碼持有人可在首次指派前刪除。' : '僅帳務負責人可執行；刪除後可立即建立下一本帳。'}</small>
        </div>
        <button className="danger-outline-button" type="button" onClick={() => setOpen(true)}><Icon name="trash" size={16} />刪除帳本</button>
      </section>

      <Modal open={open} title="永久刪除整本帳本？" description="此動作會刪除雲端帳本及其所有相依資料，無法從網站復原。" onClose={close}>
        <div className="ledger-delete-sheet">
          <div className="ledger-delete-counts">
            <div><span>成員</span><strong>{access.memberCount}</strong></div>
            <div><span>帳目</span><strong>{access.expenseCount}</strong></div>
          </div>
          <div className="ledger-delete-warning"><Icon name="alert-circle" size={18} /><span>刪除後，所有舊邀請連結與 LINE 群組綁定都會失效。建議先用上方資料工具下載 JSON 備份。</span></div>
          <label className="field-label" htmlFor="ledger-delete-confirmation">輸入完整帳本名稱「{access.groupName}」</label>
          <input id="ledger-delete-confirmation" className="text-input" value={confirmation} onChange={(event) => { setConfirmation(event.target.value); setError('') }} autoComplete="off" />
          <label className="ledger-delete-check"><input type="checkbox" checked={understood} onChange={(event) => setUnderstood(event.target.checked)} /><span>我了解此帳本資料會被永久刪除</span></label>
          <label className="ledger-delete-check"><input type="checkbox" checked={backupHandled} onChange={(event) => setBackupHandled(event.target.checked)} /><span>我已完成備份，或確認不需要保留備份</span></label>
          {error && <div className="line-error" role="alert"><Icon name="alert-circle" size={16} />{error}</div>}
          <div className="modal-actions">
            <button className="secondary-button grow" type="button" onClick={close} disabled={busy}>取消</button>
            <button className="danger-button grow" type="button" onClick={() => void remove()} disabled={!exactMatch || !understood || !backupHandled || busy}>{busy ? '正在刪除…' : '永久刪除帳本'}</button>
          </div>
        </div>
      </Modal>
    </>
  )
}

function toMessage(reason: unknown) {
  return reason instanceof Error ? reason.message : '發生未預期錯誤'
}
