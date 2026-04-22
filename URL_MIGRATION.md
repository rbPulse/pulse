# URL migration manifest — R2a

Working document for the R2c sweep. Catalogs every hardcoded URL
reference across the remaining root files, categorises by intent,
and declares the target URL. R2c executes this table.

## Scope

After the R1 rename + file deletions, the following root files
still contain URL references that need updating:

- `admin.html`
- `portal.html`
- `consultation.html`
- `checkout.html`
- `quiz.html`
- `index.html`
- `unite/index.html`
- `messaging.js` (template variables)

## Categories

Every reference falls into one of five categories:

1. **Auth redirect** — redirect on sign-out, session expiry, or
   missing role. Target: the universal root router at `/`.
2. **Role dispatch** — post-auth redirect to the correct portal for
   this user's role. Target: role-resolved tenant path.
3. **Flow transition** — purposeful in-app navigation (consult →
   checkout, etc.). Target: tenant-scoped path.
4. **Nav link** — "Back to home" style `<a>` tags. Target: either
   `/` or the Pulse tenant landing, depending on intent.
5. **Computed URL** — `new URL(…)` constructs, typically for inclusion
   in email bodies. Target: needs to resolve to the right tenant's
   portal regardless of where the code runs from.

---

## Manifest

### Auth redirects → `/` (universal router)

| File | Line | Current | Notes |
|---|---|---|---|
| `admin.html` | 1536 | `'index.html'` | auth-gate fallback |
| `admin.html` | 1581 | `'index.html'` | non-admin catch |
| `admin.html` | 3598 | `'index.html'` | `doSignOut` |
| `portal.html` | 6881 | `'index.html?session_expired=1'` | session expiry path |
| `portal.html` | 6883 | `'index.html?session_expired=1'` | session expiry path |
| `portal.html` | 7550 | `'index.html'` | `doSignOut` |
| `portal.html` | 7556 | `'index.html'` | auth catch |
| `portal.html` | 20300 | `'index.html'` | `doSignOut` |
| `portal.html` | 20343 | `'index.html?session_expired=1'` | session expiry |
| `unite/index.html` | 1218 | `'index.html'` | auth-gate fallback |
| `unite/index.html` | 1257 | `'index.html'` | denied fallback |
| `unite/index.html` | 1332 | `'index.html'` | general catch |

**Rewrite rule:** every `'index.html'` used as an auth destination becomes `'/'`. The `?session_expired=1` query string is preserved; the router honours it.

### Role dispatch → `/t/{slug}/admin/` or `/t/{slug}/portal/`

| File | Line | Current | Target |
|---|---|---|---|
| `admin.html` | 1554 | `'portal.html'` | `/t/pulse/portal/` |
| `admin.html` | 1578 | `'portal.html'` | `/t/pulse/portal/` |
| `portal.html` | 7578 | `'admin.html'` | `/t/pulse/admin/` |
| `consultation.html` | 4128 | `'admin.html'` | `/t/pulse/admin/` |
| `consultation.html` | 4132 | `'portal.html'` | `/t/pulse/portal/` |
| `consultation.html` | 4156 | `'portal.html'` | `/t/pulse/portal/` |
| `consultation.html` | 4393 | `'portal.html'` | `/t/pulse/portal/` |
| `consultation.html` | 3599, 3601, 3635, 3638 | `'portal.html'` | `/t/pulse/portal/` |
| `index.html` | 1983 | `window.location.origin + path + 'admin.html'` | `/t/pulse/admin/` |
| `index.html` | 1987 | `window.location.origin + path + 'portal.html'` | `/t/pulse/portal/` |

**Rewrite rule:** role dispatch inside a Pulse-context file hardcodes `/t/pulse/`. The universal router at `/` does smarter dispatch (reads session → profile → tenant membership → correct slug) and replaces most of these paths. Intermediate dispatch sites left in place until R2c can prove the router handles them.

### Flow transitions — stay tenant-scoped

| File | Line | Current | Target |
|---|---|---|---|
| `portal.html` | 7614 | `'consultation.html'` | `/t/pulse/consultation/` |
| `portal.html` | 7768 | `'consultation.html'` | `/t/pulse/consultation/` |
| `portal.html` | 7772 | `'consultation.html?new=1'` | `/t/pulse/consultation/?new=1` |
| `portal.html` | 7823 | `'consultation.html'` | `/t/pulse/consultation/` |
| `portal.html` | 7828 | `'consultation.html'` | `/t/pulse/consultation/` |
| `portal.html` | 5280 | `href="consultation.html"` (CTA) | `/t/pulse/consultation/` |
| `portal.html` | 5542 | `href="consultation.html"` (CTA) | `/t/pulse/consultation/` |
| `checkout.html` | 54 | `href="consultation.html"` (back) | `/t/pulse/consultation/` |
| `checkout.html` | 96 | `href="consultation.html"` (back) | `/t/pulse/consultation/` |
| `index.html` | 892, 907, 1088, 1134, 1242, 1380, 1392, 2164 | `href="consultation.html"` / `?new=1` | `/t/pulse/consultation/` |
| `index.html` | 1823 | querySelector for `[href="consultation.html?new=1"]` | `[href="/t/pulse/consultation/?new=1"]` |
| `index.html` | 1923–1924 | computed `consultation.html?new=1` | `/t/pulse/consultation/?new=1` |

**Rewrite rule:** all Pulse-internal flow links land at `/t/pulse/...`. When the file itself moves (R2c), these become relative paths like `./consultation/` or absolute `/t/pulse/consultation/` — the latter is more robust against future moves.

### Nav links → Pulse tenant landing at `/t/pulse/`

| File | Line | Current | Target | Reason |
|---|---|---|---|---|
| `admin.html` | 554 | `href="index.html"` | `/t/pulse/` | nav-brand home link |
| `portal.html` | 5133 | `href="admin.html"` | `/t/pulse/admin/` | admin badge jump |
| `consultation.html` | 773, 777 | `href="index.html"` | `/t/pulse/` | nav + back-to-home |
| `consultation.html` | 821 | `href="index.html"` ("Return to Pulse") | `/t/pulse/` | return to Pulse landing |
| `consultation.html` | 1433 | `href="index.html"` (Return Home) | `/t/pulse/` | return home |
| `consultation.html` | 4315 | `href="index.html"` (Return Home) | `/t/pulse/` | withdrawal-flow return |
| `checkout.html` | 50 | `href="index.html"` | `/t/pulse/` | nav-brand home |
| `quiz.html` | 189, 195 | `href="index.html"` | `/t/pulse/` | nav + back-to-site |
| `quiz.html` | 574, 595 | `href="index.html#pods"` | `/t/pulse/#pods` | anchor link to Pulse landing section |
| `quiz.html` | 575, 596 | `window.location='index.html#waitlist'` | `/t/pulse/#waitlist` | anchor link |
| `quiz.html` | 619 | `href="index.html#waitlist"` | `/t/pulse/#waitlist` | anchor link |

**Rewrite rule:** every nav "home" link goes to the Pulse tenant landing (`/t/pulse/`). Not to the universal router at `/`. Distinguish carefully — these are "return to the clinic you came from," not "return to the sign-in screen."

### Computed URLs (email bodies, `new URL(...)` calls)

| File | Line | Current | Notes |
|---|---|---|---|
| `consultation.html` | 1455 | Supabase `redirectTo: origin + '/consultation.html'` | needs `origin + '/t/pulse/consultation/'` |
| `consultation.html` | 3879 | `new URL('portal.html', window.location.href).href` | `new URL('/t/pulse/portal/', window.location.href).href` |
| `portal.html` | 12337 | same pattern | same |
| `portal.html` | 17719 | same pattern | same |
| `portal.html` | 18902 | same pattern | same |
| `portal.html` | 19171 | same pattern | same |
| `portal.html` | 20678 | same pattern | same |
| `portal.html` | 20686 | same pattern | same |
| `index.html` | 1937, 1940 | Supabase `redirectTo: new URL('portal.html', …)` | `new URL('/t/pulse/portal/', …)` |

**Rewrite rule:** `new URL('portal.html', …)` constructs are typically going into email-template substitution — the resulting URL is what the recipient clicks. These must resolve to the CORRECT tenant's portal, not the sender's file path. Post-R2c all Pulse-originated templates produce `/t/pulse/portal/`. When a future tenant sends, their portals produce `/t/{their-slug}/portal/`. Consider replacing with `Tenant.portalUrl()` helper that reads from `window.Tenant.slug` — future-proof against this same pattern breaking again.

### Unite view-as links (already tenant-parameterised)

| File | Line | Current | Target |
|---|---|---|---|
| `unite/index.html` | 1577 | `slug === 'pulse' ? '/portal.html' : '/t/' + slug + '/portal.html'` | `'/t/' + slug + '/portal/'` (drop the Pulse special-case) |
| `unite/index.html` | 1578 | same shape for admin | `'/t/' + slug + '/admin/'` |

**Rewrite rule:** the `slug === 'pulse'` branch was the root-URL accommodation for Pulse. Once Pulse moves in R2c, the branch becomes dead code and should go.

### `messaging.js` template variables

`{{portal_url}}` is a template variable, not a hardcoded URL. It's populated by the sender at delivery time. No change needed in `messaging.js` itself. The sender (Phase 6 delivery carry-over) must pass `portal_url` scoped to the recipient's tenant: `/t/{slug}/portal/`. Same applies to any future `{{admin_url}}` / `{{consultation_url}}` variables.

### Supabase-side URLs (outside the repo)

The Supabase dashboard has `Site URL` and `Redirect URLs` settings used for magic-link + OAuth callbacks. Currently configured for the root URLs (`https://.../portal.html`, `https://.../admin.html`). R2c must also update Supabase's allow-list:

- Add `https://<host>/t/pulse/portal/`
- Add `https://<host>/t/pulse/admin/`
- Add `https://<host>/t/pulse/consultation/`
- Add `https://<host>/` (for the universal router)
- Add `https://<host>/unite/` (platform ops)
- Remove root-level entries once R2f retires the redirects

**Not done automatically.** Requires manual dashboard update. Flag in the R2c execution checklist.

---

## Ambiguities + decisions

1. **`index.html` means two things today.** As an auth redirect: go to sign-in. As a nav link: go to Pulse's marketing landing. R2c must disambiguate at EACH call site. The manifest above already splits them; execute by category, not by blind find-replace.

2. **`?session_expired=1` query string.** Currently passed to `index.html`. The universal router at `/` must honour this and render the "your session expired" messaging. Confirm in R2d that the router handles it.

3. **Helper abstraction (`Tenant.portalUrl()` etc.).** Several of the computed-URL sites have the same shape. A single helper on `window.Tenant` that builds tenant-scoped URLs would prevent this class of drift recurring. Not required for R2c but recommended — add in R2c as part of the sweep. Signature:
   ```
   Tenant.url('portal')        → /t/{slug}/portal/
   Tenant.url('admin')         → /t/{slug}/admin/
   Tenant.url('consultation')  → /t/{slug}/consultation/
   Tenant.url('checkout')      → /t/{slug}/checkout/
   Tenant.url('home')          → /t/{slug}/
   ```

4. **Absolute vs relative paths.** Files moving into `/t/pulse/` can use relative paths (`./consultation/`, `../admin/`) OR absolute paths (`/t/pulse/consultation/`). Absolute is more robust against files moving further in the future (wizard flow into a subfolder, etc.) but couples to the exact path structure. **Decision: use absolute for cross-file navigation (admin ↔ portal ↔ consultation ↔ checkout). Use relative for fragment links (`#pods`, `#waitlist`) and same-file navigation.**

5. **Deep-link backwards-compat.** Existing bookmarks like `/admin.html` and `/portal.html` must keep working during the transition. R2c ships redirect stubs at each old URL (same pattern as `platform.html` → `/unite/`). R2f retires the stubs after 30 days of no traffic.

---

## Execution order inside R2c

1. Stand up the new `/t/pulse/` directory.
2. Copy each Pulse file into its new path (`admin.html` → `/t/pulse/admin/`, etc.). Fix asset paths (`../../tokens.css`, etc.).
3. Add the `Tenant.url(kind)` helper to `tenant.js`.
4. Sweep all the URL references per this manifest, referring back to the category rules. Checkbox each row as it's swept.
5. Add redirect stubs at the old root paths (`admin.html`, `portal.html`, `consultation.html`, `checkout.html`, `quiz.html`).
6. Update Supabase redirect allow-list in the dashboard.
7. Manual QA pass on the flow: sign-in at `/`, land in correct tenant admin/portal, click through consultation → checkout, sign-out returns to `/`.
8. Ship.

Count: **~70 individual URL references across 7 files**. Most are 1-line replacements. Helper extraction + sweep + redirects + Supabase config + QA ≈ one focused session.
