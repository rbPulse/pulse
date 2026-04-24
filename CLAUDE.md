# CLAUDE.md — Unite Platform (session handoff)

This file captures the full state of an in-flight architectural migration so any fresh Claude session can pick up without losing context. Read it fully before taking any action.

## What this codebase is

The Unite platform monolith. Pulse (peptide-delivery clinic) runs as tenant #1 inside it at `/t/pulse/`. The platform layer and the tenant layer share code today — untangling them is the explicit architectural work in progress (Stages A–E below).

Key mental model (see "Strategic plan" for detail):
- **Unite** = platform control plane (cross-tenant)
- **Pulse** = a tenant operating on Unite
- **Marketing** = separate (Pulse brand marketing lives at `ryanlich1619/trypulse`, served at `trypulse.us` and `trypulse.pages.dev`)

## Codebase layout (today)

```
/                          Unite platform monolith (this repo)
├── index.html             Unite universal router
├── admin.html / portal.html / platform.html / checkout.html / stripe-return.html
├── app.js / tenant.js / brand.js / compliance.js / integrations.js / messaging.js
├── modules.js / terminology.js / workflow.js / deck.js / bg.js / pulse-client.js
├── styles.css / tokens.css / pulse-client.css / deck.css
├── t/pulse/               Pulse tenant code (marketing + 4 surfaces)
│   ├── index.html         Pulse marketing page (originally; now lifted to trypulse)
│   ├── portal/            Member portal
│   ├── admin/             Tenant admin (Pulse staff)
│   ├── consultation/      Intake flow
│   └── quiz/              Quiz/lead gen
├── unite/                 Unite control plane UI
├── supabase/              Edge functions + migrations
├── commandos / tst / app  (unclear, likely legacy — don't touch without investigating)
└── platform/              [UPCOMING Stage A] — service types, workflow engine
```

## Strategic plan (approved)

Full text saved at `~/.claude/plans/mighty-twirling-meerkat.md` in the previous session. If that doesn't carry forward, here's the condensed version:

### Phase 2 — Architectural framework

Three-layer system:
- **Unite** (platform control plane) — owns type system, registries, plans, integrations, audit baselines. Never touches a single tenant's business logic.
- **Tenant Admin** — composes a clinic from Unite's primitives. Defines services (the central unit). Configures access/delivery/continuity per service.
- **Portals** (member + clinician) — runtime renderers of service records.

The central primitive is **Service**, defined by three orthogonal policies:
- **Access** — how a member pays (one_time / subscription / credits / membership / hybrid)
- **Delivery** — how care happens (async_review / virtual_visit / in_person_visit / self_serve / hybrid)
- **Continuity** — what happens after first event (one_time_complete / refill_cycle / recurring_auto / reactivate_after / ongoing_engagement)

Three distinct objects:

| Object | Scope | Owner |
|---|---|---|
| **Service Type** | platform (code) | Unite engineering — closed registry of ~6-10 types |
| **Service Definition** | tenant (data) | tenant admin — an instance of a type |
| **Service Record** | member (data) | workflow engine — runtime state for one member × one definition |

### Phase 3 — Target state

Every Service Type declares **9 contracts**:
1. Identity (id, label, icon, clinical category)
2. Config schema (fields tenant edits)
3. Access policy bindings
4. Delivery policy binding (workflow state machine)
5. Continuity policy binding
6. Intake contract
7. Portal card contract
8. Clinician queue contract
9. Event contract

Initial type registry:
- `peptide_protocol` (Pulse today)
- `in_person_visit` (Botox, aesthetics) — Stage C forcing function
- `virtual_visit` (telehealth)
- `subscription_rx` (Semaglutide)
- `membership` (concierge)
- `one_time_order` (labs, supplement)

Cross-cutting primitives (not types): `wallet/credits`, `bundles`.

### Phase 4 — Pulse-safe migration sequence

```
Stage 0   Subdomain migration                           [DONE]
Stage A   Tables + engine + registry land dormant       [NEXT]
Stage A+  Pulse compatibility audit on paper            [planning]
Stage B   Tenant #2 onboarded end-to-end                [greenfield]
Stage C   in_person_visit live on Tenant #2             [greenfield]
Stage D   Admin composition UI for Tenant #2            [greenfield]
Stage E   Remaining service types registered            [greenfield]

═══════ DECISION POINT ═══════
User evaluates: is this what I want Pulse to become?

Stage F   (optional) Pulse shadow backfill
Stage G   (optional) Pulse read-path migration
Stage H   (optional) Pulse write-path migration
Stage I   (optional) Retire Pulse's legacy code
```

Core rule: **Pulse is untouched through Stage E.** All platform architecture is proven on a greenfield tenant first. Pulse migration is a separate decision after Stage E, reversible.

### Phase 5 — Confirmed decisions (all 12 open questions)

| # | Decision |
|---|---|
| 1 | Closed type registry (platform engineering builds new types) |
| 2 | `in_person_visit` is Stage C forcing function |
| 3 | Bounded workflow customization (types declare overridable params) |
| 4 | Wallet/credits is a primitive, not a type |
| 5 | Intake = type defaults (non-removable) + tenant additions |
| 6 | Multiple service records per member across types — yes |
| 7 | Clinician queue: SLA-first sort, type filter chips primary, patient filter secondary |
| 8 | Subdomain migration before all abstraction work |
| 9 | No Pulse feature freeze needed (Pulse-safe sequencing makes this moot) |
| 10 | Keep written non-goal boundary; ~95% coverage, not 100% |
| 11 | Each service type contributes default terminology keys; tenants override per key |
| 12 | Commit to Stages 0→E arc; Pulse migration (F-I) is a separate deferred decision |

## Stage 0 — shipped

| Item | Where |
|---|---|
| Platform infra | `iamunited.co` on Cloudflare Pages. 3 custom domains: `admin.iamunited.co`, `pulse.iamunited.co`, `iamunited.co` (apex). Wildcard skipped (free plan). |
| Repo migration | `rbPulse/pulse` → `ryanlich1619/unite` (via GitHub Import). Old repo archived — do NOT push there anymore. |
| Cloudflare Pages rewire | `unite` Pages project now points at `ryanlich1619/unite`. |
| Stripe Connect | Added `https://pulse.iamunited.co/stripe-return.html` to Redirect URIs (Unite's Stripe account). Old `rbpulse.github.io` URL still registered for cutover window. |
| Supabase Auth | Added `https://*.iamunited.co/*`, `https://pulse.iamunited.co/*`, `https://admin.iamunited.co/*`, `https://iamunited.co/*` to redirect allowlist. |
| Code fix | `STRIPE_OAUTH_REDIRECT` in `t/pulse/admin/index.html` + `stripe-return.html` fallback now domain-agnostic (base-aware helper). On branch `claude/debug-recurring-error-cGejN`. Not yet merged to main. |
| Marketing extraction | Pulse marketing lifted to `ryanlich1619/trypulse`, served at `trypulse.pages.dev`. Only `index.html` + 11 image assets. Paths and CTAs rewired to `https://pulse.iamunited.co/t/pulse/...`. |

## Parked items (not blocking Stage A)

- **trypulse.us returns 403** — Cloudflare security rule blocking. Content is fine at `trypulse.pages.dev`. Likely fix: Security → Bot Fight Mode off, or re-add custom domain in Pages.
- **DNS cutover** for `rbpulse.github.io/pulse/*` → new domains. Wait until announcing new URLs.
- **Flip `pulse.iamunited.co/` → `trypulse.us`** — depends on trypulse.us being reachable.
- **Delete `trypulse-seed` branch** on old `rbPulse/pulse` — trivial cleanup.
- **Merge `claude/debug-recurring-error-cGejN`** to main on `ryanlich1619/unite` — prep for future tenants, not urgent.
- **Pre-existing JS errors in the marketing page** — `toggleBtn is null` (theme switcher references a non-existent element), various GSAP `not found` warnings for legacy selectors like `.stat-item`, `.problem-img`. These exist in the original too; they're not blocking visual parity.

## Stage A — in flight

### What ships

Three deliverables, all dormant. Zero Pulse impact.

1. **DB migrations** introducing:
   - `service_types` (seed table, platform-owned; rows inserted by migration)
   - `service_definitions` (tenant-scoped; RLS mirrors `tenant_integrations`)
   - `service_records` (member-scoped; RLS mirrors `prescriptions`)
2. **Workflow engine module** — reads a service type's declared state machine, applies a transition, fires events into `events_outbox` (Phase 8), writes audit log.
3. **Service type registry module** — each type declares its 9 contracts. First type registered: `peptide_protocol` (Pulse's existing shape, declared against the new abstractions).

No backfill. No Pulse data touched. Tables are empty. Nothing reads or writes them. Reversible by dropping tables.

### Design decisions locked (D1–D6)

| # | Decision | Rationale |
|---|---|---|
| D1 | Platform code lives in new `platform/` directory at repo root | Keeps Unite primitives separate from tenant code (`t/pulse/`) and existing utilities |
| D2 | Workflow engine runs client-side (JS), RLS enforces permissions | Matches current Pulse architecture; lift specific transitions into edge functions later if needed for privileged ops |
| D3 | `service_types` is a DB table (not code-only) | FK integrity; service_definitions can't reference non-existent types |
| D4 | State machine lives in JS/TS code, not DB JSON | Source-controlled, tested, type-safe. DB only holds type identity. |
| D5 | RLS mirrors existing patterns verbatim | `service_definitions` = `tenant_integrations` pattern. `service_records` = `prescriptions` pattern. No innovation. |
| D6 | Migration file naming: verify existing convention at session start | Not yet investigated |

### Stage A sub-stages

Sub-stage | Deliverable
---|---
A1 | Design review (completed — D1–D6 locked) ✓
A2 | Migration files: `service_types`, `service_definitions`, `service_records` + RLS policies
A3 | Workflow engine module (state machine runner in `platform/workflow/`)
A4 | Service type registry module (`platform/service-types/`)
A5 | Register `peptide_protocol` (declare its 9 contracts)
A6 | Verification: migration applies cleanly, dormant registry compiles, no Pulse impact

### Next concrete action

1. Check `supabase/migrations/` for existing naming convention (e.g. `YYYYMMDD_description.sql` or incrementing numbers).
2. Propose exact schema DDL for the three tables + RLS policies.
3. Propose file structure under `platform/`.
4. User reviews, green-lights, code lands.

## Infrastructure reference

### GitHub
- **`ryanlich1619/unite`** — main platform repo (Unite + Pulse as tenant). Cloudflare Pages watches this. **Push here.**
- **`ryanlich1619/trypulse`** — Pulse marketing site. Cloudflare Pages watches this.
- **`ryanlich1619/pulse`** — empty placeholder for future Pulse-specific tenant-code extraction (if Stage A+ decides to split). Leave empty for now.
- **`rbPulse/pulse`** — old location. DO NOT PUSH HERE. Archived/frozen.

### Domains
- `iamunited.co` — Unite platform (Cloudflare-hosted DNS)
  - `admin.iamunited.co` → Unite control plane
  - `pulse.iamunited.co` → Pulse's operational surfaces (`/portal/`, `/consultation/`, etc.)
  - `<slug>.iamunited.co` → future tenants (added per-tenant at onboarding; no wildcard on free plan)
- `trypulse.us` — Pulse marketing (Cloudflare-hosted DNS, currently 403 at custom domain, live at `trypulse.pages.dev`)

### Cloudflare Pages projects
- `unite` — connected to `ryanlich1619/unite`, serves iamunited.co domains
- `trypulse` — connected to `ryanlich1619/trypulse`, serves trypulse.us / trypulse.pages.dev

### Supabase
Shared project for Unite + Pulse (+ future tenants). Multi-tenant via RLS — tenant isolation is by row, not by database. This is the correct architecture, not something to untangle.

Edge functions live in `supabase/functions/`. Migrations in `supabase/migrations/`.

### Stripe
Connect platform is registered under **Unite's** Stripe account (NOT Pulse's). Pulse is a Connected Account. When a new tenant subdomain goes live, add `https://<slug>.iamunited.co/stripe-return.html` to Connect → Redirect URIs.

### Other integrations
Resend, Twilio, Daily.co, Google OAuth — all per-tenant config via `tenant_integrations` table. No hardcoded platform-level values.

## Communication style (user preferences)

When the user needs to do something outside the codebase (click a button in a dashboard, edit a file, run a command on their local machine, configure a third-party service), follow these rules without being asked:

1. **Flat numbered steps.** Each step is one action: go here, click this, paste this. No parallel paths. No "then continue to step X unless condition Y."
2. **Exact names.** Exact URLs (with `https://`). Exact button text (e.g. "Save and Deploy" not "the save button"). Exact field values to paste.
3. **Explain jargon inline, first time it appears.** "CNAME (a DNS record type that aliases one domain to another)". "OAuth Redirect URI (the URL the auth provider sends users back to after login)". Don't assume the user knows platform-engineering vocabulary.
4. **Recommend one path, not a menu.** If there are multiple ways to do something, pick the simplest and say why briefly. Only offer options if the user pushes back or the trade-off genuinely matters.
5. **Split "you do" vs "I do" cleanly.** At the top of every multi-step block, say what the user is responsible for vs. what Claude will handle. Don't mix.
6. **Checkpoints.** After any action with a verifiable result, tell the user what to report back ("reply 'done' when green" / "tell me what error you see"). Don't stack multiple user actions back-to-back without a checkpoint in between unless they're trivially related.
7. **WHY before HOW.** One short sentence explaining what the action accomplishes, then the action itself. So the user understands what they're committing to before they click.
8. **No unnecessary shell.** Prefer GUI/web-UI paths over CLI when both work. Only give CLI commands if the user is already in a terminal context or asks for them.
9. **Don't narrate your reasoning.** The user doesn't need to see "I need to check whether X, let me grep for Y". They need to see the result or the next action.
10. **If you broke something, own it directly.** Say what was wrong, why it happened, what's now fixed. No hedging, no burying the lead.
11. **Parking-lot items are OK.** If something is blocked or tangential, name it, park it with a short "pick up later" note, and move on. Don't let side quests derail the main path.
12. **One screen per response when possible.** Long multi-phase instructions overwhelm. If a task needs 20 steps, break it into phases with stop points — do first 5 now, report back, get next 5.

### Avoid

- "You could try..." / "One option is..." — pick one and recommend it
- Technical terms used before defining them
- Mixing a question with a command ("Continue with X, but first do Y" — separate these)
- Claiming "this should work" without verification — either verify or say "I haven't verified this; try it and tell me what happens"
- Assuming the user remembers context from many messages ago — re-state key names / URLs when referencing them again

## Conventions

### Git workflow
- Push to `ryanlich1619/unite` main or feature branches. **Never push to `rbPulse/pulse`.**
- Feature branches: `claude/<short-description>` convention.
- Commit messages: descriptive, explain WHY not WHAT. No emojis unless user asks.
- No `--no-verify`, no bypassing signing, unless user explicitly asks.

### Code style
- Pulse-today is static HTML/CSS/JS — no build system. Cloudflare Pages serves the repo root.
- Inline `<style>` and `<script>` blocks inside HTML are the pattern.
- Shared utilities live at repo root as .js files.
- **Don't add abstractions beyond what the task requires.**
- **Don't add comments that explain WHAT. Only comments that explain WHY (non-obvious constraint, subtle invariant, workaround).**

### Terminology (Pulse ↔ Unite conflation avoided)
- "Unite" = the platform you're building
- "Pulse" = a tenant running on Unite
- "Unite admin" = cross-tenant platform admin
- "Tenant admin" = Pulse staff composing their clinic (may later be "Pulse admin" in that tenant's context)
- Keep these separate in all instructions.

## Session boundaries / sandbox constraint

This file exists because the previous Claude session's sandbox was authorized to push only to `rbPulse/pulse` (the old repo location, pre-migration). It could not push to `ryanlich1619/unite`. Fresh sessions started from within `ryanlich1619/unite` will have the correct push authorization.

When starting a fresh session: **read this file first**, then proceed. No context is lost if you do that.
