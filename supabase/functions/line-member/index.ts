import { createClient } from 'npm:@supabase/supabase-js@2.112.2'

type MemberAction = 'status' | 'resume' | 'join' | 'restore' | 'exchange'

type MemberBody = {
  action?: unknown
  inviteToken?: unknown
  lineAccessToken?: unknown
  color?: unknown
  handoffToken?: unknown
}

type LineProfile = {
  userId: string
  displayName: string
  pictureUrl?: string
}

const supabaseUrl = Deno.env.get('SUPABASE_URL')
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
const lineLoginChannelId = Deno.env.get('LINE_LOGIN_CHANNEL_ID')
const allowedOrigins = new Set((Deno.env.get('APP_ORIGINS') ?? 'http://localhost:5173')
  .split(',').map((value) => value.trim()).filter(Boolean))

if (!supabaseUrl || !serviceRoleKey || !anonKey) throw new Error('Supabase server credentials are unavailable')
const serviceClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
const sessionClient = createClient(supabaseUrl, anonKey, {
  auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
})

Deno.serve(async (request) => {
  const origin = request.headers.get('origin') ?? ''
  const corsHeaders = {
    'Access-Control-Allow-Origin': allowedOrigins.has(origin) ? origin : 'null',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  }
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405, corsHeaders)
  if (!allowedOrigins.has(origin)) return json({ error: 'Origin is not allowed' }, 403, corsHeaders)
  if (!lineLoginChannelId) return json({ error: 'LINE Login is not configured' }, 503, corsHeaders)

  try {
    const authorization = request.headers.get('authorization')
    if (!authorization?.startsWith('Bearer ')) return json({ error: 'Authentication required' }, 401, corsHeaders)
    const userClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false },
      global: { headers: { Authorization: authorization } },
    })
    const { data: userData, error: userError } = await userClient.auth.getUser()
    if (userError || !userData.user) return json({ error: 'Invalid app session' }, 401, corsHeaders)

    const body = await request.json() as MemberBody
    const action = parseAction(body.action)
    if (action === 'exchange') {
      if (!isHandoffToken(body.handoffToken)) return json({ error: 'Invalid request' }, 400, corsHeaders)
      const { data: handoffUserId, error: consumeError } = await serviceClient.rpc('consume_line_auth_handoff', {
        p_token_hash: await sha256(body.handoffToken),
      })
      if (consumeError) {
        console.error('LINE auth handoff exchange failed', { code: consumeError.code })
        return json({ error: '無法接回 LINE 登入狀態' }, 500, corsHeaders)
      }
      if (typeof handoffUserId !== 'string') {
        console.info('LINE auth handoff pending')
        return json({ data: { status: 'pending' }, session: null }, 200, corsHeaders)
      }
      const session = await issueStableLineSession(handoffUserId)
      console.info('LINE auth handoff exchanged')
      return json({ data: { status: 'ready' }, session }, 200, corsHeaders)
    }

    const needsInvite = action !== 'restore'
    if ((needsInvite && (typeof body.inviteToken !== 'string' || !/^[0-9a-f]{64}$/.test(body.inviteToken)))
      || typeof body.lineAccessToken !== 'string' || body.lineAccessToken.length > 4096
      || (action === 'join' && (typeof body.color !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(body.color)))
      || (body.handoffToken !== undefined && !isHandoffToken(body.handoffToken))) {
      return json({ error: 'Invalid request' }, 400, corsHeaders)
    }

    const profile = await verifyLineProfile(body.lineAccessToken, lineLoginChannelId)
    if ('error' in profile) return json({ error: profile.error }, profile.status, corsHeaders)

    if (action === 'status') {
      const { data, error } = await serviceClient.rpc('get_line_invite_membership_status', {
        p_token: body.inviteToken,
        p_line_user_id: profile.userId,
      })
      if (error) {
        console.error('LINE membership status failed', { code: error.code })
        return json({ error: error.code === '22023' ? '邀請連結無效或已不存在' : '無法檢查 LINE 成員狀態' }, 400, corsHeaders)
      }
      return json({ data, session: null }, 200, corsHeaders)
    }

    const currentAuthUserId = userData.user.id
    const { data: identityData, error: identityError } = await serviceClient.rpc('record_verified_line_identity', {
      p_auth_user_id: currentAuthUserId,
      p_line_user_id: profile.userId,
      p_display_name: profile.displayName.trim(),
      p_avatar_url: profile.pictureUrl ?? null,
    })
    const stableAuthUserId = isRecord(identityData) && typeof identityData.userId === 'string'
      ? identityData.userId
      : null
    if (identityError || !stableAuthUserId) {
      console.error('LINE identity registration failed', { code: identityError?.code })
      return json({ error: identityError?.code === '23505' ? 'LINE 帳務身分與目前登入衝突' : '無法建立 LINE 帳務身分' }, 400, corsHeaders)
    }

    let data: unknown
    if (action === 'restore') {
      const result = await serviceClient.rpc('restore_active_ledger_with_line', {
        p_auth_user_id: stableAuthUserId,
        p_line_user_id: profile.userId,
        p_display_name: profile.displayName.trim(),
        p_avatar_url: profile.pictureUrl ?? null,
      })
      if (result.error) {
        console.error('LINE direct-site restore failed', { code: result.error.code })
        return json({ error: '無法恢復 LINE 帳務身分' }, 400, corsHeaders)
      }
      data = result.data
    } else if (action === 'resume') {
      const result = await serviceClient.rpc('resume_group_invite_with_line', {
        p_token: body.inviteToken,
        p_auth_user_id: stableAuthUserId,
        p_line_user_id: profile.userId,
        p_display_name: profile.displayName.trim(),
        p_avatar_url: profile.pictureUrl ?? null,
      })
      if (result.error) {
        console.error('LINE member resume failed', { code: result.error.code })
        return json({ error: result.error.code === '22023' ? '邀請連結無效或已不存在' : '無法恢復 LINE 成員狀態' }, 400, corsHeaders)
      }
      data = result.data
    } else {
      const result = await serviceClient.rpc('join_group_invite_with_line', {
        p_token: body.inviteToken,
        p_auth_user_id: stableAuthUserId,
        p_line_user_id: profile.userId,
        p_display_name: profile.displayName.trim(),
        p_avatar_url: profile.pictureUrl ?? null,
        p_color: body.color as string,
      })
      if (result.error) {
        console.error('LINE member join failed', { code: result.error.code })
        return json({ error: result.error.code === '22023' ? '邀請連結無效或已不存在' : '無法加入帳本' }, 400, corsHeaders)
      }
      data = result.data
    }

    const alreadyStable = currentAuthUserId === stableAuthUserId
      && userData.user.user_metadata?.clearsplit_line_identity === true
    const session = alreadyStable ? null : await issueStableLineSession(stableAuthUserId, profile.userId)
    if (typeof body.handoffToken === 'string') {
      const { error: handoffError } = await serviceClient.rpc('store_line_auth_handoff', {
        p_token_hash: await sha256(body.handoffToken),
        p_auth_user_id: stableAuthUserId,
      })
      if (handoffError) {
        console.error('LINE auth handoff storage failed', { code: handoffError.code })
        return json({ error: '無法交接 LINE 登入狀態' }, 500, corsHeaders)
      }
      console.info('LINE auth handoff stored')
    }
    return json({ data, session }, 200, corsHeaders)
  } catch (error) {
    console.error('LINE member function failed', error)
    return json({ error: '伺服器無法完成 LINE 登入' }, 500, corsHeaders)
  }
})

function parseAction(value: unknown): MemberAction {
  if (value === 'status' || value === 'resume' || value === 'restore' || value === 'exchange') return value
  return 'join'
}

async function verifyLineProfile(accessToken: string, channelId: string): Promise<LineProfile | { error: string; status: number }> {
  const verificationResponse = await fetch(`https://api.line.me/oauth2/v2.1/verify?access_token=${encodeURIComponent(accessToken)}`)
  if (!verificationResponse.ok) return { error: 'LINE 登入已過期', status: 401 }
  const verification = await verificationResponse.json() as { client_id?: unknown; expires_in?: unknown; scope?: unknown }
  if (verification.client_id !== channelId || typeof verification.expires_in !== 'number' || verification.expires_in <= 0
    || typeof verification.scope !== 'string' || !verification.scope.split(' ').includes('profile')) {
    return { error: 'LINE token 不屬於這個應用程式', status: 401 }
  }

  const profileResponse = await fetch('https://api.line.me/v2/profile', {
    headers: { Authorization: `Bearer ${accessToken}` },
  })
  if (!profileResponse.ok) return { error: '無法讀取 LINE 個人資料', status: 401 }
  const profile = await profileResponse.json() as { userId?: unknown; displayName?: unknown; pictureUrl?: unknown }
  if (typeof profile.userId !== 'string' || !/^U[0-9a-f]{32}$/.test(profile.userId)
    || typeof profile.displayName !== 'string' || profile.displayName.trim().length < 1
    || profile.displayName.trim().length > 80
    || (profile.pictureUrl !== undefined && (typeof profile.pictureUrl !== 'string' || !profile.pictureUrl.startsWith('https://')))) {
    return { error: 'LINE 個人資料格式不正確', status: 502 }
  }
  return profile as LineProfile
}

async function issueStableLineSession(authUserId: string, lineUserId?: string) {
  const { data: authUser, error: getUserError } = await serviceClient.auth.admin.getUserById(authUserId)
  if (getUserError || !authUser.user) throw new Error('Stable LINE Auth user is unavailable')

  const stableEmail = lineUserId
    ? `line-${await sha256(lineUserId)}@users.clearsplit.app`
    : authUser.user.email
  if (!stableEmail || (!lineUserId && (authUser.user.user_metadata?.clearsplit_line_identity !== true
    || !/^line-[0-9a-f]{64}@users\.clearsplit\.app$/.test(stableEmail)))) {
    throw new Error('LINE Auth handoff user is invalid')
  }

  if (lineUserId && (authUser.user.email !== stableEmail || authUser.user.user_metadata?.clearsplit_line_identity !== true)) {
    const { error: updateError } = await serviceClient.auth.admin.updateUserById(authUserId, {
      email: stableEmail,
      email_confirm: true,
      user_metadata: { ...authUser.user.user_metadata, clearsplit_line_identity: true },
    })
    if (updateError) throw new Error(`Unable to upgrade LINE Auth user: ${updateError.message}`)
  }

  const { data: linkData, error: linkError } = await serviceClient.auth.admin.generateLink({
    type: 'magiclink',
    email: stableEmail,
  })
  const tokenHash = linkData?.properties?.hashed_token
  if (linkError || !tokenHash) throw new Error(`Unable to create LINE app session: ${linkError?.message ?? 'token missing'}`)

  const { data: sessionData, error: sessionError } = await sessionClient.auth.verifyOtp({
    token_hash: tokenHash,
    type: 'email',
  })
  if (sessionError || !sessionData.session) throw new Error(`Unable to verify LINE app session: ${sessionError?.message ?? 'session missing'}`)
  return {
    accessToken: sessionData.session.access_token,
    refreshToken: sessionData.session.refresh_token,
  }
}

function isHandoffToken(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('')
}

function json(payload: unknown, status: number, headers: Record<string, string>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8' },
  })
}
