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
| 3–15  | Not started   | See sections above. |

### Carry-over from Phase 2

- `portal.html` accent color override. `portal.html` runs in two body
  modes (member-mode, clinician-mode) with namespaced `--m-*` / `--cl-*`
  accent tokens. Re-pointing the right variable for the right mode is
  a larger refactor than Phase 2's slice warranted. Do it as part of
  the next `portal.html` touch.
- Two `portal.html` wordmark instances live inside JS template strings
  (welcome-card brand ~line 14723, consult-reminder nav ~line 21093)
  and still read hardcoded "PULSE" because they render after the
  `applyTenantBrand()` hook fires. Rebuild those templates to read from
  `window.Tenant.brand.wordmark` when the template is built.
- `clinician.html` doesn't exist yet. Gets the same hook on creation.
- `portal.html` and `clinician.html` still carry inline `:root` blocks
  that duplicate `tokens.css` tokens (Phase 1 carry-over). Migrate
  alongside the brand touch above.
- Orphaned storage objects: replacing a logo uploads a new file with a
  timestamp suffix; the old file stays. Cleanup job belongs with the
  Phase 10 audit/retention work, not Phase 2.
- Live preview is a sandboxed render, not a real iframe of the downstream
  portal. That's fine for Phase 2 (covers the "iframe or sandboxed
  render" option in the plan). Upgrade to iframe previews alongside
  Phase 13's view-as console, where the downstream portals will learn
  to accept an operator preview session.

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
