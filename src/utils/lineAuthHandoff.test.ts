import { beforeEach, describe, expect, it, vi } from 'vitest'
import { addLineAuthHandoffToUrl, buildLineAuthHandoffLiffUrl, clearPendingLineAuthHandoff, createLineAuthHandoff, readLineAuthHandoffToken, readPendingLineAuthHandoff, recoverLineCallbackBeforePersistedSession, sanitizeLineAuthHandoffUrl } from './lineAuthHandoff'

function memoryStorage(initial: Record<string, string> = {}): Storage {
  const values = new Map(Object.entries(initial))
  return {
    get length() { return values.size },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key) },
    setItem: (key, value) => { values.set(key, value) },
  }
}

beforeEach(() => {
  vi.restoreAllMocks()
})

describe('LINE auth handoff', () => {
  it('creates a cryptographically random, short-lived handoff token', () => {
    vi.spyOn(crypto, 'getRandomValues').mockImplementation((array) => {
      const bytes = array as Uint8Array
      bytes.forEach((_, index) => { bytes[index] = index })
      return array
    })
    const storage = memoryStorage()
    const token = createLineAuthHandoff(storage, 1_000)

    expect(token).toBe('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')
    expect(readPendingLineAuthHandoff(storage, 1_001)).toBe(token)
  })

  it('removes malformed, expired, and implausibly long-lived records', () => {
    const key = 'clearsplit-line-auth-handoff'
    const token = 'a'.repeat(64)
    const malformed = memoryStorage({ [key]: '{' })
    const expired = memoryStorage({ [key]: JSON.stringify({ token, expiresAt: 999 }) })
    const excessive = memoryStorage({ [key]: JSON.stringify({ token, expiresAt: 601_001 }) })

    expect(readPendingLineAuthHandoff(malformed, 1_000)).toBeNull()
    expect(readPendingLineAuthHandoff(expired, 1_000)).toBeNull()
    expect(readPendingLineAuthHandoff(excessive, 1_000)).toBeNull()
    expect(malformed.getItem(key)).toBeNull()
    expect(expired.getItem(key)).toBeNull()
    expect(excessive.getItem(key)).toBeNull()
  })

  it('only clears the pending token requested by the completed exchange', () => {
    const storage = memoryStorage()
    const token = createLineAuthHandoff(storage, 1_000)
    expect(clearPendingLineAuthHandoff(storage, 'b'.repeat(64), 1_001)).toBe(false)
    expect(readPendingLineAuthHandoff(storage, 1_001)).toBe(token)
    expect(clearPendingLineAuthHandoff(storage, token, 1_001)).toBe(true)
    expect(readPendingLineAuthHandoff(storage, 1_001)).toBeNull()
  })

  it('reads direct, LIFF state, and external-browser callback wrappers', () => {
    const token = 'c'.repeat(64)
    expect(readLineAuthHandoffToken(`?line-auth-handoff=${token}`)).toBe(token)
    expect(readLineAuthHandoffToken(`?liff.state=${encodeURIComponent(`/callback?line-auth-handoff=${token}`)}`)).toBe(token)
    expect(readLineAuthHandoffToken(`?code=oauth&liffRedirectUri=${encodeURIComponent(`https://countapp.test/?line-auth-handoff=${token}`)}`)).toBe(token)
    expect(readLineAuthHandoffToken(`?liffRedirectUri=${encodeURIComponent(`https://countapp.test/?liff.state=${encodeURIComponent(`/?line-auth-handoff=${token}`)}`)}`)).toBe(token)
    expect(readLineAuthHandoffToken('?line-auth-handoff=short')).toBeNull()
    expect(readLineAuthHandoffToken('?liffRedirectUri=not-a-url')).toBeNull()
  })

  it('completes a requested callback before accepting an existing browser session', async () => {
    const calls: string[] = []
    const result = await recoverLineCallbackBeforePersistedSession(
      'e'.repeat(64),
      async () => { calls.push('callback'); return true },
      async () => { calls.push('persisted'); return { userId: 'old-session' } },
    )

    expect(result).toEqual({ source: 'callback', restored: true })
    expect(calls).toEqual(['callback'])
  })

  it('uses a persisted session only when there is no requested callback', async () => {
    const calls: string[] = []
    const result = await recoverLineCallbackBeforePersistedSession(
      null,
      async () => { calls.push('callback'); return true },
      async () => { calls.push('persisted'); return { userId: 'saved-session' } },
    )

    expect(result).toEqual({ source: 'persisted', account: { userId: 'saved-session' } })
    expect(calls).toEqual(['persisted'])
  })

  it('adds only the opaque handoff token to the callback URL', () => {
    const token = 'd'.repeat(64)
    expect(addLineAuthHandoffToUrl('https://countapp.test/?invite=abc', token)).toBe(
      `https://countapp.test/?invite=abc&line-auth-handoff=${token}`,
    )
  })

  it('builds a LIFF entry URL that carries the opaque handoff token', () => {
    const token = 'f'.repeat(64)
    expect(buildLineAuthHandoffLiffUrl(' 2011030817-iK5gC6LS ', token)).toBe(
      `https://liff.line.me/2011030817-iK5gC6LS?line-auth-handoff=${token}`,
    )
    expect(() => buildLineAuthHandoffLiffUrl(undefined, token)).toThrow('LIFF ID is unavailable')
    expect(() => buildLineAuthHandoffLiffUrl('2011030817-iK5gC6LS', 'short')).toThrow('invalid LINE auth handoff token')
  })

  it('removes direct and LIFF-wrapped handoff tokens while preserving invites', () => {
    const token = 'e'.repeat(64)
    expect(sanitizeLineAuthHandoffUrl(`https://countapp.test/?invite=abc&line-auth-handoff=${token}`)).toBe('/?invite=abc')
    const liffState = encodeURIComponent(`/join?invite=abc&line-auth-handoff=${token}`)
    expect(sanitizeLineAuthHandoffUrl(`https://countapp.test/?liff.state=${liffState}&code=oauth`)).toBe('/join?invite=abc')
    expect(sanitizeLineAuthHandoffUrl('https://countapp.test/?invite=abc')).toBeNull()
  })
})
