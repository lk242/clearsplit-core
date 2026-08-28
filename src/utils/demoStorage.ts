import { defaultExpenses, defaultParticipants } from '../data'

const cleanupMarker = 'clearsplit-demo-cleanup-v1'
const participantKey = 'clearsplit-participants'
const expenseKey = 'clearsplit-expenses'
const settlementKey = 'clearsplit-settlement-confirmations'

export function prepareProductionStorage(storage: Storage, production: boolean) {
  if (!production || storage.getItem(cleanupMarker) === 'done') return false

  const storedParticipants = readJson(storage.getItem(participantKey))
  const storedExpenses = readJson(storage.getItem(expenseKey))
  const isExactDemo = sameJson(storedParticipants, defaultParticipants) && sameJson(storedExpenses, defaultExpenses)

  if (isExactDemo) {
    storage.removeItem(participantKey)
    storage.removeItem(expenseKey)
    storage.removeItem(settlementKey)
  }
  storage.setItem(cleanupMarker, 'done')
  return isExactDemo
}

function readJson(raw: string | null) {
  if (raw === null) return null
  try {
    return JSON.parse(raw) as unknown
  } catch {
    return null
  }
}

function sameJson(left: unknown, right: unknown) {
  return JSON.stringify(left) === JSON.stringify(right)
}
