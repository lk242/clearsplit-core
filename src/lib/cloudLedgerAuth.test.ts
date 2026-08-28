import { afterEach, describe, expect, it, vi } from 'vitest'

const lineUser = {
  id: '00000000-0000-4000-8000-000000000101',
  user_metadata: { clearsplit_line_identity: true },
}

const emptyDirectory = {
  limits: { activeOwned: 5, totalOwned: 10, activeJoined: 30, membersPerLedger: 50 },
  usage: { activeOwned: 0, totalOwned: 0, activeJoined: 0 },
  ledgers: [],
}

afterEach(() => {
  vi.resetModules()
  vi.restoreAllMocks()
})

describe('restorePersistedLineAccount', () => {
  it('does not treat a missing Supabase session as a remembered LINE login', async () => {
    const rpc = vi.fn()
    vi.doMock('./supabase', () => ({
      supabase: {
        auth: {
          getSession: vi.fn().mockResolvedValue({ data: { session: null }, error: null }),
          getUser: vi.fn(),
        },
        rpc,
      },
    }))
    const { restorePersistedLineAccount } = await import('./cloudLedger')

    await expect(restorePersistedLineAccount()).resolves.toBeNull()
    expect(rpc).not.toHaveBeenCalled()
  })

  it('does not reuse an anonymous session as a verified LINE account', async () => {
    const getUser = vi.fn()
    vi.doMock('./supabase', () => ({
      supabase: {
        auth: {
          getSession: vi.fn().mockResolvedValue({
            data: { session: { user: { id: 'anonymous-user', user_metadata: {} } } },
            error: null,
          }),
          getUser,
        },
        rpc: vi.fn(),
      },
    }))
    const { restorePersistedLineAccount } = await import('./cloudLedger')

    await expect(restorePersistedLineAccount()).resolves.toBeNull()
    expect(getUser).not.toHaveBeenCalled()
  })

  it('validates and restores the saved LINE account, directory, and profile', async () => {
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_app_schema_version') return { data: 48, error: null }
      if (name === 'list_my_ledgers') return { data: emptyDirectory, error: null }
      if (name === 'get_my_line_profile') return { data: { displayName: '牛', avatarUrl: null }, error: null }
      return { data: null, error: new Error(`unexpected RPC ${name}`) }
    })
    vi.doMock('./supabase', () => ({
      supabase: {
        auth: {
          getSession: vi.fn().mockResolvedValue({ data: { session: { user: lineUser } }, error: null }),
          getUser: vi.fn().mockResolvedValue({ data: { user: lineUser }, error: null }),
        },
        rpc,
      },
    }))
    const { restorePersistedLineAccount } = await import('./cloudLedger')

    await expect(restorePersistedLineAccount()).resolves.toEqual({
      directory: emptyDirectory,
      profile: { displayName: '牛', avatarUrl: null },
    })
    expect(rpc.mock.calls.map(([name]) => name)).toEqual([
      'get_app_schema_version',
      'list_my_ledgers',
      'get_my_line_profile',
    ])
  })

  it('rejects a persisted token that Supabase can no longer verify', async () => {
    vi.doMock('./supabase', () => ({
      supabase: {
        auth: {
          getSession: vi.fn().mockResolvedValue({ data: { session: { user: lineUser } }, error: null }),
          getUser: vi.fn().mockResolvedValue({ data: { user: null }, error: new Error('JWT expired') }),
        },
        rpc: vi.fn(),
      },
    }))
    const { restorePersistedLineAccount } = await import('./cloudLedger')

    await expect(restorePersistedLineAccount()).rejects.toThrow('已儲存的登入狀態已失效')
  })
})

describe('exchangeLineAuthHandoff', () => {
  it('keeps waiting without replacing the anonymous session before Safari finishes', async () => {
    const setSession = vi.fn()
    const invoke = vi.fn().mockResolvedValue({
      data: { data: { status: 'pending' }, session: null },
      error: null,
    })
    vi.doMock('./supabase', () => ({
      supabase: {
        auth: {
          getSession: vi.fn().mockResolvedValue({
            data: { session: { user: { id: 'anonymous-user', user_metadata: {} } } },
            error: null,
          }),
          setSession,
        },
        functions: { invoke },
        rpc: vi.fn().mockResolvedValue({ data: 48, error: null }),
      },
    }))
    const { exchangeLineAuthHandoff } = await import('./cloudLedger')

    await expect(exchangeLineAuthHandoff('a'.repeat(64))).resolves.toBeNull()
    expect(invoke).toHaveBeenCalledWith('line-member', {
      body: { action: 'exchange', handoffToken: 'a'.repeat(64) },
    })
    expect(setSession).not.toHaveBeenCalled()
  })

  it('applies the one-time session and verifies the stable LINE account', async () => {
    const anonymousUser = { id: 'anonymous-user', user_metadata: {} }
    const getSession = vi.fn()
      .mockResolvedValueOnce({ data: { session: { user: anonymousUser } }, error: null })
      .mockResolvedValueOnce({ data: { session: { user: lineUser } }, error: null })
    const setSession = vi.fn().mockResolvedValue({ data: {}, error: null })
    const rpc = vi.fn(async (name: string) => {
      if (name === 'get_app_schema_version') return { data: 48, error: null }
      if (name === 'list_my_ledgers') return { data: emptyDirectory, error: null }
      if (name === 'get_my_line_profile') return { data: { displayName: '牛', avatarUrl: null }, error: null }
      return { data: null, error: new Error(`unexpected RPC ${name}`) }
    })
    vi.doMock('./supabase', () => ({
      supabase: {
        auth: {
          getSession,
          getUser: vi.fn().mockResolvedValue({ data: { user: lineUser }, error: null }),
          setSession,
        },
        functions: {
          invoke: vi.fn().mockResolvedValue({
            data: {
              data: { status: 'ready' },
              session: { accessToken: 'a'.repeat(32), refreshToken: 'b'.repeat(16) },
            },
            error: null,
          }),
        },
        rpc,
      },
    }))
    const { exchangeLineAuthHandoff } = await import('./cloudLedger')

    await expect(exchangeLineAuthHandoff('c'.repeat(64))).resolves.toEqual({
      directory: emptyDirectory,
      profile: { displayName: '牛', avatarUrl: null },
    })
    expect(setSession).toHaveBeenCalledWith({
      access_token: 'a'.repeat(32),
      refresh_token: 'b'.repeat(16),
    })
    expect(rpc.mock.calls.map(([name]) => name)).toEqual([
      'get_app_schema_version',
      'get_app_schema_version',
      'list_my_ledgers',
      'get_my_line_profile',
    ])
  })
})
