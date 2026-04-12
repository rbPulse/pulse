// ═══ PULSE INVESTOR DECK — Slide Navigation ═══
(function() {
  var slides = document.querySelectorAll('.slide');
  var total = slides.length;
  var current = 0;

  var totalEl = document.getElementById('totalSlides');
  var currentEl = document.getElementById('currentSlide');
  var progressBar = document.getElementById('progressBar');
  var prevBtn = document.getElementById('prevBtn');
  var nextBtn = document.getElementById('nextBtn');

  if (totalEl) totalEl.textContent = String(total).padStart(2, '0');

  function go(n) {
    if (n < 0 || n >= total) return;
    slides[current].classList.remove('active');
    current = n;
    slides[current].classList.add('active');
    if (currentEl) currentEl.textContent = String(current + 1).padStart(2, '0');
    if (progressBar) progressBar.style.width = ((current + 1) / total * 100) + '%';
  }

  function next() { go(Math.min(current + 1, total - 1)); }
  function prev() { go(Math.max(current - 1, 0)); }

  if (prevBtn) prevBtn.addEventListener('click', prev);
  if (nextBtn) nextBtn.addEventListener('click', next);

  document.addEventListener('keydown', function(e) {
    if (e.key === 'ArrowRight' || e.key === ' ' || e.key === 'PageDown') { e.preventDefault(); next(); }
    else if (e.key === 'ArrowLeft' || e.key === 'PageUp') { e.preventDefault(); prev(); }
    else if (e.key === 'Home') { e.preventDefault(); go(0); }
    else if (e.key === 'End') { e.preventDefault(); go(total - 1); }
  });

  // Touch swipe
  var touchStartX = 0;
  document.addEventListener('touchstart', function(e) { touchStartX = e.touches[0].clientX; }, { passive: true });
  document.addEventListener('touchend', function(e) {
    var dx = e.changedTouches[0].clientX - touchStartX;
    if (Math.abs(dx) > 50) { if (dx < 0) next(); else prev(); }
  });

  // Init
  go(0);
})();
