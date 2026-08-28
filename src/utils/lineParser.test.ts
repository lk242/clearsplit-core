import { describe, expect, it } from 'vitest'
import { parseLineCommand } from '../../supabase/functions/_shared/lineParser'

describe('parseLineCommand', () => {
  it('ignores ordinary group conversation', () => {
    expect(parseLineCommand('明天幾點集合？')).toEqual({ kind: 'ignore' })
  })

  it('creates only a public-fund expense command', () => {
    expect(parseLineCommand('#記帳 晚餐 400')).toEqual({
      kind: 'fund_expense', title: '晚餐', amount: 400,
    })
  })

  it('accepts common mobile punctuation and money formats', () => {
    expect(parseLineCommand('＃記帳 週末晚餐 NT$1,200')).toEqual({
      kind: 'fund_expense', title: '週末晚餐', amount: 1200,
    })
  })

  it('rejects private payer and participant syntax', () => {
    expect(parseLineCommand('#記帳 晚餐 400 阿哲 全員')).toMatchObject({ kind: 'invalid' })
    expect(parseLineCommand('#記帳 飲料 240 參與 牛、小美')).toMatchObject({ kind: 'invalid' })
  })

  it('never guesses from incomplete or invalid money text', () => {
    expect(parseLineCommand('#記帳 晚餐很多錢')).toMatchObject({ kind: 'invalid' })
    expect(parseLineCommand('#記帳 晚餐 0')).toMatchObject({ kind: 'invalid' })
  })

  it('accepts only exact 32-character binding codes', () => {
    expect(parseLineCommand(`#綁定 ${'a'.repeat(32)}`)).toEqual({ kind: 'bind', code: 'a'.repeat(32) })
    expect(parseLineCommand('#綁定 abc')).toMatchObject({ kind: 'invalid' })
  })
})
