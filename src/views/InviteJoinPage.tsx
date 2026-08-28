import { useEffect, useRef, useState } from 'react'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import { participantColors } from '../data'
import { joinCloudInviteWithLine, previewCloudInvite, resumeCloudInviteWithLine, type InvitePreview, type LineInviteMembershipStatus } from '../lib/cloudLedger'
import { isLiffConfigured, loadLineIdentity, type LineIdentity } from '../lib/lineLiff'
import type { CloudLedgerState, Participant } from '../types'
import { buildInviteCallbackUrl, buildInviteUrl } from '../utils/inviteUrl'
import { addLineAuthHandoffToUrl, clearPendingLineAuthHandoff, createLineAuthHandoff, isStandaloneWebApp, readLineAuthHandoffToken, readPendingLineAuthHandoff, removeLineAuthHandoffFromCurrentUrl } from '../utils/lineAuthHandoff'
import './InviteJoinPage.css'

type InviteJoinPageProps = {
  token: string
  onJoined: (ledger: CloudLedgerState, members: Participant[]) => void
}

export function InviteJoinPage({ token, onJoined }: InviteJoinPageProps) {
  const [callbackHandoffToken] = useState(() => readLineAuthHandoffToken(window.location.search))
  const [preview, setPreview] = useState<InvitePreview | null>(null)
  const [lineIdentity, setLineIdentity] = useState<LineIdentity | null>(null)
  const [membership, setMembership] = useState<LineInviteMembershipStatus | null>(null)
  const [membershipChecking, setMembershipChecking] = useState(false)
  const [identityChecking, setIdentityChecking] = useState(isLiffConfigured)
  const [membershipCheckFinished, setMembershipCheckFinished] = useState(false)
  const [color, setColor] = useState(participantColors[0])
  const [status, setStatus] = useState<'loading' | 'ready' | 'line-loading' | 'joining' | 'error'>('loading')
  const [error, setError] = useState('')
  const automaticEntryStarted = useRef(false)

  useEffect(() => {
    let active = true
    previewCloudInvite(token)
      .then((result) => {
        if (!active) return
        setPreview(result)
        if (!automaticEntryStarted.current) setStatus('ready')
      })
      .catch((reason) => {
        if (active && !automaticEntryStarted.current) {
          setError(toMessage(reason))
          setStatus('error')
        }
      })
    return () => { active = false }
  }, [token])

  useEffect(() => {
    if (!isLiffConfigured) { setIdentityChecking(false); return }
    loadLineIdentity(false)
      .then((identity) => { if (identity) setLineIdentity(identity) })
      .catch(() => undefined)
      .finally(() => setIdentityChecking(false))
  }, [])

  useEffect(() => {
    if (!lineIdentity) {
      setMembership(null)
      setMembershipChecking(false)
      setMembershipCheckFinished(true)
      return
    }
    let active = true
    setMembership(null)
    setMembershipChecking(true)
    setMembershipCheckFinished(false)
    resumeCloudInviteWithLine(token, lineIdentity.accessToken, callbackHandoffToken)
      .then((result) => {
        if (active) setMembership(result.membership)
        if (callbackHandoffToken) {
          clearPendingLineAuthHandoff(window.localStorage, callbackHandoffToken)
          removeLineAuthHandoffFromCurrentUrl()
        }
        if (!result.membership.isMember || !result.ledger || automaticEntryStarted.current) return

        automaticEntryStarted.current = true
        if (active) {
          setError('')
          setStatus('joining')
        }
        onJoined(result.ledger, result.members)
      })
      .catch((reason) => {
        if (!active) return
        setError(toMessage(reason))
        setStatus('ready')
        setMembership(null)
      })
      .finally(() => { if (active) { setMembershipChecking(false); setMembershipCheckFinished(true) } })
    return () => { active = false }
  }, [callbackHandoffToken, lineIdentity, onJoined, token])

  const loginWithLine = async () => {
    setStatus('line-loading')
    setError('')
    try {
      if (isStandaloneWebApp()) {
        const handoffToken = readPendingLineAuthHandoff(window.localStorage)
          ?? createLineAuthHandoff(window.localStorage)
        const liffInviteUrl = buildInviteUrl(token, import.meta.env.VITE_LIFF_ID, window.location.origin, window.location.pathname)
        window.location.assign(addLineAuthHandoffToUrl(liffInviteUrl, handoffToken))
        return
      }
      const callbackUrl = buildInviteCallbackUrl(token, window.location.origin, window.location.pathname)
      const redirectUrl = callbackHandoffToken
        ? addLineAuthHandoffToUrl(callbackUrl, callbackHandoffToken)
        : callbackUrl
      const identity = await loadLineIdentity(true, redirectUrl)
      if (identity) {
        setLineIdentity(identity)
        setStatus('ready')
      }
    } catch (reason) {
      setError(toMessage(reason))
      setStatus('ready')
    }
  }

  const join = async () => {
    if (!lineIdentity) return loginWithLine()
    setStatus('joining')
    setError('')
    try {
      const result = await joinCloudInviteWithLine(token, lineIdentity.accessToken, color, callbackHandoffToken)
      if (callbackHandoffToken) {
        clearPendingLineAuthHandoff(window.localStorage, callbackHandoffToken)
        removeLineAuthHandoffFromCurrentUrl()
      }
      onJoined(result.ledger, result.members)
    } catch (reason) {
      setError(toMessage(reason))
      setStatus('ready')
    }
  }

  const previewMember: Participant = { id: 'preview', name: lineIdentity?.displayName ?? '你', color, createdAt: '', avatarUrl: lineIdentity?.pictureUrl }
  const isReturningMember = membership?.isMember === true
  const automaticCheckPending = identityChecking || Boolean(lineIdentity && !membershipCheckFinished)

  return (
    <main className="invite-page">
      <section className="invite-brand"><span><Icon name="wallet" size={20} /></span><strong>ClearSplit</strong></section>
      <section className="join-card">
        <span className="line-hero-badge">LINE 邀請</span>
        {status === 'loading' && <div className="join-loading"><span /><strong>正在安全驗證邀請…</strong></div>}
        {status === 'joining' && !preview && <div className="join-loading"><span /><strong>已確認成員，正在前往正式帳本…</strong></div>}
        {status === 'error' && <div className="join-failure"><Icon name="alert-circle" size={28} /><strong>無法開啟邀請</strong><p>{error}</p></div>}
        {preview && status !== 'error' && (
          <>
            <p className="join-eyebrow">你受邀加入</p>
            <h1>{preview.groupName}</h1>
            <p className="join-description">使用 LINE 登入後，系統會帶入你的帳戶名稱與頭像；後端會向 LINE 驗證身分。</p>
            {automaticCheckPending ? <div className="join-loading"><span /><strong>正在確認 LINE 成員身分…</strong></div> : <div className="join-form">
              <div className="join-preview"><Avatar participant={previewMember} size="large" /><div><strong>{lineIdentity?.displayName ?? '尚未登入 LINE'}</strong><span>{lineIdentity ? membershipChecking ? '正在確認成員身分…' : isReturningMember ? '已是帳本成員，不會重複新增' : '名稱與頭像已由 LINE 帶入' : '不會讀取任何聊天內容'}</span></div></div>
              {!isReturningMember && <fieldset className="color-fieldset">
                <legend>代表色</legend>
                <div className="color-options">
                  {participantColors.map((option) => <button key={option} type="button" className={color === option ? 'color-option is-selected' : 'color-option'} style={{ backgroundColor: option }} onClick={() => setColor(option)} aria-label={`選擇顏色 ${option}`} aria-pressed={color === option}>{color === option && <Icon name="check" size={16} />}</button>)}
                </div>
              </fieldset>}
              {error && <div className="join-error" role="alert">{error}</div>}
              <button className="line-join-button" type="button" onClick={join} disabled={status === 'joining' || status === 'line-loading' || membershipChecking}>{membershipChecking ? '正在確認…' : status === 'joining' ? isReturningMember ? '正在進入…' : '正在加入…' : status === 'line-loading' ? '正在開啟 LINE…' : lineIdentity ? isReturningMember ? `以 ${lineIdentity.displayName} 繼續進入帳本` : `以 ${lineIdentity.displayName} 加入` : '使用 LINE 身分加入'}</button>
            </div>}
            <p className="join-privacy"><Icon name="check" size={14} />只取得名稱、頭像與不可逆顯示的成員身分，不會讀取 LINE 聊天記錄。</p>
          </>
        )}
      </section>
    </main>
  )
}

function toMessage(reason: unknown) {
  return reason instanceof Error ? reason.message : '發生未預期錯誤'
}
