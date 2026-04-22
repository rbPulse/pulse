# Routing refactor — completion log

Companion to `ARCHITECTURE.md`. Tracks the R1-R14 refactor that
moved the system from "Pulse at root + Unite in a subtab" to
"Unite at /unite + every tenant (including Pulse) at
/t/{slug}/".

## Shipped

| Phase | Commit(s) | Summary |
|---|---|---|
| R1 | `a4a0198` | platform.html → unite/index.html; Unite branding; ARCHITECTURE.md rewrite |
| R2a | `964b464` | URL migration manifest (URL_MIGRATION.md) |
| R2b | `90e7d53` | Deleted 11 marketing + prototype files |
| R2c | `67dd47d`, `da12819` | Tenant.url() helper; 5 Pulse files moved to /t/pulse/; ~70 URL references swept; root redirect stubs |
| R2d | `cb8d632` | index.html split — universal router at /, Pulse marketing at /t/pulse/ |
| R3 | `ac45ccc` | Tenant admin shell — Setup / Operations / Insights / Billing / Legacy sidebar groups |
| R4 | `a62bc70` (migration 022), `e1c0cb3` | Brand editor migrated to tenant admin; Unite collapsed to read-only summary |
| R5 | `80cb99b` | Terminology editor migrated; Unite summary |
| R6 | `f9455b5` | Catalog live-count summary; CRUD stays in Legacy → Configuration (full reconciliation is R6 carry-over) |
| R7 | `f080a61` | Workflow editor migrated; Unite summary |
| R8 | `56d1abc`, `6dc7725` | Comms template editor ported into tenant admin |
| R9 | `56d1abc`, `9bb5552` | Compliance editor ported into tenant admin |
| R10 | `56d1abc`, `59f5a55` + migration 023 | Integrations config editor (credentials remain platform-only via trigger guard) |
| R6 (full) | `6196daf` | Catalog read-only view in tenant admin (protocols table + category/type chips + packages list); legacy Configuration editor still primary for writes pending tenant-scoping carry-over |
| R11 (full) | `13b10c6` | Per-tenant operational pulse (stat cards + 30-day bars + enabled modules) above the existing Pulse analytics KPIs |
| R12 (full) | `8777678` | Config-change timeline (before/after diff rows, change-type filter) above the HIPAA audit table |
| R13 (full) | `ef23b64` | Module entitlements panel in Subscription view (grouped by source + plan-gap indicator) |

## Migrations 022 + 023 — RUN

`supabase/migrations/022_tenant_admin_config_write.sql` added the
RLS policy + column-guard trigger that lets tenant_owner /
tenant_admin write their own tenant's config columns (brand,
terminology, workflow, compliance, features, legal_name) while
keeping slug / name / lifecycle_state / created_by platform-only.

`supabase/migrations/023_tenant_admin_integrations_config_write.sql`
applied the same pattern to `tenant_integrations`: tenant admins
can now update `config` on their own rows; `credentials` +
system-managed columns (last_connected_at, last_error, etc.)
stay platform-only via a BEFORE UPDATE trigger.

Both migrations have been run against the live Supabase instance.

## R2e — Supabase URL allow-list — DONE

Supabase `Site URL` + `Redirect URLs` allow-list has been updated:
- Site URL: `https://rbpulse.github.io/pulse/`
- Redirect URLs include a `**` wildcard plus explicit entries for
  `/unite/`, `/t/pulse/`, `/t/pulse/admin/`, `/t/pulse/portal/`,
  `/t/pulse/consultation/`, `/t/pulse/checkout/`, `/t/pulse/quiz/`.
- Magic-link + OAuth callbacks now resolve to the new paths.

## Not yet shipped

### R2f — deprecate legacy root URLs

The redirect stubs at `/admin.html`, `/portal.html`,
`/consultation.html`, `/checkout.html`, `/quiz.html`, and
`/platform.html` still serve meta-refresh redirects to their
new homes. Delete after 30 days of no traffic (Cloudflare /
GitHub Pages analytics will confirm).

### R6 carry-over — SHIPPED

All 12 catalog DB operations in Legacy → Configuration are now
tenant-scoped (`loadProtocols`, `saveProtocol`,
`toggleArchiveProtocol`, `loadCategories`, `addCategory`,
`toggleArchiveCategory`, `loadProductTypes`, `addProductType`,
`toggleArchiveProductType`, bulk protocol upsert,
`_populateProtocolSelect`, and the existing R6 read views).
Every SELECT filters by `tenant_id`; every INSERT sets
`tenant_id`; every UPDATE gates by `tenant_id` as defense-in-
depth.

Migration `024_tenant_admin_catalog_write.sql` adds the
missing RLS policies on `protocol_templates`, `protocol_categories`,
and `protocol_product_types` so tenant owners/admins can write
their own tenant's catalog rows. Retires the legacy
`profiles.role = 'admin'` write policies from migration 005.

UI shuffle shipped: the `cfg-protocols` editor block and the
Manage Catalog Settings modal were relocated from
`tab-configure` into `tab-setup-catalog`, beneath the read-only
summary. `renderCatalogSetup` now kicks off `loadProtocols` /
`loadCategories` / `loadProductTypes` so the editor populates
together with the summary. `switchConfigSection` was scoped to
`tab-configure` so the relocated section isn't affected by
subnav clicks inside the legacy tab.

What remains of the Legacy group: Clinician Capacity and
Automations. Sidebar section renamed "Operations"; item relabeled
"Clinicians & Automations" to match. The `tab-configure` tab
title is now "Operations Legacy" and its subnav starts on
Clinician Capacity.

### R8-R13 ports — SHIPPED

R8 (Comms), R9 (Compliance), R10 (Integrations), R11 (Analytics),
R12 (Activity) and R13 (Subscription) all shipped their full
ports. Nothing pending here.

### Unite cleanup

Every `READ_ONLY_PLACEHOLDER = true` guard in Unite's
`buildXxxTab` functions has the legacy full-editor code
preserved below it. Once the corresponding tenant-admin editor
proves stable (30+ days), delete the legacy code paths. Single
commit per surface.

## Known architectural invariants preserved

- Pulse has no URL privileges. Every tenant lives at /t/{slug}/.
- Unite is not tenant-scoped. It never renders a single
  tenant's config as its own.
- Credentials never enter the tenant admin portal — Phase 7's
  security posture held through R10.
- The four-helper JS contract (tenant.js, terminology.js,
  workflow.js, messaging.js, integrations.js, compliance.js,
  modules.js) is the stable interface between Unite and
  every tenant admin. Every migration reused the helpers
  without duplicating catalog state.
