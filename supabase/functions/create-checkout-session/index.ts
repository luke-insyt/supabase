import { withLogging } from '../_shared/log.ts'
import { corsHeaders, handle } from './handler.ts'

// GET-470: retired — always 410 Gone (see handler.ts). The log line per call shows whether
// anything still calls it.
Deno.serve(withLogging('create-checkout-session', corsHeaders, (req, log) => {
  if (req.method !== 'OPTIONS') log.warn('retired endpoint called', { method: req.method })
  return Promise.resolve(handle(req))
}))
