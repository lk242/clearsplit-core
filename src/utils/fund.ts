export type FundAllocation = { participantId: string; amount: number }

export type FundCollectionOffsetPreview = {
  participantId: string
  grossAmount: number
  offsetAmount: number
  cashAmount: number
  advanceIds: string[]
}

export function allocateFundEqually(total: number, participantIds: string[]): FundAllocation[] {
  if (!Number.isSafeInteger(total) || total < 0) throw new Error('公費金額必須是非負整數')
  if (participantIds.length === 0 || new Set(participantIds).size !== participantIds.length) {
    throw new Error('公費分配成員不可為空或重複')
  }
  const base = Math.floor(total / participantIds.length)
  const remainder = total % participantIds.length
  return participantIds.map((participantId, index) => ({
    participantId,
    amount: base + (index < remainder ? 1 : 0),
  }))
}

export function previewFundCollectionOffsets(
  grossAmount: number,
  participantIds: string[],
  advances: Array<{ id: string; memberId: string; remainingAmount: number; createdAt: string }>,
  applyOffsets = true,
): FundCollectionOffsetPreview[] {
  if (!Number.isSafeInteger(grossAmount) || grossAmount <= 0) throw new Error('每人公費必須是正整數')
  if (participantIds.length === 0 || new Set(participantIds).size !== participantIds.length) {
    throw new Error('公費收款成員不可為空或重複')
  }
  if (advances.some((advance) => !Number.isSafeInteger(advance.remainingAmount) || advance.remainingAmount < 0)) {
    throw new Error('代墊餘額格式不正確')
  }

  return participantIds.map((participantId) => {
    let remainingGross = grossAmount
    const advanceIds: string[] = []
    if (applyOffsets) {
      const memberAdvances = advances
        .filter((advance) => advance.memberId === participantId && advance.remainingAmount > 0)
        .sort((left, right) => left.createdAt.localeCompare(right.createdAt) || left.id.localeCompare(right.id))
      for (const advance of memberAdvances) {
        if (remainingGross === 0) break
        const offset = Math.min(remainingGross, advance.remainingAmount)
        remainingGross -= offset
        if (offset > 0) advanceIds.push(advance.id)
      }
    }
    return {
      participantId,
      grossAmount,
      offsetAmount: grossAmount - remainingGross,
      cashAmount: remainingGross,
      advanceIds,
    }
  })
}
