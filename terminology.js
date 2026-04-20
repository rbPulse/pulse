// ═══════════════════════════════════════════════════════════════════════════
// terminology.js — shared terminology bootstrap for every Pulse portal
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
//   Each tenant can rename the nouns Pulse uses. "Member" becomes
//   "Patient" at a medical tenant; "Protocol" becomes "Plan" elsewhere.
//   This file is the single source of truth for which terms are
//   overridable (the catalog below) and the runtime accessor portals
//   call to read them (`Terminology.t('member')`).
//
//   Zero-dependency, zero-framework — matches tenant.js and composes
//   cleanly with the inline-JS portals that the rest of Pulse is
//   written in.
//
// HOW PORTALS USE IT
//   1. Load this file in <head>, AFTER tenant.js so window.Tenant exists
//      by the time Terminology.init runs:
//        <script src="tenant.js"></script>
//        <script src="terminology.js"></script>
//   2. After TenantBootstrap.init resolves, call:
//        Terminology.init();
//      This reads window.Tenant.terminology and merges it over defaults.
//   3. Read terms anywhere after init:
//        document.title = Terminology.t('member_portal');
//        Terminology.t('members');      // plural
//        Terminology.t('member', { lower: true });
//
// STORAGE SHAPE
//   tenants.terminology is a flat JSONB object keyed by the entries in
//   TERMINOLOGY_KEYS below. Operators fill in only the keys they want
//   to override — unset keys fall back to the bundled defaults. Example:
//     { "member": "Patient", "members": "Patients",
//       "protocol": "Treatment Plan", "protocols": "Treatment Plans" }
//
// DESIGN CHOICES
//   - Flat keys (not nested). Keeps JSONB reads cheap and the audit
//     diffs legible. Plurals are separate keys rather than `{singular,
//     plural}` tuples so the helper stays one-argument.
//   - Case handling in the caller. Terms are stored capitalised; if a
//     portal needs lowercase ("visit a member"), it passes `{lower:
//     true}` and the helper lowercases. This is simpler than storing
//     both cases or guessing at sentence position.
//   - No pluralisation rules. English plurals are irregular enough that
//     asking operators to specify both is safer than splitting on 's'.
//   - No interpolation. If a page needs "3 members", it does
//     `count + ' ' + Terminology.t(count === 1 ? 'member' : 'members')`.
//
// ═══════════════════════════════════════════════════════════════════════════

(function () {
  'use strict';

  // ── Catalog ──────────────────────────────────────────────────────────────
  // Every renameable term in Pulse. Keep this list tight — adding a key
  // means every portal has to audit for that term and route it through
  // Terminology.t(). When in doubt, leave a string hardcoded and add the
  // key later when a real tenant needs to override it.
  //
  // `group` buckets keys in the operator portal's Terminology tab so
  // operators see related terms together (e.g. all clinical artefacts).
  // `description` is the helper text rendered under the input — write it
  // for a tenant admin who's never seen Pulse, not for a developer.
  var TERMINOLOGY_KEYS = [
    // People ──────────────────────────────────────────────────────────────
    { key: 'member',       default: 'Member',       group: 'people',    description: 'End-user of the clinical service. Some tenants call them "patients" or "clients".' },
    { key: 'members',      default: 'Members',      group: 'people',    description: 'Plural of member.' },
    { key: 'clinician',    default: 'Clinician',    group: 'people',    description: 'Licensed provider. Some tenants prefer "provider", "doctor", or "practitioner".' },
    { key: 'clinicians',   default: 'Clinicians',   group: 'people',    description: 'Plural of clinician.' },
    { key: 'admin',        default: 'Admin',        group: 'people',    description: 'Clinic administrator. Rarely renamed.' },
    { key: 'admins',       default: 'Admins',       group: 'people',    description: 'Plural of admin.' },

    // Clinical artefacts ──────────────────────────────────────────────────
    { key: 'protocol',     default: 'Protocol',     group: 'clinical',  description: 'Treatment plan template. Some tenants use "plan", "program", or "regimen".' },
    { key: 'protocols',    default: 'Protocols',    group: 'clinical',  description: 'Plural of protocol.' },
    { key: 'consultation', default: 'Consultation', group: 'clinical',  description: 'Clinical intake/review event. Some tenants use "visit" or "appointment".' },
    { key: 'consultations',default: 'Consultations',group: 'clinical',  description: 'Plural of consultation.' },
    { key: 'prescription', default: 'Prescription', group: 'clinical',  description: 'Clinical order. Some tenants use "order" or "regimen".' },
    { key: 'prescriptions',default: 'Prescriptions',group: 'clinical',  description: 'Plural of prescription.' },
    { key: 'dose',         default: 'Dose',         group: 'clinical',  description: 'Individual medication event. Some tenants use "session", "administration", or "cycle".' },
    { key: 'doses',        default: 'Doses',        group: 'clinical',  description: 'Plural of dose.' },
    { key: 'refill',       default: 'Refill',       group: 'clinical',  description: 'Re-order of an existing prescription. Some tenants use "renewal" or "re-order".' },
    { key: 'refills',      default: 'Refills',      group: 'clinical',  description: 'Plural of refill.' },
    { key: 'appointment',  default: 'Appointment',  group: 'clinical',  description: 'Live video consult. Some tenants use "visit" or "session".' },
    { key: 'appointments', default: 'Appointments', group: 'clinical',  description: 'Plural of appointment.' },
    { key: 'intake',       default: 'Intake',       group: 'clinical',  description: 'Initial onboarding questionnaire. Some tenants use "screening" or "assessment".' },
    { key: 'intakes',      default: 'Intakes',      group: 'clinical',  description: 'Plural of intake.' },
    { key: 'note',         default: 'Note',         group: 'clinical',  description: 'Clinician-authored record. Some tenants use "chart note" or "progress note".' },
    { key: 'notes',        default: 'Notes',        group: 'clinical',  description: 'Plural of note.' },
    { key: 'message',      default: 'Message',      group: 'clinical',  description: 'Async clinical message. Some tenants use "chat" (careful if you already use "note").' },
    { key: 'messages',     default: 'Messages',     group: 'clinical',  description: 'Plural of message.' },

    // Workflow ────────────────────────────────────────────────────────────
    { key: 'enrollment',   default: 'Enrollment',   group: 'workflow',  description: 'State of being registered with the clinic. Some tenants use "registration" or "membership".' },
    { key: 'enrollments',  default: 'Enrollments',  group: 'workflow',  description: 'Plural of enrollment.' },
    { key: 'package',      default: 'Package',      group: 'workflow',  description: 'Bundled offering. Some tenants use "kit", "bundle", or "program".' },
    { key: 'packages',     default: 'Packages',     group: 'workflow',  description: 'Plural of package.' },

    // Commercial ──────────────────────────────────────────────────────────
    { key: 'plan',         default: 'Plan',         group: 'commercial', description: 'Subscription tier. Some tenants use "tier", "level", or "membership level".' },
    { key: 'plans',        default: 'Plans',        group: 'commercial', description: 'Plural of plan.' }
  ];

  // Flatten the catalog to a defaults map for O(1) lookup.
  var DEFAULTS = {};
  TERMINOLOGY_KEYS.forEach(function(entry) { DEFAULTS[entry.key] = entry.default; });

  // Group catalog into buckets, preserving order within each group. Used
  // by the operator portal to render the Terminology tab sectioned.
  var GROUPS = [
    { key: 'people',     label: 'People',                description: 'What a tenant calls its end-users, clinicians, and admins.' },
    { key: 'clinical',   label: 'Clinical artefacts',    description: 'Protocols, consultations, prescriptions, doses, and the rest of the clinical vocabulary.' },
    { key: 'workflow',   label: 'Workflow',              description: 'Enrolment, packaging, lifecycle language.' },
    { key: 'commercial', label: 'Commercial',            description: 'Plans, pricing, anything a member sees during checkout or billing.' }
  ];

  // In-memory merged map. Null until init() runs. Keep it nullable so
  // a portal that calls t() before init gets the default (via the
  // fallback branch) instead of a silent miss.
  var _terms = null;

  // Merge tenant overrides over defaults. Called after tenant.js resolves.
  // Safe to call multiple times — later calls pick up any mutations to
  // window.Tenant.terminology (operator portal does this after a save).
  function init() {
    var overrides = (window.Tenant && window.Tenant.terminology) || {};
    var merged = {};
    for (var k in DEFAULTS) if (Object.prototype.hasOwnProperty.call(DEFAULTS, k)) merged[k] = DEFAULTS[k];
    for (var k2 in overrides) {
      if (!Object.prototype.hasOwnProperty.call(overrides, k2)) continue;
      var v = overrides[k2];
      if (typeof v === 'string' && v.trim()) merged[k2] = v;
    }
    _terms = merged;
    return merged;
  }

  // The accessor portals call. Returns the configured term or the
  // default if the key is unknown (and logs once so a typo in a portal
  // doesn't silently ship as an empty string).
  var _missingLogged = {};
  function t(key, opts) {
    var map = _terms || DEFAULTS;
    var val = Object.prototype.hasOwnProperty.call(map, key) ? map[key] : null;
    if (val == null) {
      if (!_missingLogged[key]) {
        console.warn('[terminology] unknown key', key);
        _missingLogged[key] = true;
      }
      val = key; // Last resort so rendering doesn't blow up.
    }
    if (opts && opts.lower) return val.toLowerCase();
    if (opts && opts.upper) return val.toUpperCase();
    return val;
  }

  // Reset the cache. Intended for the operator portal's Terminology
  // tab, which mutates window.Tenant.terminology in place after a save
  // and needs to re-merge without a full page reload.
  function reset() { _terms = null; _missingLogged = {}; }

  // Public surface.
  window.Terminology = {
    init:    init,
    t:       t,
    reset:   reset,
    KEYS:    TERMINOLOGY_KEYS,
    GROUPS:  GROUPS,
    DEFAULTS: DEFAULTS
  };
})();
