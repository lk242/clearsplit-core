const storageKey = 'clearsplit-line-auth-handoff'
const queryParameter = 'line-auth-handoff'
const tokenPattern = /^[0-9a-f]{64}$/
const lifetimeMs = 10 * 60 * 1000

type PendingLineAuthHandoff = {
  token: string
  expiresAt: number
}

export type InitialLineAccountRecovery<TAccount> =
  | { source: 'callback'; restored: boolean }
  | { source: 'persisted'; account: TAccount }
  | { source: 'none' }

export function isStandaloneWebApp() {
  const iosNavigator = navigator as Navigator & { standalone?: boolean }
  return window.matchMedia('(display-mode: standalone)').matches || iosNavigator.standalone === true
}

export function createLineAuthHandoff(storage: Storage, now = Date.now()) {
  const bytes = new Uint8Array(32)
  crypto.getRandomValues(bytes)
  const token = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
  const handoff: PendingLineAuthHandoff = { token, expiresAt: now + lifetimeMs }
  storage.setItem(storageKey, JSON.stringify(handoff))
  return token
}

export function readPendingLineAuthHandoff(storage: Storage, now = Date.now()) {
  const raw = storage.getItem(storageKey)
  if (!raw) return null
  try {
    const value = JSON.parse(raw) as Partial<PendingLineAuthHandoff>
    if (!isHandoffToken(value.token) || typeof value.expiresAt !== 'number'
      || !Number.isSafeInteger(value.expiresAt) || value.expiresAt <= now
      || value.expiresAt > now + lifetimeMs) {
      storage.removeItem(storageKey)
      return null
    }
    return value.token
  } catch {
    storage.removeItem(storageKey)
    return null
  }
}

export function clearPendingLineAuthHandoff(storage: Storage, expectedToken?: string, now = Date.now()) {
  if (expectedToken && readPendingLineAuthHandoff(storage, now) !== expectedToken) return false
  const existed = storage.getItem(storageKey) !== null
  storage.removeItem(storageKey)
  return existed
}

export function readLineAuthHandoffToken(search: string) {
  return readLineAuthHandoffFromParams(new URLSearchParams(search), 0)
}

export async function recoverLineCallbackBeforePersistedSession<TAccount>(
  callbackToken: string | null,
  restoreCallback: () => Promise<boolean>,
  restorePersisted: () => Promise<TAccount | null>,
): Promise<InitialLineAccountRecovery<TAccount>> {
  // A LIFF browser may already have its own valid ClearSplit session. The
  // one-time callback still has to run first so that the isolated Home Screen
  // app receives the newly requested session instead of remaining anonymous.
  if (callbackToken) return { source: 'callback', restored: await restoreCallback() }
  const account = await restorePersisted()
  return account ? { source: 'persisted', account } : { source: 'none' }
}

export function addLineAuthHandoffToUrl(url: string, token: string) {
  if (!isHandoffToken(token)) throw new Error('invalid LINE auth handoff token')
  const callbackUrl = new URL(url)
  callbackUrl.searchParams.set(queryParameter, token)
  return callbackUrl.toString()
}

export function buildLineAuthHandoffLiffUrl(liffId: string | undefined, token: string) {
  if (!isHandoffToken(token)) throw new Error('invalid LINE auth handoff token')
  const normalizedLiffId = liffId?.trim()
  if (!normalizedLiffId) throw new Error('LIFF ID is unavailable')
  const liffUrl = new URL(`https://liff.line.me/${encodeURIComponent(normalizedLiffId)}`)
  liffUrl.searchParams.set(queryParameter, token)
  return liffUrl.toString()
}

export function removeLineAuthHandoffFromCurrentUrl() {
  const sanitizedUrl = sanitizeLineAuthHandoffUrl(window.location.href)
  if (!sanitizedUrl) return false
  window.history.replaceState({}, '', sanitizedUrl)
  return true
}

export function sanitizeLineAuthHandoffUrl(value: string) {
  const url = new URL(value)
  if (url.searchParams.has(queryParameter)) {
    url.searchParams.delete(queryParameter)
    return `${url.pathname}${url.search}${url.hash}`
  }

  const liffState = url.searchParams.get('liff.state')
  if (!liffState) return null
  try {
    const stateUrl = new URL(liffState, url.origin)
    if (!stateUrl.searchParams.has(queryParameter)) return null
    stateUrl.searchParams.delete(queryParameter)
    return `${stateUrl.pathname}${stateUrl.search}${stateUrl.hash}`
  } catch {
    return null
  }
}

function isHandoffToken(value: unknown): value is string {
  return typeof value === 'string' && tokenPattern.test(value)
}

function readLineAuthHandoffFromParams(params: URLSearchParams, depth: number): string | null {
  const directToken = params.get(queryParameter)
  if (isHandoffToken(directToken)) return directToken
  if (depth >= 2) return null

  // During an external-browser LIFF login, LINE returns the requested callback
  // URL inside liffRedirectUri. liff.init() consumes and then removes that
  // parameter, so the handoff token must also be read from this wrapper before
  // initialization completes. LIFF links use liff.state for the same purpose.
  for (const wrapper of ['liff.state', 'liffRedirectUri']) {
    const wrappedUrl = params.get(wrapper)
    if (!wrappedUrl) continue
    try {
      const nestedUrl = new URL(wrappedUrl, 'https://liff-callback.invalid')
      const nestedToken = readLineAuthHandoffFromParams(nestedUrl.searchParams, depth + 1)
      if (nestedToken) return nestedToken
    } catch {
      // Ignore malformed LINE callback metadata and continue checking wrappers.
    }
  }
  return null
}
