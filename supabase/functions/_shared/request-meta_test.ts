// GET-470 — request-meta: server-secret trust + IP/UA resolution.
// Run: DENO_NO_PACKAGE_JSON=1 deno test supabase/functions/_shared/request-meta_test.ts
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { cleanIp, cleanUa, ipFromHeaders, requestMeta, secretMatches } from './request-meta.ts'

Deno.test('secretMatches: equal strings only; unset or empty configured secret never matches', () => {
  assertEquals(secretMatches('s3cret-value', 's3cret-value'), true)
  assertEquals(secretMatches('s3cret-valuX', 's3cret-value'), false)
  assertEquals(secretMatches('s3cret', 's3cret-value'), false)
  assertEquals(secretMatches('s3cret-value-longer', 's3cret-value'), false)
  assertEquals(secretMatches('', 's3cret-value'), false)
  assertEquals(secretMatches(null, 's3cret-value'), false)
  assertEquals(secretMatches('anything', ''), false)
  assertEquals(secretMatches('', ''), false)
  assertEquals(secretMatches(undefined, undefined), false)
})

Deno.test('cleanIp / cleanUa', () => {
  assertEquals(cleanIp(' 203.0.113.7 '), '203.0.113.7')
  assertEquals(cleanIp('2001:db8::1'), '2001:db8::1')
  assertEquals(cleanIp('evil.example.com'), null)
  assertEquals(cleanIp('1.2.3.4, 5.6.7.8'), null)
  assertEquals(cleanIp(42), null)
  assertEquals(cleanUa('  Mozilla/5.0  '), 'Mozilla/5.0')
  assertEquals(cleanUa(''), null)
  assertEquals(cleanUa('x'.repeat(900))?.length, 500)
})

Deno.test('ipFromHeaders: cf-connecting-ip first, else the right-most X-Forwarded-For entry', () => {
  assertEquals(ipFromHeaders(new Headers({ 'cf-connecting-ip': '198.51.100.2', 'x-forwarded-for': '1.1.1.1' })), '198.51.100.2')
  // The left-most entry is whatever the client sent — never used.
  assertEquals(ipFromHeaders(new Headers({ 'x-forwarded-for': '6.6.6.6, 198.51.100.9' })), '198.51.100.9')
  assertEquals(ipFromHeaders(new Headers({})), null)
})

Deno.test('requestMeta: body ip/UA trusted only with the matching server secret', () => {
  const body = { ip: '203.0.113.50', user_agent: 'RealBrowser/1.0' }
  const server = new Headers({ 'x-gi-server-secret': 'top', 'user-agent': 'node', 'x-forwarded-for': '10.0.0.1' })
  assertEquals(requestMeta(server, body, 'top'), { ip: '203.0.113.50', userAgent: 'RealBrowser/1.0', trusted: true })

  const forged = new Headers({ 'x-gi-server-secret': 'guess', 'user-agent': 'curl/8', 'x-forwarded-for': '9.9.9.9' })
  assertEquals(requestMeta(forged, body, 'top'), { ip: '9.9.9.9', userAgent: 'curl/8', trusted: false })

  const direct = new Headers({ 'user-agent': 'Safari', 'cf-connecting-ip': '198.51.100.3' })
  assertEquals(requestMeta(direct, body, 'top'), { ip: '198.51.100.3', userAgent: 'Safari', trusted: false })

  // Secret not configured: nobody is trusted, even with a header.
  assertEquals(requestMeta(server, body, undefined).trusted, false)
})
