// ═══════════════════════════════════════════════════════════════════════════
// tenant.js — shared tenant bootstrap for every Pulse portal
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
//   Every downstream portal (admin, member, clinician) runs under a
//   specific tenant. This module resolves which tenant the current page
//   belongs to (from the URL) and loads that tenant's config so the
//   page can render itself with the right brand / terminology / catalog
//   / feature flags.
//
//   It's deliberately zero-dependency and zero-framework. Every portal
//   is a single HTML file with inline JS today; keep the bootstrap in
//   the same style so it composes without a build step.
//
// HOW PORTALS USE IT
//   1. Load this file early in <head>:
//        <script src="tenant.js"></script>
//   2. After you've established a Supabase session and confirmed the
//      user is authenticated, call:
//        TenantBootstrap.init(db).then(function(tenant) {
//          // window.Tenant is now populated.
//          // Continue page-specific init here.
//        });
//   3. Read tenant state from window.Tenant anywhere after init resolves.
//
// URL CONTRACT
//   Tenant portals live at  /t/{slug}/{portal}.html  (e.g.
//   /t/acme/admin.html, /t/pulse/portal.html). This module extracts
//   the slug from the path. If no /t/ prefix is present, it falls back
//   to 'pulse' so the existing Pulse URLs (/admin.html, /portal.html)
//   keep working during the transition phase.
//
//   The operator portal (/platform.html) and marketing site
//   (/pulse-client.html) are NOT tenant-scoped and should not load
//   this file.
//
// MULTI-TENANT USERS
//   A user with memberships at multiple tenants sees tenant data from
//   whatever tenant matches the URL they're on. Cross-tenant data
//   leakage is prevented by RLS (each tenant-scoped table filters by
//   current_tenant_ids()). When a user has memberships at multiple
//   tenants AND there's a need to narrow further (e.g. don't show
//   tenant B's rows when on tenant A's portal), the page should add
//   an explicit .eq('tenant_id', Tenant.id) filter to the query.
//   This is a non-issue at Phase 0 — every Pulse user has exactly one
//   membership today.
//
// ═══════════════════════════════════════════════════════════════════════════

(function () {
  'use strict';

  // Pulse's seed tenant UUID — matches the value inserted by migration 010.
  // Fallback only; real portals should always call init() and read from
  // window.Tenant.id instead of referencing this constant directly.
  var PULSE_TENANT_ID = '00000000-0000-0000-0000-000000000001';

  // Parse /t/{slug}/... from the current URL. Slug format matches the
  // server-side check constraint in migration 010: lowercase alphanumerics
  // and hyphens, starting with alphanumeric. Trailing slash or end-of-path
  // both accepted so /t/pulse and /t/pulse/ both resolve.
  function resolveSlug() {
    var m = window.location.pathname.match(/^\/t\/([a-z0-9][a-z0-9-]*)(\/|$)/);
    return m ? m[1] : 'pulse';
  }

  // Single in-memory cache. Repeated init() calls on the same page reuse
  // the first load instead of re-querying the tenants table. This matters
  // when portals call init() from multiple entry points during startup.
  var _cached = null;

  // Load the active tenant's row and publish it on window.Tenant.
  // Must be called AFTER the Supabase session is established, because
  // the tenants table is RLS-gated and requires auth.uid() to resolve.
  //
  // Returns a Promise that resolves with the tenant object, or rejects
  // if the tenant can't be loaded (wrong slug / no access / DB error).
  function init(db) {
    if (_cached) {
      window.Tenant = _cached;
      return Promise.resolve(_cached);
    }
    if (!db || !db.from) {
      return Promise.reject(new Error('TenantBootstrap.init: supabase client required'));
    }
    var slug = resolveSlug();
    return db.from('tenants')
      .select([
        'id', 'slug', 'name', 'legal_name', 'lifecycle_state',
        'brand', 'terminology', 'workflow', 'catalog_config',
        'comms_config', 'integrations', 'compliance', 'features'
      ].join(','))
      .eq('slug', slug)
      .single()
      .then(function (r) {
        if (r.error || !r.data) {
          // eslint-disable-next-line no-console
          console.error('[tenant.js] failed to load tenant', slug, r.error);
          throw new Error('tenant_load_failed:' + slug);
        }
        _cached = r.data;
        window.Tenant = _cached;
        return _cached;
      });
  }

  // Convenience accessors. These return sensible defaults before init()
  // has completed so pages calling them during startup don't crash, but
  // real code should await init() and read from window.Tenant directly.
  function id() { return window.Tenant ? window.Tenant.id : PULSE_TENANT_ID; }
  function slug() { return window.Tenant ? window.Tenant.slug : resolveSlug(); }

  // Test hook: clear the cache so init() re-fetches. Intended for the
  // operator portal's "view as tenant" switcher, which needs to swap
  // tenant context without a full page reload.
  function reset() { _cached = null; window.Tenant = null; }

  // Public surface. Explicit sentinel on window.Tenant until init runs
  // so downstream code can guard with `if (!window.Tenant) return;`.
  window.Tenant = null;
  window.TenantBootstrap = {
    init: init,
    id: id,
    slug: slug,
    resolveSlug: resolveSlug,
    reset: reset,
    PULSE_TENANT_ID: PULSE_TENANT_ID
  };
})();
