// ═══════════════════════════════════════════════════════════════════════════
// workflow.js — shared tenant workflow config for every Pulse portal
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
//   Tenants run their clinical operations differently. One clinic
//   requires a live consult for every prescription; another accepts
//   async review. One refills 14 days before run-out; another waits
//   until 3 days out. Today those rules are scattered as magic numbers
//   and `if (role === ...)` checks across admin.html and portal.html.
//   This file is the single source of truth for the shape of the
//   workflow config (the SCHEMA below), the merged view of tenant
//   overrides on top of defaults (`Workflow.all()`), and the runtime
//   accessor portals call to read individual rules
//   (`Workflow.get('refill.eligibility_days_before_runout')`).
//
//   Zero-dependency, zero-framework — matches tenant.js and
//   terminology.js.
//
// HOW PORTALS USE IT
//   1. Load this file in <head> AFTER tenant.js so window.Tenant exists
//      by the time Workflow.init runs:
//        <script src="tenant.js"></script>
//        <script src="workflow.js"></script>
//   2. After TenantBootstrap.init resolves, call:
//        Workflow.init();
//   3. Read rules anywhere after init:
//        if (Workflow.get('refill.clinician_review_required')) { ... }
//        var slaHours = Workflow.get('sla_hours.refill_approval');
//        var consultPolicy = Workflow.get('consult.policy');
//
// STORAGE SHAPE
//   tenants.workflow is a JSONB object keyed by the sections below. All
//   fields are persisted (not just overrides) so the on-disk config
//   reflects what the tenant chose rather than what's missing. An
//   empty `{}` falls through entirely to defaults; a partial object
//   merges section-by-section.
//
// DESIGN CHOICES
//   - Rich SCHEMA catalog with types, defaults, options, validation.
//     The operator portal auto-renders the form from this catalog, so
//     adding a new rule is a one-place change here (and a read-site
//     change in whatever portal code uses it).
//   - Dot-path accessor (Workflow.get('section.field')) rather than a
//     flat key namespace. Keeps related rules visually grouped in
//     storage and in the UI.
//   - No interpolation, no derived values, no conditional defaults.
//     Rules are raw values. Derived workflow (e.g. "can this member
//     refill right now?") is computed at the call site from the rule
//     + runtime state.
//   - No backfill on init. A tenant with an empty workflow JSONB reads
//     every default; the JSONB fills up gradually as operators save
//     the form. Avoids a migration-shaped operation on every page
//     load.
//   - "Bad config impossible by construction" per PHASES.md: types
//     gate inputs, enums gate options, number fields have min/max.
//     Client-side validation mirrors these; there's no CHECK at the
//     DB level because enforcing nested JSONB shape in Postgres is
//     brittle — the app owns the shape, the DB stores the bag.
//
// ═══════════════════════════════════════════════════════════════════════════

(function () {
  'use strict';

  // ── Schema catalog ───────────────────────────────────────────────────────
  // Each section is a group of related rules rendered together in the
  // operator portal. `description` is written for a tenant admin who's
  // never seen Pulse internals; don't reference implementation details.
  var WORKFLOW_SCHEMA = [
    {
      section: 'intake',
      label: 'Intake',
      description: 'How new members start. Controls whether the intake questionnaire is required and who reviews it.',
      fields: [
        {
          key: 'required',
          label: 'Intake questionnaire required',
          type: 'bool',
          default: true,
          description: 'If on, new members must complete intake before being prescribed. If off, members can skip straight to a consult request (typically for tenants that do full evaluations live).'
        },
        {
          key: 'auto_approve_min_age',
          label: 'Minimum age for auto-approval',
          type: 'number',
          default: 18,
          min: 0, max: 120,
          description: 'Members younger than this need manual clinician review regardless of intake score.'
        }
      ]
    },
    {
      section: 'consult',
      label: 'Clinical consult',
      description: 'When and how clinicians review cases.',
      fields: [
        {
          key: 'policy',
          label: 'Consult policy',
          type: 'enum',
          default: 'required_for_first_rx',
          options: [
            { value: 'always_required',         label: 'Always required (every Rx)' },
            { value: 'required_for_first_rx',   label: 'Required for first Rx only' },
            { value: 'optional',                label: 'Optional (member can opt in)' },
            { value: 'none',                    label: 'No consults' }
          ],
          description: 'Sets the default rule. Individual protocols can still override (e.g. a controlled substance protocol may force a consult regardless).'
        },
        {
          key: 'allow_async_review',
          label: 'Allow async chart review',
          type: 'bool',
          default: true,
          description: 'If on, clinicians can review and approve from a chart without a live video call. Off forces a scheduled video consult for every review.'
        },
        {
          key: 'default_duration_minutes',
          label: 'Default consult duration (minutes)',
          type: 'number',
          default: 15,
          min: 5, max: 120,
          description: 'Suggested slot length when a clinician creates an appointment.'
        }
      ]
    },
    {
      section: 'refill',
      label: 'Refills',
      description: 'When members can request refills and who approves them.',
      fields: [
        {
          key: 'eligibility_days_before_runout',
          label: 'Eligibility window (days before run-out)',
          type: 'number',
          default: 7,
          min: 0, max: 90,
          description: 'How many days before a member runs out they can request a refill. Larger windows reduce no-medication gaps; smaller windows reduce stockpiling.'
        },
        {
          key: 'clinician_review_required',
          label: 'Clinician approval required for each refill',
          type: 'bool',
          default: true,
          description: 'If on, every refill request enters the clinician queue. Off enables auto-refill for protocols the clinician previously approved for standing orders.'
        },
        {
          key: 'max_refills_per_rx',
          label: 'Max refills per prescription',
          type: 'number',
          default: 3,
          min: 0, max: 24,
          description: '0 means unlimited. Resets when a new Rx is issued (typically after a follow-up consult).'
        }
      ]
    },
    {
      section: 'sla_hours',
      label: 'SLAs (hours)',
      description: 'Response-time targets. Cases that exceed these bubble up to the escalation queue.',
      fields: [
        { key: 'intake_review',      label: 'Intake review',      type: 'number', default: 24,  min: 1, max: 720, description: 'Time from intake submission to first clinician review.' },
        { key: 'message_response',   label: 'Message response',   type: 'number', default: 24,  min: 1, max: 168, description: 'Time from member message to clinician/staff reply.' },
        { key: 'refill_approval',    label: 'Refill approval',    type: 'number', default: 48,  min: 1, max: 168, description: 'Time from refill request to approval or denial.' },
        { key: 'escalation_ping',    label: 'Escalation ping',    type: 'number', default: 4,   min: 1, max: 72,  description: 'Internal ping sent this many hours before an SLA is about to breach.' }
      ]
    },
    {
      section: 'assignment',
      label: 'Case assignment',
      description: 'How incoming work is routed to clinicians.',
      fields: [
        {
          key: 'strategy',
          label: 'Assignment strategy',
          type: 'enum',
          default: 'round_robin',
          options: [
            { value: 'round_robin',   label: 'Round-robin across on-shift clinicians' },
            { value: 'least_loaded',  label: 'Least-loaded clinician' },
            { value: 'manual',        label: 'Manual (admin assigns each case)' }
          ],
          description: 'Round-robin is the simplest fair distribution; least-loaded balances by active caseload; manual is for small teams or specialised cases.'
        },
        {
          key: 'respect_state_license',
          label: 'Respect state license',
          type: 'bool',
          default: true,
          description: 'If on, only assign cases to clinicians licensed in the member\u2019s state. Off disables this check (use only for non-clinical or cash-pay workflows).'
        },
        {
          key: 'max_concurrent_per_clinician',
          label: 'Max concurrent cases per clinician',
          type: 'number',
          default: 150,
          min: 1, max: 1000,
          description: 'Soft cap used by the least-loaded strategy and surfaced to admins as a warning when a clinician exceeds it.'
        }
      ]
    },
    {
      section: 'follow_up',
      label: 'Follow-up',
      description: 'Automated check-ins after enrolment and after refills.',
      fields: [
        {
          key: 'cadence_days',
          label: 'General follow-up cadence (days)',
          type: 'number',
          default: 90,
          min: 0, max: 365,
          description: 'Automated outreach every N days. 0 disables general follow-up.'
        },
        {
          key: 'after_refill_check_days',
          label: 'Post-refill check-in (days)',
          type: 'number',
          default: 14,
          min: 0, max: 90,
          description: 'Days after a refill ships before the follow-up message goes out. 0 disables post-refill check-ins.'
        }
      ]
    }
  ];

  // Build a defaults object from the schema. Computed once at module
  // load; every init() call reuses it.
  var DEFAULTS = {};
  WORKFLOW_SCHEMA.forEach(function(section) {
    DEFAULTS[section.section] = {};
    section.fields.forEach(function(f) {
      DEFAULTS[section.section][f.key] = f.default;
    });
  });

  // Merged in-memory view. Null until init runs.
  var _merged = null;

  // Deep-merge tenant overrides on top of defaults. Tenant can override
  // a single field inside a section without having to resupply the rest
  // of the section's fields.
  function _mergeSection(defaults, overrides) {
    var out = {};
    for (var k in defaults) if (Object.prototype.hasOwnProperty.call(defaults, k)) out[k] = defaults[k];
    if (overrides && typeof overrides === 'object') {
      for (var k2 in overrides) {
        if (!Object.prototype.hasOwnProperty.call(overrides, k2)) continue;
        if (overrides[k2] !== null && overrides[k2] !== undefined) out[k2] = overrides[k2];
      }
    }
    return out;
  }

  function init() {
    var overrides = (window.Tenant && window.Tenant.workflow) || {};
    var merged = {};
    for (var section in DEFAULTS) {
      if (!Object.prototype.hasOwnProperty.call(DEFAULTS, section)) continue;
      merged[section] = _mergeSection(DEFAULTS[section], overrides[section]);
    }
    _merged = merged;
    return merged;
  }

  // Dot-path accessor. Unknown paths log once and return undefined —
  // same pattern as Terminology.t() so a typo at a call site surfaces
  // in console rather than silently returning some safe-looking value.
  var _missingLogged = {};
  function get(path) {
    var map = _merged || DEFAULTS;
    var parts = String(path).split('.');
    var cur = map;
    for (var i = 0; i < parts.length; i++) {
      if (cur == null || typeof cur !== 'object' || !Object.prototype.hasOwnProperty.call(cur, parts[i])) {
        if (!_missingLogged[path]) {
          console.warn('[workflow] unknown path', path);
          _missingLogged[path] = true;
        }
        return undefined;
      }
      cur = cur[parts[i]];
    }
    return cur;
  }

  // Returns the whole merged object. Useful for the operator portal's
  // Workflow tab, which renders every field; individual call sites
  // should prefer get() so they declare their dependency clearly.
  function all() { return _merged || init(); }

  function reset() { _merged = null; _missingLogged = {}; }

  window.Workflow = {
    init:     init,
    get:      get,
    all:      all,
    reset:    reset,
    SCHEMA:   WORKFLOW_SCHEMA,
    DEFAULTS: DEFAULTS
  };
})();
