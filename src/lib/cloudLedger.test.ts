import { describe, expect, it } from 'vitest'
import type { Expense, Participant } from '../types'
import { applyBootstrapMapping, formatLedgerSetupKey, markResponsibleMember, mergeJoinedLedgerAccess, parseCloudMembers, parseFundCollections, parseGroupFund, parseLedgerDirectory, parseLedgerSetupKey, parseLineAccountProfile, parseLineAppSession, parseLineInviteMembershipStatus, parseRecoveredSetup, selectCloudLedger } from './cloudLedger'

describe('applyBootstrapMapping', () => {
  it('replaces every participant reference without changing money', () => {
    const participants: Participant[] = [
      { id: 'local-a', name: '阿哲', color: '#111111', createdAt: '2026-01-01T00:00:00Z' },
      { id: 'local-b', name: '美玲', color: '#222222', createdAt: '2026-01-01T00:00:01Z' },
    ]
    const expenses: Expense[] = [{
      id: 'expense-1', title: '晚餐', amount: 100, category: 'food', paidById: 'local-a',
      participantIds: ['local-a', 'local-b'], splitMode: 'custom',
      shares: [{ participantId: 'local-a', amount: 40, receivedAt: null }, { participantId: 'local-b', amount: 60, receivedAt: null }],
      date: '2026-01-01', note: '', createdAt: '2026-01-01T00:01:00Z',
    }]
    const result = {
      groupId: '00000000-0000-4000-8000-000000000001', groupName: '測試帳本',
      setupToken: 'a'.repeat(32), setupExpiresAt: '2026-09-08T00:00:00Z',
      members: [
        { clientId: 'local-a', id: '00000000-0000-4000-8000-000000000010', name: '阿哲', color: '#111111', createdAt: '2026-01-01T00:00:00Z', linked: true },
        { clientId: 'local-b', id: '00000000-0000-4000-8000-000000000011', name: '美玲', color: '#222222', createdAt: '2026-01-01T00:00:01Z', linked: false },
      ],
    }

    const mapped = applyBootstrapMapping(participants, expenses, result)
    expect(mapped.participants.map((member) => member.id)).toEqual(result.members.map((member) => member.id))
    expect(mapped.expenses[0]).toMatchObject({
      amount: 100,
      paidById: result.members[0].id,
      participantIds: result.members.map((member) => member.id),
      shares: [
        { participantId: result.members[0].id, amount: 40, receivedAt: null },
        { participantId: result.members[1].id, amount: 60, receivedAt: null },
      ],
    })
  })

  it('rejects a partial mapping instead of corrupting references', () => {
    const participants: Participant[] = [{ id: 'missing', name: '小宇', color: '#333333', createdAt: '' }]
    expect(() => applyBootstrapMapping(participants, [], {
      groupId: 'group', groupName: '帳本', members: [], setupToken: 'a'.repeat(32), setupExpiresAt: '2026-09-08T00:00:00Z',
    })).toThrow('雲端回應缺少成員')
  })

  it('adds the verified LINE creator without changing imported money references', () => {
    const participant: Participant = { id: 'local-a', name: '同行者', color: '#111111', createdAt: '' }
    const result = {
      groupId: '00000000-0000-4000-8000-000000000001', groupName: '新帳本',
      members: [
        { id: '00000000-0000-4000-8000-000000000020', name: '建立者', color: '#4f7c68', createdAt: '2026-01-01', linked: true },
        { clientId: 'local-a', id: '00000000-0000-4000-8000-000000000021', name: '同行者', color: '#111111', createdAt: '2026-01-02', linked: false },
      ],
    }
    const mapped = applyBootstrapMapping([participant], [], result)
    expect(mapped.participants).toEqual([
      expect.objectContaining({ name: '建立者', isResponsible: true }),
      expect.objectContaining({ id: result.members[1].id, name: '同行者' }),
    ])
  })

  it('round-trips a portable setup key and rejects malformed input', () => {
    const groupId = '00000000-0000-4000-8000-000000000001'
    const setupToken = 'b'.repeat(32)
    const key = formatLedgerSetupKey(groupId, setupToken)
    expect(parseLedgerSetupKey(key.toUpperCase())).toEqual({ groupId, setupToken })
    expect(() => parseLedgerSetupKey(`${groupId}.short`)).toThrow('格式不正確')
  })

  it('strictly parses a rotated setup key without accepting partial data', () => {
    const recovered = parseRecoveredSetup({
      groupId: '00000000-0000-4000-8000-000000000001',
      groupName: '找回的帳本',
      setupToken: 'c'.repeat(32),
      setupExpiresAt: '2026-09-08T00:00:00Z',
    })
    expect(recovered).toMatchObject({ groupName: '找回的帳本', setupToken: 'c'.repeat(32) })
    expect(() => parseRecoveredSetup({ ...recovered, setupToken: 'short' })).toThrow('格式不正確')
  })

  it('requires a strict responsible-member boolean in cloud member data', () => {
    const member = {
      id: '00000000-0000-4000-8000-000000000010',
      name: '美玲',
      color: '#5E7868',
      avatarUrl: null,
      createdAt: '2026-08-09T00:00:00Z',
    }

    expect(parseCloudMembers([{ ...member, isResponsible: false }])).toEqual([
      { ...member, isResponsible: false },
    ])
    expect(() => parseCloudMembers([{ ...member, isResponsible: null }])).toThrow('雲端成員資料格式不正確')
  })

  it('preserves setup authority when the creator joins the same ledger', () => {
    const current = {
      groupId: '00000000-0000-4000-8000-000000000001',
      groupName: '開帳中的帳本',
      setupToken: 'a'.repeat(32),
      setupExpiresAt: '2026-09-08T00:00:00Z',
    }
    const joined = { groupId: current.groupId, groupName: current.groupName }

    expect(mergeJoinedLedgerAccess(current, joined)).toEqual(current)
    expect(mergeJoinedLedgerAccess(current, { groupId: 'other', groupName: '另一帳本' })).toEqual({
      groupId: 'other',
      groupName: '另一帳本',
    })
  })

  it('keeps the handoff member list and marks exactly one responsible member', () => {
    const participants: Participant[] = [
      { id: 'member-a', name: '阿哲', color: '#111111', createdAt: '' },
      { id: 'member-b', name: '美玲', color: '#222222', createdAt: '' },
    ]
    const result = markResponsibleMember(participants, 'member-b')

    expect(result).toHaveLength(2)
    expect(result.filter((member) => member.isResponsible)).toEqual([{ ...participants[1], isResponsible: true }])
  })

  it('keeps creator and current-owner boundaries separate in a multi-ledger directory', () => {
    const directory = parseLedgerDirectory({
      limits: { activeOwned: 5, totalOwned: 10, activeJoined: 30, membersPerLedger: 50 },
      usage: { activeOwned: 1, totalOwned: 2, activeJoined: 1 },
      ledgers: [
        { groupId: '00000000-0000-4000-8000-000000000031', groupName: '我建立後已轉移', status: 'active', archivedAt: null, createdAt: '2026-01-01', updatedAt: '2026-01-03', isCreator: true, isOwner: false, memberId: 'member-1', memberCount: 2, expenseCount: 4 },
        { groupId: '00000000-0000-4000-8000-000000000032', groupName: '別人建立由我負責', status: 'archived', archivedAt: '2026-01-04', createdAt: '2026-01-02', updatedAt: '2026-01-04', isCreator: false, isOwner: true, memberId: 'member-2', memberCount: 3, expenseCount: 8 },
      ],
    })
    expect(directory.ledgers[0]).toMatchObject({ isCreator: true, isOwner: false })
    expect(directory.ledgers[1]).toMatchObject({ isCreator: false, isOwner: true, status: 'archived' })
    expect(selectCloudLedger(directory, directory.ledgers[1].groupId)).toMatchObject({ groupName: '別人建立由我負責', status: 'archived' })
    expect(() => parseLedgerDirectory({ ...directory, usage: { ...directory.usage, activeOwned: 6 } })).toThrow('配額資料不一致')
  })

  it('strictly parses the LINE invite membership status', () => {
    expect(parseLineInviteMembershipStatus({ groupId: 'group-1', groupName: '白海豚', isMember: true, isResponsible: true, inviteAvailable: false })).toEqual({
      groupId: 'group-1',
      groupName: '白海豚',
      isMember: true,
      isResponsible: true,
      inviteAvailable: false,
    })
    expect(() => parseLineInviteMembershipStatus({ groupId: 'group-1', groupName: '白海豚', isMember: 'yes', isResponsible: true, inviteAvailable: true })).toThrow('資料格式不正確')
  })

  it('accepts only complete LINE app sessions', () => {
    const session = { accessToken: 'a'.repeat(40), refreshToken: 'r'.repeat(12) }
    expect(parseLineAppSession(session)).toEqual(session)
    expect(parseLineAppSession(null)).toBeNull()
    expect(() => parseLineAppSession({ ...session, refreshToken: 'short' })).toThrow('LINE 帳務登入資料格式不正確')
  })

  it('accepts only a minimal verified LINE profile contract', () => {
    expect(parseLineAccountProfile({ displayName: ' 牛 ', avatarUrl: 'https://profile.line-scdn.net/example' })).toEqual({
      displayName: '牛',
      avatarUrl: 'https://profile.line-scdn.net/example',
    })
    expect(parseLineAccountProfile(null)).toBeNull()
    expect(() => parseLineAccountProfile({ displayName: '', avatarUrl: null })).toThrow('LINE 個人資料格式不正確')
    expect(() => parseLineAccountProfile({ displayName: '牛', avatarUrl: 'http://unsafe.example/avatar' })).toThrow('LINE 個人資料格式不正確')
    expect(() => parseLineAccountProfile({ displayName: '牛', avatarUrl: null, lineUserId: 'must-not-be-trusted' })).toThrow('LINE 個人資料格式不正確')
  })

  it('strictly parses fund balances and dual-confirmed close-out data', () => {
    const data = {
      configured: true,
      balance: 1200,
      netBalance: 1000,
      version: 3,
      cycleNumber: 1,
      status: 'closing',
      configuredAt: '2026-08-09T00:00:00Z',
      closingStartedAt: '2026-08-09T01:00:00Z',
      closedAt: null,
      currentMemberId: 'member-a',
      isOwner: true,
      accounts: [{
        memberId: 'member-a', name: '阿哲', color: '#5E7868', avatarUrl: null,
        balance: -200, contributedTotal: 1000, consumedTotal: 1200, refundedTotal: 0,
      }],
      advances: [{
        id: 'advance-1', transactionId: 'transaction-1', memberId: 'member-a', memberName: '阿哲',
        amount: 200, settledAmount: 0, remainingAmount: 200,
        recordedByMemberId: 'member-a', recordedByName: '阿哲', sourceType: 'web', isOnBehalf: false,
        status: 'open', memberConfirmedAt: null, responsibleConfirmedAt: null,
        completedAt: null, createdAt: '2026-08-09T00:30:00Z',
      }],
      settlements: [{
        memberId: 'member-a', direction: 'offset', amount: 0, cashAmount: 0,
        accountBalance: -200, accountTopUp: 200, accountRefund: 0,
        advanceAmount: 200, advanceOffsetAmount: 200,
        memberConfirmedAt: null, responsibleConfirmedAt: null, hasStaleConfirmation: false,
      }],
      transactions: [{
        id: 'transaction-1', cycleNumber: 1, type: 'expense', title: '代墊支出',
        amountDelta: -200, balanceAfter: 100, effectiveDate: '2026-08-09', note: null,
        createdAt: '2026-08-09T00:30:00Z', sourceMemberId: 'member-a', sourceName: '阿哲',
        sourceType: 'web', lines: [{ memberId: 'member-a', amountDelta: -200 }],
      }],
    }

    expect(parseGroupFund(data)).toMatchObject({
      configured: true,
      currentMemberId: 'member-a',
      status: 'closing',
      advances: [{ amount: 200, settledAmount: 0, remainingAmount: 200, status: 'open' }],
      settlements: [{ direction: 'offset', amount: 0, advanceOffsetAmount: 200 }],
      transactions: [{ sourceMemberId: 'member-a', sourceType: 'web' }],
    })
    expect(() => parseGroupFund({ ...data, settlements: [{ ...data.settlements[0], direction: 'transfer' }] })).toThrow('公費結清資料格式不正確')
    expect(() => parseGroupFund({ ...data, settlements: [{ ...data.settlements[0], cashAmount: 1 }] })).toThrow('公費結清資料格式不正確')
    expect(() => parseGroupFund({ ...data, transactions: [{ ...data.transactions[0], sourceType: 'bot' }] })).toThrow('公費交易格式不正確')
    expect(() => parseGroupFund({ ...data, settlements: [{ ...data.settlements[0], hasStaleConfirmation: 'no' }] })).toThrow('公費結清資料格式不正確')
    expect(() => parseGroupFund({ ...data, cycleNumber: 0 })).toThrow('公費資料格式不完整')
  })

  it('strictly parses recurring trip collection rounds', () => {
    const data = {
      currentMemberId: 'member-a',
      rounds: [{
        id: 'round-1', cycleNumber: 2, title: '花蓮出遊公費', amountPerMember: 2000,
        effectiveDate: '2026-08-09', status: 'open', createdAt: '2026-08-09T00:00:00Z', completedAt: null,
        entries: [{
          memberId: 'member-a', name: '阿哲', color: '#5E7868', avatarUrl: null,
          amount: 2000, offsetAmount: 700, cashAmount: 1300,
          offsets: [{ id: 'offset-1', advanceId: 'advance-1', amount: 700, status: 'pending', completedAt: null }],
          status: 'pending', memberConfirmedAt: '2026-08-09T00:01:00Z',
          responsibleConfirmedAt: null, completedAt: null,
        }],
      }],
    }

    expect(parseFundCollections(data)).toEqual(data)
    expect(() => parseFundCollections({ ...data, rounds: [{ ...data.rounds[0], cycleNumber: 0 }] })).toThrow('公費收款批次格式不正確')
    expect(() => parseFundCollections({ ...data, rounds: [{ ...data.rounds[0], status: 'cancelled' }] })).toThrow('公費收款批次格式不正確')
    expect(() => parseFundCollections({ ...data, rounds: [{ ...data.rounds[0], entries: [{ ...data.rounds[0].entries[0], memberConfirmedAt: false }] }] })).toThrow('公費收款成員格式不正確')
  })
})
