import { useState, type FormEvent } from 'react'
import { formatLedgerSetupKey, type MessagingProvider } from '../lib/cloudLedger'
import type { CloudLedgerState, Participant } from '../types'
import { parseLineBotFriendUrl } from '../utils/lineBot'
import { Icon } from './Icon'
import { Modal } from './Modal'
import './LineInviteCard.css'

type LineInviteCardProps = {
  cloudLedger: CloudLedgerState | null
  participants: Participant[]
  canManage: boolean
  canSetup: boolean
  canRecoverSetup: boolean
  onEnable: (groupName: string) => Promise<void>
  onRecoverCreatedSetup: () => Promise<void>
  onRestoreSetup: (setupKey: string) => Promise<void>
  onCreateInvite: () => Promise<{ url: string; expiresAt: string }>
  onCreateBindCode: (provider: MessagingProvider) => Promise<{ command: string; expiresAt: string; provider: MessagingProvider }>
  onCreateIdentityCode: (memberId: string, provider: MessagingProvider) => Promise<{ command: string; expiresAt: string; provider: MessagingProvider }>
  onRefresh: () => Promise<void>
  onResetLocal: () => void
}

export function MessagingConnectionsCard({ cloudLedger, participants, canManage, canSetup, canRecoverSetup, onEnable, onRecoverCreatedSetup, onRestoreSetup, onCreateInvite, onCreateBindCode, onCreateIdentityCode, onRefresh, onResetLocal }: LineInviteCardProps) {
  const botFriendUrl = parseLineBotFriendUrl(import.meta.env.VITE_LINE_BOT_FRIEND_URL)
  const [provider, setProvider] = useState<MessagingProvider>('line')
  const [setupOpen, setSetupOpen] = useState(false)
  const [inviteOpen, setInviteOpen] = useState(false)
  const [groupName, setGroupName] = useState('我們的團體公帳')
  const [invite, setInvite] = useState<{ url: string; expiresAt: string } | null>(null)
  const [bindOpen, setBindOpen] = useState(false)
  const [resetOpen, setResetOpen] = useState(false)
  const [setupKeyOpen, setSetupKeyOpen] = useState(false)
  const [restoreOpen, setRestoreOpen] = useState(false)
  const [restoreValue, setRestoreValue] = useState('')
  const [bindCode, setBindCode] = useState<{ command: string; expiresAt: string; provider: MessagingProvider } | null>(null)
  const [identityCode, setIdentityCode] = useState<{ command: string; expiresAt: string; provider: MessagingProvider } | null>(null)
  const [identityMemberId, setIdentityMemberId] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [copied, setCopied] = useState(false)

  const enableCloud = async (event: FormEvent) => {
    event.preventDefault()
    const name = groupName.trim()
    if (!name) return setError('請輸入帳本名稱')
    setBusy(true)
    setError('')
    try {
      await onEnable(name)
      setCopied(false)
      setSetupOpen(false)
      setSetupKeyOpen(true)
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  const restoreSetup = async (event: FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      await onRestoreSetup(restoreValue)
      setRestoreOpen(false)
      setRestoreValue('')
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  const recoverCreatedSetup = async () => {
    setBusy(true)
    setError('')
    try {
      await onRecoverCreatedSetup()
      setCopied(false)
      setSetupKeyOpen(true)
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  const generateInvite = async () => {
    setBusy(true)
    setError('')
    setCopied(false)
    try {
      setInvite(await onCreateInvite())
      setInviteOpen(true)
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  const refresh = async () => {
    setBusy(true)
    setError('')
    try {
      await onRefresh()
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  const generateBindCode = async () => {
    setBusy(true)
    setError('')
    setCopied(false)
    try {
      setBindCode(await onCreateBindCode(provider))
      setBindOpen(true)
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  const generateIdentityCode = async () => {
    if (!identityMemberId) return setError('請先選擇要連結的成員')
    setBusy(true)
    setError('')
    setCopied(false)
    try {
      setIdentityCode(await onCreateIdentityCode(identityMemberId, provider))
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  const copyInvite = async () => {
    if (!invite) return
    await navigator.clipboard.writeText(invite.url)
    setCopied(true)
  }

  const lineText = invite && cloudLedger
    ? `邀請你加入「${cloudLedger.groupName}」一起記帳：\n${invite.url}`
    : ''
  const setupKey = cloudLedger?.setupToken
    ? formatLedgerSetupKey(cloudLedger.groupId, cloudLedger.setupToken)
    : null

  return (
    <>
      <section className="line-invite-card">
        <span className="line-badge">CHAT</span>
        <div className="line-invite-copy">
          <strong>{cloudLedger ? cloudLedger.groupName : '建立可協作的團體公帳'}</strong>
          <span>{cloudLedger ? (canSetup ? '等待指定帳務負責人；請妥善保存開帳碼' : canManage ? '連結 7 天有效；新成員確認後自動加入' : canRecoverSetup ? '已加入；回原開帳頁指派，或輸入開帳碼接手' : '由帳務負責人管理邀請與成員') : '先建立空白帳本，或輸入既有開帳碼'}</span>
        </div>
        {cloudLedger ? (
          <div className="line-actions">
            <button className="row-icon-button" type="button" aria-label="同步最新成員" onClick={refresh} disabled={busy}><Icon name="refresh" size={17} /></button>
            {canSetup && setupKey && <button className="line-mini-button" type="button" onClick={() => setSetupKeyOpen(true)}>開帳碼</button>}
            {canRecoverSetup && <button className="line-mini-button" type="button" onClick={() => setRestoreOpen(true)} disabled={busy}>輸入開帳碼</button>}
            {canManage && <button className="line-mini-button" type="button" onClick={() => { setBindOpen(true); setBindCode(null); setIdentityCode(null) }} disabled={busy}>Bots</button>}
            {(canManage || canSetup) && <button className="line-button" type="button" onClick={generateInvite} disabled={busy}><Icon name="share" size={17} />邀請</button>}
          </div>
        ) : (
          <div className="line-actions">
            <button className="line-mini-button" type="button" onClick={recoverCreatedSetup} disabled={busy}>{busy ? '尋找中' : '找回未完成'}</button>
            <button className="line-mini-button" type="button" onClick={() => setRestoreOpen(true)} disabled={busy}>輸入開帳碼</button>
            <button className="line-button" type="button" onClick={() => setSetupOpen(true)} disabled={busy}><Icon name="cloud" size={17} />建立</button>
          </div>
        )}
      </section>
      {error && <div className="line-error" role="alert"><Icon name="alert-circle" size={16} /><span>{error}</span>{isAccessError(error) && <button type="button" onClick={() => setResetOpen(true)}>重新開始</button>}</div>}

      <Modal open={setupOpen} title="建立帳本並開始邀請" description={"不建立獨立管理者；系統會提供一次性開帳碼，成員到齊後用它指定帳務負責人。"} onClose={() => !busy && setSetupOpen(false)}>
        <form onSubmit={enableCloud}>
          <label className="field-label" htmlFor="cloud-group-name">帳本名稱</label>
          <input id="cloud-group-name" className="text-input" value={groupName} maxLength={80} onChange={(event) => { setGroupName(event.target.value); setError('') }} />
          <div className="migration-note"><Icon name="check" size={17} /><span>開帳碼只在指定第一位負責人前有效；不會建立沒有驗證身分的假成員。</span></div>
          <button className="primary-button full-width" type="submit" disabled={busy}>{busy ? '建立安全帳本中…' : '建立並開始邀請'}</button>
        </form>
      </Modal>

      <Modal open={setupKeyOpen} title="備份一次性開帳碼" description="任何持有此碼的人都能在負責人尚未指定前邀請成員並完成首次指派。指定後立即失效。" onClose={() => setSetupKeyOpen(false)}>
        {setupKey && cloudLedger?.setupExpiresAt && (
          <div className="invite-sheet">
            <div className="setup-key-warning"><Icon name="alert-circle" size={18} /><span>請先複製保存；不要貼到公開群組。</span></div>
            <div className="invite-link-box"><span>開帳設定碼</span><code>{setupKey}</code></div>
            <span className="invite-expiry">有效至 {new Date(cloudLedger.setupExpiresAt).toLocaleString('zh-TW')}</span>
            <button className="primary-button full-width" type="button" onClick={async () => { await navigator.clipboard.writeText(setupKey); setCopied(true) }}>{copied ? '已複製開帳碼' : '複製開帳碼'}</button>
          </div>
        )}
      </Modal>

      <Modal open={restoreOpen} title="輸入開帳設定碼" description="可在另一台裝置繼續邀請成員與指定第一位帳務負責人。" onClose={() => !busy && setRestoreOpen(false)}>
        <form onSubmit={restoreSetup}>
          <label className="field-label" htmlFor="ledger-setup-key">完整開帳設定碼</label>
          <textarea id="ledger-setup-key" className="setup-key-input" value={restoreValue} onChange={(event) => { setRestoreValue(event.target.value); setError('') }} autoComplete="off" spellCheck={false} />
          {error && <div className="line-error" role="alert"><Icon name="alert-circle" size={16} /><span>{error}</span></div>}
          <button className="primary-button full-width" type="submit" disabled={busy || !restoreValue.trim()}>{busy ? '正在驗證…' : '恢復開帳流程'}</button>
        </form>
      </Modal>

      <Modal open={inviteOpen} title="分享帳本邀請" description="每位成員都要自己開啟並確認名稱，系統不會從聊天群組偷偷匯入名單。" onClose={() => setInviteOpen(false)}>
        {invite && cloudLedger && (
          <div className="invite-sheet">
            <div className="invite-link-box"><span>邀請連結</span><code>{invite.url}</code></div>
            <span className="invite-expiry">有效至 {new Date(invite.expiresAt).toLocaleString('zh-TW')}</span>
            <a className="line-share-button" href={`https://line.me/R/share?text=${encodeURIComponent(lineText)}`} target="_blank" rel="noreferrer"><Icon name="share" size={18} />分享到 LINE</a>
            <button className="secondary-button full-width" type="button" onClick={copyInvite}>{copied ? '已複製連結' : '複製連結'}</button>
          </div>
        )}
      </Modal>

      <Modal open={bindOpen} title="連接聊天 Bot" description="先綁定群組，再為每位發話者建立一次性身分連結碼。所有訊息只會成為待確認草稿。" onClose={() => setBindOpen(false)}>
        <div className="invite-sheet">
          <label className="field-label" htmlFor="messaging-provider">通訊服務</label>
          <select id="messaging-provider" className="text-input" value={provider} onChange={(event) => { setProvider(event.target.value as MessagingProvider); setBindCode(null); setIdentityCode(null); setCopied(false) }}>
            <option value="line">LINE</option><option value="discord">Discord</option><option value="telegram">Telegram</option>
          </select>
          {providerBotUrl(provider, botFriendUrl) ? (
            <a className="bot-add-friend" href={providerBotUrl(provider, botFriendUrl) ?? undefined} target="_blank" rel="noreferrer"><span className="line-badge">{providerLabel(provider)}</span><span><strong>加入 ClearSplit Bot</strong><small>{providerSetupHint(provider)}</small></span><Icon name="chevron-right" size={18} /></a>
          ) : <div className="bot-not-ready"><Icon name="alert-circle" size={18} /><span><strong>{providerLabel(provider)} Bot 尚未設定公開加入網址</strong><small>部署者可在環境變數加入 Bot URL；不影響手動綁定。</small></span></div>}
          <button className="primary-button full-width" type="button" onClick={generateBindCode} disabled={busy}>{busy ? '產生中…' : '產生群組綁定碼'}</button>
          {bindCode?.provider === provider && <>
            <div className="bind-command"><code>{bindCode.command}</code></div>
            <span className="invite-expiry">有效至 {new Date(bindCode.expiresAt).toLocaleString('zh-TW')}</span>
            <button className="secondary-button full-width" type="button" onClick={async () => { await navigator.clipboard.writeText(bindCode.command); setCopied(true) }}><Icon name="share" size={18} />{copied ? '已複製' : '複製群組綁定指令'}</button>
          </>}
          <label className="field-label" htmlFor="messaging-member">要連結的帳本成員</label>
          <select id="messaging-member" className="text-input" value={identityMemberId} onChange={(event) => { setIdentityMemberId(event.target.value); setIdentityCode(null) }}>
            <option value="">請選擇成員</option>{participants.map((member) => <option key={member.id} value={member.id}>{member.name}</option>)}
          </select>
          <button className="secondary-button full-width" type="button" onClick={generateIdentityCode} disabled={busy || !identityMemberId}>產生個人身分連結碼</button>
          {identityCode?.provider === provider && <>
            <div className="bind-command"><code>{identityCode.command}</code></div>
            <span className="invite-expiry">有效至 {new Date(identityCode.expiresAt).toLocaleString('zh-TW')}</span>
            <button className="secondary-button full-width" type="button" onClick={async () => { await navigator.clipboard.writeText(identityCode.command); setCopied(true) }}><Icon name="share" size={18} />複製身分連結指令</button>
          </>}
          <div className="bot-format"><strong>公帳支出草稿（不記私人代墊）</strong><code>{providerExpenseExample(provider)}</code></div>
        </div>
      </Modal>

      <Modal open={resetOpen} title="移除這台裝置的失效連結？" description="這只會清除目前裝置上的帳本連結與暫存畫面，不會刪除 Supabase 上的帳本或其他成員資料。" onClose={() => setResetOpen(false)} compact>
        <div className="modal-actions">
          <button className="secondary-button grow" type="button" onClick={() => setResetOpen(false)}>取消</button>
          <button className="danger-button grow" type="button" onClick={() => { onResetLocal(); setResetOpen(false); setError('') }}>移除本機連結</button>
        </div>
      </Modal>
    </>
  )
}

function toMessage(reason: unknown) {
  return reason instanceof Error ? reason.message : '發生未預期錯誤'
}

function isAccessError(message: string) {
  return /permission|required|denied|無權限|工作階段/i.test(message)
}

function providerLabel(provider: MessagingProvider) {
  return provider === 'line' ? 'LINE' : provider === 'discord' ? 'Discord' : 'Telegram'
}

function providerExpenseExample(provider: MessagingProvider) {
  return provider === 'line' ? '#記帳 晚餐 400' : provider === 'discord' ? '/clearsplit expense title:晚餐 amount:400' : '/expense 晚餐 400'
}

function providerSetupHint(provider: MessagingProvider) {
  return provider === 'line' ? '加入好友後邀請進群組' : provider === 'discord' ? '把 App 加入你的 Server' : '開啟 Bot 後加入群組'
}

function providerBotUrl(provider: MessagingProvider, lineUrl: string | null) {
  if (provider === 'line') return lineUrl
  const value = provider === 'discord' ? import.meta.env.VITE_DISCORD_BOT_INVITE_URL : import.meta.env.VITE_TELEGRAM_BOT_URL
  try {
    const url = new URL(value)
    return url.protocol === 'https:' ? url.toString() : null
  } catch {
    return null
  }
}
