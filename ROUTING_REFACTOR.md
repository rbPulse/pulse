# Routing refactor — completion log

Companion to `ARCHITECTURE.md`. Tracks the R1-R14 refactor that
moved the system from "Pulse at root + CommandOS in a subtab" to
"CommandOS at /commandos + every tenant (including Pulse) at
/t/{slug}/".

## Shipped

| Phase | Commit(s) | Summary |
|---|---|---|
| R1 | `a4a0198` | platform.html → commandos/index.html; CommandOS branding; ARCHITECTURE.md rewrite |
| R2a | `964b464` | URL migration manifest (URL_MIGRATION.md) |
| R2b | `90e7d53` | Deleted 11 marketing + prototype files |
| R2c | `67dd47d`, `da12819` | Tenant.url() helper; 5 Pulse files moved to /t/pulse/; ~70 URL references swept; root redirect stubs |
| R2d | `cb8d632` | index.html split — universal router at /, Pulse marketing at /t/pulse/ |
| R3 | `ac45ccc` | Tenant admin shell — Setup / Operations / Insights / Billing / Legacy sidebar groups |
| R4 | `a62bc70` (migration 022), `e1c0cb3` | Brand editor migrated to tenant admin; CommandOS collapsed to read-only summary |
| R5 | `80cb99b` | Terminology editor migrated; CommandOS summary |
| R6 | `f9455b5` | Catalog live-count summary; CRUD stays in Legacy → Configuration (full reconciliation is R6 carry-over) |
| R7 | `f080a61` | Workflow editor migrated; CommandOS summary |
| R8-R13 | `56d1abc` | Tenant-admin read-only / summary surfaces for Comms, Compliance, Integrations, Subscription; Analytics + Activity stubbed pending reconciliation with admin.html's existing tabs |

## Migration 022

`supabase/migrations/022_tenant_admin_config_write.sql` added the
RLS policy + column-guard trigger that lets tenant_owner /
tenant_admin write their own tenant's config columns (brand,
terminology, workflow, compliance, features, legal_name) while
keeping slug / name / lifecycle_state / created_by platform-only.
Required for every R4+ save path from inside the tenant admin.

## Not yet shipped

### R2e — Supabase dashboard (manual)

Supabase's `Site URL` + `Redirect URLs` allow-list must be updated
by hand in the dashboard before magic-link / OAuth callbacks
resolve to the new paths. URLs to add are enumerated in
`URL_MIGRATION.md` → "Supabase-side URLs" section.

Until that's done, password sign-in works everywhere, but
passwordless flows + OAuth error on the redirect step.

### R2f — deprecate legacy root URLs

The redirect stubs at `/admin.html`, `/portal.html`,
`/consultation.html`, `/checkout.html`, `/quiz.html`, and
`/platform.html` still serve meta-refresh redirects to their
new homes. Delete after 30 days of no traffic (Cloudflare /
GitHub Pages analytics will confirm).

### R6 carry-over — Catalog full CRUD

admin.html's Legacy → Configuration tab is the pre-multi-tenant
catalog editor. Its inserts don't set `tenant_id`; they assume
single-tenant. Reconciliation = sweep the Configuration tab's
DB writes to always filter/set `tenant_id = window.Tenant.id`,
then move the resulting tenant-aware editor into Setup → Catalog
and delete the Legacy sidebar section.

### R8-R13 carry-overs — full editors

Each of Comms / Compliance / Integrations / Subscription / etc.
ships with a live count / status summary today in the tenant
admin. Full editors still run out of CommandOS for tenant-owner
convenience. Each migrates to its tenant-admin tab when the
authoring surface gets its own dedicated port, matching the
shape R4 (Brand) / R5 (Terminology) / R7 (Workflow) used.

### R11 / R12 — reconcile admin.html's existing tabs

admin.html's Analytics + Audit tabs predate the CommandOS-era
per-tenant views. R11 and R12 carry-overs reconcile the two,
keeping the best of each and deleting duplicates.

### CommandOS cleanup

Every `READ_ONLY_PLACEHOLDER = true` guard in CommandOS's
`buildXxxTab` functions has the legacy full-editor code
preserved below it. Once the corresponding tenant-admin editor
proves stable (30+ days), delete the legacy code paths. Single
commit per surface.

## Known architectural invariants preserved

- Pulse has no URL privileges. Every tenant lives at /t/{slug}/.
- CommandOS is not tenant-scoped. It never renders a single
  tenant's config as its own.
- Credentials never enter the tenant admin portal — Phase 7's
  security posture held through R10.
- The four-helper JS contract (tenant.js, terminology.js,
  workflow.js, messaging.js, integrations.js, compliance.js,
  modules.js) is the stable interface between CommandOS and
  every tenant admin. Every migration reused the helpers
  without duplicating catalog state.
