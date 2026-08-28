import { describe, expect, it } from 'vitest'
import { parseLineBotFriendUrl } from './lineBot'

describe('parseLineBotFriendUrl', () => {
  it('accepts only official LINE HTTPS add-friend links', () => {
    expect(parseLineBotFriendUrl('https://lin.ee/abc123')).toBe('https://lin.ee/abc123')
    expect(parseLineBotFriendUrl('https://line.me/R/ti/p/%40clearsplit')).toBe('https://line.me/R/ti/p/%40clearsplit')
  })

  it('rejects missing, insecure and lookalike links', () => {
    expect(parseLineBotFriendUrl(undefined)).toBeNull()
    expect(parseLineBotFriendUrl('http://lin.ee/abc123')).toBeNull()
    expect(parseLineBotFriendUrl('https://lin.ee.example.com/abc123')).toBeNull()
  })
})
