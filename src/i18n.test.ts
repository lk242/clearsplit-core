import { describe, expect, it } from 'vitest'
import { translate } from './i18n'

describe('web i18n dictionary', () => {
  it('translates the public navigation in both bundled locales', () => {
    expect(translate('zh-TW', 'nav.fund')).toBe('公費')
    expect(translate('en', 'nav.fund')).toBe('Public fund')
  })

  it('interpolates variables without evaluating their content', () => {
    expect(translate('en', 'status.lastSync', { time: '<12:00>' })).toBe('Last sync: <12:00>')
  })
})
