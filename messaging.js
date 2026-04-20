// ═══════════════════════════════════════════════════════════════════════════
// messaging.js — shared tenant messaging catalog & helper
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
//   Every automated message Pulse sends — welcome email, refill
//   approval, consult reminder — is a tenant-overridable template.
//   This file holds the CATALOG of message keys the system knows
//   about, the bundled default subject/body for each, and the
//   runtime accessor portals call to resolve a template by key
//   (with tenant overrides merged on top of defaults).
//
//   Zero-dependency, zero-framework — same pattern as tenant.js,
//   terminology.js, workflow.js.
//
// HOW PORTALS USE IT
//   1. Load this file in <head> AFTER tenant.js:
//        <script src="tenant.js"></script>
//        <script src="messaging.js"></script>
//   2. After authenticating, load the tenant's overrides into the
//      cache. This needs a db call, so it's an async init:
//        Messaging.init(db, window.Tenant.id).then(function() {
//          // Messaging.render(key, vars) now works.
//        });
//   3. Render a template (returns { subject, body, channel } with
//      variables interpolated):
//        var msg = Messaging.render('refill.approved', {
//          member_first_name: 'Alex',
//          protocol_name: 'Sleep Protocol'
//        });
//
// STORAGE SHAPE
//   communication_templates rows hold per-tenant overrides. If no
//   row exists for (tenant_id, key, channel), the bundled default
//   from CATALOG below is used. Overrides can be partial — a tenant
//   that only changes the subject still inherits the default body.
//
// INTERPOLATION
//   {{variable_name}} in subject or body is replaced with the value
//   from the vars argument. Missing variables render as the literal
//   placeholder (e.g. "{{member_first_name}}") so the failure is
//   visible rather than silent. Extra variables are ignored.
//
// DESIGN CHOICES
//   - Catalog in JS, not DB. Adding a new message key without a
//     migration matters because message keys evolve faster than
//     table shapes. The migration only provisions the storage; keys
//     are app-level.
//   - Channel is part of the key's identity. A refill approval can
//     exist as email AND SMS with different bodies; they're two
//     rows with the same `key` and different `channel`.
//   - No send path here. This file resolves a template and gives
//     you the rendered output; actual delivery (Resend/Postmark/
//     Twilio) lives in Phase 7's integrations layer.
//
// ═══════════════════════════════════════════════════════════════════════════

(function () {
  'use strict';

  // ── Catalog ───────────────────────────────────────────────────────────
  // Every message key the system knows about. Adding a new one:
  //   1. Append an entry here (key + channel + default subject/body
  //      + the variables it can reference).
  //   2. Call Messaging.render('your.new.key', vars) from wherever
  //      triggers the send.
  //   3. Operator portal's Comms tab picks it up automatically.
  //
  // Group keys by dotted namespace (`member.welcome`, `refill.approved`)
  // so the operator tab can show them sectioned.
  var CATALOG = [
    {
      key:     'member.welcome',
      channel: 'email',
      group:   'member',
      label:   'Member welcome',
      description: 'Sent to a new member after their first enrolment at the tenant.',
      subject: 'Welcome to {{tenant_name}}',
      body:    'Hi {{member_first_name}},\n\n' +
               'Welcome to {{tenant_name}}. Your account is set up and ready.\n\n' +
               'Next step: complete your intake at {{portal_url}}.\n\n' +
               'Need help? Reach us at {{support_email}}.\n\n' +
               '— The {{tenant_name}} team',
      variables: [
        { name: 'tenant_name',        required: true  },
        { name: 'member_first_name',  required: true  },
        { name: 'portal_url',         required: true  },
        { name: 'support_email',      required: false }
      ]
    },
    {
      key:     'intake.submitted',
      channel: 'email',
      group:   'intake',
      label:   'Intake submitted confirmation',
      description: 'Confirms receipt after a member submits their intake questionnaire.',
      subject: 'We received your intake — {{tenant_name}}',
      body:    'Hi {{member_first_name}},\n\n' +
               'Thanks for completing your intake. A {{clinician_term}} will review it shortly.\n\n' +
               'Typical review time: {{sla_hours}} hours.\n\n' +
               'You\u2019ll hear back at this email address.',
      variables: [
        { name: 'tenant_name',        required: true  },
        { name: 'member_first_name',  required: true  },
        { name: 'clinician_term',     required: false },
        { name: 'sla_hours',          required: true  }
      ]
    },
    {
      key:     'refill.approved',
      channel: 'email',
      group:   'refill',
      label:   'Refill approved',
      description: 'Sent when a clinician approves a refill request.',
      subject: 'Your refill has been approved',
      body:    'Hi {{member_first_name}},\n\n' +
               'Your refill for {{protocol_name}} has been approved.\n\n' +
               'It will ship to your address on file. You\u2019ll get a shipping confirmation once it\u2019s on its way.\n\n' +
               'Questions? Reply to this email or reach us at {{support_email}}.',
      variables: [
        { name: 'member_first_name',  required: true  },
        { name: 'protocol_name',      required: true  },
        { name: 'support_email',      required: false }
      ]
    },
    {
      key:     'refill.denied',
      channel: 'email',
      group:   'refill',
      label:   'Refill denied',
      description: 'Sent when a clinician denies a refill request. Should always include a follow-up path.',
      subject: 'Update on your refill request',
      body:    'Hi {{member_first_name}},\n\n' +
               'Your clinician reviewed your refill request for {{protocol_name}} and needs more information before approving.\n\n' +
               '{{denial_reason}}\n\n' +
               'Please message your care team at {{portal_url}} so we can follow up.',
      variables: [
        { name: 'member_first_name',  required: true  },
        { name: 'protocol_name',      required: true  },
        { name: 'denial_reason',      required: true  },
        { name: 'portal_url',         required: true  }
      ]
    },
    {
      key:     'consult.scheduled',
      channel: 'email',
      group:   'consult',
      label:   'Consult scheduled',
      description: 'Confirms a newly-scheduled consult. Includes the calendar hold and the join link.',
      subject: 'Your consult is scheduled for {{consult_time}}',
      body:    'Hi {{member_first_name}},\n\n' +
               'Your consult with {{clinician_name}} is confirmed for {{consult_time}}.\n\n' +
               'Join link: {{join_url}}\n\n' +
               'Need to reschedule? Use the link in your portal.',
      variables: [
        { name: 'member_first_name',  required: true  },
        { name: 'clinician_name',     required: true  },
        { name: 'consult_time',       required: true  },
        { name: 'join_url',           required: true  }
      ],
      cadence: null
    },
    {
      key:     'consult.reminder',
      channel: 'email',
      group:   'consult',
      label:   'Consult reminder',
      description: 'Fires before a scheduled consult. Cadence controls how many reminders and how far in advance.',
      subject: 'Reminder: your consult is {{when}}',
      body:    'Hi {{member_first_name}},\n\n' +
               'Just a reminder: your consult with {{clinician_name}} is {{when}}.\n\n' +
               'Join link: {{join_url}}',
      variables: [
        { name: 'member_first_name',  required: true  },
        { name: 'clinician_name',     required: true  },
        { name: 'when',               required: true  },
        { name: 'join_url',           required: true  }
      ],
      cadence: { days_before: [1], hours_before: [2] }
    },
    {
      key:     'followup.check_in',
      channel: 'email',
      group:   'followup',
      label:   'Follow-up check-in',
      description: 'Automated check-in sent at the interval configured in Workflow.follow_up.cadence_days.',
      subject: 'Checking in — how\u2019s it going?',
      body:    'Hi {{member_first_name}},\n\n' +
               'It\u2019s been a little while since we last spoke. How are you doing with {{protocol_name}}?\n\n' +
               'If you have questions or want to adjust anything, reply to this email or message your care team at {{portal_url}}.',
      variables: [
        { name: 'member_first_name',  required: true  },
        { name: 'protocol_name',      required: false },
        { name: 'portal_url',         required: true  }
      ]
    }
  ];

  var GROUPS = [
    { key: 'member',   label: 'Member onboarding' },
    { key: 'intake',   label: 'Intake'             },
    { key: 'refill',   label: 'Refills'            },
    { key: 'consult',  label: 'Consults'           },
    { key: 'followup', label: 'Follow-up'          }
  ];

  // Flatten catalog into a lookup map for O(1) default resolution.
  // Composite key: "key|channel" since the same key can exist across
  // multiple channels.
  var DEFAULTS = {};
  CATALOG.forEach(function(entry) {
    DEFAULTS[entry.key + '|' + entry.channel] = entry;
  });

  // Cache of overrides keyed by "key|channel". Populated by init().
  var _overrides = {};
  var _missingLogged = {};

  // Load this tenant's overrides from the DB. Returns a promise so
  // portals can chain page-init off a successful load. Failure is
  // non-fatal — we fall through to bundled defaults with a warning
  // rather than blocking the portal from rendering.
  function init(db, tenantId) {
    _overrides = {};
    if (!db || !db.from || !tenantId) return Promise.resolve({});
    return db.from('communication_templates')
      .select('key, channel, subject, body, is_enabled, cadence')
      .eq('tenant_id', tenantId)
      .then(function(r) {
        if (r.error) {
          console.warn('[messaging] failed to load overrides; using defaults', r.error);
          return {};
        }
        (r.data || []).forEach(function(row) {
          _overrides[row.key + '|' + row.channel] = row;
        });
        return _overrides;
      })
      .catch(function(err) {
        console.warn('[messaging] overrides load errored; using defaults', err);
        return {};
      });
  }

  // Resolve a template to { key, channel, subject, body, cadence,
  // is_enabled } merged view. Default channel is 'email'.
  function resolve(key, channel) {
    channel = channel || 'email';
    var k = key + '|' + channel;
    var def  = DEFAULTS[k];
    var over = _overrides[k];
    if (!def) {
      if (!_missingLogged[k]) {
        console.warn('[messaging] unknown template', key, channel);
        _missingLogged[k] = true;
      }
      return null;
    }
    return {
      key:        def.key,
      channel:    def.channel,
      subject:    over && over.subject != null ? over.subject : def.subject,
      body:       over && over.body    != null ? over.body    : def.body,
      cadence:    over && over.cadence != null ? over.cadence : (def.cadence || null),
      is_enabled: over ? over.is_enabled !== false : true,
      variables:  def.variables || []
    };
  }

  // Render a template with variables interpolated. Missing variables
  // render as the literal "{{name}}" so a malformed call is visible
  // in the delivered message instead of silently swallowed.
  function render(key, vars, channel) {
    var t = resolve(key, channel);
    if (!t) return null;
    return {
      key:      t.key,
      channel:  t.channel,
      subject:  interpolate(t.subject || '', vars),
      body:     interpolate(t.body    || '', vars),
      cadence:  t.cadence,
      is_enabled: t.is_enabled
    };
  }

  function interpolate(tpl, vars) {
    vars = vars || {};
    return String(tpl).replace(/\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/g, function(m, name) {
      return Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : m;
    });
  }

  function reset() { _overrides = {}; _missingLogged = {}; }

  window.Messaging = {
    init:     init,
    resolve:  resolve,
    render:   render,
    reset:    reset,
    CATALOG:  CATALOG,
    GROUPS:   GROUPS,
    DEFAULTS: DEFAULTS
  };
})();
