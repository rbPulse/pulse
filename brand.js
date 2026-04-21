// ════════════════════════════════════════════════════════════════
// Shared brand applier
// Reads window.Tenant.brand (populated by tenant.js) and applies
// every field to the DOM. Replaces the per-page applyTenantBrand()
// helpers that each portal was writing independently — one source
// of truth so adding a new tenant field only requires editing
// here plus adding the data-brand attribute wherever it appears.
//
// DOM contract: pages mark elements they want branded with
//   data-brand="<field>"
// and the applier fills textContent (or src / href depending on
// the element type). Supported fields:
//
//   wordmark          — text or <img>; falls back to the configured
//                       default role noun for the mode-specific
//                       portal ("PULSE", "Admin", etc.)
//   logo              — <img src>; falls back to data-default-src
//   favicon           — sets <link rel="icon">
//   legal-name        — textContent
//   support-email     — textContent and href mailto:
//   support-phone     — textContent and href tel:
//   sender-name       — textContent
//   sender-email      — textContent and href mailto:
//   footer-copy       — innerHTML (allows simple markup from admin)
//   accent            — data-brand="accent" targets elements that
//                       want the color inline (rare — most things
//                       should pick up the CSS custom property)
//
// Also sets --brand-accent on <html> so CSS can reference it in
// any rule. Pages that want the accent to drive button color
// just use color: var(--brand-accent, <existing fallback>).
//
// Wordmark dual-mode: if brand.wordmark_image_url is set, any
// element with data-brand="wordmark" gets its innerHTML replaced
// with an <img>. Otherwise textContent is set to brand.wordmark
// (or the data-brand-default fallback).
//
// Usage:
//   <script src="path/to/brand.js"></script>
//   // after Tenant.init() resolves:
//   window.Brand.apply();
//
// Pages that re-render branded DOM dynamically (e.g. open a modal)
// can call window.Brand.applyTo(rootElement) to brand just that
// subtree without re-walking the whole document.
// ════════════════════════════════════════════════════════════════
(function() {
  'use strict';

  function hexToRgba(hex, alpha) {
    if (!hex || !/^#[0-9a-fA-F]{6}$/.test(hex)) return null;
    var h = hex.replace('#', '');
    var r = parseInt(h.substring(0, 2), 16);
    var g = parseInt(h.substring(2, 4), 16);
    var b = parseInt(h.substring(4, 6), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
  }

  function escHtml(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function setFavicon(url) {
    if (!url) return;
    var link = document.querySelector('link[rel="icon"]');
    if (!link) {
      link = document.createElement('link');
      link.rel = 'icon';
      document.head.appendChild(link);
    }
    link.href = url;
  }

  function applyAccent(hex) {
    if (!hex || !/^#[0-9a-fA-F]{6}$/.test(hex)) return;
    var root = document.documentElement;
    root.style.setProperty('--brand-accent',        hex);
    root.style.setProperty('--brand-accent-tint',   hexToRgba(hex, 0.10));
    root.style.setProperty('--brand-accent-border', hexToRgba(hex, 0.30));
    root.style.setProperty('--brand-accent-glow',   hexToRgba(hex, 0.35));
    // Each portal's CSS declares its native primary color as
    //   --green: var(--brand-accent, <hardcoded>);
    // so the accent cascades automatically. No per-portal shim
    // needed here — if an accent is set it replaces the primary;
    // otherwise the fallback keeps the default look.
  }

  function applyWordmark(el, brand) {
    if (brand.wordmark_image_url) {
      var alt = brand.wordmark || 'Logo';
      el.innerHTML = '<img src="' + escHtml(brand.wordmark_image_url) + '" alt="' + escHtml(alt) + '" style="max-height:1.4em;width:auto;vertical-align:middle;display:inline-block;"/>';
    } else {
      var text = (brand.wordmark || '').trim() || el.getAttribute('data-brand-default') || 'Pulse';
      el.textContent = text;
    }
  }

  function applyLogo(el, brand) {
    if (brand.logo_url) {
      el.src = brand.logo_url;
    } else {
      var def = el.getAttribute('data-default-src');
      if (def) el.src = def;
    }
  }

  // data-brand="logo-mark" lives on the circular brand-mark container
  // in each portal's nav. Rendering rules:
  //   1. tenant has logo_url       → replace innerHTML with <img>
  //   2. tenant.slug === 'pulse'   → no-op (keep the default heartbeat
  //                                  SVG the page baked in — it's Pulse's own mark)
  //   3. otherwise                 → render initials from the wordmark
  //                                  (e.g. "Acme Health" → "AH"). If there's
  //                                  no wordmark either, hide the container
  //                                  so we don't flash Pulse's icon for a
  //                                  tenant that hasn't set up a mark.
  function applyLogoMark(el, brand) {
    if (brand.logo_url) {
      el.innerHTML = '<img src="' + escHtml(brand.logo_url) + '" alt="" style="width:100%;height:100%;object-fit:cover;border-radius:50%;"/>';
      el.removeAttribute('data-brand-empty');
      return;
    }
    var slug = (window.Tenant && window.Tenant.slug) || '';
    if (slug === 'pulse') {
      // Pulse tenant keeps its native heartbeat. No-op.
      return;
    }
    var wm = (brand.wordmark || '').trim();
    if (wm) {
      var initials = wm.split(/\s+/).map(function(w){ return w.charAt(0).toUpperCase(); }).slice(0, 2).join('');
      el.innerHTML = '<span style="font-family:\'Inter\',sans-serif;font-size:11px;font-weight:700;letter-spacing:0;color:var(--brand-accent, currentColor);">' + escHtml(initials) + '</span>';
      el.removeAttribute('data-brand-empty');
    } else {
      // No logo, no wordmark — collapse the container to avoid showing
      // Pulse's heartbeat mark to a tenant that hasn't set anything up.
      el.style.display = 'none';
      el.setAttribute('data-brand-empty', 'true');
    }
  }

  function applyTo(root) {
    var brand = (window.Tenant && window.Tenant.brand) || {};
    var scope = root || document;

    applyAccent(brand.accent_color);

    var nodes = scope.querySelectorAll('[data-brand]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var kind = el.getAttribute('data-brand');
      switch (kind) {
        case 'wordmark':
          applyWordmark(el, brand);
          break;
        case 'logo':
          applyLogo(el, brand);
          break;
        case 'logo-mark':
          applyLogoMark(el, brand);
          break;
        case 'legal-name':
          el.textContent = brand.legal_name || el.getAttribute('data-brand-default') || '';
          break;
        case 'support-email':
          var se = brand.support_email;
          if (se) {
            el.textContent = se;
            if (el.tagName === 'A') el.href = 'mailto:' + se;
          }
          break;
        case 'support-phone':
          var sp = brand.support_phone;
          if (sp) {
            el.textContent = sp;
            if (el.tagName === 'A') el.href = 'tel:' + sp.replace(/[^0-9+]/g, '');
          }
          break;
        case 'sender-email':
          if (brand.sender_email) el.textContent = brand.sender_email;
          break;
        case 'sender-name':
          if (brand.sender_name) el.textContent = brand.sender_name;
          break;
        case 'footer-copy':
          if (brand.footer_copy) el.innerHTML = escHtml(brand.footer_copy).replace(/\n/g, '<br>');
          break;
        case 'accent':
          if (brand.accent_color) el.style.color = brand.accent_color;
          break;
      }
    }

    // Favicon is a singleton: not annotated via data-brand, applied
    // unconditionally if configured. Same for <title>: the page
    // controls the prefix, we just suffix with the wordmark.
    setFavicon(brand.favicon_url);
    var titleAttr = document.documentElement.getAttribute('data-brand-title-pattern');
    if (titleAttr) {
      var wm = (brand.wordmark || '').trim() || 'Pulse';
      document.title = titleAttr.replace(/\{wordmark\}/g, wm);
    }
  }

  function apply() {
    applyTo(document);
    // Cache the current tenant's brand so the next visit (or a hard
    // reload) can paint it before tenant.js has finished fetching.
    // Only write when we actually have a tenant resolved — apply()
    // may be called from the wizard preview with window.Tenant not
    // yet set, and we don't want to poison the cache with empties.
    if (window.Tenant && window.Tenant.slug && window.Tenant.brand) {
      _writeBrandCache(window.Tenant.slug, window.Tenant.brand);
    }
  }

  // ── Brand cache (localStorage) ────────────────────────────────────
  // Keyed by tenant slug extracted from the URL. applyEarly() reads
  // this cache before tenant.js kicks in so returning visitors see
  // the correct wordmark / logo / accent on the loading screen
  // instead of Pulse's defaults for a few hundred milliseconds.
  //
  // apply() writes back every time a fresh brand resolves, so the
  // cache stays close to source-of-truth without a separate sync.

  function _slugFromUrl() {
    var m = (window.location && window.location.pathname || '').match(/\/t\/([^\/]+)\//);
    return m ? m[1] : null;
  }
  function _cacheKey(slug) { return 'pulse_brand_cache_' + slug; }

  function _writeBrandCache(slug, brand) {
    try { localStorage.setItem(_cacheKey(slug), JSON.stringify(brand || {})); }
    catch (_) { /* quota / privacy mode — ignore */ }
  }
  function _readBrandCache(slug) {
    try {
      var raw = localStorage.getItem(_cacheKey(slug));
      return raw ? JSON.parse(raw) : null;
    } catch (_) { return null; }
  }

  // Called before tenant.js has resolved. Reads the cached brand for
  // the URL-derived slug and applies it to any data-brand elements on
  // the page. Safe to call multiple times — tenant.js later runs
  // Brand.apply() which overwrites anything the cache injected.
  function applyEarly() {
    var slug = _slugFromUrl();
    if (!slug) return false;
    var cached = _readBrandCache(slug);
    if (!cached) return false;
    // Stub window.Tenant with just enough for applyTo to work. If
    // tenant.js later populates a richer object, it takes over.
    if (!window.Tenant) window.Tenant = { slug: slug, brand: cached };
    else if (!window.Tenant.brand) window.Tenant.brand = cached;
    applyTo(document);
    return true;
  }

  window.Brand = {
    apply:      apply,
    applyTo:    applyTo,
    applyEarly: applyEarly,
    // Helpers exposed for edge cases (admin preview paints a single
    // preview block that isn't backed by window.Tenant).
    _hexToRgba: hexToRgba,
    _applyAccent: applyAccent
  };

  // Kick off early-brand as soon as brand.js loads. Paints from cache
  // if present so the loading screen reflects the correct tenant.
  if (document.readyState !== 'loading') applyEarly();
  else document.addEventListener('DOMContentLoaded', applyEarly);
})();
