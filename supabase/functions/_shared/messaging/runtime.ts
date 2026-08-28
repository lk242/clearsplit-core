import { createClient } from 'npm:@supabase/supabase-js@2.112.2'
import { createMessagingRepository } from './repository.ts'

export function createServerRepository() {
  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!url || !key) throw new Error('Supabase server credentials are unavailable')
  return createMessagingRepository(createClient(url, key, { auth: { persistSession: false } }))
}

export function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message
  if (typeof error === 'object' && error !== null && 'message' in error && typeof error.message === 'string') return error.message
  return String(error)
}
