import { describe, expect, it } from 'vitest'
import { defaultExpenses, defaultParticipants } from '../data'
import { isCloudLedgerState, isExpenseArray, isLedgerHandoffReceipt, isParticipantArray, isTextScale, isTheme } from './storageValidation'

describe('storage validation', () => {
  it('accepts the known application data shapes', () => {
    expect(isParticipantArray(defaultParticipants)).toBe(true)
    expect(isExpenseArray(defaultExpenses)).toBe(true)
    expect(isTheme('dark')).toBe(true)
    expect(isTextScale('xlarge')).toBe(true)
    expect(isCloudLedgerState({
      groupId: '00000000-0000-4000-8000-000000000001',
      groupName: '測試帳本',
      setupToken: 'a'.repeat(32),
      setupExpiresAt: '2026-09-08T00:00:00.000Z',
    })).toBe(true)
    expect(isLedgerHandoffReceipt({
      groupId: '00000000-0000-4000-8000-000000000001',
      groupName: '測試帳本',
      responsibleMemberId: 'member-1',
      responsibleMemberName: '美玲',
      completedAt: '2026-08-09T00:00:00.000Z',
    })).toBe(true)
  })

  it('rejects structurally unsafe stored values', () => {
    expect(isParticipantArray([{ id: 'a', name: null }])).toBe(false)
    expect(isExpenseArray([{ ...defaultExpenses[0], participantIds: 'member-alex' }])).toBe(false)
    expect(isExpenseArray([{ ...defaultExpenses[0], amount: Number.NaN }])).toBe(false)
    expect(isTheme('system')).toBe(false)
    expect(isTextScale('huge')).toBe(false)
    expect(isCloudLedgerState({ groupId: '00000000-0000-4000-8000-000000000001', groupName: '測試', setupToken: 'a'.repeat(32) })).toBe(false)
    expect(isCloudLedgerState({ groupId: '00000000-0000-4000-8000-000000000001', groupName: '測試', setupToken: 'short', setupExpiresAt: '2026-09-08' })).toBe(false)
    expect(isLedgerHandoffReceipt({ groupId: 'invalid', groupName: '測試' })).toBe(false)
  })
})
