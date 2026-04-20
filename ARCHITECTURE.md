# Pulse Platform — Architecture

Living doc for the multi-tenant platform built on top of Pulse. Every
downstream decision should be consistent with what's below. If reality
diverges from this doc, update the doc, not reality.

## Purpose

Pulse is becoming a multi-tenant clinical operations platform. A single
"platform portal" (`platform.html`) lets the Pulse internal team
provision and manage independent clinic tenants. Each tenant runs its
own configured instance of the downstream portals:

- `admin.html` — clinic admin portal
- `portal.html` — member/patient portal
- `clinician.html` (or equivalent) — clinician portal

Pulse itself is the pilot tenant. New clients follow the same pattern.

## Core decisions

### 1. Tenant isolation: row-level with RLS

All tenant-scoped tables gain a `tenant_id uuid not null references
tenants(id)` column. A Postgres RLS policy restricts access to rows
whose `tenant_id` matches one of the requesting user's memberships.

Why not schema-per-tenant or database-per-tenant:
- RLS scales fine to ~50 tenants on a single Supabase instance.
- No operational overhead of managing N schemas/DBs.
- Cross-tenant queries (operator portal, analytics) are a single
  `SELECT` away, not a fan-out.
- Migration path to schema-per-tenant remains open if regulatory or
  contractual pressure demands it.

### 2. Tenant resolution: path-based

URL pattern for client portals: `/t/{slug}/{portal}.html` (e.g.
`/t/acme/admin.html`). A small bootstrap (`tenant.js`) on every
downstream portal:

1. Reads the slug from `window.location.pathname`.
2. Looks up the tenant record (id + config snapshot).
3. Exposes a global `window.Tenant` object with config for the rest
   of the page to consume.
4. Calls `supabase.rpc('set_current_tenant', { p_tenant_id })` so RLS
   sees the active tenant for the session.

Pulse's existing URLs (`/admin.html`, `/portal.html`) remain valid:
when no `/t/{slug}/` prefix is present, `tenant.js` resolves to the
Pulse tenant by default. This avoids breaking existing bookmarks and
auth callbacks. A future cleanup can normalise Pulse to `/t/pulse/*`.

The platform portal itself (`platform.html`) is NOT tenant-scoped —
it's the cross-tenant operator surface. It stays at root and requires
a `platform_*` role on the user.

Subdomain routing (`acme.pulse.clinic`) is explicitly deferred. DNS
and SSL overhead with no functional gain over path-based. Revisit if
a client contractually demands a vanity domain.

### 3. Config storage: JSONB on tenant row

Each tenant gets one row in `tenants` with config organised into
typed JSONB columns:

| Column              | Layer                    | Phase introduced |
|---------------------|--------------------------|------------------|
| `brand`             | Brand identity           | Phase 2          |
| `terminology`       | Copy/labels              | Phase 3          |
| `workflow`          | Business logic           | Phase 5          |
| `catalog_config`    | Product/pricing rules    | Phase 4          |
| `comms_config`      | Communication defaults   | Phase 6          |
| `integrations`      | External system config   | Phase 7          |
| `compliance`        | Region/license rules     | Phase 8          |
| `features`          | Module entitlement flags | Phase 9          |

JSONB was chosen over normalized tables because (a) the schema will
evolve rapidly during the first 3 tenants and (b) most reads are
full-config-on-page-load, not per-key queries. Any JSONB column that
grows past ~30 keys or becomes a query hotspot gets promoted to a
normalized child table at the phase boundary.

High-cardinality per-tenant data that isn't config (catalog items,
templates, clinician rosters) lives in separate tables, all scoped by
`tenant_id`.

### 4. Lifecycle states

Every tenant has a `lifecycle_state`:

- **sandbox** — tenant created; config in progress; no real users.
  Default state on creation.
- **live** — accepting real traffic; billable.
- **suspended** — temporarily read-only (billing issue, compliance
  action). Users see a maintenance banner.
- **archived** — soft-deleted. Retained for audit; excluded from
  operator dashboards by default. Reactivation possible.

State transitions are audit-logged and role-gated (only
`platform_admin` and `platform_super_admin` can move to `live` or
`suspended`).

### 5. Auth + membership model

`profiles` remains a global per-user record (identity, name, avatar,
auth metadata). It is NOT tenant-scoped — a single human with one
email belongs to one `profiles` row regardless of how many tenants
they touch.

A new `tenant_memberships(user_id, tenant_id, role, capabilities)`
table maps users to the tenants they can access, with a role per
tenant. A user can have:

- Zero memberships — not allowed into any tenant portal.
- One membership — standard case (one clinic's admin, or a member of
  one clinic).
- Multiple memberships — a clinician working across two clinics, or a
  Pulse internal ops user with memberships across many tenants.

**Role hierarchy (enum `tenant_role`):**

- `tenant_owner` — tenant-level super-admin; can manage billing and
  all other roles.
- `tenant_admin` — standard clinic admin; manages day-to-day ops.
- `tenant_clinician` — licensed provider; reviews and prescribes.
- `tenant_nurse` — clinical support; limited write access.
- `tenant_billing` — billing/finance read + invoice management.
- `tenant_analyst` — read-only analytics access.
- `tenant_member` — end-user (patient/client).

**Platform-level role (separate enum `platform_role`, on profile):**

- `platform_super_admin` — Pulse founders / CTO-level. All access.
- `platform_admin` — Pulse ops managers. Create tenants, manage
  integrations, move lifecycle states.
- `platform_ops` — day-to-day operator work. No billing/dangerous
  actions.
- `platform_support` — read + impersonation (view-as only), no write.
- `platform_billing` — billing access across tenants.
- `platform_readonly` — executive/auditor read-only.

A user's platform role is stored on `profiles.platform_role` (nullable
— most users are just tenant members and have none). Tenant roles
live on `tenant_memberships` only.

Existing `profiles.role` and `profiles.admin_role` columns are
superseded by this model. Phase 0's migration will backfill them into
the new structure without dropping the old columns (kept for one
release as a safety net, then removed in Phase 1 cleanup).

### 6. RLS policy pattern

The canonical policy template for a tenant-scoped table:

```sql
-- SELECT: any member of the tenant may read
CREATE POLICY "tenant_read" ON {table}
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
    )
  );

-- INSERT/UPDATE/DELETE: gated by role capability
CREATE POLICY "tenant_write" ON {table}
  FOR ALL TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN (...)
    )
  );
```

Platform-level users bypass tenant-scope RLS via a companion policy:

```sql
CREATE POLICY "platform_admin_read" ON {table}
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM profiles
      WHERE user_id = auth.uid()
        AND platform_role IS NOT NULL
    )
  );
```

Write access for platform users is narrower (only operations that
explicitly need cross-tenant write, e.g. lifecycle transitions).

## Tenant-scoping inventory

Seventeen existing tables. Scoping decisions:

| Table                    | Scope          | Notes                                          |
|--------------------------|----------------|------------------------------------------------|
| `tenants`                | n/a (new)      | The registry itself. One row per client.       |
| `tenant_memberships`     | n/a (new)      | Cross-tenant by definition.                    |
| `profiles`               | **global**     | User identity is cross-tenant.                 |
| `consultations`          | tenant         | Per-tenant patient intake data.                |
| `prescriptions`          | tenant         |                                                |
| `prescription_versions`  | tenant         | Scoped transitively via prescription.          |
| `patient_notes`          | tenant         |                                                |
| `patient_events`         | tenant         |                                                |
| `dose_logs`              | tenant         |                                                |
| `messages`               | tenant         |                                                |
| `appointments`           | tenant         |                                                |
| `notifications`          | tenant         |                                                |
| `availability`           | tenant         | Clinician availability per tenant.             |
| `support_requests`       | tenant         |                                                |
| `protocol_templates`     | tenant         | Per-tenant product catalog.                    |
| `protocol_categories`    | tenant         |                                                |
| `protocol_product_types` | tenant         |                                                |
| `platform_automations`   | tenant         | Despite the name, this is per-tenant config.   |
| `audit_logs`             | tenant         | Extended with `tenant_id` in Phase 10.         |

`profiles.max_concurrent_patients` and `profiles.working_hours` are
tenant-specific-per-clinician. Phase 0 leaves them on `profiles` for
now (Pulse is still the only tenant). They move to
`tenant_memberships.capabilities` in Phase 6 when the roles UI lands.

## Migration path for Pulse data

All existing data belongs to the Pulse tenant. Phase 0 migrations:

1. **010** — create `tenants` + `tenant_memberships` + enums.
   Insert Pulse as the seed tenant with a known UUID.
2. **011** — add `tenant_id` to every tenant-scoped table. Backfill
   every existing row to Pulse's UUID. Add NOT NULL constraint *after*
   backfill. Swap RLS policies from existing (likely permissive) to
   the tenant-scoped template.

A full database dump is taken before running 011. Rollback = restore
the dump. This is the only phase where a full restore is the
disaster-recovery plan; every later phase is forward-fixable.

## Platform portal specifics

`platform.html` at repo root. Lives outside the `/t/{slug}/` path
tree. Access gated by `profiles.platform_role IS NOT NULL`.

Design system: reuses admin.html's cream/beige theme, card layout,
`admin-table` + sortable headers, status pills, sidebar nav. Accent
colour is **slate** (`#3a4a5c`) — visually distinct from admin's
amber so internal users never confuse the two surfaces. A dedicated
"PLATFORM" role badge uses the slate accent.

A shared `tokens.css` (extracted from admin.html in Phase 1) will
hold the common design tokens. Operator portal + the three downstream
portals all `<link>` it.

## Open questions deferred to later phases

- **Terminology scope**: per-tenant vs per-tenant-per-region? (Phase 3
  decision.)
- **Workflow versioning**: do we need to snapshot workflow config at
  patient-intake time so later changes don't retroactively alter
  in-flight cases? (Phase 5.)
- **Webhook routing**: single endpoint with tenant dispatch vs per-
  tenant endpoints? (Phase 7.)
- **Data export format**: HL7/FHIR vs CSV vs both? (Phase 8.)
- **Billing owner**: does the tenant pay Pulse, or do end-users pay
  the tenant and Pulse takes a cut? (Phase 9 — commercial decision
  more than technical.)
- **Impersonation audit requirements**: what's the minimum legal
  record for "platform_support viewed tenant X data"? (Phase 13.)

## Non-goals for the foreseeable future

- Subdomain per tenant.
- Full action-taking impersonation (read-only view-as only).
- Custom permission DSL per tenant.
- Tenant-level schema customisation (custom fields on core entities).
- Multi-region database deployment.

These are explicitly not on the roadmap. If a client contractually
demands any of them, treat it as a new scoping conversation.
