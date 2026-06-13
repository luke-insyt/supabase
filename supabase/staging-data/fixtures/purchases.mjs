// Purchase fixtures consumed by seed.mjs.
// stripe_session_id pattern: seed-sess-NN — used as the reset marker
// (purchases WHERE stripe_session_id LIKE 'seed-sess-%').

export const PURCHASES = [
  {
    stripe_session_id: 'seed-sess-01',
    buyer_email:  'lukaslampe87@gmail.com',
    insyt_slug:   'seed-insyt-02-paid-pdf-tutorial',
    creator_email:'lukas.lampe@ll-endeavors.com',
    amount_paid:  1900,
    payment_status: 'paid',
    purchased_days_ago: 14,
  },
  {
    stripe_session_id: 'seed-sess-02',
    buyer_email:  'lukaslampe87@gmail.com',
    insyt_slug:   'seed-insyt-03-gallery-walkthrough',
    creator_email:'lukas.lampe@ll-endeavors.com',
    amount_paid:  2900,
    payment_status: 'paid',
    purchased_days_ago: 7,
  },
  {
    stripe_session_id: 'seed-sess-03',
    buyer_email:  'lukaslampe87@gmail.com',
    insyt_slug:   'seed-insyt-01-free-intro',
    creator_email:'lukas.lampe@ll-endeavors.com',
    amount_paid:  0,
    payment_status: 'paid',
    purchased_days_ago: 3,
  },
  {
    stripe_session_id: 'seed-sess-04',
    buyer_email:  'seed-consumer-multi@getinsyts.test',
    insyt_slug:   'seed-insyt-04-video-deep-dive',
    creator_email:'lukas.lampe@ll-endeavors.com',
    amount_paid:  4900,
    payment_status: 'paid',
    purchased_days_ago: 21,
  },
  {
    stripe_session_id: 'seed-sess-05',
    buyer_email:  'seed-consumer-multi@getinsyts.test',
    insyt_slug:   'seed-insyt-10-long-title',
    creator_email:'seed-creator-full@getinsyts.test',
    amount_paid:  2900,
    payment_status: 'paid',
    purchased_days_ago: 10,
  },
  {
    stripe_session_id: 'seed-sess-06',
    buyer_email:  'seed-consumer-multi@getinsyts.test',
    insyt_slug:   'seed-insyt-11-tags-overload',
    creator_email:'seed-creator-full@getinsyts.test',
    amount_paid:  1900,
    payment_status: 'paid',
    purchased_days_ago: 5,
  },
  {
    stripe_session_id: 'seed-sess-07',
    buyer_email:  'seed-consumer-refunded@getinsyts.test',
    insyt_slug:   'seed-insyt-02-paid-pdf-tutorial',
    creator_email:'lukas.lampe@ll-endeavors.com',
    amount_paid:  1900,
    payment_status: 'refunded',
    purchased_days_ago: 30,
  },
]
