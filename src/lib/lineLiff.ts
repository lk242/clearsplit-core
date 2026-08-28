export type LineIdentity = {
  accessToken: string
  displayName: string
  pictureUrl: string | null
}

export const isLiffConfigured = Boolean(import.meta.env.VITE_LIFF_ID?.trim())

export async function loadLineIdentity(loginIfNeeded: boolean, redirectUri: string | (() => string) = window.location.href, forceLogin = false): Promise<LineIdentity | null> {
  const liffId = import.meta.env.VITE_LIFF_ID?.trim()
  if (!liffId) throw new Error('這個部署尚未設定 LIFF ID')

  const { default: liff } = await import('@line/liff')
  await liff.init({ liffId })
  if (forceLogin && liff.isLoggedIn()) {
    liff.logout()
    liff.login({ redirectUri: resolveRedirectUri(redirectUri) })
    return null
  }
  if (!liff.isLoggedIn()) {
    if (loginIfNeeded) liff.login({ redirectUri: resolveRedirectUri(redirectUri) })
    return null
  }

  const accessToken = liff.getAccessToken()
  if (!accessToken) throw new Error('LINE 沒有提供有效登入憑證，請重新開啟邀請')
  const profile = await liff.getProfile()
  return {
    accessToken,
    displayName: profile.displayName,
    pictureUrl: profile.pictureUrl ?? null,
  }
}

function resolveRedirectUri(value: string | (() => string)) {
  return typeof value === 'function' ? value() : value
}
