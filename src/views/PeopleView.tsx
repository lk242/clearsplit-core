import { useEffect, useState, type FormEvent } from 'react'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import { MessagingConnectionsCard } from '../components/LineInviteCard'
import { LedgerDangerZone } from '../components/LedgerDangerZone'
import { LedgerDataTools } from '../components/LedgerDataTools'
import { Modal } from '../components/Modal'
import { participantColors } from '../data'
import { fetchCloudLedgerAccess, type CloudLedgerAccess, type MessagingProvider } from '../lib/cloudLedger'
import type { CloudLedgerState, Participant } from '../types'
import './PeopleView.css'

type PeopleViewProps = {
  participants: Participant[]
  formOpen: boolean
  editingParticipant: Participant | null
  onOpenCreate: () => void
  onOpenEdit: (participant: Participant) => void
  onCloseForm: () => void
  onChange: (participants: Participant[]) => void | Promise<void>
  expenseCounts: Record<string, number>
  cloudLedger: CloudLedgerState | null
  onEnableCloud: (groupName: string) => Promise<void>
  onRecoverCreatedSetup: () => Promise<void>
  onRestoreSetup: (setupKey: string) => Promise<void>
  onCreateInvite: () => Promise<{ url: string; expiresAt: string }>
  onCreateBindCode: (provider: MessagingProvider) => Promise<{ command: string; expiresAt: string; provider: MessagingProvider }>
  onCreateIdentityCode: (memberId: string, provider: MessagingProvider) => Promise<{ command: string; expiresAt: string; provider: MessagingProvider }>
  onRefreshCloud: () => Promise<void>
  onAssignResponsible: (memberId: string) => Promise<void>
  onResetLocal: () => void
  onDeleteCloud: (confirmation: string) => Promise<void>
  readOnly?: boolean
}

export function PeopleView({ participants, formOpen, editingParticipant, onOpenCreate, onOpenEdit, onCloseForm, onChange, expenseCounts, cloudLedger, onEnableCloud, onRecoverCreatedSetup, onRestoreSetup, onCreateInvite, onCreateBindCode, onCreateIdentityCode, onRefreshCloud, onAssignResponsible, onResetLocal, onDeleteCloud, readOnly = false }: PeopleViewProps) {
  const [deleteTarget, setDeleteTarget] = useState<Participant | null>(null)
  const [changeError, setChangeError] = useState('')
  const [assigningId, setAssigningId] = useState<string | null>(null)
  const [cloudAccess, setCloudAccess] = useState<CloudLedgerAccess | null>(null)
  const responsibleMemberId = participants.find((participant) => participant.isResponsible)?.id

  useEffect(() => {
    if (!cloudLedger) {
      setCloudAccess(null)
      setChangeError('')
      return
    }
    let active = true
    fetchCloudLedgerAccess(cloudLedger.groupId, cloudLedger.setupToken)
      .then((access) => { if (active) setCloudAccess(access) })
      .catch((reason) => { if (active) setChangeError(reason instanceof Error ? reason.message : '無法讀取帳本權限') })
    return () => { active = false }
  }, [cloudLedger, responsibleMemberId])

  const canManageCloud = cloudAccess?.isOwner === true && !readOnly
  const canSetup = cloudAccess?.canSetup === true && !readOnly
  const canRecoverSetup = cloudAccess?.hasResponsibleMember === false && !canManageCloud && !canSetup
  const canManage = (!cloudLedger || canManageCloud) && !readOnly
  const canAssignResponsible = canManageCloud || canSetup

  const saveParticipant = async (participant: Participant) => {
    const exists = participants.some((item) => item.id === participant.id)
    try {
      await onChange(exists
        ? participants.map((item) => item.id === participant.id ? participant : item)
        : [...participants, participant])
      setChangeError('')
      onCloseForm()
    } catch (reason) {
      setChangeError(reason instanceof Error ? reason.message : '無法更新成員')
    }
  }

  const deleteParticipant = async () => {
    if (!deleteTarget) return
    try {
      await onChange(participants.filter((participant) => participant.id !== deleteTarget.id))
      setChangeError('')
      setDeleteTarget(null)
    } catch (reason) {
      setChangeError(reason instanceof Error ? reason.message : '無法刪除成員')
    }
  }

  return (
    <>
      <MessagingConnectionsCard cloudLedger={cloudLedger} participants={participants} canManage={canManageCloud} canSetup={canSetup} canRecoverSetup={canRecoverSetup} onEnable={onEnableCloud} onRecoverCreatedSetup={onRecoverCreatedSetup} onRestoreSetup={onRestoreSetup} onCreateInvite={onCreateInvite} onCreateBindCode={onCreateBindCode} onCreateIdentityCode={onCreateIdentityCode} onRefresh={onRefreshCloud} onResetLocal={onResetLocal} />
      {changeError && (
        <div className="line-error" role="alert">
          <Icon name="alert-circle" size={16} />
          <span>{changeError}</span>
          {isAccessError(changeError) && <button type="button" onClick={onResetLocal}>清除舊連結</button>}
        </div>
      )}
      <div className="people-summary">
        <div className="avatar-stack" aria-hidden="true">
          {participants.slice(0, 4).map((participant) => <Avatar key={participant.id} participant={participant} size="small" />)}
        </div>
        <div><strong>{participants.length} 位成員</strong><span>共同參與這本帳</span></div>
        {canManage && <button className="secondary-button" type="button" onClick={onOpenCreate}><Icon name="user-plus" size={18} /> 新增</button>}
      </div>

      {participants.length > 0 ? (
        <section className="people-list" aria-label="參與者名單">
          {participants.map((participant, index) => (
            <article className="person-row" key={participant.id}>
              <Avatar participant={participant} size="large" />
              <div className="person-copy">
                <strong>{participant.name}</strong>
                <span>{participant.isResponsible ? '帳務負責人' : `參與成員 ${index + 1}`}</span>
              </div>
              <div className="row-actions">
                {canAssignResponsible && cloudLedger && !participant.isResponsible && <button className="responsible-button" type="button" disabled={assigningId !== null} onClick={async () => { setAssigningId(participant.id); setChangeError(''); try { await onAssignResponsible(participant.id) } catch (reason) { setChangeError(reason instanceof Error ? reason.message : '無法指派負責人') } finally { setAssigningId(null) } }}>{assigningId === participant.id ? '指派中' : '設為負責人'}</button>}
                {canManage && <button className="row-icon-button" type="button" aria-label={`編輯 ${participant.name}`} onClick={() => onOpenEdit(participant)}><Icon name="pencil" size={17} /></button>}
                {canManage && <button className="row-icon-button danger" type="button" aria-label={`刪除 ${participant.name}`} onClick={() => setDeleteTarget(participant)}><Icon name="trash" size={17} /></button>}
              </div>
            </article>
          ))}
        </section>
      ) : (
        <section className="empty-state large">
          <span className="empty-icon"><Icon name="users" size={30} /></span>
          <strong>{cloudLedger ? '邀請第一位成員' : '先建立帳本'}</strong>
          <p>{cloudLedger ? '點上方「邀請」分享連結，成員會用 LINE 名稱與頭像加入。' : '點上方「啟用」建立空白帳本，接著就能直接發送邀請。'}</p>
          {canManage && <button className="primary-button" type="button" onClick={onOpenCreate}><Icon name="plus" size={18} /> 新增成員</button>}
        </section>
      )}

      {cloudLedger && !cloudLedger.setupToken && <LedgerDataTools cloudLedger={cloudLedger} canExport={cloudAccess?.isOwner === true} />}
      {cloudLedger && <LedgerDangerZone cloudLedger={cloudLedger} onDelete={onDeleteCloud} />}

      <ParticipantForm open={formOpen && !readOnly} participant={editingParticipant} onClose={onCloseForm} onSave={saveParticipant} />

      <Modal open={deleteTarget !== null} title={deleteTarget && expenseCounts[deleteTarget.id] ? '目前無法刪除' : '刪除這位成員？'} description={deleteTarget && expenseCounts[deleteTarget.id] ? `這位成員仍與 ${expenseCounts[deleteTarget.id]} 筆帳目有關，請先刪除或修改相關帳目。` : '名單中將不再顯示這位成員。'} onClose={() => setDeleteTarget(null)} compact>
        {deleteTarget && (
          <div className="confirm-person">
            <Avatar participant={deleteTarget} size="large" />
            <strong>{deleteTarget.name}</strong>
          </div>
        )}
        <div className="modal-actions">
          <button className="secondary-button grow" type="button" onClick={() => setDeleteTarget(null)}>{deleteTarget && expenseCounts[deleteTarget.id] ? '知道了' : '保留'}</button>
          {deleteTarget && !expenseCounts[deleteTarget.id] && <button className="danger-button grow" type="button" onClick={deleteParticipant}>刪除</button>}
        </div>
      </Modal>
    </>
  )
}

function isAccessError(message: string) {
  return /permission|required|denied|無權限|工作階段/i.test(message)
}

function ParticipantForm({ open, participant, onClose, onSave }: { open: boolean; participant: Participant | null; onClose: () => void; onSave: (participant: Participant) => void }) {
  const [name, setName] = useState('')
  const [color, setColor] = useState(participantColors[0])
  const [error, setError] = useState('')

  useEffect(() => {
    if (!open) return
    setName(participant?.name ?? '')
    setColor(participant?.color ?? participantColors[0])
    setError('')
  }, [open, participant])

  const submit = (event: FormEvent) => {
    event.preventDefault()
    const trimmedName = name.trim()
    if (!trimmedName) {
      setError('請輸入成員名稱')
      return
    }

    onSave({
      id: participant?.id ?? createId(),
      name: trimmedName,
      color,
      createdAt: participant?.createdAt ?? new Date().toISOString(),
      avatarUrl: participant?.avatarUrl,
      isResponsible: participant?.isResponsible,
    })
  }

  const preview: Participant = { id: 'preview', name: name || '新', color, createdAt: '' }

  return (
    <Modal open={open} title={participant ? '編輯成員' : '新增成員'} description="用一個容易辨認的名稱與代表色。" onClose={onClose}>
      <form className="participant-form" onSubmit={submit}>
        <div className="form-preview"><Avatar participant={preview} size="large" /><span>{name.trim() || '新成員'}</span></div>
        <label className="field-label" htmlFor="participant-name">成員名稱</label>
        <input
          id="participant-name"
          className={error ? 'text-input has-error' : 'text-input'}
          value={name}
          onChange={(event) => { setName(event.target.value); setError('') }}
          placeholder="例如：小安"
          maxLength={24}
          autoFocus
        />
        {error && <span className="field-error">{error}</span>}
        <fieldset className="color-fieldset">
          <legend>代表色</legend>
          <div className="color-options">
            {participantColors.map((option) => (
              <button
                key={option}
                type="button"
                className={color === option ? 'color-option is-selected' : 'color-option'}
                style={{ backgroundColor: option }}
                onClick={() => setColor(option)}
                aria-label={`選擇顏色 ${option}`}
                aria-pressed={color === option}
              >
                {color === option && <Icon name="check" size={16} />}
              </button>
            ))}
          </div>
        </fieldset>
        <button className="primary-button full-width" type="submit"><Icon name="check" size={18} /> {participant ? '儲存變更' : '加入名單'}</button>
      </form>
    </Modal>
  )
}

function createId() {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
