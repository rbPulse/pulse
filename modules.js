// ═══════════════════════════════════════════════════════════════════════════
// modules.js — shared module catalog & feature-flag helper
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
//   Pulse sells features as modules. Each tenant's plan includes a
//   set of module keys (`live_video`, `e_prescribing`, `labs`, etc.);
//   module_entitlements rows record what's actually active. This file
//   holds the CATALOG of every module the system knows about and the
//   runtime accessor portals call to gate UI:
//
//     if (Modules.isEnabled('live_video')) { renderVideoButton(); }
//
//   Zero-dependency, zero-framework. Same shape as every other helper
//   in the project.
//
// HOW PORTALS USE IT
//   1. Load in <head> AFTER tenant.js:
//        <script src="tenant.js"></script>
//        <script src="modules.js"></script>
//   2. After authenticating, init:
//        Modules.init(db, window.Tenant.id);
//      This fetches module_entitlements rows and caches them.
//   3. Anywhere downstream:
//        if (Modules.isEnabled('live_video')) { ... }
//        var all = Modules.enabled();           // array of keys
//        var cat = Modules.forKey('live_video'); // catalog entry
//
// STORAGE
//   module_entitlements rows are the source of truth. Cached in memory
//   after init. Reset + re-init on tenant switch (operator view-as).
//
// CONVENTION
//   Module keys are stable slugs — renaming one means migrating every
//   downstream read-site AND every existing entitlement row. Add new
//   ones freely; rename with caution.
//
// ═══════════════════════════════════════════════════════════════════════════

(function () {
  'use strict';

  // ── Catalog ───────────────────────────────────────────────────────────
  // Every feature module Pulse can entitle a tenant with. Grouped by
  // `category` for the operator-portal UI. `description` is written
  // for a non-technical buyer.
  var CATALOG = [
    // ── Core (included everywhere) ────────────────────────────────────
    { key: 'portal_access',       label: 'Portal access',           category: 'core',      description: 'Member + clinician web portals. Required baseline for every plan.' },
    { key: 'member_intake',       label: 'Member intake',           category: 'core',      description: 'Onboarding questionnaire that new members complete before prescription.' },
    { key: 'async_messaging',     label: 'Async messaging',         category: 'core',      description: 'In-portal messaging between members and clinicians.' },

    // ── Clinical ──────────────────────────────────────────────────────
    { key: 'live_video',          label: 'Live video consults',     category: 'clinical',  description: 'Scheduled video appointments powered by Daily.co. Requires the Daily integration in Phase 7.' },
    { key: 'e_prescribing',       label: 'E-prescribing',           category: 'clinical',  description: 'Electronic prescription transmission to pharmacies.' },
    { key: 'labs',                label: 'Lab ordering + results',  category: 'clinical',  description: 'Order panels, receive results, surface on the member chart.' },
    { key: 'id_verification',     label: 'ID verification',         category: 'clinical',  description: 'Document + selfie verification via Stripe Identity at enrolment.' },

    // ── Commercial ────────────────────────────────────────────────────
    { key: 'subscription_billing', label: 'Subscription billing',    category: 'commercial', description: 'Recurring charges for members on a plan cadence.' },
    { key: 'promo_codes',          label: 'Promo codes',             category: 'commercial', description: 'Member-facing discount codes.' },
    { key: 'referral_program',     label: 'Referral program',        category: 'commercial', description: 'Referral links + credits between members.' },

    // ── Analytics + ops ───────────────────────────────────────────────
    { key: 'advanced_analytics',  label: 'Advanced analytics',      category: 'analytics', description: 'Funnel dashboards, SLA reports, clinician load, payment failures.' },
    { key: 'multi_location',      label: 'Multi-location',          category: 'analytics', description: 'More than one physical clinic location per tenant.' },

    // ── Enterprise ────────────────────────────────────────────────────
    { key: 'custom_sso',          label: 'Custom SSO',              category: 'enterprise', description: 'SAML / OIDC SSO for tenant staff (Okta, Azure AD).' },
    { key: 'white_label',         label: 'White-label branding',    category: 'enterprise', description: 'Remove Pulse attribution from downstream portals.' },
    { key: 'api_access',          label: 'API access',              category: 'enterprise', description: 'Programmatic access to tenant data via REST API.' },
    { key: 'dedicated_infra',     label: 'Dedicated infrastructure', category: 'enterprise', description: 'Isolated DB instance + compute. For tenants with contractual isolation requirements.' }
  ];

  var CATEGORIES = [
    { key: 'core',       label: 'Core'       },
    { key: 'clinical',   label: 'Clinical'   },
    { key: 'commercial', label: 'Commercial' },
    { key: 'analytics',  label: 'Analytics + ops' },
    { key: 'enterprise', label: 'Enterprise' }
  ];

  var BY_KEY = {};
  CATALOG.forEach(function(m) { BY_KEY[m.key] = m; });

  // Cache: module_key → entitlement row. Populated by init().
  var _entitlements = {};

  function init(db, tenantId) {
    _entitlements = {};
    if (!db || !db.from || !tenantId) return Promise.resolve({});
    return db.from('module_entitlements')
      .select('module_key, enabled, source, expires_at')
      .eq('tenant_id', tenantId)
      .then(function(r) {
        if (r.error) {
          console.warn('[modules] load failed; treating all as disabled', r.error);
          return _entitlements;
        }
        (r.data || []).forEach(function(row) { _entitlements[row.module_key] = row; });
        return _entitlements;
      })
      .catch(function(err) {
        console.warn('[modules] load errored; treating all as disabled', err);
        return _entitlements;
      });
  }

  function isEnabled(key) {
    var ent = _entitlements[key];
    if (!ent) return false;
    if (!ent.enabled) return false;
    if (ent.expires_at && new Date(ent.expires_at).getTime() < Date.now()) return false;
    return true;
  }

  function enabled() {
    return Object.keys(_entitlements).filter(isEnabled);
  }

  function entitlement(key) { return _entitlements[key] || null; }

  function forKey(key) { return BY_KEY[key] || null; }

  function reset() { _entitlements = {}; }

  window.Modules = {
    init:         init,
    isEnabled:    isEnabled,
    enabled:      enabled,
    entitlement:  entitlement,
    forKey:       forKey,
    reset:        reset,
    CATALOG:      CATALOG,
    CATEGORIES:   CATEGORIES
  };
})();
