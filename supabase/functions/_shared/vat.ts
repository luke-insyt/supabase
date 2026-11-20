// GET-458: EU VAT ID pre-check for our own (embedded) checkouts.
//
// Stripe's checkout has no server hook between "buyer typed a VAT ID" and "payment
// confirmed", and it applies reverse charge (0% VAT) to any ID that merely LOOKS
// right. So our checkouts never show Stripe's VAT field: the buyer enters the ID in
// our UI, we check it against VIES here, and only a non-invalid ID is attached to
// the Stripe customer — which is what Stripe Tax then reverse-charges.
//
//  - VIES says invalid → caller rejects the checkout with an error.
//  - VIES unreachable → allowed (product decision): the ID is attached, and the n8n
//    Purchase Completed check + daily "VAT ID recheck" workflow alert if it later
//    turns out invalid.
//
// Payment Links (the fallback) keep Stripe's own field + the after-payment check.

// EU member states as VIES / Stripe `eu_vat` prefixes (Greece = EL) + Northern Ireland.
const EU_VAT_PREFIXES = new Set([
  'AT', 'BE', 'BG', 'CY', 'CZ', 'DE', 'DK', 'EE', 'EL', 'ES', 'FI', 'FR', 'HR', 'HU',
  'IE', 'IT', 'LT', 'LU', 'LV', 'MT', 'NL', 'PL', 'PT', 'RO', 'SE', 'SI', 'SK', 'XI',
])

export type VatStatus = 'valid' | 'invalid' | 'unavailable'

export type VatCheck =
  | { ok: false; code: 'vat_id_format'; message: string }
  | { ok: false; code: 'vat_id_invalid'; message: string; vatId: string }
  | { ok: true; status: 'valid' | 'unavailable'; vatId: string }

export const normalizeVatId = (raw: string): string =>
  String(raw || '').replace(/[\s.\-]/g, '').toUpperCase()

export async function checkVatId(raw: string): Promise<VatCheck> {
  let vatId = normalizeVatId(raw)
  // Buyers commonly type Greece as GR (the ISO code); VIES and Stripe want EL.
  if (vatId.startsWith('GR')) vatId = 'EL' + vatId.slice(2)
  const country = vatId.slice(0, 2)
  const number = vatId.slice(2)
  if (!EU_VAT_PREFIXES.has(country) || !/^[0-9A-Z]{2,12}$/.test(number)) {
    return {
      ok: false,
      code: 'vat_id_format',
      message: 'Enter an EU VAT ID starting with the country code, e.g. DE123456789.',
    }
  }

  let status: VatStatus = 'unavailable'
  try {
    const resp = await fetch('https://ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ countryCode: country, vatNumber: number }),
      signal: AbortSignal.timeout(8000),
    })
    const r = resp.ok ? await resp.json() : {}
    if (r.valid === true) status = 'valid'
    // A definite "no" is plain valid:false; outages come back as errorWrappers /
    // userError codes (MS_UNAVAILABLE, …) — those stay 'unavailable'. Same rule as
    // the n8n "VAT: map result" node.
    else if (
      r.valid === false &&
      !r.error &&
      !(r.errorWrappers || []).length &&
      (!r.userError || r.userError === 'INVALID')
    )
      status = 'invalid'
  } catch {
    status = 'unavailable'
  }

  if (status === 'invalid') {
    return {
      ok: false,
      code: 'vat_id_invalid',
      vatId,
      message:
        'This VAT ID is not valid according to the EU VIES register. Check the number, or continue without a VAT ID.',
    }
  }
  return { ok: true, status, vatId }
}

const stripeFetch = async (stripeKey: string, path: string, init: RequestInit = {}) => {
  const resp = await fetch('https://api.stripe.com/v1' + path, {
    ...init,
    headers: {
      Authorization: 'Bearer ' + stripeKey,
      'Content-Type': 'application/x-www-form-urlencoded',
      ...(init.headers || {}),
    },
  })
  const body = await resp.json()
  if (!resp.ok) throw new Error('Stripe ' + path + ': ' + (body?.error?.message || resp.status))
  return body
}

// Find (or create) the buyer's Stripe customer and make the checked VAT ID its ONLY
// eu_vat tax ID — a stale ID from an earlier purchase must not be reverse-charged.
export async function attachVatIdToCustomer(
  stripeKey: string,
  email: string,
  vatId: string
): Promise<string> {
  const found = await stripeFetch(
    stripeKey,
    '/customers?limit=1&email=' + encodeURIComponent(email)
  )
  let customerId: string = found.data?.[0]?.id
  if (!customerId) {
    const created = await stripeFetch(stripeKey, '/customers', {
      method: 'POST',
      body: new URLSearchParams({ email }).toString(),
    })
    customerId = created.id
  }

  const ids = await stripeFetch(stripeKey, '/customers/' + customerId + '/tax_ids?limit=100')
  let hasIt = false
  for (const t of ids.data || []) {
    if (t.type !== 'eu_vat') continue
    if (normalizeVatId(t.value) === vatId && !hasIt) {
      hasIt = true
      continue
    }
    await stripeFetch(stripeKey, '/customers/' + customerId + '/tax_ids/' + t.id, {
      method: 'DELETE',
    })
  }
  if (!hasIt) {
    await stripeFetch(stripeKey, '/customers/' + customerId + '/tax_ids', {
      method: 'POST',
      body: new URLSearchParams({ type: 'eu_vat', value: vatId }).toString(),
    })
  }
  return customerId
}

// Shared session wiring: with a checked VAT ID the session runs on that customer
// (Stripe Tax reads its tax ID → reverse charge); without one it stays a plain
// email checkout. Stripe's own VAT field is never enabled on these sessions.
export function applyBuyerToSession(form: URLSearchParams, email: string, customerId: string | null) {
  if (customerId) {
    form.set('customer', customerId)
    // Save the billing address + company name the buyer enters onto the customer,
    // so the invoice and the tax calculation use them.
    form.set('customer_update[address]', 'auto')
    form.set('customer_update[name]', 'auto')
  } else {
    form.set('customer_email', email)
  }
}
