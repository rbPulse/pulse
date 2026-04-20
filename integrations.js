// ═══════════════════════════════════════════════════════════════════════════
// integrations.js — shared integrations catalog & helper
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
//   Defines the catalog of external providers Pulse can integrate with
//   (Stripe, Daily.co, Resend, Twilio, labs, shipping, ID verification),
//   the shape of the credentials each one needs, and the non-secret
//   config each one exposes. Operator portal renders the Integrations
//   tab from this catalog; downstream portals call `Integrations.status
//   (provider)` to check "is payment wired up?" before showing the
//   corresponding UI.
//
//   Zero-dependency, zero-framework — matches tenant.js, terminology.js,
//   workflow.js, messaging.js.
//
// HOW PORTALS USE IT
//   1. Load this file in <head> AFTER tenant.js:
//        <script src="tenant.js"></script>
//        <script src="integrations.js"></script>
//   2. After TenantBootstrap resolves, portals call:
//        Integrations.init(db, window.Tenant.id);
//      This loads per-tenant status + config (NOT credentials — those
//      stay platform-only) from the tenant_integrations_public view.
//   3. Anywhere downstream:
//        if (Integrations.isConnected('stripe')) { ... }
//        var config = Integrations.config('dailyco');
//
// WHAT'S IN THE CATALOG
//   Each PROVIDER entry declares:
//     - key          stable slug used as the DB provider column
//     - label        display name
//     - category     for grouping in the operator UI
//     - description  what this integration does for the tenant
//     - credentials  array of fields the operator enters. Each field
//                    has { name, label, type: 'text'|'password'|'url',
//                    required, placeholder, description }. `password`
//                    rendering hides the value in the UI.
//     - config       array of non-secret fields (mode, webhook URL,
//                    feature toggles). Same shape as credentials but
//                    readable by tenant staff.
//     - test_action  name of the test action the platform-side test
//                    button fires. Value is a string key the server
//                    (Edge Function, future) recognises; this file
//                    doesn't do HTTP.
//
// SECURITY POSTURE
//   This file never receives credential VALUES — the operator portal
//   writes credentials directly to tenant_integrations, gated by the
//   platform-write RLS policy. Downstream portals calling
//   Integrations.config() see only the non-secret projection.
//   Credentials round-trip from the form to the DB; they do not pass
//   through any long-lived cache here.
//
// ═══════════════════════════════════════════════════════════════════════════

(function () {
  'use strict';

  var PROVIDERS = [
    // ── Payments ────────────────────────────────────────────────────────
    {
      key:         'stripe',
      label:       'Stripe',
      category:    'payments',
      description: 'Card processing, subscription billing, the Customer Portal embed. Required for any tenant that takes payment.',
      credentials: [
        { name: 'secret_key',      label: 'Secret key',       type: 'password', required: true,  placeholder: 'sk_live_…', description: 'Server-side key. Starts with sk_live_ or sk_test_.' },
        { name: 'publishable_key', label: 'Publishable key',  type: 'text',     required: true,  placeholder: 'pk_live_…', description: 'Client-side key. Starts with pk_live_ or pk_test_.' },
        { name: 'webhook_secret',  label: 'Webhook signing secret', type: 'password', required: false, placeholder: 'whsec_…', description: 'Signs incoming Stripe webhook events so the tenant router can verify authenticity.' }
      ],
      config: [
        { name: 'mode',        label: 'Mode',    type: 'enum', default: 'test',
          options: [
            { value: 'test', label: 'Test' },
            { value: 'live', label: 'Live' }
          ],
          description: 'Test until the tenant goes live. Live routes real payments.' },
        { name: 'currency',    label: 'Default currency', type: 'text', default: 'usd', description: 'ISO 4217 currency code. Case-insensitive; Stripe is case-sensitive in some contexts, so we lowercase.' }
      ],
      test_action: 'stripe.ping_account'
    },

    // ── Video consults ───────────────────────────────────────────────────
    {
      key:         'dailyco',
      label:       'Daily.co',
      category:    'video',
      description: 'Live-video consults between clinicians and members. Room creation, recording, join tokens.',
      credentials: [
        { name: 'api_key', label: 'API key', type: 'password', required: true, placeholder: 'daily_…', description: 'Server-side key used to create rooms and generate join tokens.' }
      ],
      config: [
        { name: 'domain', label: 'Sub-domain', type: 'text', required: true, placeholder: 'acme.daily.co', description: 'Daily-assigned sub-domain for the tenant.' },
        { name: 'record_consults', label: 'Record consults by default', type: 'bool', default: false, description: 'Consent + retention policies are the tenant\u2019s concern; this just sets the default.' }
      ],
      test_action: 'dailyco.get_domain'
    },

    // ── Messaging: email ──────────────────────────────────────────────────
    {
      key:         'resend',
      label:       'Resend',
      category:    'messaging',
      description: 'Transactional email delivery. Used by Phase 6 templates once wiring lands.',
      credentials: [
        { name: 'api_key', label: 'API key', type: 'password', required: true, placeholder: 're_…', description: 'Server-side key with send permission.' }
      ],
      config: [
        { name: 'from_verified', label: 'Verified sender configured', type: 'bool', default: false, description: 'Check only after the sender domain is verified in Resend. Nothing enforces this today; it\u2019s a reminder surface for operators.' }
      ],
      test_action: 'resend.list_domains'
    },

    // ── Messaging: SMS ────────────────────────────────────────────────────
    {
      key:         'twilio',
      label:       'Twilio',
      category:    'messaging',
      description: 'SMS + voice. Use for appointment reminders, refill pings, and (future) voice callbacks.',
      credentials: [
        { name: 'account_sid', label: 'Account SID', type: 'text',     required: true, placeholder: 'AC…', description: 'Twilio account identifier.' },
        { name: 'auth_token',  label: 'Auth token',  type: 'password', required: true, placeholder: '\u2022\u2022\u2022\u2022', description: 'Server-side auth token.' }
      ],
      config: [
        { name: 'from_number', label: 'From number', type: 'text', required: true, placeholder: '+15550100', description: 'E.164 format. Must be a Twilio-provisioned number on the account.' }
      ],
      test_action: 'twilio.fetch_account'
    },

    // ── Clinical: labs ────────────────────────────────────────────────────
    {
      key:         'labcorp',
      label:       'Labcorp',
      category:    'clinical',
      description: 'Electronic lab ordering and result delivery. Required for tenants that order labs; skip otherwise.',
      credentials: [
        { name: 'api_key',     label: 'API key',    type: 'password', required: true, placeholder: '…', description: 'Vendor-issued API key.' },
        { name: 'account_id',  label: 'Account ID', type: 'text',     required: true, placeholder: '…', description: 'Vendor account identifier.' }
      ],
      config: [
        { name: 'mode', label: 'Mode', type: 'enum', default: 'test',
          options: [
            { value: 'test', label: 'Test / sandbox' },
            { value: 'live', label: 'Live' }
          ] }
      ],
      test_action: 'labcorp.ping'
    },

    // ── Clinical: ID verification ─────────────────────────────────────────
    {
      key:         'stripe_identity',
      label:       'Stripe Identity',
      category:    'clinical',
      description: 'Document + selfie ID verification. Stripe\u2019s separate product from card processing, but uses the same Stripe account.',
      credentials: [
        { name: 'secret_key',     label: 'Secret key',          type: 'password', required: true,  placeholder: 'sk_…', description: 'Can reuse Stripe payments secret key if the same account handles both.' },
        { name: 'webhook_secret', label: 'Webhook signing secret', type: 'password', required: false, placeholder: 'whsec_…' }
      ],
      config: [
        { name: 'required_for_enrollment', label: 'Require ID at enrolment', type: 'bool', default: false,
          description: 'If on, members can\u2019t complete enrolment without passing ID verification. Off treats it as an optional step triggered by workflow rules.' }
      ],
      test_action: 'stripe_identity.ping_account'
    },

    // ── Fulfilment: shipping ──────────────────────────────────────────────
    {
      key:         'shippo',
      label:       'Shippo',
      category:    'fulfilment',
      description: 'Multi-carrier shipping label generation and tracking. Required for tenants that ship physical product.',
      credentials: [
        { name: 'api_token', label: 'API token', type: 'password', required: true, placeholder: 'shippo_live_…' }
      ],
      config: [
        { name: 'default_service',  label: 'Default service', type: 'text', default: 'usps_priority', description: 'Shippo service code. Tenant can override per-order.' },
        { name: 'ship_from_address', label: 'Ship-from address ID', type: 'text', required: true, placeholder: 'adr_…', description: 'Shippo address ID of the tenant\u2019s origin location.' }
      ],
      test_action: 'shippo.fetch_carrier_accounts'
    }
  ];

  var CATEGORIES = [
    { key: 'payments',   label: 'Payments'            },
    { key: 'video',      label: 'Video'               },
    { key: 'messaging',  label: 'Messaging'           },
    { key: 'clinical',   label: 'Clinical'            },
    { key: 'fulfilment', label: 'Fulfilment'          }
  ];

  // Lookup map so Integrations.forKey('stripe') is O(1).
  var BY_KEY = {};
  PROVIDERS.forEach(function(p) { BY_KEY[p.key] = p; });

  // Runtime cache of tenant integration rows (non-secret projection
  // only). Keyed by provider.
  var _rows = {};

  // Load the tenant's integrations into the cache. Non-secret
  // projection only — credentials never enter this helper.
  function init(db, tenantId) {
    _rows = {};
    if (!db || !db.from || !tenantId) return Promise.resolve({});
    // Tenant staff call the RPC (SECURITY DEFINER, no-secret view);
    // platform users can hit the base table directly. Both land the
    // same projection here since we only select non-secret columns.
    return db.rpc('tenant_integrations_for_my_tenants')
      .then(function(r) {
        if (r.error) {
          // Platform user? Retry via base table filtered to this tenant.
          return db.from('tenant_integrations')
            .select('id, tenant_id, provider, status, config, last_connected_at, last_error, last_error_at')
            .eq('tenant_id', tenantId);
        }
        return r;
      })
      .then(function(r) {
        if (r.error) {
          console.warn('[integrations] load failed; treating all as disconnected', r.error);
          return _rows;
        }
        (r.data || []).forEach(function(row) {
          if (row.tenant_id && row.tenant_id !== tenantId) return; // safety
          _rows[row.provider] = row;
        });
        return _rows;
      })
      .catch(function(err) {
        console.warn('[integrations] load errored; treating all as disconnected', err);
        return _rows;
      });
  }

  function forKey(key) { return BY_KEY[key] || null; }

  function status(key)      {
    var row = _rows[key];
    return row ? row.status : 'disconnected';
  }

  function isConnected(key) { return status(key) === 'connected'; }

  function config(key) {
    var row = _rows[key];
    return (row && row.config) || {};
  }

  function reset() { _rows = {}; }

  window.Integrations = {
    init:        init,
    forKey:      forKey,
    status:      status,
    isConnected: isConnected,
    config:      config,
    reset:       reset,
    PROVIDERS:   PROVIDERS,
    CATEGORIES:  CATEGORIES
  };
})();
