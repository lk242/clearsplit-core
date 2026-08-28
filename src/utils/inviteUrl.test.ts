import { describe, expect, it } from 'vitest'
import { buildInviteCallbackUrl, buildInviteUrl, readInviteToken } from './inviteUrl'

const token = 'a'.repeat(64)

describe('readInviteToken', () => {
  it('reads a direct invite token', () => {
    expect(readInviteToken(`?invite=${token}`)).toBe(token)
  })

  it('restores an invite token wrapped by a LIFF callback', () => {
    const state = encodeURIComponent(`/join?invite=${token}`)
    expect(readInviteToken(`?liff.state=${state}`)).toBe(token)
  })

  it('rejects malformed direct and LIFF state tokens', () => {
    expect(readInviteToken('?invite=not-a-token')).toBeNull()
    expect(readInviteToken(`?liff.state=${encodeURIComponent('?invite=short')}`)).toBeNull()
  })
})

describe('buildInviteUrl', () => {
  it('uses the LIFF entry URL when configured', () => {
    expect(buildInviteUrl(token, 'test-liff-id', 'https://countapp.test', '/')).toBe(
      `https://liff.line.me/test-liff-id?invite=${token}`,
    )
  })

  it('falls back to the current web app without LIFF configuration', () => {
    expect(buildInviteUrl(token, undefined, 'http://localhost:5173', '/app/')).toBe(
      `http://localhost:5173/app/?invite=${token}`,
    )
  })
})

describe('buildInviteCallbackUrl', () => {
  it('keeps the invite token on the allowed application callback', () => {
    expect(buildInviteCallbackUrl(token, 'https://countapp.test', '/')).toBe(
      `https://countapp.test/?invite=${token}`,
    )
  })
})
