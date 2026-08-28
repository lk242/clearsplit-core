/* oxlint-disable react/only-export-components */
import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

export type AppLocale = 'en' | 'zh-TW'

const dictionaries = {
  en: {
    'nav.overview': 'Overview',
    'nav.expenses': 'Expenses',
    'nav.fund': 'Public fund',
    'nav.settlement': 'Settlement',
    'nav.people': 'People',
    'view.overview.eyebrow': 'Welcome back',
    'view.overview.title': 'Group ledger',
    'view.overview.welcomeName': 'Hi, {name}. Welcome back',
    'view.expenses.eyebrow': 'Every entry stays clear',
    'view.expenses.title': 'Expense history',
    'view.fund.eyebrow': 'Shared money, separate records',
    'view.fund.title': 'Public-fund wallet',
    'view.settlement.eyebrow': 'Confirm payments and receipts separately',
    'view.settlement.title': 'Settlement center',
    'view.people.eyebrow': 'Split together, settle fairly',
    'view.people.title': 'Participants',
    'action.addExpense': 'Add expense',
    'action.switchDark': 'Switch to dark mode',
    'action.switchLight': 'Switch to light mode',
    'action.switchLocale': '切換為繁體中文',
    'status.disconnected': 'Cloud not connected',
    'status.archived': 'Archived · read only',
    'status.syncing': 'Syncing',
    'status.error': 'Sync failed · retry',
    'status.synced': 'Cloud ledger synced',
    'status.lastSync': 'Last sync: {time}',
    'archive.title': 'This ledger is archived',
    'archive.body': 'Data and exports remain available; database rules block new entries, edits, settlement and messaging drafts.',
    'aria.mainNav': 'Primary navigation',
  },
  'zh-TW': {
    'nav.overview': '總覽',
    'nav.expenses': '帳目',
    'nav.fund': '公費',
    'nav.settlement': '結算',
    'nav.people': '成員',
    'view.overview.eyebrow': '嗨，歡迎回來',
    'view.overview.title': '團體公帳',
    'view.overview.welcomeName': '嗨，{name}，歡迎回來',
    'view.expenses.eyebrow': '每一筆都清楚',
    'view.expenses.title': '帳目紀錄',
    'view.fund.eyebrow': '共同資金分開管理',
    'view.fund.title': '公費錢包',
    'view.settlement.eyebrow': '付款收款分開確認',
    'view.settlement.title': '結算中心',
    'view.people.eyebrow': '一起分得剛剛好',
    'view.people.title': '參與成員',
    'action.addExpense': '新增帳目',
    'action.switchDark': '切換為深色模式',
    'action.switchLight': '切換為淺色模式',
    'action.switchLocale': 'Switch to English',
    'status.disconnected': '尚未連接雲端',
    'status.archived': '已封存・僅供檢視',
    'status.syncing': '同步中',
    'status.error': '同步失敗，點此重試',
    'status.synced': '雲端帳務已同步',
    'status.lastSync': '上次同步：{time}',
    'archive.title': '這本帳已封存',
    'archive.body': '資料與匯出仍可查看；新增、修改、結算與通訊草稿都已由資料庫鎖定。',
    'aria.mainNav': '主要導覽',
  },
} as const

export type TranslationKey = keyof typeof dictionaries.en
type Translator = (key: TranslationKey, variables?: Record<string, string | number>) => string

const I18nContext = createContext<{ locale: AppLocale; setLocale: (locale: AppLocale) => void; t: Translator } | null>(null)

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<AppLocale>(readInitialLocale)
  useEffect(() => { document.documentElement.lang = locale }, [locale])
  const value = useMemo(() => ({
    locale,
    setLocale(next: AppLocale) {
      window.localStorage.setItem('clearsplit-locale', next)
      setLocaleState(next)
    },
    t: (key: TranslationKey, variables?: Record<string, string | number>) => translate(locale, key, variables),
  }), [locale])
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}

export function useI18n() {
  const value = useContext(I18nContext)
  if (!value) throw new Error('useI18n must be used inside I18nProvider')
  return value
}

export function translate(locale: AppLocale, key: TranslationKey, variables: Record<string, string | number> = {}) {
  let result: string = dictionaries[locale][key] ?? dictionaries.en[key]
  for (const [name, value] of Object.entries(variables)) result = result.replaceAll(`{${name}}`, String(value))
  return result
}

function readInitialLocale(): AppLocale {
  const saved = window.localStorage.getItem('clearsplit-locale')
  if (saved === 'en' || saved === 'zh-TW') return saved
  return navigator.language.toLowerCase().startsWith('zh') ? 'zh-TW' : 'en'
}
