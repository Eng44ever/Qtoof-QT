import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const supabaseUrl = Deno.env.get('SUPABASE_URL')!
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!

const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } })
const authClient = createClient(supabaseUrl, anonKey, { auth: { autoRefreshToken: false, persistSession: false } })

async function sha256(value: string): Promise<string> {
  const data = new TextEncoder().encode(value)
  const digest = await crypto.subtle.digest('SHA-256', data)
  return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('')
}

function genericFailure(status = 401) {
  return new Response(JSON.stringify({ error: 'INVALID_LOGIN' }), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
  })
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })

  try {
    const body = await req.json()
    const username = String(body?.username ?? '').trim()
    const password = String(body?.password ?? '')
    if (username.length < 2 || username.length > 40 || password.length < 1) return genericFailure()

    const forwarded = req.headers.get('x-forwarded-for') || req.headers.get('cf-connecting-ip') || 'unknown'
    const ip = forwarded.split(',')[0].trim().slice(0, 100) || 'unknown'
    const normalized = username.toLowerCase()
    const usernameKey = await sha256(`username:${normalized}`)
    const ipKey = await sha256(`ip:${ip}`)

    for (const key of [usernameKey, ipKey]) {
      const { data: limit, error: limitError } = await admin.rpc('qtoof_check_login_rate_limit', {
        p_key_hash: key,
        p_max_attempts: 5,
        p_window_seconds: 900
      })
      if (limitError || !limit?.allowed) return genericFailure(429)
    }

    const { data: profile, error: profileError } = await admin
      .from('users')
      .select('auth_user_id')
      .ilike('username', normalized)
      .limit(1)
      .maybeSingle()

    if (profileError || !profile?.auth_user_id) return genericFailure()

    const { data: authUser, error: authUserError } = await admin.auth.admin.getUserById(profile.auth_user_id)
    const email = authUser?.user?.email || ''
    if (authUserError || !email) return genericFailure()

    const { data: session, error: signInError } = await authClient.auth.signInWithPassword({ email, password })
    if (signInError || !session.session) return genericFailure()

    for (const key of [usernameKey, ipKey]) {
      await admin.rpc('qtoof_clear_login_rate_limit', { p_key_hash: key })
    }

    return new Response(JSON.stringify({
      access_token: session.session.access_token,
      refresh_token: session.session.refresh_token,
      expires_in: session.session.expires_in,
      expires_at: session.session.expires_at,
      token_type: session.session.token_type,
      user: session.user
    }), {
      status: 200,
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' }
    })
  } catch (_) {
    return genericFailure()
  }
})
