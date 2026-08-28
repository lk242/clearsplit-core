export async function verifyHmacSha256Base64(body: string, signature: string, secret: string) {
  let supplied: Uint8Array
  try {
    supplied = Uint8Array.from(atob(signature), (character) => character.charCodeAt(0))
  } catch {
    return false
  }
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const expected = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)))
  return timingSafeEqual(supplied, expected)
}

export async function verifyEd25519Hex(body: string, timestamp: string, signature: string, publicKey: string) {
  try {
    const key = await crypto.subtle.importKey('raw', fromHex(publicKey), { name: 'Ed25519' }, false, ['verify'])
    return await crypto.subtle.verify('Ed25519', key, fromHex(signature), new TextEncoder().encode(timestamp + body))
  } catch {
    return false
  }
}

export function timingSafeEqual(left: Uint8Array, right: Uint8Array) {
  if (left.length !== right.length) return false
  let difference = 0
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index]
  return difference === 0
}

function fromHex(value: string) {
  if (!/^[0-9a-f]+$/i.test(value) || value.length % 2 !== 0) throw new Error('invalid hex')
  return Uint8Array.from(value.match(/.{2}/g) ?? [], (byte) => Number.parseInt(byte, 16))
}
