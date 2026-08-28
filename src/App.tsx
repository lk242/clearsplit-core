import { useCallback, useEffect, useRef, useState } from 'react'
import { Icon, type IconName } from './components/Icon'
import { LedgerSwitcher } from './components/LedgerSwitcher'
import { InstallAppButton } from './components/InstallAppButton'
import { defaultExpenses, defaultParticipants } from './data'
import { useLocalStorage } from './hooks/useLocalStorage'
import { useI18n, type TranslationKey } from './i18n'
import { applyBootstrapMapping, archiveCloudLedger, assignResponsibleMember, bootstrapCloudLedger, createCloudInvite, createMessagingBindCode, createMessagingIdentityCode, deleteCloudExpense, deleteCloudLedger, exchangeLineAuthHandoff, fetchCloudExpenses, fetchCloudMembers, ledgerSummaryToState, listCloudLedgers, markResponsibleMember, mergeJoinedLedgerAccess, persistCloudMemberChanges, recoverIncompleteLedgerSetup, restoreArchivedCloudLedger, restoreCloudLedgerWithLine, restoreLedgerSetup, restorePersistedLineAccount, saveCloudExpense, selectCloudLedger, type LineAccountProfile, type MessagingProvider, type RestoredLineAccount } from './lib/cloudLedger'
import { isLiffConfigured, loadLineIdentity } from './lib/lineLiff'
import type { CloudLedgerState, Expense, LedgerDirectory, LedgerHandoffReceipt, LedgerSummary, Participant, TextScale, Theme } from './types'
import { isCloudLedgerState, isExpenseArray, isLedgerHandoffReceipt, isParticipantArray, isTextScale, isTheme } from './utils/storageValidation'
import { prepareProductionStorage } from './utils/demoStorage'
import { buildInviteUrl, readInviteToken } from './utils/inviteUrl'
import { addLineAuthHandoffToUrl, buildLineAuthHandoffLiffUrl, clearPendingLineAuthHandoff, createLineAuthHandoff, isStandaloneWebApp, readLineAuthHandoffToken, readPendingLineAuthHandoff, recoverLineCallbackBeforePersistedSession, removeLineAuthHandoffFromCurrentUrl } from './utils/lineAuthHandoff'
import { ExpensesView } from './views/ExpensesView'
import { OverviewView } from './views/OverviewView'
import { PeopleView } from './views/PeopleView'
import { SettlementView } from './views/SettlementView'
import { InviteJoinPage } from './views/InviteJoinPage'
import { FundView } from './views/FundView'
import { HandoffCompleteView } from './views/HandoffCompleteView'
import './App.css'

type View = 'overview' | 'expenses' | 'fund' | 'settlement' | 'people'
type LineRecoveryStatus = 'idle' | 'checking' | 'restoring' | 'synced' | 'login-required' | 'not-member' | 'error'

const navigation: Array<{ id: View; label: TranslationKey; icon: IconName }> = [
  { id: 'overview', label: 'nav.overview', icon: 'home' },
  { id: 'expenses', label: 'nav.expenses', icon: 'receipt' },
  { id: 'fund', label: 'nav.fund', icon: 'wallet' },
  { id: 'settlement', label: 'nav.settlement', icon: 'check' },
  { id: 'people', label: 'nav.people', icon: 'users' },
]

const viewTitleKeys: Record<View, { eyebrow: TranslationKey; title: TranslationKey }> = {
  overview: { eyebrow: 'view.overview.eyebrow', title: 'view.overview.title' },
  expenses: { eyebrow: 'view.expenses.eyebrow', title: 'view.expenses.title' },
  fund: { eyebrow: 'view.fund.eyebrow', title: 'view.fund.title' },
  settlement: { eyebrow: 'view.settlement.eyebrow', title: 'view.settlement.title' },
  people: { eyebrow: 'view.people.eyebrow', title: 'view.people.title' },
}

function App() {
  const { locale, setLocale, t } = useI18n()
  prepareProductionStorage(window.localStorage, import.meta.env.PROD)
  const [activeView, setActiveView] = useState<View>('overview')
  const [participants, setParticipants] = useLocalStorage<Participant[]>('clearsplit-participants', import.meta.env.DEV ? defaultParticipants : [], isParticipantArray)
  const [expenses, setExpenses] = useLocalStorage<Expense[]>('clearsplit-expenses', () => {
    if (!import.meta.env.DEV) return []
    const participantIds = new Set(participants.map((participant) => participant.id))
    return defaultExpenses.every((expense) => participantIds.has(expense.paidById) && expense.participantIds.every((id) => participantIds.has(id))) ? defaultExpenses : []
  }, isExpenseArray)
  const [theme, setTheme] = useLocalStorage<Theme>('clearsplit-theme', getPreferredTheme, isTheme)
  const [textScale, setTextScale] = useLocalStorage<TextScale>('clearsplit-text-scale', 'normal', isTextScale)
  const [cloudLedger, setCloudLedger] = useLocalStorage<CloudLedgerState | null>('clearsplit-cloud-ledger', null, (value): value is CloudLedgerState | null => value === null || isCloudLedgerState(value))
  const [pendingInviteToken, setPendingInviteToken] = useState(() => readInviteToken(window.location.search))
  const [participantFormOpen, setParticipantFormOpen] = useState(false)
  const [editingParticipant, setEditingParticipant] = useState<Participant | null>(null)
  const [expenseFormOpen, setExpenseFormOpen] = useState(false)
  const [editingExpense, setEditingExpense] = useState<Expense | null>(null)
  const [handoffReceipt, setHandoffReceipt] = useLocalStorage<LedgerHandoffReceipt | null>('clearsplit-handoff-receipt', null, (value): value is LedgerHandoffReceipt | null => value === null || isLedgerHandoffReceipt(value))
  const [cloudSync, setCloudSync] = useState<{ status: 'idle' | 'syncing' | 'synced' | 'error'; at: string | null }>({ status: 'idle', at: null })
  const [lineRecoveryStatus, setLineRecoveryStatus] = useState<LineRecoveryStatus>(isLiffConfigured && !pendingInviteToken ? 'checking' : 'idle')
  const [lineRecoveryError, setLineRecoveryError] = useState('')
  const [lineHandoffCompleted, setLineHandoffCompleted] = useState(getVisualTestLineHandoffCompleted)
  const [initialLineHandoffToken] = useState(() => readLineAuthHandoffToken(window.location.search))
  const [lineProfile, setLineProfile] = useState<LineAccountProfile | null>(getVisualTestLineProfile)
  const [ledgerDirectory, setLedgerDirectory] = useState<LedgerDirectory | null>(getVisualTestLedgerDirectory)
  const [ledgerManagerOpen, setLedgerManagerOpen] = useState(false)
  const [ledgerManagerBusy, setLedgerManagerBusy] = useState(false)
  const [ledgerManagerError, setLedgerManagerError] = useState('')
  const cloudSyncPromise = useRef<Promise<void> | null>(null)
  const lineRestorePromise = useRef<Promise<boolean> | null>(null)
  const lineRecoveryStarted = useRef(false)
  const overviewHeading = {
    eyebrow: lineProfile ? t('view.overview.welcomeName', { name: lineProfile.displayName }) : t(viewTitleKeys.overview.eyebrow),
    title: cloudLedger?.groupName ?? t(viewTitleKeys.overview.title),
  }
  const heading = activeView === 'overview' ? overviewHeading : { eyebrow: t(viewTitleKeys[activeView].eyebrow), title: t(viewTitleKeys[activeView].title) }
  const isArchived = cloudLedger?.status === 'archived'

  const activateLedger = useCallback(async (ledger: CloudLedgerState) => {
    const [members, cloudExpenses] = await Promise.all([
      fetchCloudMembers(ledger.groupId, ledger.setupToken),
      fetchCloudExpenses(ledger.groupId),
    ])
    setCloudLedger((current) => mergeJoinedLedgerAccess(current, ledger))
    setParticipants(members)
    setExpenses(cloudExpenses)
    setHandoffReceipt(null)
    setCloudSync({ status: 'synced', at: new Date().toISOString() })
  }, [setCloudLedger, setExpenses, setHandoffReceipt, setParticipants])

  const refreshCloudLedger = useCallback(async () => {
    if (!cloudLedger) return
    if (cloudSyncPromise.current) return cloudSyncPromise.current
    const operation = (async () => {
      setCloudSync((current) => ({ status: 'syncing', at: current.at }))
      try {
        const [members, cloudExpenses] = await Promise.all([
          fetchCloudMembers(cloudLedger.groupId, cloudLedger.setupToken),
          fetchCloudExpenses(cloudLedger.groupId),
        ])
        setParticipants((current) => sameParticipants(current, members) ? current : members)
        setExpenses((current) => sameExpenses(current, cloudExpenses) ? current : cloudExpenses)
        setCloudSync({ status: 'synced', at: new Date().toISOString() })
      } catch (reason) {
        setCloudSync((current) => ({ status: 'error', at: current.at }))
        throw reason
      }
    })()
    cloudSyncPromise.current = operation
    try {
      await operation
    } finally {
      cloudSyncPromise.current = null
    }
  }, [cloudLedger, setExpenses, setParticipants])

  const applyRestoredLineAccount = useCallback(async (account: RestoredLineAccount) => {
    setLineProfile(account.profile)
    setLedgerDirectory(account.directory)
    const selected = selectCloudLedger(account.directory, cloudLedger?.groupId)
    if (selected) await activateLedger(selected)
    else {
      setCloudLedger(null)
      setParticipants([])
      setExpenses([])
    }
    setLineRecoveryStatus(selected ? 'synced' : 'not-member')
    return true
  }, [activateLedger, cloudLedger?.groupId, setCloudLedger, setExpenses, setParticipants])

  const restoreFromLine = useCallback(async (loginIfNeeded: boolean, forceLogin = false) => {
    if (!isLiffConfigured) return false
    setLineRecoveryStatus(loginIfNeeded ? 'restoring' : 'checking')
    setLineRecoveryError('')
    try {
      const formalPageUrl = new URL(window.location.pathname, window.location.origin).toString()
      const callbackHandoffToken = readLineAuthHandoffToken(window.location.search) ?? initialLineHandoffToken
      if (loginIfNeeded && isStandaloneWebApp() && !callbackHandoffToken) {
        const handoffToken = readPendingLineAuthHandoff(window.localStorage)
          ?? createLineAuthHandoff(window.localStorage)
        window.location.assign(buildLineAuthHandoffLiffUrl(import.meta.env.VITE_LIFF_ID, handoffToken))
        return false
      }
      const callbackUrl = () => {
        const handoffToken = readLineAuthHandoffToken(window.location.search) ?? callbackHandoffToken
        return handoffToken ? addLineAuthHandoffToUrl(formalPageUrl, handoffToken) : formalPageUrl
      }
      const identity = await loadLineIdentity(loginIfNeeded || Boolean(callbackHandoffToken), callbackUrl, forceLogin)
      if (!identity) {
        setLineRecoveryStatus('login-required')
        return false
      }
      const effectiveHandoffToken = readLineAuthHandoffToken(window.location.search) ?? callbackHandoffToken
      const restored = await restoreCloudLedgerWithLine(identity.accessToken, effectiveHandoffToken)
      if (effectiveHandoffToken) {
        clearPendingLineAuthHandoff(window.localStorage, effectiveHandoffToken)
        removeLineAuthHandoffFromCurrentUrl()
        setLineHandoffCompleted(!isStandaloneWebApp())
      }
      return applyRestoredLineAccount(restored)
    } catch (reason) {
      setLineRecoveryError(reason instanceof Error ? reason.message : '無法恢復 LINE 帳務登入')
      setLineRecoveryStatus('error')
      return false
    }
  }, [applyRestoredLineAccount, initialLineHandoffToken])

  const restoreLineAccount = useCallback(async (loginIfNeeded: boolean) => {
    if (lineRestorePromise.current) return lineRestorePromise.current
    const operation = (async () => {
      setLineRecoveryStatus(loginIfNeeded ? 'restoring' : 'checking')
      setLineRecoveryError('')
      try {
        const initialRecovery = await recoverLineCallbackBeforePersistedSession(
          initialLineHandoffToken,
          () => restoreFromLine(false),
          restorePersistedLineAccount,
        )
        if (initialRecovery.source === 'callback') return initialRecovery.restored
        if (initialRecovery.source === 'persisted') return applyRestoredLineAccount(initialRecovery.account)

        const handoffToken = readPendingLineAuthHandoff(window.localStorage)
        if (handoffToken) {
          const exchangedAccount = await exchangeLineAuthHandoff(handoffToken)
          if (exchangedAccount) {
            clearPendingLineAuthHandoff(window.localStorage, handoffToken)
            return applyRestoredLineAccount(exchangedAccount)
          }
        }
      } catch (reason) {
        setLineRecoveryError(reason instanceof Error ? reason.message : '無法恢復已儲存的登入狀態')
        setLineRecoveryStatus('error')
        return false
      }
      return restoreFromLine(loginIfNeeded)
    })()
    lineRestorePromise.current = operation
    try {
      return await operation
    } finally {
      if (lineRestorePromise.current === operation) lineRestorePromise.current = null
    }
  }, [applyRestoredLineAccount, initialLineHandoffToken, restoreFromLine])

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', theme === 'dark' ? '#171a18' : '#f8f6f1')
  }, [theme])

  useEffect(() => {
    document.documentElement.dataset.textScale = textScale
  }, [textScale])

  useEffect(() => {
    if (!isLiffConfigured || pendingInviteToken || lineRecoveryStarted.current) return
    lineRecoveryStarted.current = true
    void restoreLineAccount(false)
  }, [pendingInviteToken, restoreLineAccount])

  useEffect(() => {
    if (!isLiffConfigured || pendingInviteToken || lineRecoveryStatus === 'synced') return
    const resumeHandoff = () => {
      if (document.visibilityState !== 'visible' || !readPendingLineAuthHandoff(window.localStorage)) return
      void restoreLineAccount(false)
    }
    document.addEventListener('visibilitychange', resumeHandoff)
    window.addEventListener('focus', resumeHandoff)
    return () => {
      document.removeEventListener('visibilitychange', resumeHandoff)
      window.removeEventListener('focus', resumeHandoff)
    }
  }, [lineRecoveryStatus, pendingInviteToken, restoreLineAccount])

  useEffect(() => {
    if (!cloudLedger || pendingInviteToken || lineRecoveryStatus === 'checking' || lineRecoveryStatus === 'restoring') {
      setCloudSync({ status: 'idle', at: null })
      return
    }
    const sync = () => { if (document.visibilityState === 'visible') void refreshCloudLedger().catch(() => undefined) }
    sync()
    const timer = window.setInterval(sync, 10000)
    const onVisibility = () => { if (document.visibilityState === 'visible') sync() }
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('focus', sync)
    window.addEventListener('online', sync)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('focus', sync)
      window.removeEventListener('online', sync)
    }
  }, [cloudLedger, lineRecoveryStatus, pendingInviteToken, refreshCloudLedger])

  const openCreateParticipant = () => {
    setEditingParticipant(null)
    setParticipantFormOpen(true)
  }

  const openEditParticipant = (participant: Participant) => {
    setEditingParticipant(participant)
    setParticipantFormOpen(true)
  }

  const handleQuickAdd = () => {
    if (isArchived) return
    setEditingExpense(null)
    setActiveView('expenses')
    setExpenseFormOpen(true)
  }

  const participantExpenseCounts = expenses.reduce<Record<string, number>>((counts, expense) => {
    new Set([expense.paidById, ...expense.participantIds]).forEach((id) => { counts[id] = (counts[id] ?? 0) + 1 })
    return counts
  }, {})

  const enableCloud = async (groupName: string) => {
    if (!await restoreLineAccount(true)) throw new Error('建立帳本前請先完成 LINE 登入')
    const bootstrapParticipants = participants
    const result = await bootstrapCloudLedger(groupName, bootstrapParticipants)
    const mapped = applyBootstrapMapping(bootstrapParticipants, expenses, result)
    const persistedExpenses = await Promise.all(mapped.expenses.map((expense) => saveCloudExpense(result.groupId, expense)))
    setParticipants(mapped.participants)
    setExpenses(persistedExpenses)
    setCloudLedger({
      groupId: result.groupId,
      groupName: result.groupName,
      status: 'active',
      isCreator: true,
      isOwner: true,
      setupToken: result.setupToken,
      setupExpiresAt: result.setupExpiresAt,
    })
    setLedgerDirectory(await listCloudLedgers())
    setHandoffReceipt(null)
  }

  const createAdditionalLedger = async (groupName: string) => {
    setLedgerManagerBusy(true)
    setLedgerManagerError('')
    try {
      if (!await restoreLineAccount(true)) throw new Error('建立帳本前請先完成 LINE 登入')
      const result = await bootstrapCloudLedger(groupName, [])
      const directory = await listCloudLedgers()
      setLedgerDirectory(directory)
      const ledger = directory.ledgers.find((item) => item.groupId === result.groupId)
      if (!ledger) throw new Error('新帳本已建立，但清單尚未同步，請重新整理')
      await activateLedger(ledgerSummaryToState(ledger))
      setActiveView('overview')
      setLedgerManagerOpen(false)
    } catch (reason) {
      const message = reason instanceof Error ? reason.message : '無法建立帳本'
      setLedgerManagerError(message)
      throw reason
    } finally {
      setLedgerManagerBusy(false)
    }
  }

  const switchLedger = async (ledger: LedgerSummary) => {
    setLedgerManagerBusy(true)
    setLedgerManagerError('')
    try {
      await activateLedger(ledgerSummaryToState(ledger))
      setActiveView('overview')
      setLedgerManagerOpen(false)
    } catch (reason) {
      setLedgerManagerError(reason instanceof Error ? reason.message : '無法切換帳本')
      throw reason
    } finally {
      setLedgerManagerBusy(false)
    }
  }

  const archiveLedger = async (ledger: LedgerSummary) => {
    setLedgerManagerBusy(true)
    setLedgerManagerError('')
    try {
      await archiveCloudLedger(ledger.groupId)
      const directory = await listCloudLedgers()
      setLedgerDirectory(directory)
      const updated = directory.ledgers.find((item) => item.groupId === ledger.groupId)
      if (updated && cloudLedger?.groupId === ledger.groupId) await activateLedger(ledgerSummaryToState(updated))
    } catch (reason) {
      setLedgerManagerError(reason instanceof Error ? reason.message : '無法封存帳本')
      throw reason
    } finally {
      setLedgerManagerBusy(false)
    }
  }

  const restoreArchivedLedger = async (ledger: LedgerSummary) => {
    setLedgerManagerBusy(true)
    setLedgerManagerError('')
    try {
      await restoreArchivedCloudLedger(ledger.groupId)
      const directory = await listCloudLedgers()
      setLedgerDirectory(directory)
      const updated = directory.ledgers.find((item) => item.groupId === ledger.groupId)
      if (updated && cloudLedger?.groupId === ledger.groupId) await activateLedger(ledgerSummaryToState(updated))
    } catch (reason) {
      setLedgerManagerError(reason instanceof Error ? reason.message : '無法恢復帳本')
      throw reason
    } finally {
      setLedgerManagerBusy(false)
    }
  }

  const restoreSetup = async (setupKey: string) => {
    const result = await restoreLedgerSetup(setupKey)
    if (cloudLedger && result.ledger.groupId !== cloudLedger.groupId) {
      throw new Error('這組開帳碼不屬於目前帳本')
    }
    setCloudLedger(result.ledger)
    setParticipants(result.members)
    setExpenses([])
    setHandoffReceipt(null)
    setActiveView('people')
  }

  const recoverCreatedSetup = async () => {
    const ledger = await recoverIncompleteLedgerSetup()
    const [members, cloudExpenses] = await Promise.all([
      fetchCloudMembers(ledger.groupId, ledger.setupToken),
      fetchCloudExpenses(ledger.groupId),
    ])
    setCloudLedger(ledger)
    setParticipants(members)
    setExpenses(cloudExpenses)
    setHandoffReceipt(null)
    setActiveView('people')
  }

  const createInvite = async () => {
    if (!cloudLedger) throw new Error('請先啟用雲端帳本')
    const invite = await createCloudInvite(cloudLedger.groupId, cloudLedger.setupToken)
    return {
      url: buildInviteUrl(invite.token, import.meta.env.VITE_LIFF_ID, window.location.origin, window.location.pathname),
      expiresAt: invite.expiresAt,
    }
  }

  const createBindCode = async (provider: MessagingProvider) => {
    if (!cloudLedger) throw new Error('請先啟用雲端帳本')
    return createMessagingBindCode(cloudLedger.groupId, provider)
  }

  const createIdentityCode = async (memberId: string, provider: MessagingProvider) => {
    if (!cloudLedger) throw new Error('請先啟用雲端帳本')
    return createMessagingIdentityCode(cloudLedger.groupId, memberId, provider)
  }

  const deleteLedger = async (confirmation: string) => {
    if (!cloudLedger) throw new Error('找不到要刪除的雲端帳本')
    await deleteCloudLedger(cloudLedger.groupId, confirmation, cloudLedger.setupToken)
    const directory = await listCloudLedgers()
    setLedgerDirectory(directory)
    const next = selectCloudLedger(directory)
    if (next) await activateLedger(next)
    else {
      setParticipants([])
      setExpenses([])
      setCloudLedger(null)
    }
    setHandoffReceipt(null)
    setActiveView('overview')
  }

  const resetLocalLedger = () => {
    setParticipants([])
    setExpenses([])
    setCloudLedger(null)
    setHandoffReceipt(null)
    setActiveView('people')
  }

  const saveExpense = async (expense: Expense) => {
    if (isArchived) throw new Error('已封存帳本僅供檢視，無法新增或修改帳目')
    const savedExpense = cloudLedger ? await saveCloudExpense(cloudLedger.groupId, expense) : expense
    setExpenses((current) => current.some((item) => item.id === savedExpense.id)
      ? current.map((item) => item.id === savedExpense.id ? savedExpense : item)
      : [...current, savedExpense])
  }

  const deleteExpense = async (expense: Expense) => {
    if (isArchived) throw new Error('已封存帳本僅供檢視，無法刪除帳目')
    if (cloudLedger) await deleteCloudExpense(cloudLedger.groupId, expense)
    setExpenses((current) => current.filter((item) => item.id !== expense.id))
  }

  const handleJoined = (ledger: CloudLedgerState, members: Participant[]) => {
    lineRecoveryStarted.current = true
    setLineRecoveryStatus('synced')
    setCloudLedger((current) => mergeJoinedLedgerAccess(current, ledger))
    setHandoffReceipt(null)
    setParticipants(members)
    setExpenses([])
    setPendingInviteToken(null)
    setActiveView('people')
    window.history.replaceState({}, '', window.location.pathname)
    void listCloudLedgers().then(setLedgerDirectory).catch(() => undefined)
  }

  if (pendingInviteToken) {
    return <InviteJoinPage token={pendingInviteToken} onJoined={handleJoined} />
  }

  if (handoffReceipt) {
    return <HandoffCompleteView receipt={handoffReceipt} participants={participants} theme={theme} onToggleTheme={() => setTheme(theme === 'light' ? 'dark' : 'light')} onFinish={resetLocalLedger} />
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <button className="brand" type="button" onClick={() => setActiveView('overview')}>
          <span className="brand-mark"><Icon name="wallet" size={18} /></span>
          <span>ClearSplit</span>
        </button>
        <div className="topbar-actions">
          <InstallAppButton />
          <LedgerSwitcher
            directory={ledgerDirectory}
            activeGroupId={cloudLedger?.groupId}
            open={ledgerManagerOpen}
            busy={ledgerManagerBusy}
            error={ledgerManagerError}
            onOpen={() => { setLedgerManagerError(''); setLedgerManagerOpen(true) }}
            onClose={() => setLedgerManagerOpen(false)}
            onSelect={switchLedger}
            onCreate={createAdditionalLedger}
            onArchive={archiveLedger}
            onRestore={restoreArchivedLedger}
          />
          <button className="icon-button" type="button" aria-label={t('action.switchLocale')} title={t('action.switchLocale')} onClick={() => setLocale(locale === 'en' ? 'zh-TW' : 'en')}>{locale === 'en' ? '中' : 'EN'}</button>
          <button className="icon-button text-scale-button" type="button" aria-label={`目前${textScaleLabel(textScale)}，點擊切換字體大小`} title={`字體：${textScaleLabel(textScale)}`} onClick={() => setTextScale(nextTextScale(textScale))}>
            字<span>{textScale === 'normal' ? '' : textScale === 'large' ? '+' : '++'}</span>
          </button>
          <button className="icon-button" type="button" aria-label={theme === 'light' ? t('action.switchDark') : t('action.switchLight')} onClick={() => setTheme(theme === 'light' ? 'dark' : 'light')}>
            <Icon name={theme === 'light' ? 'moon' : 'sun'} size={20} />
          </button>
        </div>
      </header>

      <main className="page-content">
        <section className="page-heading">
          <div>
            <p className="eyebrow">{heading.eyebrow}</p>
            <h1>{heading.title}</h1>
          </div>
          <button className={`status-pill is-${cloudSync.status}`} type="button" disabled={!cloudLedger || cloudSync.status === 'syncing'} onClick={() => void refreshCloudLedger().catch(() => undefined)} title={cloudSync.at ? t('status.lastSync', { time: new Date(cloudSync.at).toLocaleString(locale) }) : undefined}><span className="status-dot" />{!cloudLedger ? t('status.disconnected') : isArchived ? t('status.archived') : cloudSync.status === 'syncing' ? t('status.syncing') : cloudSync.status === 'error' ? t('status.error') : t('status.synced')}</button>
        </section>
        {isArchived && <section className="archived-ledger-banner"><Icon name="alert-circle" size={18} /><div><strong>{t('archive.title')}</strong><p>{t('archive.body')}</p></div></section>}
        {lineHandoffCompleted && <section className="line-session-banner is-synced">
          <span className="line-session-icon">LINE</span>
          <div><strong>LINE 登入已完成</strong><p>主畫面 App 正在接回登入狀態；請回到主畫面的 ClearSplit，之後重開就不必再次登入。</p></div>
          <button type="button" onClick={() => setLineHandoffCompleted(false)}>知道了</button>
        </section>}
        {isLiffConfigured && (
          (lineRecoveryStatus === 'checking' || lineRecoveryStatus === 'restoring')
          || lineRecoveryStatus === 'error'
          || (lineRecoveryStatus === 'login-required' && (!cloudLedger || cloudSync.status === 'error'))
          || (lineRecoveryStatus === 'not-member' && !cloudLedger)
        ) && <section className={`line-session-banner is-${lineRecoveryStatus}`}>
          <span className="line-session-icon">LINE</span>
          <div>
            <strong>{lineRecoveryStatus === 'checking' || lineRecoveryStatus === 'restoring' ? initialLineHandoffToken ? '正在把 LINE 登入交回主畫面' : '正在連接 LINE 帳務身分' : lineRecoveryStatus === 'not-member' ? '這個 LINE 帳號還沒有帳本' : lineRecoveryStatus === 'error' ? 'LINE 帳務同步失敗' : '在這台裝置登入 LINE'}</strong>
            <p>{lineRecoveryStatus === 'not-member' ? '可以建立自己的新帳本，或使用別人分享的 LIFF 邀請連結加入。' : lineRecoveryStatus === 'error' ? lineRecoveryError : lineRecoveryStatus === 'checking' || lineRecoveryStatus === 'restoring' ? initialLineHandoffToken ? '請先不要關閉這個頁面；看到「LINE 登入已完成」後，再回到主畫面的 ClearSplit。' : '確認身分後會載入這個帳號可使用的全部帳本。' : '登入後，這台裝置會保留帳務登入狀態，正式頁與 LIFF 會使用同一個身分。'}</p>
          </div>
          {(lineRecoveryStatus === 'login-required' || lineRecoveryStatus === 'error') && <button type="button" onClick={() => void restoreFromLine(true, lineRecoveryStatus === 'error')}>{lineRecoveryStatus === 'error' ? '更新 LINE 登入' : '用 LINE 登入同步'}</button>}
        </section>}
        {activeView === 'overview' && (
          <OverviewView
            participants={participants}
            expenses={expenses}
            onShowExpenses={() => setActiveView('expenses')}
            onShowFund={() => setActiveView('fund')}
            onShowSettlement={() => setActiveView('settlement')}
            onAddExpense={handleQuickAdd}
            cloudLedger={cloudLedger}
          />
        )}
        {activeView === 'settlement' && (
          <SettlementView
            participants={participants}
            expenses={expenses}
            cloudLedger={cloudLedger}
            onExpenseUpdated={(expense) => setExpenses((current) => current.map((item) => item.id === expense.id ? expense : item))}
            readOnly={isArchived}
          />
        )}
        {activeView === 'fund' && (
          <FundView
            cloudLedger={cloudLedger}
            participants={participants}
            onShowPeople={() => setActiveView('people')}
            readOnly={isArchived}
          />
        )}
        {activeView === 'expenses' && (
          <ExpensesView
            expenses={expenses}
            participants={participants}
            formOpen={expenseFormOpen}
            editingExpense={editingExpense}
            onOpenCreate={() => { setEditingExpense(null); setExpenseFormOpen(true) }}
            onOpenEdit={(expense) => { setEditingExpense(expense); setExpenseFormOpen(true) }}
            onCloseForm={() => setExpenseFormOpen(false)}
            onSaveExpense={saveExpense}
            onDeleteExpense={deleteExpense}
            cloudLedger={cloudLedger}
            readOnly={isArchived}
          />
        )}
        {activeView === 'people' && (
          <PeopleView
            participants={participants}
            formOpen={participantFormOpen}
            editingParticipant={editingParticipant}
            onOpenCreate={openCreateParticipant}
            onOpenEdit={openEditParticipant}
            onCloseForm={() => setParticipantFormOpen(false)}
            onChange={(nextParticipants) => {
              const persist = cloudLedger ? persistCloudMemberChanges(cloudLedger.groupId, participants, nextParticipants) : Promise.resolve()
              return persist.then(() => {
              setParticipants(nextParticipants)
              })
            }}
            expenseCounts={participantExpenseCounts}
            cloudLedger={cloudLedger}
            onEnableCloud={enableCloud}
            onRecoverCreatedSetup={recoverCreatedSetup}
            onRestoreSetup={restoreSetup}
            onCreateInvite={createInvite}
            onCreateBindCode={createBindCode}
            onCreateIdentityCode={createIdentityCode}
            onRefreshCloud={refreshCloudLedger}
            onAssignResponsible={async (memberId) => {
              if (!cloudLedger) throw new Error('請先啟用雲端帳本')
              const memberName = participants.find((member) => member.id === memberId)?.name ?? '所選成員'
              const wasSetupHandoff = Boolean(cloudLedger.setupToken)
              await assignResponsibleMember(cloudLedger.groupId, memberId, cloudLedger.setupToken)
              if (!wasSetupHandoff) return refreshCloudLedger()
              const handoffMembers = markResponsibleMember(participants, memberId)
              try {
                const members = await fetchCloudMembers(cloudLedger.groupId)
                setParticipants(members)
                setCloudLedger({ groupId: cloudLedger.groupId, groupName: cloudLedger.groupName })
              } catch {
                setParticipants(handoffMembers)
                setCloudLedger(null)
                setHandoffReceipt({
                  groupId: cloudLedger.groupId,
                  groupName: cloudLedger.groupName,
                  responsibleMemberId: memberId,
                  responsibleMemberName: memberName,
                  completedAt: new Date().toISOString(),
                })
              }
            }}
            onResetLocal={resetLocalLedger}
            onDeleteCloud={deleteLedger}
            readOnly={isArchived}
          />
        )}
      </main>

      <nav className="bottom-nav" aria-label={t('aria.mainNav')}>
        {navigation.map((item) => (
          <button
            className={activeView === item.id ? 'nav-item is-active' : 'nav-item'}
            type="button"
            key={item.id}
            onClick={() => setActiveView(item.id)}
            aria-current={activeView === item.id ? 'page' : undefined}
          >
            <Icon name={item.icon} size={21} />
            <span>{t(item.label)}</span>
          </button>
        ))}
        <button className="nav-add" type="button" aria-label={t('action.addExpense')} disabled={isArchived} onClick={handleQuickAdd}>
          <Icon name="plus" size={24} />
        </button>
      </nav>
    </div>
  )
}

function getPreferredTheme(): Theme {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

function nextTextScale(current: TextScale): TextScale {
  if (current === 'normal') return 'large'
  if (current === 'large') return 'xlarge'
  return 'normal'
}

function textScaleLabel(value: TextScale) {
  return value === 'normal' ? '標準字體' : value === 'large' ? '大字體' : '特大字體'
}

function getVisualTestLedgerDirectory(): LedgerDirectory | null {
  if (!import.meta.env.DEV || new URLSearchParams(window.location.search).get('visual-test') !== 'multi-ledger') return null
  const base = { archivedAt: null, createdAt: '2026-08-01T00:00:00Z', updatedAt: '2026-08-27T00:00:00Z', memberId: 'visual-member', memberCount: 4, expenseCount: 12 }
  return {
    limits: { activeOwned: 5, totalOwned: 10, activeJoined: 30, membersPerLedger: 50 },
    usage: { activeOwned: 2, totalOwned: 3, activeJoined: 1 },
    ledgers: [
      { ...base, groupId: '00000000-0000-4000-8000-000000000201', groupName: '北海道家族旅行', status: 'active', isCreator: true, isOwner: true },
      { ...base, groupId: '00000000-0000-4000-8000-000000000202', groupName: '同學會公帳', status: 'active', isCreator: false, isOwner: false, memberCount: 8, expenseCount: 24 },
      { ...base, groupId: '00000000-0000-4000-8000-000000000203', groupName: '去年跨年旅行', status: 'archived', archivedAt: '2026-08-20T00:00:00Z', isCreator: true, isOwner: false },
      { ...base, groupId: '00000000-0000-4000-8000-000000000204', groupName: '社區採買', status: 'archived', archivedAt: '2026-08-21T00:00:00Z', isCreator: false, isOwner: true },
    ],
  }
}

function getVisualTestLineProfile(): LineAccountProfile | null {
  if (!import.meta.env.DEV) return null
  const displayName = new URLSearchParams(window.location.search).get('visual-profile')?.trim()
  return displayName ? { displayName: displayName.slice(0, 80), avatarUrl: null } : null
}

function getVisualTestLineHandoffCompleted() {
  return import.meta.env.DEV && new URLSearchParams(window.location.search).get('visual-handoff') === 'complete'
}

function sameParticipants(left: Participant[], right: Participant[]) {
  return left.length === right.length && left.every((member, index) => {
    const other = right[index]
    return other && member.id === other.id && member.name === other.name && member.color === other.color
      && member.createdAt === other.createdAt && member.avatarUrl === other.avatarUrl
      && member.isResponsible === other.isResponsible
  })
}

function sameExpenses(left: Expense[], right: Expense[]) {
  return left.length === right.length && left.every((expense, index) => {
    const other = right[index]
    return other && expense.id === other.id && expense.title === other.title
      && expense.amount === other.amount && expense.category === other.category
      && expense.paidById === other.paidById && expense.date === other.date
      && expense.note === other.note && expense.createdAt === other.createdAt
      && expense.version === other.version
      && (expense.splitMode ?? 'equal') === (other.splitMode ?? 'equal')
      && (expense.status ?? 'active') === (other.status ?? 'active')
      && (expense.resolvedAt ?? null) === (other.resolvedAt ?? null)
      && expense.participantIds.length === other.participantIds.length
      && expense.participantIds.every((id, participantIndex) => id === other.participantIds[participantIndex])
      && (expense.shares?.length ?? 0) === (other.shares?.length ?? 0)
      && (expense.shares ?? []).every((share, shareIndex) => {
        const otherShare = other.shares?.[shareIndex]
        return otherShare && share.participantId === otherShare.participantId
          && share.amount === otherShare.amount && share.receivedAt === otherShare.receivedAt
      })
  })
}

export default App
