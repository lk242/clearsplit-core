const inviteTokenPattern = /^[0-9a-f]{64}$/

export function readInviteToken(search: string): string | null {
  const params = new URLSearchParams(search)
  const directToken = params.get('invite')
  if (isInviteToken(directToken)) return directToken

  const liffState = params.get('liff.state')
  if (!liffState) return null

  try {
    const stateUrl = new URL(liffState, 'https://liff-callback.invalid')
    const stateToken = stateUrl.searchParams.get('invite')
    return isInviteToken(stateToken) ? stateToken : null
  } catch {
    return null
  }
}

export function buildInviteUrl(token: string, liffId: string | undefined, origin: string, pathname: string) {
  assertInviteToken(token)
  const normalizedLiffId = liffId?.trim()
  const url = normalizedLiffId
    ? new URL(`https://liff.line.me/${encodeURIComponent(normalizedLiffId)}`)
    : new URL(pathname, origin)
  url.searchParams.set('invite', token)
  return url.toString()
}

export function buildInviteCallbackUrl(token: string, origin: string, pathname: string) {
  assertInviteToken(token)
  const url = new URL(pathname, origin)
  url.searchParams.set('invite', token)
  return url.toString()
}

function isInviteToken(value: string | null): value is string {
  return value !== null && inviteTokenPattern.test(value)
}

function assertInviteToken(token: string) {
  if (!isInviteToken(token)) throw new Error('invalid invite token')
}
