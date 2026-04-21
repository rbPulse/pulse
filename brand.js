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

  function apply() { applyTo(document); }

  window.Brand = {
    apply:   apply,
    applyTo: applyTo,
    // Helpers exposed for edge cases (admin preview paints a single
    // preview block that isn't backed by window.Tenant).
    _hexToRgba: hexToRgba,
    _applyAccent: applyAccent
  };
})();
