export function parseLineBotFriendUrl(value: unknown) {
  if (typeof value !== 'string' || !value.trim()) return null
  try {
    const url = new URL(value.trim())
    if (url.protocol !== 'https:' || (url.hostname !== 'lin.ee' && url.hostname !== 'line.me')) return null
    return url.toString()
  } catch {
    return null
  }
}
