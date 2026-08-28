import { describe, expect, it } from 'vitest'
import { allocateFundEqually, previewFundCollectionOffsets } from './fund'

describe('equal public-fund allocation', () => {
  it('keeps an exactly divisible balance equal', () => {
    expect(allocateFundEqually(1800, ['a', 'b', 'c'])).toEqual([
      { participantId: 'a', amount: 600 },
      { participantId: 'b', amount: 600 },
      { participantId: 'c', amount: 600 },
    ])
  })

  it('distributes integer remainder deterministically without losing money', () => {
    const result = allocateFundEqually(1000, ['a', 'b', 'c'])
    expect(result).toEqual([
      { participantId: 'a', amount: 334 },
      { participantId: 'b', amount: 333 },
      { participantId: 'c', amount: 333 },
    ])
    expect(result.reduce((sum, item) => sum + item.amount, 0)).toBe(1000)
  })

  it('rejects an empty or duplicated allocation list', () => {
    expect(() => allocateFundEqually(100, [])).toThrow()
    expect(() => allocateFundEqually(100, ['a', 'a'])).toThrow()
  })
})

describe('public-fund collection advance offsets', () => {
  const advances = [
    { id: 'later', memberId: 'peter', remainingAmount: 500, createdAt: '2026-08-09T02:00:00Z' },
    { id: 'first', memberId: 'peter', remainingAmount: 700, createdAt: '2026-08-09T01:00:00Z' },
  ]

  it('applies oldest advances first and preserves gross = offset + cash', () => {
    const [peter, other] = previewFundCollectionOffsets(1000, ['peter', 'other'], advances)
    expect(peter).toEqual({
      participantId: 'peter', grossAmount: 1000, offsetAmount: 1000,
      cashAmount: 0, advanceIds: ['first', 'later'],
    })
    expect(other).toEqual({
      participantId: 'other', grossAmount: 1000, offsetAmount: 0,
      cashAmount: 1000, advanceIds: [],
    })
    expect(peter.grossAmount).toBe(peter.offsetAmount + peter.cashAmount)
  })

  it('supports a partial offset and an explicit cash-only collection', () => {
    expect(previewFundCollectionOffsets(1500, ['peter'], advances)[0]).toMatchObject({
      offsetAmount: 1200, cashAmount: 300,
    })
    expect(previewFundCollectionOffsets(1500, ['peter'], advances, false)[0]).toMatchObject({
      offsetAmount: 0, cashAmount: 1500,
    })
  })

  it('rejects unsafe amounts and malformed advance balances', () => {
    expect(() => previewFundCollectionOffsets(0, ['peter'], advances)).toThrow()
    expect(() => previewFundCollectionOffsets(100, ['peter'], [{ ...advances[0], remainingAmount: -1 }])).toThrow()
  })
})
