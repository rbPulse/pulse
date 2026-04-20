# Pulse Platform — Phased plan (full vision)

Companion to `ARCHITECTURE.md`. That doc is *what* we're building and
*why* we made each decision. This doc is *when* and *in what order*.

Sized so each phase is 1.5–4 weeks, ends with something demoable, and
unblocks the next. Estimates assume one focused full-time developer;
double-track if you have two.

When a phase lands, update the **Status** section at the bottom of this
doc. When reality diverges from a phase's stated deliverables, update
this doc — don't let the gap silently widen.

---

## Phase 0 — Multi-tenancy foundation (1.5 weeks)

**Ships:** architecture is multi-tenant; Pulse still works exactly as
before.

- `ARCHITECTURE.md`: lock isolation model (RLS), tenant resolution
  (path-based), config storage (JSONB on tenants).
- Migration `010_tenants.sql`: `tenants`, `tenant_memberships(user_id,
  tenant_id, role)`, `tenant_lifecycle_state` enum, `tenant_role` enum,
  `platform_role` enum, `patient_enrollments`, `profiles.platform_role`
  column, RLS helpers `current_tenant_ids()` / `is_platform_user()`.
- Migration `011_tenant_scoping.sql`: add `tenant_id uuid not null` to
  every existing tenant-scoped table, backfill = Pulse, swap RLS
  policies to tenant-scoped templates.
- Migration `012_support_requests.sql`: new `support_requests` table
  with tenant scope (needed by Phase 1 sidebar and Phase 13 console).
- `tenant.js`: shared bootstrap that resolves tenant from path, fetches
  tenant config once, exposes `window.Tenant` global.

**Risk:** highest single phase — touches every existing table. Test
against a Pulse clone first.

---

## Phase 1 — Operator portal shell + Tenant CRUD + Roles framework (2 weeks)

**Ships:** internal team can log in, list tenants, create tenants,
assign roles.

- New `/platform.html` at repo root with admin.html's design system,
  slate accent (`#3a4a5c`). *(Deviation from original plan's
  `/platform/index.html` — ARCHITECTURE.md decided flat root files.)*
- Sidebar nav with placeholders for every section built later:
  **Dashboard, Clients, Templates, Modules, Integrations, Billing,
  Analytics, Support, Audit, Settings**.
- Roles framework lands here, not later. Enums shipped in migration
  010:
  - Platform-level (on `profiles.platform_role`):
    `platform_super_admin`, `platform_admin`, `platform_ops`,
    `platform_support`, `platform_billing`, `platform_readonly`.
  - Tenant-level (on `tenant_memberships.role`): `tenant_owner`,
    `tenant_admin`, `tenant_clinician`, `tenant_nurse`,
    `tenant_billing`, `tenant_analyst`.
  - Per-role overrides live in `tenant_memberships.capabilities` JSONB.
- **Clients tab** — tenant directory: list with status pills, plan,
  active users, created date.
- **Create tenant** — name + slug + lifecycle state + initial admin
  email.
- **Tenant detail page** — Overview tab (read-only summary).
- **Lifecycle state controls** — sandbox / live / suspended / archived,
  audit-logged, gated to `platform_admin`+.

---

## Phase 2 — Brand configuration (2 weeks)

**Ships:** each tenant can have its own logo, colors, sender identity.
All 3 downstream portals respect it.

- Brand tab on tenant detail: logo upload (Supabase storage), accent
  color picker, wordmark, sender email, support email/phone, legal
  name, footer copy, favicon.
- Refactor downstream portals one at a time (admin → portal →
  clinician) to read `Tenant.brand.*`. Each gets its own PR.
- Brand preview embedded in operator portal (iframe or sandboxed
  render).

---

## Phase 3 — Terminology configuration (2 weeks)

**Ships:** a tenant can call them "patients" instead of "members,"
"treatment plans" instead of "protocols," etc.

- Audit downstream portals for hardcoded patient-facing strings (~30
  keys: member/patient/client, protocol/plan, clinician/provider,
  dose/session, refill/renewal, intake/consult, etc.).
- Schema: `tenants.terminology` jsonb.
- Build an i18n-style helper: `t('member')` returns the configured
  term.
- Refactor downstream portals — heavier than brand because terms are
  everywhere. Slice by portal.
- Terminology tab on tenant detail: form fields with helper text and
  live preview.

---

## Phase 4 — Catalog + product configuration (2.5 weeks)

**Ships:** each tenant has its own product catalog, dosing options,
packages.

- Add `tenant_id` to `protocol_templates`, `protocol_categories`,
  `product_types`. Backfill to Pulse. *(Already done in Phase 0 / 011
  — confirm no rework needed here.)*
- Catalog tab on tenant detail: port the existing admin.html catalog
  UI, scoped to selected tenant.
- Pricing schema: per-product price, refill price, subscription
  cadence, package bundles.
- Refactor checkout/consultation flows to query tenant-scoped catalog.

---

## Phase 5 — Workflow configuration (3.5 weeks) — the big one

**Ships:** tenants can have different intake rules, refill SLAs,
escalation rules, consult policies.

- Audit hardcoded business logic across all 3 portals. This is the
  deepest audit because workflow logic is buried in event handlers, not
  just templates.
- Schema: `tenants.workflow` jsonb with structured keys
  (`intake_required`, `consult_policy`, `refill_eligibility_days`,
  `sla_hours`, `escalation_rules`, `follow_up_cadence`,
  `auto_assign_strategy`, etc.).
- Per-rule configurable in operator portal as form fields, not
  free-form JSON. Bad config should be impossible by construction.
- Refactor execution paths in downstream portals to read workflow
  config.
- **This is the phase most likely to slip. Plan a 2-week buffer.**

---

## Phase 6 — Communications layer (2 weeks)

**Ships:** each tenant has its own email/SMS/push templates, sender
identity, reminder cadence.

- Schema: `communication_templates(tenant_id, key, channel, subject,
  body, variables)`.
- Comms tab on tenant detail: list templates, edit with variable
  interpolation, test-send.
- Reminder cadence config per template type.
- Sender identity per tenant (verified with Resend/Postmark API).
- Refactor existing automation triggers (admin.html migration 008) to
  load templates from this table.

---

## Phase 7 — Integrations management (2.5 weeks)

**Ships:** per-tenant Stripe, Daily.co, email, EHR, shipping, ID
verification credentials.

- Schema: `tenant_integrations(tenant_id, provider, status,
  encrypted_credentials, config)`. Use Supabase Vault or pgcrypto for
  credential encryption.
- Integrations tab on tenant detail: list available integrations,
  connect/disconnect, status indicator (red/yellow/green).
- Webhook routing infrastructure: incoming webhooks resolve to tenant
  via reference (e.g., Stripe customer metadata → tenant_id).
- Test connections built into the tab.

---

## Phase 8 — Compliance + multi-location + regional (2.5 weeks)

**Ships:** state/region restrictions, multi-location support,
compliance guardrails.

- Schema: `tenant_locations`, `tenant_regions(tenant_id, state,
  allowed)`, `tenant_consents`, `clinician_state_licenses`.
- Compliance tab on tenant detail: operating states, consent
  templates, disclaimer sets, region-restricted features.
- Locations tab (or section under Compliance): per-location address,
  phone, hours, assigned clinicians.
- Data export endpoint per tenant (GDPR/HIPAA contract requirement).
- License expiry alerts.

---

## Phase 9 — Modules + plans + billing (2.5 weeks)

**Ships:** each tenant is on a plan; modules/features are entitled by
plan; Stripe drives billing.

- Schema: `plans`, `tenant_subscriptions`,
  `module_entitlements(tenant_id, module_key, enabled, source)`.
- Pricing & Modules tab on tenant detail: shows plan, line-item
  modules, monthly cost, override toggles.
- Feature-flag system wired to entitlements:
  `Tenant.features.live_video` checks entitlement table.
- Stripe integration: tenant has a Stripe customer; subscription items
  map to modules.
- Use Stripe Customer Portal link for invoicing UI — don't rebuild it.
- Pulse internal billing dashboard: MRR, by-plan breakdown, churn
  flags.

---

## Phase 10 — Audit log + change management (1.5 weeks)

**Ships:** every config change is logged with before/after; per-tenant
activity timeline.

- Migration: `tenant_id` on existing `audit_logs` (already exists from
  migration 009); add `change_type`, `before_snapshot`, `after_snapshot`
  jsonb columns.
- Activity tab on tenant detail: timeline view of config changes, with
  diff view on click.
- Operator-level audit: cross-tenant filter for "what did Pulse
  internal change."

---

## Phase 11 — Onboarding wizard (2 weeks)

**Ships:** new tenant goes from zero to launch-ready in a guided 9-step
flow.

- Wizard wraps every tab built in Phases 1–10.
- Each step validates required fields and shows a launch checklist.
- Final step: "QA preview" embeds the 3 downstream portals in iframes
  for visual review.
- Activate button moves tenant lifecycle from `sandbox` → `live`.

---

## Phase 12 — Templates / Starter Packs (2 weeks)

**Ships:** save Pulse's full config as "Wellness Clinic Starter"; apply
to new tenants.

- Schema: `tenant_templates(name, description, vertical,
  config_snapshot jsonb)`.
- "Save as template" button on tenant detail captures full config
  (brand, terminology, workflow, catalog, comms).
- "Apply template" step in the onboarding wizard.
- Initial template library seeded from Pulse + 1–2 fictional verticals
  as worked examples.

---

## Phase 13 — Support + implementation console (2 weeks)

**Ships:** internal team can diagnose tenants without leaving the
operator portal.

- "View as tenant role" — drops operator into tenant's portal in
  read-only mode with a persistent yellow banner.
- Diagnostic checks per tenant: integration health, queue depth, stale
  workflows, expired licenses.
- Launch checklist tracking.
- Re-send invites, reset workflow states (with audit log entries).
- Internal support ticket inbox (or just a Linear/Intercom integration
  link if not building from scratch).

---

## Phase 14 — Cross-tenant analytics (3 weeks)

**Ships:** operator dashboard with platform-wide metrics; per-tenant
funnel/SLA dashboards.

- Operator dashboard: total active clients, active members, consult
  volume, GMV, churn risk, integration failures, module adoption.
- Per-tenant analytics tab: funnel drop-off, refill conversion, SLA
  performance, clinician load, payment failures, no-shows, inactivity
  signals.
- Daily snapshot job (Postgres trigger or Supabase Edge Function)
  aggregates into `analytics_snapshots` table.
- Charts use admin.html's existing chart components
  (`renderBarChart` etc.).

---

## Phase 15 — Intelligence layer / Agents (4 weeks) — last

**Ships:** 6 agents that surface recommendations across tenants.

- **Implementation Agent** — scans tenant config for gaps, missing
  setup, inconsistencies.
- **Operations Agent** — monitors workflow bottlenecks, response
  delays, support spikes.
- **Revenue Optimization Agent** — refill drop-off, conversion gaps,
  package opportunities.
- **Patient Experience Agent** — onboarding friction, message
  overload, low engagement.
- **Clinician Capacity Agent** — backlog risk, distribution imbalance,
  state coverage gaps.
- **Compliance/Risk Agent** — missing consents, state mismatches,
  expired licenses.

Each agent surfaces in: (a) operator dashboard ("3 tenants need
attention"), (b) tenant detail page ("4 recommendations"), (c)
optionally as a paid add-on entitlement.

---

## Total estimate

~37 weeks of focused single-developer work. 9 months if continuous,
more realistic at 11–12 months with discovery, review cycles, and
unforeseen complexity. With 2 developers running parallel tracks (e.g.,
one on infra/config, one on UI), this compresses to ~6–7 months.

## Shippable milestones along the way

| After phase | What you can demo |
|-------------|-------------------|
| Phase 1     | Internal team logs in, sees Pulse, creates a test tenant |
| Phase 4     | Second tenant onboarded with own brand, terminology, catalog |
| Phase 5     | Tenant has functioning custom workflow end-to-end |
| Phase 9     | Tenant is on a paid plan with entitled modules |
| Phase 11    | Onboarding takes <30 min for a new client |
| Phase 13    | Internal ops can manage 5+ clients efficiently |
| Phase 15    | Full platform vision realized |

---

## Status

| Phase | State         | Notes |
|-------|---------------|-------|
| 0     | **Done**      | Migrations 010–012 run; `tenant.js` wired into admin + portal; seed tenant "pulse" live. |
| 1     | **Done**      | Shell (auth gate, slate accent, 10-section sidebar), Clients directory (list + stats + filter), Create-client form (slug validation + initial admin wiring), Client detail modal (read-only + config layer status), Lifecycle state controls (role-gated + audit-logged), `tokens.css` created and wired into `platform.html`. |
| 2     | **Done (with carry-overs)** | Client detail modal refactored to tabbed structure (placeholders for all Phase 3–10 surfaces). Brand tab: wordmark, accent color, sender identity, support contacts, footer copy, legal name. Migration 013 adds `brand-assets` storage bucket (public-read, platform-write). Logo + favicon upload with thumbnail previews. Sandboxed live preview panel updates as the operator types. `admin.html` reads `Tenant.brand.*` via `applyTenantBrand()` hook (wordmark → nav + loading + title, accent → `--amber` override, favicon). `portal.html` reads `Tenant.brand.*` (wordmark + favicon + title; accent deferred — see below). |
| 3     | **Foundations done; full refactor = carry-over** | `terminology.js` shipped with a catalog of ~30 renameable terms across 4 groups (people, clinical, workflow, commercial) and a single `Terminology.t(key)` accessor with `{ lower }` / `{ upper }` opts. Operator portal's Terminology tab renders one input per term (grouped, with live "overridden" badges) and a 4-line live preview. Save writes diff-only to `tenants.terminology` JSONB with audit log. `admin.html` and `portal.html` both load `terminology.js` + call `Terminology.init()` after tenant resolves; PoC replacement in each (role noun in document title / loading screen) proves the plumbing. See carry-over below for the per-portal string audit. |
| 4     | **Foundations done; full CRUD + downstream refactor = carry-over** | Migration 014 extends the catalog schema: per-tenant key uniqueness on `protocol_templates` (dropped the global UNIQUE, added composite `(tenant_id, key)`), `refill_price` + `subscription_cadence` columns, new `protocol_packages` table with JSONB `items` bundle + RLS following the Phase 0 staff/platform template. Operator portal's Catalog tab fetches and displays all four catalog tables (protocols, categories, product types, packages) scoped to the selected tenant with per-section error hints (e.g. "run migration 014" when `protocol_packages` is missing). See carry-over for the editor UI and the downstream refactor. |
| 5     | **Foundations done; execution-path refactor = carry-over** | `workflow.js` ships with a rich SCHEMA catalog (6 sections, ~15 fields: intake, consult, refill, sla_hours, assignment, follow_up) and a dot-path accessor (`Workflow.get('refill.eligibility_days_before_runout')`). Operator portal's Workflow tab auto-renders from SCHEMA with type-appropriate inputs (toggle / bounded number / enum select), live override badges, client-side validation. Save writes full shape to `tenants.workflow` JSONB with diff-only audit log. `admin.html` and `portal.html` both load `workflow.js` + call `Workflow.init()` after tenant resolves. Execution-path refactor — replacing every hardcoded SLA timer, refill window, consult policy branch, assignment rule across all three portal surfaces — is the multi-session carry-over the PHASES.md 3.5-week estimate anticipates. |
| 6     | **Foundations done; delivery + trigger refactor = carry-over** | Migration 015 adds `communication_templates(tenant_id, key, channel, subject, body, variables, cadence)` with composite unique on `(tenant_id, key, channel)` and RLS (staff read / tenant-owner+admin write / platform read-write). `messaging.js` ships a catalog of ~7 default templates (member welcome, intake confirmation, refill approved/denied, consult scheduled/reminder, follow-up) with `Messaging.resolve(key, channel)` / `Messaging.render(key, vars, channel)` helpers. Operator Comms tab lists every template grouped by namespace; each card has subject/body editors, clickable variable chips that insert `{{tokens}}` at the cursor, per-template save + reset + preview (with hardcoded sample data). `admin.html` and `portal.html` load messaging.js and fire `Messaging.init()` in parallel with page boot. See carry-over for delivery wiring and automation-trigger refactor. |
| 7     | **Foundations done; delivery + Vault + webhook router = carry-over** | Migration 016 creates `tenant_integrations(tenant_id, provider, status, credentials jsonb, config jsonb, last_connected_at, last_error, last_error_at)` with platform-only RLS on the base table and a SECURITY DEFINER RPC (`tenant_integrations_for_my_tenants`) that returns a non-secret projection to tenant staff. `integrations.js` ships a catalog of 7 providers (Stripe, Daily.co, Resend, Twilio, Labcorp, Stripe Identity, Shippo) with credential + config field schemas. Operator Integrations tab renders one card per provider grouped by category; Connect/Edit/Disconnect/Test actions manage the row. Password fields always render blank on edit — leaving blank keeps the stored value. Audit log redacts credential VALUES (writes `credential_keys: [...]` instead). `admin.html` + `portal.html` load integrations.js and fire `Integrations.init()` in parallel with page boot. See carry-over for the real delivery path, Vault migration, and the webhook router. |
| 8     | **Foundations done; data-export + alerts + read-site gating = carry-over** | Migration 017 creates four compliance tables in one migration: `tenant_locations` (addresses, hours, primary-flag with partial unique index), `tenant_regions` (operating states with allowed/blocked/unset tri-state), `tenant_consents` (versioned — editing creates a new version so prior signatures stay traceable), `clinician_state_licenses` (per-user, cross-tenant). `compliance.js` ships the US states catalog + `tenantOperatesIn` / `cliniciansLicensedIn` / `licensesExpiringWithin` / `primaryLocation` helpers. Operator Compliance tab has four sections: clickable states grid with cycle-semantics (unset → allowed → blocked → unset), locations CRUD with primary management, consent templates with versioned edit flow, read-only licenses summary with expiry stat cards (expired / ≤30d / ≤60d). `admin.html` + `portal.html` load compliance.js and fire `Compliance.init()` in parallel. See carry-over for data-export, license-expiry notifications, and the read-site gates that actually enforce state restrictions. |
| 9     | **Foundations done; Stripe sync + feature-gate refactor = carry-over** | Migration 018 creates `plans` (seeded with Starter / Pro / Enterprise), `tenant_subscriptions` (partial unique index — one active sub per tenant; canceled rows stay as history), `module_entitlements` (sourced from plan or manually granted, with expiry for trials). `modules.js` ships a catalog of 16 modules across 5 categories (core, clinical, commercial, analytics, enterprise) and a `Modules.isEnabled(key)` feature-gate accessor. Per-client Billing tab manages subscription + per-module entitlements. Two top-level fleet tabs: **Modules** (catalog with adoption counts + plan-membership chips) and **Billing** (MRR, ARR, plan mix, churn flags). `admin.html` + `portal.html` load modules.js and fire `Modules.init()` in parallel. See carry-over for Stripe sync, Customer Portal embed, and the downstream feature-gate refactor. |
| 10    | **Done (with carry-overs)** | Migration 019 extends `audit_logs` with `change_type` (stable classifier), `before_snapshot` (jsonb, pre-change state), `after_snapshot` (jsonb, post-change state). Append-only trigger from migration 009 preserved. Backfill classifies every existing audit action via a CASE mapping so historical rows get `change_type` populated without losing the legacy `details` string. Per-client Activity tab renders a timeline filtered by tenant with change-type filter, click-to-expand diff view (before/after side-by-side for new rows, raw `details` JSON for legacy rows). Top-level Audit tab has cross-tenant filter on top of the same renderer. Change-type colour mapping: brand/comms = slate, terminology/billing = green, workflow/compliance = amber, integration = blue, lifecycle = red. See carry-over for write-site structured snapshots + export. |
| 11    | **Done (with carry-overs)** | No schema. Onboarding wizard layers over the existing detail modal as a view mode toggle: wizard button hides the tab strip and renders a 10-step sidebar (Basics, Brand, Terminology, Catalog, Workflow, Comms, Integrations, Compliance, Billing, Launch). Each step reuses its existing build function (zero duplicate form code); completion is derived dynamically from tenant row + async probes of related tables. Launch step aggregates a pre-flight checklist with Jump buttons for remaining work; Activate button (role-gated) moves sandbox → live with a structured Phase-10-shaped audit entry. Sandbox tenants get an inline "Onboard" button in the Clients table; newly created tenants auto-open in wizard mode post-save. See carry-over for QA-preview iframes and required-field validation. |
| 12    | **Done (with carry-overs)** | Migration 020 creates `tenant_templates` (Pulse-owned starter-pack library) seeded with Blank + Wellness Clinic templates. config_snapshot JSONB holds `layers` (brand / terminology / workflow / compliance / features merged onto tenant row) and `seeds` (catalog rows + comms templates + operating regions + consents inserted with target tenant_id). Shared `applyTemplateToTenant(templateId, tenantId)` helper handles merge + seed insertion with per-row unique-violation skip so partial re-apply is safe. Top-level Templates tab lists available templates with Archive + Apply-to-tenant actions. Save-as-template dialog on the client detail header captures the source tenant's layers + seeds into a new template row. Template picker on the create-client form auto-applies after tenant creation and before the wizard opens, so operators get a seeded starting point in one flow. See carry-over for conflict UI and richer seed coverage. |
| 13    | **Foundations done; view-as + real actions = carry-over** | No migration (support_requests table already shipped in 012). Top-level Support tab renders a cross-tenant queue with stat strip (open / in-review / resolved / closed), per-row status transitions (Start review / Resolve / Reopen / Close), and filters for status + tenant. Per-client Diagnostics tab (new DETAIL_TABS entry) shows a stat-card dashboard — integrations health, support queue depth, license expiry buckets, billing flags, member + staff counts — plus view-as launcher strip (opens `/t/{slug}/*.html` in a new tab for member / clinician / admin portals) and operator actions (welcome resend stub, workflow reset, local cache flush). Every action writes a Phase-10-shape audit entry. See carry-over for true view-as (auth-bypassed tenant-role render) + real delivery wiring for the stubs. |
| 14–15 | Not started   | See sections above. |

### Carry-over from Phase 2

- `portal.html` accent color override. Portal.html hosts BOTH the member
  portal (`body.member-mode`) and the clinician portal
  (`body.clinician-mode`) in one file, each with its own namespaced
  accent tokens (`--m-*` for member, `--cl-*` for clinician). The
  `applyTenantBrand()` hook runs before the body class is set, so it
  needs to either (a) override both `--m-*` and `--cl-*` accent
  variables up-front, or (b) re-run after `initPortal` decides the
  mode. Option (b) is simpler and is what the next portal touch
  should do.
- Two `portal.html` wordmark instances live inside JS template strings
  (welcome-card brand ~line 14723, consult-reminder nav ~line 21093)
  and still read hardcoded "PULSE" because they render after the
  `applyTenantBrand()` hook fires. Rebuild those templates to read from
  `window.Tenant.brand.wordmark` when the template is built.
- `portal.html` still carries an inline `:root` block that duplicates
  `tokens.css` tokens (Phase 1 carry-over). Migrate alongside the brand
  touch above.
- Orphaned storage objects: replacing a logo uploads a new file with a
  timestamp suffix; the old file stays. Cleanup job belongs with the
  Phase 10 audit/retention work, not Phase 2.
- Live preview is a sandboxed render, not a real iframe of the downstream
  portal. That's fine for Phase 2 (covers the "iframe or sandboxed
  render" option in the plan). Upgrade to iframe previews alongside
  Phase 13's view-as console, where the downstream portals will learn
  to accept an operator preview session.

### Carry-over from Phase 3

- Full per-surface string audit. `terminology.js` + `Terminology.t()`
  are plumbed into `admin.html` and `portal.html`, but most hardcoded
  strings haven't been routed through the helper yet. Three distinct
  surfaces need a pass, even though they live in two files:

  1. **Admin portal** (`admin.html`) — "Patients" in the sidebar,
     "Live Consults", "Messages", tab titles, stat labels, detail
     modal copy. Start here: smaller file, operator-facing, regressions
     are caught fast.

  2. **Member portal** (`portal.html` rendering under
     `body.member-mode`) — every string a patient sees: welcome
     card, protocol/plan copy, dose/session language, refill/renewal
     language, support copy. This is the largest audit of the three
     and needs visual QA on the real member journey.

  3. **Clinician portal** (`portal.html` rendering under
     `body.clinician-mode`) — every string a clinician sees: queue
     labels, patient list headers, review flows, message composer
     labels. Can be sliced separately from the member audit because
     the clinician-mode code paths are distinct from the member-mode
     ones inside the same file.

- Pulse tenant needs a terminology override setting `member → "Patient"`
  and `members → "Patients"` to match the current admin sidebar text
  before the per-portal audit lands. Otherwise Pulse's sidebar flips
  to "Members" on first refactor. Operator can do this via the
  Terminology tab in platform.html.
- Two `portal.html` wordmark instances in JS template strings (called
  out in Phase 2 carry-over) also hardcode terminology-adjacent copy —
  address both at the same time when rebuilding those templates to
  read from `window.Tenant`.

### Carry-over from Phase 4

- **Catalog editor UI.** The Catalog tab in platform.html is read-only
  today. Full CRUD (create/edit/archive protocols, categories, product
  types, packages with drag-to-reorder) needs porting from admin.html's
  existing Configure tab, scoped to the selected tenant instead of the
  global `tenant_id IS NULL` assumption the current admin UI makes.
- **Admin portal's Configure tab refactor.** `admin.html` has an
  existing catalog editor (search for `tab-configure`) that writes to
  `protocol_templates` / `protocol_categories` / `protocol_product_types`.
  Its queries don't filter by `tenant_id` — they assume a single-tenant
  world. Needs a pass to add `.eq('tenant_id', Tenant.id)` on every read
  and set `tenant_id: Tenant.id` on every insert. Until this lands, a
  tenant admin inserting a new protocol from their own admin UI creates
  a row with `tenant_id` set by the default (likely NULL or a Postgres
  error depending on the NOT NULL constraint set by migration 011);
  double-check the constraint before touching this.
- **Downstream portal refactor.** `portal.html` (member + clinician)
  and the checkout / consultation flows still read catalog data without
  a tenant filter. Slice this alongside the admin.html refactor — each
  portal is a separate PR with a visual QA pass on a real member
  journey.
- **Pricing display in the downstream portals.** `refill_price` and
  `subscription_cadence` are new columns; nothing reads them yet. The
  next pass through the checkout and refill flows should surface refill
  pricing separately from initial pricing and show cadence where
  relevant ("$49 / month" instead of just "$49").
- **Package renderer.** No downstream portal renders packages today.
  Decide during the Phase 4 follow-up whether packages ship as a
  separate catalog section in the member protocol picker or are
  flattened into the regular protocol list with a "bundle of N" badge.

### Carry-over from Phase 5

- **Execution-path refactor.** This is the big piece PHASES.md flags
  as 3.5 weeks on its own. `Workflow.get()` is available everywhere
  but nothing reads it yet. Every hardcoded SLA, refill window, consult
  branch, assignment rule across the three portal surfaces needs a
  pass. Slice by concern (not by portal) — a single refactor PR
  typically touches all three surfaces when it refactors one rule:

  1. **Refill eligibility.** Search for places computing
     "can this member refill?" (date arithmetic on prescriptions /
     dose_logs). Route through
     `Workflow.get('refill.eligibility_days_before_runout')` and
     `Workflow.get('refill.clinician_review_required')`.

  2. **Consult policy.** Branches that decide "does this member
     need a consult before this Rx?" — replace the hardcoded rule
     with `Workflow.get('consult.policy')` and the
     enum-to-behaviour mapping.

  3. **SLA timers.** Anywhere admin.html highlights stale queues
     or sends escalation notifications on magic-number hour
     thresholds — route through the `sla_hours.*` fields.

  4. **Assignment strategy.** Admin.html's clinician-assignment
     logic (currently round-robin by default). Read strategy +
     state-license toggle + max-concurrent from `assignment.*`.

  5. **Follow-up cadence.** Any scheduled job or client-side
     reminder that fires on hardcoded day intervals — route through
     `follow_up.cadence_days` and `follow_up.after_refill_check_days`.

  Each of the five is a dedicated PR with a visual QA pass on the
  real workflow it governs. Plan the 2-week buffer PHASES.md
  recommends before shipping Phase 5 as "done".

- **Default override seeding for the Pulse tenant.** The bundled
  defaults are reasonable general-purpose values. If Pulse today
  runs with specific thresholds (e.g. a 14-day refill window instead
  of the default 7), capture the actual values in Pulse's
  `tenants.workflow` before the refactor starts — otherwise the
  first hardcoded-to-`Workflow.get()` replacement silently changes
  Pulse's operating rules. Use the Workflow tab to set these now.

- **Downstream validation / enforcement.** Client-side validation in
  the Workflow tab prevents bad form input, but nothing enforces the
  shape at the DB level. A Phase 10 (audit) or Phase 13 (support)
  concern: add an integrity check that logs-and-repairs tenants whose
  workflow JSONB diverges from SCHEMA (missing section, stray key,
  out-of-range value). Not urgent — the operator UI is the only
  writer today.

### Carry-over from Phase 6

- **Actual delivery wiring.** `Messaging.render()` returns the
  rendered subject + body; nothing sends it yet. Delivery belongs
  with Phase 7 integrations where per-tenant Resend / Postmark /
  Twilio credentials land. The send function should pull
  integrations config + rendered template, route through the
  configured provider, and log the delivery attempt.
- **Automation trigger refactor.** Admin.html's migration 008
  `platform_automations` table already fires automated messages on
  events (e.g. refill approved). Those triggers currently build
  subject + body with hardcoded templates. Refactor each trigger
  to look up its template via `Messaging.render('refill.approved',
  vars)` instead — once delivery wiring lands, the trigger becomes
  two lines: `var msg = Messaging.render(key, vars); deliver(msg);`.
- **Cadence enforcement.** The schema supports a `cadence` JSONB on
  each template (e.g. `consult.reminder` defaults to
  `{ days_before: [1], hours_before: [2] }`) but nothing reads it.
  Wire the reminder scheduler to pull cadence per-template when
  deciding when to fire.
- **Test-send (real delivery, not just preview).** Once Phase 7
  delivery is in place, add a "Test send to me" button to each
  template card that delivers the rendered template to the current
  operator's email via the tenant's configured sender. Preview
  stays as it is — the button should be distinct, not replace it.
- **Plural-channel templates.** A tenant might want the same
  semantic message (e.g. `refill.approved`) delivered as BOTH email
  and SMS. The schema supports it (two rows with different
  `channel`), but the Comms tab currently only renders templates
  that are in the bundled catalog. Add an "Add SMS variant" or
  "Add push variant" action on each template card so operators can
  author additional channels without a code change.
- **Variable catalog per trigger context.** Today every template
  lists its allowed variables. As more triggers land, the variable
  names will drift unless we check that trigger-supplied vars match
  the template's declared allow-list. Belongs with the trigger
  refactor above: when `Messaging.render(key, vars)` is called, warn
  if `vars` keys don't match `CATALOG[key].variables` names.

### Carry-over from Phase 7

- **Supabase Vault migration.** This is the top carry-over. Today,
  credentials are stored inline in `tenant_integrations.credentials`
  JSONB with RLS gating reads to platform users only. That protects
  against tenant-session exfiltration but not against a compromised
  platform user or accidental backup exposure. Move to Supabase
  Vault: the column shape accommodates a vault-ref pattern
  (`{ "vault_secret_id": "abc-..." }`) without a schema change, so
  the swap is app-level. Order of operations: stand up Vault, write
  all existing credentials to Vault, update the save path to write
  vault refs instead of inline values, update the server-side
  delivery/test path to resolve vault refs, drop any inline values
  still present, document the new posture in
  `supabase/migrations/016_tenant_integrations.sql`'s header.
- **Server-side delivery paths (Edge Functions).** Every provider
  needs a server-side wrapper so credentials never leave the DB
  for a live call. Minimum set:
    - `stripe.create_customer` / `stripe.create_subscription`
    - `dailyco.create_room` / `dailyco.create_meeting_token`
    - `resend.send_email` (called by Phase 6 send wiring)
    - `twilio.send_sms`
    - `labcorp.order_panel` (and the inbound result ingest)
    - `stripe_identity.create_verification_session`
    - `shippo.create_shipment` / `shippo.create_label`
  Each reads `tenant_integrations.credentials` with a service-role
  key, constructs the provider call, handles the response, and
  writes `last_connected_at` / `last_error` back. Expose minimal
  RPCs to the browser so admin/portal code never touches secrets.
- **Webhook router.** External providers POST back to Pulse with
  status updates (Stripe checkout completed, Twilio message
  delivered, Shippo label printed, Labcorp result ready). Build a
  single webhook receiver Edge Function that:
    1. Extracts the tenant from the URL path (`/webhooks/{provider}/{slug}`)
       or from provider metadata (e.g. Stripe customer metadata's
       `tenant_id`).
    2. Looks up `tenant_integrations.credentials.webhook_secret`
       to verify the payload signature.
    3. Dispatches to a per-provider handler.
  Store each raw webhook event in a new `webhook_events(tenant_id,
  provider, event_type, payload, received_at, processed_at, error)`
  table so replay and debugging work.
- **Test-connection stub → real ping.** The Integrations tab's Test
  button optimistically stamps `last_connected_at` today. Replace
  with an RPC that the server implements per-provider (matches the
  `test_action` key declared in each catalog entry). The RPC reads
  credentials, makes a read-only probe call (Stripe: retrieve
  account; Daily: fetch domain; Resend: list domains), returns
  success/error, and writes `last_connected_at` or `last_error`
  back. Until the RPC lands, the button's warn-toast makes the
  stub status explicit to the operator.
- **Inbound Labcorp result ingest.** Labcorp posts results back
  via webhooks once orders complete. Build the handler after the
  generic webhook router above. Store results in a new
  `lab_results(tenant_id, patient_id, panel, result_data, received_at)`
  table, notify the clinician queue, surface on the patient chart.
- **Stripe Customer Portal embed.** Phase 9 billing needs the
  Customer Portal link generated per-tenant. Add a
  `stripe.create_billing_portal_session` RPC to the integrations
  server-side layer; the admin portal generates + redirects when
  a member clicks "Manage subscription".
- **Error-state recovery UX.** When `status='error'`, surface the
  last error prominently on the integration card plus a "View
  failures" link that shows recent `webhook_events` rows where the
  handler errored. Helps ops diagnose a down integration without
  SSHing into logs.

### Carry-over from Phase 8

- **State-restriction read sites.** `Compliance.tenantOperatesIn`
  is available in admin + portal, but nothing gates on it yet. Key
  read-sites to wire:
    - Member intake submit: reject if the member's state isn't in
      the tenant's operating states. Surface a specific "We don't
      currently operate in {state}" message, not a generic error.
    - Checkout: block cart submission in unsupported states.
    - Clinician assignment: combine with
      `Compliance.cliniciansLicensedIn(memberState)` +
      `Workflow.get('assignment.respect_state_license')` to narrow
      the assignable pool. Admin portal currently ignores the
      license check; this is where the Phase 5 assignment carry-
      over intersects with Phase 8.
- **Data export endpoint per tenant.** PHASES.md Phase 8 lists a
  GDPR/HIPAA-contract data export as a deliverable. Build a
  platform-triggered Edge Function that: (1) verifies the caller
  is platform_admin+, (2) collects all tenant-scoped rows across
  every Phase 0-8 table into a zip (CSV per table + consent
  signatures as PDFs if signed), (3) uploads to a time-limited
  signed URL, (4) writes an audit_logs entry. Triggered from a
  new "Export data" button on the Compliance tab.
- **License expiry notifications.** `licensesExpiringWithin`
  returns the expiring rows but no automation fires on them. Wire
  a daily scheduled job that checks for 60/30/7-day expiries and
  sends the clinician + their tenant admins a notification via
  the Phase 6 messaging layer (add the `license.expiring` template
  to the default catalog). Requires the Phase 6 delivery wiring
  to be done first; coordinate with the Phase 6 trigger-refactor
  carry-over.
- **License CRUD on the clinician profile.** The Compliance tab
  surfaces licenses read-only because editing is a per-clinician
  concern, not per-tenant. Add a Licenses section to the clinician
  profile surface (admin.html user detail + clinician-mode
  portal.html own-profile view) with add/edit/archive + document
  upload to the `brand-assets` or a new `license-docs` storage
  bucket.
- **Consent signatures table.** The schema versions consent
  templates but nothing records which member signed which version.
  Add `member_consent_signatures(user_id, tenant_id, consent_id,
  signed_at, ip_address, user_agent)` with RLS allowing the member
  to read their own and tenant admins to read all. Hook into member
  intake so signing a required consent writes the signature row.
- **User-label resolution in Licenses summary.** The Licenses
  section shows "User &lt;id-prefix&gt;…" because resolving the
  profile display name cross-tenant isn't trivial (operator hasn't
  necessarily cached profiles for this tenant). Add a small bulk
  profile fetch keyed by user_id when the tab loads, or wait for
  Phase 13's view-as console which does the same cache lookup.
- **Per-location hours editor.** The `tenant_locations.hours` JSONB
  column holds operating hours but the UI doesn't render or edit
  them yet. Design the hours editor when a tenant first asks for
  it — until then, the field is documented in the schema for
  future use.
- **Archived locations visibility.** Archived locations are hidden
  from the operator view today. Add a "Show archived" toggle and a
  small-print footer like "3 archived" so deliberate hide-vs-delete
  is discoverable.

### Carry-over from Phase 9

- **Stripe sync — inbound (webhooks).** The `tenant_subscriptions`
  and `module_entitlements` tables can be populated manually today.
  Real billing flow should have Stripe drive state via webhooks:
  `customer.subscription.created/updated/deleted`,
  `invoice.payment_succeeded/failed`, `customer.subscription.
  trial_will_end`. Each event looks up the tenant by
  `stripe_customer_id`, updates the matching row. Build on Phase 7's
  webhook router carry-over.
- **Stripe sync — outbound (changes flow back).** When an operator
  assigns a plan or switches cycle on the per-client Billing tab,
  that should call a server-side RPC that updates the Stripe
  subscription (proration, cycle change, cancel scheduling) — NOT
  just the DB row. Today the tab is DB-only; Stripe's out of sync
  the moment anyone touches it. Add
  `stripe.update_subscription(tenant_id, plan_id, cycle)` to the
  Phase 7 server-side layer; wire the Billing tab's Save button
  through it.
- **Customer Portal embed.** PHASES.md explicitly says "Use Stripe
  Customer Portal link for invoicing UI — don't rebuild it." Add a
  server-side RPC (`stripe.create_billing_portal_session`) that
  returns a short-lived portal URL; surface a "Manage subscription"
  button on the tenant admin's own billing screen (admin.html, not
  platform.html) that redirects there. Keeps Pulse out of the
  invoice-rendering business.
- **Feature-gate refactor.** `Modules.isEnabled()` is plumbed into
  admin.html + portal.html but no read-site reads it yet. Known
  gates to add when the per-module UI work lands:
    - `live_video`: gates the video-consult button in the member
      portal and the "Create video appointment" action in admin.
      Requires the Daily.co integration (Phase 7) connected too;
      both gates should be AND-ed.
    - `e_prescribing`: gates the prescribe flow; without, the
      clinician writes a standard Rx record instead of transmitting.
    - `labs`: gates the labs tab in admin + the lab results section
      on the member chart.
    - `advanced_analytics`: gates the Analytics top-level tab in
      admin.html (collapse to "basic" view when off).
    - `multi_location`: gates the Locations UI and the
      per-location picker on member intake.
    - `white_label`: gates Pulse attribution in portal.html footers
      (when on, hide "Powered by Pulse"; when off, show it).
    - `custom_sso`: gates the SSO config panel inside admin.html's
      tenant self-serve surface (which itself is a future feature).
- **Plan CRUD on the operator portal.** Plans are seeded by the
  migration; the top-level Modules tab shows plan chips but there's
  no UI to add/edit/archive plans. Add a Plans editor (inside the
  top-level Modules tab or its own surface) with the same pattern
  as the Compliance tab's sections — list, inline form, archive.
  Important: editing a plan's `included_modules` array should NOT
  silently revoke entitlements from existing tenants on that plan;
  either prompt the operator or require an explicit sync step.
- **Proration semantics.** When a tenant changes plans mid-cycle,
  today nothing prorates anything — the DB row flips and the next
  invoice reflects the new price. Once Stripe sync lands, Stripe
  does the proration automatically. Document the behaviour in
  Billing tab copy so operators don't get surprised.
- **Trial expiry automation.** `expires_at` on `module_entitlements`
  is honoured by `Modules.isEnabled()` at read time (expired means
  disabled), but no job actively flips `enabled=false` when an
  entitlement expires. Add a nightly cleanup that sets
  `enabled=false` on expired rows so the DB state stays honest +
  audit trail reflects the auto-disable. Alternatively, rely on the
  read-time check alone and accept that
  `module_entitlements.enabled` might report stale data between the
  expiry moment and the cleanup — either approach is defensible.
- **Past-due escalation workflow.** The fleet Billing tab surfaces
  past-due subs in the churn-flags section, but nothing fires
  actions. Hook the Phase 6 messaging layer (once delivery wiring
  lands) to send a dunning template to the tenant admin on
  `past_due` status, escalating weekly.
- **Per-module analytics.** Which tenants use which modules HOW
  MUCH? `Modules.isEnabled` is binary; actual usage telemetry
  (live_video calls per month, labs ordered, api_access requests)
  would inform pricing and module consolidation. Belongs with Phase
  14 analytics work — note the cross-dependency.

### Carry-over from Phase 10

- **Write-site migration to structured snapshots.** Every platform.html
  write-site today writes its audit diff into the legacy `details`
  text column (as `JSON.stringify({from, to})`). Migration 019 added
  `before_snapshot` + `after_snapshot` JSONB columns; new write-sites
  should populate those. Known write-sites to refactor:
    - brand save → before = prev brand + legal_name; after = new
    - terminology save → before/after tenant.terminology map
    - workflow save → before/after workflow nested object
    - comms template save/reset → before/after {subject, body}
    - integration connect/disconnect → before/after config only
      (credentials stay OUT of audit per Phase 7 posture)
    - region toggle → before/after {state, is_allowed}
    - location add/update/archive → before/after the full row
    - consent version added → after only (insert of new version)
    - subscription assign/update/cancel → before/after the sub row
    - module entitlement toggle → before/after {enabled, source,
      expires_at}
    - lifecycle change → before/after {lifecycle_state}
  Do them in one PR so the Activity tab's diff view renders uniformly
  across all change types.
- **Shared audit helper.** Extract a `logAudit(action, changeType,
  targetId, before, after, details)` helper that every write-site
  calls, instead of inlining the `db.from('audit_logs').insert({...})`
  everywhere. Reduces the surface area for drift and standardises the
  column set. Best to ship alongside the write-site migration above.
- **Audit export.** Add an "Export CSV" button on the top-level Audit
  tab that writes the current filter result to a downloadable CSV.
  Required for tenants with compliance / SOC2 audit-trail obligations.
  CSV columns: timestamp, tenant slug, actor email, action,
  change_type, before JSON, after JSON.
- **Pagination for large fleets.** Both the Activity tab and the
  top-level Audit tab cap at 500 entries per fetch. Fine for Pulse
  today (<50 tenants, bounded audit volume); starts to bite once a
  tenant has > 500 config changes or the fleet has > 10 tenants with
  chatty configs. Add cursor-based pagination using
  `created_at DESC + id` when fleet-wide rows cross ~5000.
- **Change-type classifier for new actions.** The backfill CASE in
  migration 019 covers every action platform.html writes as of
  Phase 10 landing. New actions need BOTH a case in any future backfill
  (if historical rows exist) AND direct `change_type` on new writes.
  Forcing the helper above to take a required `changeType` arg is the
  cleanest way to never forget.
- **Actor resolution.** Audit rows store `actor_id` (uuid) +
  `actor_email` (text, often stale). On render we show the email
  when present. Cross-tenant profile-name resolution isn't implemented
  here — same limitation as the Compliance tab's Licenses section.
  Resolve together with Phase 13's view-as console, which needs the
  same profile-cache primitive.
- **Date-range filter on the Audit toolbar.** A common regulator-
  response query is "show me every state-restriction change for this
  tenant in the last 90 days." That works today by scrolling, but a
  date filter saves time. Add to the audit toolbar when the next
  regulator request comes in; defer until there's a real use case.

### Carry-over from Phase 11

- **QA preview iframes.** PHASES.md calls for "Final step: QA preview
  embeds the 3 downstream portals in iframes for visual review."
  Today the Launch step shows a checklist + Activate button; iframes
  are not rendered. Same blocker as the Phase 2 brand-preview iframe
  carry-over: downstream portals need to accept an operator preview
  session (auth bypass + brand injected via query string or
  postMessage) before an iframe of them is useful. Resolve together
  with Phase 13's view-as console, which needs the same primitive.
- **Step-level required-field validation.** Each step's `completed`
  predicate today checks a single minimum signal (brand has wordmark
  OR logo; compliance has operating-state + primary-location). Richer
  validation — "catalog has at least one active protocol priced above
  $0", "billing subscription has current_period_end in the future" —
  lands as the real tenants come online and reveal what actually
  matters to activate safely. Extend the predicates as you learn;
  don't pre-empt.
- **Resume affordance beyond the "Onboard" button.** Sandbox tenants
  surface an inline Onboard button in the Clients table. A tenant
  mid-onboarding who gets switched to suspended (e.g. failed payment
  during trial-conversion) loses the button but keeps the incomplete
  state. Add "Resume onboarding" to the client detail header when
  any step incomplete, regardless of lifecycle.
- **Step-skip audit trail.** Jumping to the Launch step with
  incomplete items then activating anyway (if platform_super_admin
  overrides) should be an explicitly flagged audit event —
  `tenant.activated_with_incomplete_onboarding` with the list of
  unchecked steps. Not implemented today; current Activate button
  is disabled when checks fail rather than overrideable. If ops asks
  for the override path, add it with the loud audit entry.
- **Save-between-steps semantics.** The Next button doesn't save
  the current step's form automatically — that was a deliberate
  choice so operators can browse without accidentally persisting
  half-typed state, but it means jumping between steps without
  pressing the tab's own Save loses anything entered. Consider a
  "Save draft" vs "Save + continue" split on each step's form, or an
  unsaved-changes warning on Next. Defer until a user actually
  complains about losing work.
- **Wizard state link.** No deep-link to a specific step today
  (`platform.html#wizard/<tenant>/step-4`). Low priority — wizards
  are typically opened from the Clients table, worked through, and
  closed. Add if the onboarding flow grows long enough that
  operators want to resume at the specific step they left off.

### Carry-over from Phase 12

- **Conflict UI on apply.** Applying a template to a tenant with
  existing config silently merges layers (template keys overwrite
  tenant keys; untouched tenant keys stay) and swallows per-row
  unique-violations on seeds. That's the right default for a sandbox
  tenant, but an operator applying to a configured tenant should see
  "These layers will overwrite: brand, terminology. These seeds skip
  because keys already exist: 3 protocols, 1 consent." Add a pre-
  flight diff dialog to the Apply picker.
- **Richer seed coverage.** The initial seed shape covers the six
  most impactful tables (catalog rows, comms, regions, consents).
  Tables not yet templated: `tenant_integrations` (credentials
  intentionally excluded per Phase 7 posture, but `config` bag +
  provider slot could seed), `tenant_locations` (address + hours
  shape), `tenant_subscriptions` default plan reference, default
  `module_entitlements`. Extend the snapshot + apply + save paths
  together when a real tenant needs one of them.
- **Template versioning.** Templates are replaced in-place today
  (save with an existing key UPDATE via ON CONFLICT during the
  seed migration, but the app-level save flow rejects on duplicate
  key). Adding a `version` column + treating saves as new versions
  would let operators evolve a template without breaking past
  applications. Shape is already in migration 020's rollback notes
  for future extension. Wait for the second iteration to
  demonstrate the need.
- **Template export / import.** A template is just a JSONB blob —
  export it as a .json file so a template authored on one Pulse
  install can be loaded into another (sales demo env → prod, say).
  Quick follow-up: add an Export button on each card that downloads
  `config_snapshot` as JSON, and an Import dropzone that pastes the
  blob into the save-template form pre-populated.
- **Apply-in-wizard step.** Today the wizard doesn't have a
  "Choose template" step — the picker lives on the create-client
  form instead. Operators who open the wizard on an existing
  tenant can't apply a template from within the wizard. Low
  priority since the top-level Templates tab covers that path,
  but if operators ask "can I apply a template to a tenant mid-
  wizard?", add step 0.5 between Basics and Brand.
- **Source-tenant attribution.** `source_tenant_id` is populated on
  save-as-template but not surfaced in the Templates list UI. Adding
  "Saved from: Acme Health" to each template card gives operators
  context on where an opinionated template came from.
- **Test-apply / dry-run.** No way to preview what a template will
  apply without actually applying it. A "Dry run" action that runs
  through the merge logic and returns the diff + seed counts without
  writing would reduce risk on unfamiliar templates. Pairs naturally
  with the conflict UI above.

### Carry-over from Phase 13

- **True view-as.** The Diagnostics tab's view-as strip opens the
  downstream portal in a new tab as the OPERATOR's authenticated
  user. Useful for "what does this tenant's surface look like" but
  NOT for "what does a tenant_clinician at this tenant see" — the
  operator's own permissions don't reproduce the tenant-staff render
  path. Real view-as needs the downstream portals to accept an
  operator preview session with tenant context injected and auth
  bypassed for read-only. Same blocker as Phase 2 brand preview +
  Phase 11 launch-step QA iframes; resolve together with a single
  `preview_session.js` primitive the downstream portals opt into.
- **Real operator actions.** Three stubs today:
    - Resend welcome writes an audit entry but doesn't actually send
      anything. Needs Phase 6 delivery wiring.
    - Reset workflow DOES reset (writes `{}` to `tenants.workflow`)
      with audit, but only full reset; per-section would be nice.
    - Flush cache is operator-side only — resets the operator's
      in-memory helper caches. Doesn't affect the tenant's own
      portals; each tenant portal re-fetches on next page load.
      If a tenant admin reports "I saved but the portal still shows
      old config," the fix is typically a hard refresh on their end.
      Document in the ops runbook.
- **Additional operator actions to add** (driven by what real
  onboardings surface):
    - Force member re-enrolment (soft-delete patient_enrollments row,
      member re-walks intake on next login).
    - Re-seed from template from Diagnostics (shortcut; Templates tab
      already does this).
    - Cache-bust hint (generates a cache-busted link operators can
      email tenant admins).
    - Regenerate Stripe Customer Portal session (once Phase 7/9
      Stripe wiring lands).
- **Support ticket notes / assignee.** `support_requests` today is
  (type, message, status). Add `assigned_to` (user_id FK), plus
  `internal_notes` (text) and `resolution_summary` (text). Surface
  on the expanded row: notes editor + assignee dropdown. Keeps ops
  conversations inside Pulse.
- **Ticket → email echo.** When an operator resolves a ticket, send
  an auto-generated "Your request was resolved" email via the
  Phase 6 messaging layer. Belongs with Phase 6 delivery carry-over.
- **SLA tracking on support tickets.** Use
  `Workflow.get('sla_hours.message_response')` (24h default) as the
  response target. Show ticket age on rows; colour-code red when
  over SLA; red dot on the sidebar Support nav item when any tenant
  has an over-SLA ticket.
- **Impersonation audit.** The current view-as links don't write an
  audit entry — they're plain anchors. Once true view-as lands, every
  session open writes `support.view_as_started` and the close writes
  `support.view_as_ended`. Required for regulator "who looked at
  patient X's data when" questions.

### Carry-over from Phase 1

- `admin.html` and `portal.html` still define their own `:root` blocks
  inline. They should `<link rel="stylesheet" href="tokens.css">` and
  delete the duplicated tokens. Safe to do in the Phase 2 PRs that
  refactor those portals for brand config, since those PRs already
  visit each portal's `<head>`. Until then, duplicate definitions are
  harmless — the portal's inline `:root` wins for any token defined in
  both places, so nothing regresses.
- "Plan" column on the Clients table is deferred to Phase 9 (when the
  `plans` / `tenant_subscriptions` tables land) rather than carrying a
  placeholder value that communicates nothing.
