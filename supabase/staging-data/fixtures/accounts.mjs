// Account fixtures consumed by seed.mjs.
// Anchor UUIDs are pinned — the seed looks them up by email at runtime but
// these are recorded here for reference / Playwright tests.

export const ANCHORS = [
  {
    email: 'lukas.lampe@ll-endeavors.com',
    persona: 'anchor-creator',
    authUserId: '75d65f85-b057-4874-9ad4-087c4afb3ca1',
    profile: {
      display_name: 'Lukas Lampe',
      username: 'lukaslampe',
      headline: 'Founder · GetInsyt',
      bio: 'Building GetInsyt — short, sharp insights from real practitioners. Test data lives in this profile.',
      location: 'Berlin',
      website: 'https://getinsyts.com',
      is_creator: true,
      // creator_terms_accepted_at filled in at runtime (NOW())
      // Mirrors what the anchor already set via the Edit Profile modal — the
      // seed must not clobber hand-maintained values with different ones.
      sports: ['Basketball'],
      content_types: ['Player Report'],
      avatar: 'avatar.svg',
      cover: 'cover.svg',
    },
    socials: [
      { platform: 'youtube',   handle: '@getinsyts' },
      { platform: 'instagram', handle: 'getinsyts' },
      { platform: 'facebook',  handle: 'getinsyts' },
      { platform: 'tiktok',    handle: '@getinsyts' },
    ],
  },
  {
    email: 'lukaslampe87@gmail.com',
    persona: 'anchor-consumer',
    authUserId: 'a313e6e3-e077-44ff-93ec-0ddaaa60897a',
    profile: {
      display_name: 'Lukas (Consumer)',
      username: null,
      headline: null,
      bio: null,
      location: null,
      website: null,
      is_creator: false,
      avatar: null,
      cover: null,
    },
    socials: [],
  },
]

export const TEST_USERS = [
  // ---- Creators ----
  {
    email: 'seed-creator-full@getinsyts.test',
    persona: 'fully-populated',
    profile: {
      display_name: 'Fully Populated Creator',
      username: 'fullycreator',
      headline: 'Coach · Mentor · Loud opinions',
      bio: 'Every field on this profile is set so the design language can be QAed end-to-end. Avatar, cover, headline, bio, socials, location, website — the works.',
      location: 'Munich',
      website: 'https://example.com/fully-populated',
      is_creator: true,
      sports: ['Soccer', 'Basketball'],
      content_types: ['Match Analysis', 'Tactical Breakdown', 'Training Session'],
      avatar: 'avatar.svg',
      cover: 'cover.svg',
    },
    socials: [
      { platform: 'youtube',   handle: '@fullcreator' },
      { platform: 'instagram', handle: 'fullcreator' },
      { platform: 'facebook',  handle: 'fullcreator' },
      { platform: 'tiktok',    handle: '@fullcreator' },
    ],
  },
  {
    email: 'seed-creator-minimal@getinsyts.test',
    persona: 'bare-minimum',
    profile: {
      display_name: 'Bare Minimum',
      username: null,
      headline: null,
      bio: null,
      location: null,
      website: null,
      is_creator: true,
      avatar: null,
      cover: null,
    },
    socials: [],
  },
  {
    email: 'seed-creator-terms-pending@getinsyts.test',
    persona: 'terms-pending',
    profile: {
      display_name: 'Terms Pending',
      username: 'termspending',
      headline: 'Has not signed the Creator Terms yet',
      bio: 'This profile exists so the cp-terms-banner has somewhere to render.',
      location: null,
      website: null,
      is_creator: true,
      // override: this creator does NOT accept the terms
      skip_terms: true,
      sports: ['Tennis'],
      content_types: ['Player Report'],
      avatar: null,
      cover: null,
    },
    socials: [
      { platform: 'youtube',   handle: '@termspending' },
      { platform: 'instagram', handle: 'termspending' },
    ],
  },
  {
    email: 'seed-creator-long-strings@getinsyts.test',
    persona: 'long-strings',
    profile: {
      display_name: 'Edge Case ä ö ü ø 中 🎯 ab',
      username: 'longstrings',
      headline: 'Headline with 80 chars — hits the upper bound exactly so we can see how it lays out',
      bio: 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. ' +
           'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. '.repeat(12) +
           'End ä ö ü ø 中 🎯.',
      location: 'København / 東京 / Reykjavík',
      website: 'https://example.com/very-long-path-that-goes-on-and-on-and-on-' +
               'so-that-the-website-pill-overflows-the-edge-of-the-card-' +
               'and-tests-the-text-truncation-rules',
      is_creator: true,
      // Deliberately long tag lists — this persona exists to QA overflow.
      sports: [
        'Soccer', 'Basketball', 'American Football', 'Baseball', 'Ice Hockey',
        'Tennis', 'Combat Sports', 'Rugby', 'Cricket', 'Volleyball', 'Handball', 'Esports',
      ],
      content_types: [
        'Match Analysis', 'Player Report', 'Tactical Breakdown', 'Drill Library',
        'Scouting Report', 'Opponent Analysis', 'Set Piece Analysis', 'Season Review',
      ],
      avatar: 'avatar.svg',
      cover: null,
    },
    socials: [
      { platform: 'tiktok', handle: 'https://www.tiktok.com/@really-long-tiktok-handle-name-for-overflow-testing-purposes-only' },
    ],
  },
  {
    email: 'seed-creator-stripe-not-onboarded@getinsyts.test',
    persona: 'stripe-not-onboarded',
    profile: {
      display_name: 'Stripe Not Onboarded',
      username: 'nostripe',
      headline: 'Cannot publish paid insyts until Stripe Connect is done',
      bio: 'This creator has signed the terms but never finished Stripe onboarding.',
      location: null,
      website: null,
      is_creator: true,
      stripe_connect_onboarded: false,
      sports: ['Ice Hockey', 'Swimming'],
      content_types: ['Training Session', 'Drill Library'],
      avatar: 'avatar.svg',
      cover: null,
    },
    socials: [],
  },
  {
    // GET-75: a dedicated creator that OFFERS a subscription, so the subscribe
    // CTA renders on their paid insyts in e2e — without depending on the real
    // anchor account. The price id below is a PLACEHOLDER (option B): the CTA
    // renders (creator_subscription_offer returns a row because the price id is
    // non-null), but clicking Subscribe will NOT reach a real Stripe checkout.
    // Swap in a real sk_test subscription Price id for clickable coverage.
    email: 'seed-creator-subscription@getinsyts.test',
    persona: 'subscription-creator',
    profile: {
      display_name: 'Subscription Creator',
      username: 'subcreator',
      headline: 'Offers a monthly subscription',
      bio: 'Has a subscription offer set up so the subscribe CTA renders on their paid insyts (GET-75).',
      location: null,
      website: null,
      is_creator: true,
      sports: ['Basketball'],
      content_types: ['Player Report'],
      // Subscription offer (the four fields creator_subscription_offer reads):
      subscription_price_usd: 500, // cents → €5.00/mo
      subscription_currency: 'eur',
      subscription_trial_days: 0,
      stripe_subscription_price_id: 'price_seed_placeholder_GET75', // PLACEHOLDER (not a real Stripe price)
      avatar: 'avatar.svg',
      cover: null,
    },
    socials: [],
  },

  // ---- Consumers ----
  {
    email: 'seed-consumer-empty@getinsyts.test',
    persona: 'consumer-empty',
    profile: {
      display_name: 'Consumer Empty',
      is_creator: false,
    },
    socials: [],
  },
  {
    email: 'seed-consumer-multi@getinsyts.test',
    persona: 'consumer-multi',
    profile: {
      display_name: 'Consumer Multi',
      is_creator: false,
    },
    socials: [],
  },
  {
    email: 'seed-consumer-refunded@getinsyts.test',
    persona: 'consumer-refunded',
    profile: {
      display_name: 'Consumer Refunded',
      is_creator: false,
    },
    socials: [],
  },
  {
    email: 'seed-consumer-checkout@getinsyts.test',
    persona: 'consumer-checkout',
    profile: {
      display_name: 'Consumer Checkout',
      is_creator: false,
    },
    socials: [],
  },

  // ---- UI-driven promotable ----
  {
    email: 'seed-non-creator-promotable@getinsyts.test',
    persona: 'non-creator-promotable',
    profile: {
      display_name: 'Promotable Non-Creator',
      is_creator: false,
    },
    socials: [],
  },
]

// Convenience accessor used by seed.mjs.
export function allUsers() {
  return [...ANCHORS, ...TEST_USERS]
}

export function findByEmail(email) {
  return allUsers().find(u => u.email === email)
}

export function findByPersona(persona) {
  return allUsers().find(u => u.persona === persona)
}
