import { describe, expect, it } from 'vitest'
import { defaultExpenses, defaultParticipants } from '../data'
import { prepareProductionStorage } from './demoStorage'

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

describe('production demo cleanup', () => {
  it('removes only the exact built-in demo once', () => {
    const storage = memoryStorage({
      'clearsplit-participants': JSON.stringify(defaultParticipants),
      'clearsplit-expenses': JSON.stringify(defaultExpenses),
      'clearsplit-settlement-confirmations': JSON.stringify([{ participantId: 'member-alex' }]),
    })
    expect(prepareProductionStorage(storage, true)).toBe(true)
    expect(storage.getItem('clearsplit-participants')).toBeNull()
    expect(storage.getItem('clearsplit-expenses')).toBeNull()
    expect(storage.getItem('clearsplit-settlement-confirmations')).toBeNull()
    expect(prepareProductionStorage(storage, true)).toBe(false)
  })

  it('preserves any user-modified data', () => {
    const storage = memoryStorage({
      'clearsplit-participants': JSON.stringify(defaultParticipants),
      'clearsplit-expenses': JSON.stringify([{ ...defaultExpenses[0], amount: 2000 }]),
    })
    expect(prepareProductionStorage(storage, true)).toBe(false)
    expect(storage.getItem('clearsplit-participants')).not.toBeNull()
    expect(storage.getItem('clearsplit-expenses')).not.toBeNull()
  })

  it('does nothing in local development', () => {
    const storage = memoryStorage({
      'clearsplit-participants': JSON.stringify(defaultParticipants),
      'clearsplit-expenses': JSON.stringify(defaultExpenses),
    })
    expect(prepareProductionStorage(storage, false)).toBe(false)
    expect(storage.getItem('clearsplit-expenses')).not.toBeNull()
  })
})
