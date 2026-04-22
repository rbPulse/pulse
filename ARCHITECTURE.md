# Unite — Architecture

Living doc for the multi-tenant clinical-operations platform. Every
downstream decision should be consistent with what's below. If reality
diverges from this doc, update the doc, not reality.

## Naming

- **Unite** is the platform — the global control plane. Authored
  by Pulse internal ops; manages every tenant on the system.
- **Pulse** is tenant #1. It runs on Unite the same way any future
  tenant would. Pulse is not special. No root URL privileges, no
  schema exceptions, no code paths that check for `slug === 'pulse'`
  beyond the transition fallback in `tenant.js`.

Do not refer to Unite as "Pulse" anywhere in product copy, URLs,
code comments, docs, or conversation. "Platform" is acceptable as a
role qualifier (`platform_role`, `platform_admin`) because it's a
neutral scoping term; the product name is Unite.

## Purpose

Unite lets a platform operator provision and manage independent
clinic tenants from a single control plane. Each tenant runs its own
configured instance of two downstream portals:

- `admin.html` — clinic admin portal. One per tenant. Authors
  tenant-owned configuration (brand, terminology, catalog, workflow,
  communications, compliance, tenant-side integrations config) and
  handles daily operations (users, patients, consults, messages,
  queues).
- `portal.html` — both the member/patient portal AND the clinician
  portal, rendered from the same file with the UI switched by a body
  class at boot: `body.member-mode` for end-users, `body.clinician-mode`
  for staff with a `clinician` or `admin` profile role. Same URL,
  same file, different render path. When a new downstream portal is
  needed ("a family-member view", "an ops dashboard"), the question
  is always "mode inside portal.html, or new file?" — inline inside
  portal.html unless the two experiences diverge enough that they'd
  share very little code.

The three portals above run PER TENANT. Unite itself runs ONCE
and is NOT tenant-scoped — it sees every tenant.

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

URL pattern for tenant portals: `/t/{slug}/{portal-path}` (e.g.
`/t/acme/admin/`, `/t/pulse/portal/`). A small bootstrap (`tenant.js`)
on every downstream portal:

1. Reads the slug from `window.location.pathname`.
2. Looks up the tenant record (id + config snapshot).
3. Exposes a global `window.Tenant` object with config for the rest
   of the page to consume.
4. When no `/t/{slug}/` prefix is present, falls back to the Pulse
   tenant — transition fallback so legacy bookmarks still resolve
   while R2c migration is in flight. Remove the fallback in R2f once
   the root no longer serves tenant content.

### 3. Target URL structure

```
/                     Universal root router.
                      Checks the Supabase session, dispatches by
                      profile: platform_role → /unite/,
                      tenant staff → /t/{slug}/admin/, patient →
                      /t/{slug}/portal/. Shows a minimal sign-in
                      form if no session. No tenant branding. No
                      marketing. ~10KB target.

/unite/           Unite — the platform control plane.
                      Gated by profiles.platform_role IS NOT NULL.
                      NOT tenant-scoped; sees every tenant.

/t/{slug}/admin/      Tenant admin portal — authors tenant-owned
                      configuration + handles daily operations for
                      this specific tenant. Same code, different
                      tenant context per slug.

/t/{slug}/portal/     Tenant member/clinician portal. Dual-mode
                      render via body.member-mode /
                      body.clinician-mode based on the
                      authenticated user's profile role.

/t/{slug}/            Optional tenant landing / marketing page.
                      Serves pre-auth traffic ("customers looking
                      at Pulse"). Contains the tenant's sign-up
                      CTA. Per-tenant; each tenant brings their
                      own content or hosts externally and points
                      DNS at their own domain.
```

Pulse has no URL privileges. Its admin portal lives at
`/t/pulse/admin/`. Its marketing lives at `/t/pulse/`. Other tenants
use the same shape with their own slug.

Subdomain routing (`acme.unite.app`) is explicitly deferred. DNS
and SSL overhead with no functional gain over path-based. Revisit if
a client contractually demands a vanity domain AND tenant count
crosses ~20 (the point at which path collisions between tenants
become a design concern).

### 4. Files at repo root (current, transitional)

Root should eventually hold only the universal router + shared
assets. Today it contains the following transitional files:

- `unite/index.html` — Unite. **Final location.**
- `platform.html` — redirect stub pointing at `/unite/`.
  Removed in R2f.
- `admin.html` — Pulse's admin portal at root. Moves to
  `/t/pulse/admin/` in R2c.
- `portal.html` — Pulse's member/clinician portal at root. Moves to
  `/t/pulse/portal/` in R2c.
- `consultation.html`, `checkout.html`, `quiz.html` — Pulse's
  member-journey flows. Move to `/t/pulse/...` in R2c.
- `index.html` — Pulse's marketing + sign-in. Splits in R2d:
  sign-in becomes the universal router at `/`; marketing moves to
  `/t/pulse/`.
- Shared assets (`tokens.css`, `tenant.js`, `terminology.js`,
  `workflow.js`, `messaging.js`, `integrations.js`, `compliance.js`,
  `modules.js`) — these stay at root; they're imported from every
  portal regardless of path depth via relative `../` references.

### 5. Config storage: JSONB on tenant row

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

### 6. Lifecycle states

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

### 7. Auth + membership model

`profiles` remains a global per-user record (identity, name, avatar,
auth metadata). It is NOT tenant-scoped — a single human with one
email belongs to one `profiles` row regardless of how many tenants
they touch.

Tenant access is split across two tables so staff authorisation stays
clean and small, while end-user (patient) volume doesn't bloat the
role-gating layer:

**`tenant_memberships(user_id, tenant_id, role, capabilities)`** —
staff only. Clinicians, admins, nurses, billing, analysts. This is
the high-trust, low-volume table that answers "who has PHI access
at this tenant."

**`patient_enrollments(user_id, tenant_id, status, enrolled_at, ...)`**
— patients/end-users. High volume. No role field; policy is always
"you see only your own rows." Status tracks enrolment lifecycle
(active, inactive, discharged).

A user can simultaneously have:

- A `tenant_memberships` row at Tenant A (they're a clinician there)
- A `patient_enrollments` row at Tenant B (they're a patient there)
- A `platform_role` on their profile (they're also Pulse internal ops)

Cross-cutting "all tenant users" queries use a `tenant_users` view
that unions both tables.

**Role hierarchy (enum `tenant_role`, staff only):**

- `tenant_owner` — tenant-level super-admin; can manage billing and
  all other roles.
- `tenant_admin` — standard clinic admin; manages day-to-day ops.
- `tenant_clinician` — licensed provider; reviews and prescribes.
- `tenant_nurse` — clinical support; limited write access.
- `tenant_billing` — billing/finance read + invoice management.
- `tenant_analyst` — read-only analytics access.

Patients are NOT in this enum. They're identified by the presence of
a `patient_enrollments` row.

**Platform-level role (separate enum `platform_role`, on profile):**

- `platform_super_admin` — Pulse founders / CTO-level. All access.
- `platform_admin` — Pulse ops managers. Create tenants, manage
  integrations, move lifecycle states.
- `platform_ops` — day-to-day operator work. No billing/dangerous
  actions.
- `platform_support` — read + view-as only, no write.
- `platform_billing` — billing access across tenants.
- `platform_readonly` — executive/auditor read-only.

A user's platform role is stored on `profiles.platform_role` (nullable
— most users are just tenant members and have none). Tenant roles
live on `tenant_memberships` only.

Existing `profiles.role` and `profiles.admin_role` columns are
superseded by this model. Phase 0's migration will backfill them:

- `role = 'member'` users → `patient_enrollments` rows.
- `role IN ('clinician', 'admin')` users → `tenant_memberships` rows
  with matching `tenant_role`.
- `admin_role = 'super_admin'` → additionally gets
  `profiles.platform_role = 'platform_super_admin'`.

The old columns are kept for one release as a safety net, then
removed in Phase 1 cleanup.

### 8. RLS policy patterns

Two canonical templates depending on table type.

**Staff-scoped tables** (clinical/admin data — consultations,
prescriptions, notes, etc.) are readable by any staff member of the
tenant and writable by staff whose role matches:

```sql
CREATE POLICY "staff_read" ON {table}
  FOR SELECT TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "staff_write" ON {table}
  FOR ALL TO authenticated
  USING (
    tenant_id IN (
      SELECT tenant_id FROM tenant_memberships
      WHERE user_id = auth.uid()
        AND role IN (...)
    )
  );
```

**Patient-scoped tables** (rows owned by a specific end-user — their
own consultations, their own messages) additionally allow the patient
to read their own rows:

```sql
CREATE POLICY "patient_own_read" ON {table}
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    AND tenant_id IN (
      SELECT tenant_id FROM patient_enrollments
      WHERE user_id = auth.uid()
    )
  );
```

Most tables need BOTH policies — staff see all tenant rows, each
patient sees only their own. Writes for patients are narrower (their
own data only, and not always permitted — e.g., patients can't edit
prescriptions).

Platform-level users bypass tenant scoping via a companion policy:

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
| `tenant_memberships`     | n/a (new)      | Staff-to-tenant mapping. Cross-tenant.         |
| `patient_enrollments`    | n/a (new)      | Patient-to-tenant mapping. Cross-tenant.       |
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

1. **010** — create `tenants`, `tenant_memberships`,
   `patient_enrollments`, and the `tenant_role` / `platform_role`
   enums. Insert Pulse as the seed tenant with a known UUID. No
   changes to existing tables — zero risk.
2. **011** — add `tenant_id` to every tenant-scoped table. Backfill
   every existing row to Pulse's UUID. Add NOT NULL constraint *after*
   backfill. Split existing `profiles.role` users into the new
   `tenant_memberships` (staff) and `patient_enrollments` (patients)
   tables. Swap RLS policies from existing to the tenant-scoped
   templates. Move Pulse files to `/t/pulse/` and add root-path
   redirects.

A full database dump is taken before running 011. Rollback = restore
the dump. This is the only phase where a full restore is the
disaster-recovery plan; every later phase is forward-fixable.

## Unite specifics

`unite/index.html` served from `/unite/`. Lives outside the
`/t/{slug}/` path tree. Access gated by `profiles.platform_role IS
NOT NULL`. Never tenant-scoped; never renders a single tenant's
config as if it were its own.

Design system: cream/beige theme shared with the tenant portals via
`tokens.css`. Accent colour is **slate** (`#3a4a5c`) — visually
distinct from the tenant admin portal's amber so operators never
confuse the two surfaces. A "Unite" role badge uses the slate
accent.

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
