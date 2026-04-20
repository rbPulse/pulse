// ═══════════════════════════════════════════════════════════════════════════
// compliance.js — shared compliance helpers
// ═══════════════════════════════════════════════════════════════════════════
//
// WHY THIS EXISTS
//   Shared US states catalog + helpers for "is this state operational
//   for this tenant?" and "does this clinician have a valid license in
//   this state?" checks. Referenced by:
//
//     - Operator portal Compliance tab (render state picker, surface
//       expiring licenses).
//     - Admin portal assignment logic (gate clinician picks on state
//       match when Workflow.get('assignment.respect_state_license')
//       is on).
//     - Member portal intake (refuse intake submissions from members
//       whose state the tenant doesn't operate in).
//
//   Zero-dependency, zero-framework. Same shape as the other shared
//   helpers (tenant.js, terminology.js, workflow.js, messaging.js,
//   integrations.js).
//
// HOW PORTALS USE IT
//   1. Load this file in <head>:
//        <script src="compliance.js"></script>
//   2. After tenant + auth are established, init:
//        Compliance.init(db, window.Tenant.id);
//   3. Anywhere downstream:
//        if (!Compliance.tenantOperatesIn(memberState)) { ... }
//        var expiring = Compliance.licensesExpiringWithin(60, userId);
//        var primaryLoc = Compliance.primaryLocation();
//
// STORAGE
//   Loads three slices into memory:
//     _regions    — tenant_regions rows (state → is_allowed)
//     _locations  — tenant_locations rows
//     _licenses   — clinician_state_licenses scoped to the viewer +
//                   tenant-scoped clinicians (what RLS permits)
//
//   Consents are NOT cached here because they can be large (markdown
//   bodies) and are only read when a member is about to sign. Callers
//   fetch consents on demand via db directly.
//
// ═══════════════════════════════════════════════════════════════════════════

(function () {
  'use strict';

  // ── US states + DC + territories ───────────────────────────────────────
  // Postal codes are the UNIQUE ID. Long names render in UI.
  // No clinical tenant today ships into US territories, but include
  // them so the constraint regex doesn't trip and so future-us has the
  // data ready without a helper-file update.
  var STATES = [
    { code: 'AL', name: 'Alabama'        }, { code: 'AK', name: 'Alaska'        },
    { code: 'AZ', name: 'Arizona'        }, { code: 'AR', name: 'Arkansas'      },
    { code: 'CA', name: 'California'     }, { code: 'CO', name: 'Colorado'      },
    { code: 'CT', name: 'Connecticut'    }, { code: 'DE', name: 'Delaware'      },
    { code: 'DC', name: 'District of Columbia' },
    { code: 'FL', name: 'Florida'        }, { code: 'GA', name: 'Georgia'       },
    { code: 'HI', name: 'Hawaii'         }, { code: 'ID', name: 'Idaho'         },
    { code: 'IL', name: 'Illinois'       }, { code: 'IN', name: 'Indiana'       },
    { code: 'IA', name: 'Iowa'           }, { code: 'KS', name: 'Kansas'        },
    { code: 'KY', name: 'Kentucky'       }, { code: 'LA', name: 'Louisiana'     },
    { code: 'ME', name: 'Maine'          }, { code: 'MD', name: 'Maryland'      },
    { code: 'MA', name: 'Massachusetts'  }, { code: 'MI', name: 'Michigan'      },
    { code: 'MN', name: 'Minnesota'      }, { code: 'MS', name: 'Mississippi'   },
    { code: 'MO', name: 'Missouri'       }, { code: 'MT', name: 'Montana'       },
    { code: 'NE', name: 'Nebraska'       }, { code: 'NV', name: 'Nevada'        },
    { code: 'NH', name: 'New Hampshire'  }, { code: 'NJ', name: 'New Jersey'    },
    { code: 'NM', name: 'New Mexico'     }, { code: 'NY', name: 'New York'      },
    { code: 'NC', name: 'North Carolina' }, { code: 'ND', name: 'North Dakota'  },
    { code: 'OH', name: 'Ohio'           }, { code: 'OK', name: 'Oklahoma'      },
    { code: 'OR', name: 'Oregon'         }, { code: 'PA', name: 'Pennsylvania'  },
    { code: 'RI', name: 'Rhode Island'   }, { code: 'SC', name: 'South Carolina'},
    { code: 'SD', name: 'South Dakota'   }, { code: 'TN', name: 'Tennessee'     },
    { code: 'TX', name: 'Texas'          }, { code: 'UT', name: 'Utah'          },
    { code: 'VT', name: 'Vermont'        }, { code: 'VA', name: 'Virginia'      },
    { code: 'WA', name: 'Washington'     }, { code: 'WV', name: 'West Virginia' },
    { code: 'WI', name: 'Wisconsin'      }, { code: 'WY', name: 'Wyoming'       },
    { code: 'PR', name: 'Puerto Rico'    }, { code: 'VI', name: 'U.S. Virgin Islands' },
    { code: 'GU', name: 'Guam'           }, { code: 'AS', name: 'American Samoa'}
  ];

  var STATE_BY_CODE = {};
  STATES.forEach(function(s) { STATE_BY_CODE[s.code] = s; });

  var _regions   = {};  // state code → { is_allowed, notes }
  var _locations = [];  // tenant_locations rows
  var _licenses  = [];  // clinician_state_licenses rows
  var _tenantId  = null;

  function init(db, tenantId) {
    _regions = {}; _locations = []; _licenses = [];
    _tenantId = tenantId;
    if (!db || !db.from || !tenantId) return Promise.resolve();

    return Promise.all([
      db.from('tenant_regions').select('state, is_allowed, notes').eq('tenant_id', tenantId),
      db.from('tenant_locations').select('*').eq('tenant_id', tenantId).eq('is_archived', false).order('display_order'),
      db.from('clinician_state_licenses').select('*').eq('is_active', true)
    ]).then(function(results) {
      (results[0].data || []).forEach(function(r) { _regions[r.state] = r; });
      _locations = results[1].data || [];
      _licenses  = results[2].data || [];
      return { regions: _regions, locations: _locations, licenses: _licenses };
    }).catch(function(err) {
      console.warn('[compliance] init failed; treating as no data', err);
      return { regions: _regions, locations: _locations, licenses: _licenses };
    });
  }

  // True if the tenant operates in the given state. A state is
  // operational when it has a row with is_allowed=true. Absence or
  // is_allowed=false both mean "not operational" — the UI distinction
  // (explicitly blocked vs never considered) exists for audit, but
  // most gates just want the boolean.
  function tenantOperatesIn(state) {
    if (!state) return false;
    var s = String(state).toUpperCase();
    return !!(_regions[s] && _regions[s].is_allowed);
  }

  // Return the list of state codes the tenant operates in.
  function operatingStates() {
    return Object.keys(_regions).filter(function(s) { return _regions[s].is_allowed; });
  }

  // Clinicians licensed in the given state, as a list of user_ids.
  // Expired licenses are excluded.
  function cliniciansLicensedIn(state) {
    if (!state) return [];
    var s = String(state).toUpperCase();
    var now = Date.now();
    return _licenses.filter(function(l) {
      if (l.state !== s) return false;
      if (l.expires_date && new Date(l.expires_date).getTime() < now) return false;
      return true;
    }).map(function(l) { return l.user_id; });
  }

  // Licenses expiring within N days for the given user (or for every
  // loaded clinician if userId is omitted). Used by the operator
  // portal to surface a "3 licenses expiring within 60 days" counter.
  function licensesExpiringWithin(days, userId) {
    var cutoff = Date.now() + (days * 86400000);
    return _licenses.filter(function(l) {
      if (userId && l.user_id !== userId) return false;
      if (!l.expires_date) return false;
      var exp = new Date(l.expires_date).getTime();
      return exp <= cutoff && exp >= Date.now();
    });
  }

  function primaryLocation() {
    for (var i = 0; i < _locations.length; i++) {
      if (_locations[i].is_primary) return _locations[i];
    }
    return _locations[0] || null;
  }

  function reset() { _regions = {}; _locations = []; _licenses = []; _tenantId = null; }

  window.Compliance = {
    init:                   init,
    tenantOperatesIn:       tenantOperatesIn,
    operatingStates:        operatingStates,
    cliniciansLicensedIn:   cliniciansLicensedIn,
    licensesExpiringWithin: licensesExpiringWithin,
    primaryLocation:        primaryLocation,
    reset:                  reset,
    STATES:                 STATES,
    STATE_BY_CODE:          STATE_BY_CODE
  };
})();
