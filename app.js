// ===== PULSE — Landing Page Interactions =====

(function() {
    'use strict';

    // ===== Scroll-triggered animations =====
    const animateElements = document.querySelectorAll('[data-animate]');

    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                const delay = entry.target.dataset.delay || 0;
                setTimeout(() => {
                    entry.target.classList.add('visible');
                }, parseInt(delay));
                observer.unobserve(entry.target);
            }
        });
    }, {
        threshold: 0.1,
        rootMargin: '0px 0px -40px 0px'
    });

    animateElements.forEach(el => observer.observe(el));

    // ===== Nav scroll effect =====
    const nav = document.getElementById('nav');
    let lastScroll = 0;

    window.addEventListener('scroll', () => {
        const currentScroll = window.pageYOffset;
        if (currentScroll > 50) {
            nav.classList.add('scrolled');
        } else {
            nav.classList.remove('scrolled');
        }
        lastScroll = currentScroll;
    }, { passive: true });

    // ===== Mobile menu toggle =====
    const mobileToggle = document.getElementById('mobileToggle');
    const mobileMenu = document.getElementById('mobileMenu');

    if (mobileToggle && mobileMenu) {
        mobileToggle.addEventListener('click', () => {
            mobileToggle.classList.toggle('active');
            mobileMenu.classList.toggle('active');
        });

        // Close on link click
        mobileMenu.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', () => {
                mobileToggle.classList.remove('active');
                mobileMenu.classList.remove('active');
            });
        });
    }

    // ===== Smooth scroll for anchor links =====
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function(e) {
            const target = document.querySelector(this.getAttribute('href'));
            if (target) {
                e.preventDefault();
                target.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        });
    });

    // ===== Animated counter =====
    const counters = document.querySelectorAll('[data-count]');

    const counterObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                const el = entry.target;
                const target = parseInt(el.dataset.count);
                const duration = 1500;
                const start = performance.now();

                function update(now) {
                    const elapsed = now - start;
                    const progress = Math.min(elapsed / duration, 1);
                    const eased = 1 - Math.pow(1 - progress, 3);
                    el.textContent = Math.round(eased * target);
                    if (progress < 1) {
                        requestAnimationFrame(update);
                    }
                }

                requestAnimationFrame(update);
                counterObserver.unobserve(el);
            }
        });
    }, { threshold: 0.5 });

    counters.forEach(el => counterObserver.observe(el));

    // ===== Waitlist form =====
    const form = document.getElementById('waitlistForm');
    if (form) {
        form.addEventListener('submit', function(e) {
            e.preventDefault();
            const input = form.querySelector('.cta-input');
            const btn = form.querySelector('.btn');

            btn.textContent = 'Added';
            btn.style.background = 'var(--accent)';
            input.value = '';

            setTimeout(() => {
                btn.textContent = 'Join Waitlist';
                btn.style.background = '';
            }, 3000);
        });
    }

    // ===== Pulse line parallax =====
    const pulseLine = document.querySelector('.hero-pulse-line');
    if (pulseLine) {
        window.addEventListener('scroll', () => {
            const scroll = window.pageYOffset;
            if (scroll < window.innerHeight) {
                pulseLine.style.transform = `translateY(${scroll * 0.3}px)`;
                pulseLine.style.opacity = Math.max(0, 0.6 - scroll / window.innerHeight);
            }
        }, { passive: true });
    }
})();
