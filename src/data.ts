import type { Expense, Participant } from './types'

export const participantColors = ['#587561', '#9a725f', '#647995', '#8d6d8e', '#9b874f', '#5f8587']

export const defaultParticipants: Participant[] = [
  { id: 'member-alex', name: '阿哲', color: participantColors[0], createdAt: '2026-08-01T10:00:00.000Z' },
  { id: 'member-mei', name: '美玲', color: participantColors[1], createdAt: '2026-08-01T10:01:00.000Z' },
  { id: 'member-yu', name: '小宇', color: participantColors[2], createdAt: '2026-08-01T10:02:00.000Z' },
]

export const defaultExpenses: Expense[] = [
  {
    id: 'expense-dinner',
    title: '週末聚餐',
    amount: 1860,
    category: 'food',
    paidById: 'member-alex',
    participantIds: ['member-alex', 'member-mei', 'member-yu'],
    splitMode: 'equal',
    shares: [
      { participantId: 'member-alex', amount: 620, receivedAt: null },
      { participantId: 'member-mei', amount: 620, receivedAt: null },
      { participantId: 'member-yu', amount: 620, receivedAt: null },
    ],
    status: 'active',
    resolvedAt: null,
    date: '2026-08-07',
    note: '大家一起吃的晚餐',
    createdAt: '2026-08-07T13:20:00.000Z',
  },
  {
    id: 'expense-taxi',
    title: '回程計程車',
    amount: 540,
    category: 'transport',
    paidById: 'member-mei',
    participantIds: ['member-alex', 'member-mei', 'member-yu'],
    splitMode: 'equal',
    shares: [
      { participantId: 'member-alex', amount: 180, receivedAt: null },
      { participantId: 'member-mei', amount: 180, receivedAt: null },
      { participantId: 'member-yu', amount: 180, receivedAt: null },
    ],
    status: 'active',
    resolvedAt: null,
    date: '2026-08-07',
    note: '',
    createdAt: '2026-08-07T15:45:00.000Z',
  },
]
