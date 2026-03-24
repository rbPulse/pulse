// ===== PULSE DECK — Slide Navigation & Interactions =====

(function() {
    'use strict';

    const deck = document.getElementById('deck');
    const slides = document.querySelectorAll('.slide');
    const progressBar = document.getElementById('progressBar');
    const currentSlideEl = document.getElementById('currentSlide');
    const dots = document.querySelectorAll('.slide-dot');
    const keyboardHint = document.getElementById('keyboardHint');

    const totalSlides = slides.length;
    let activeIndex = 0;
    let isScrolling = false;
    let scrollTimeout;

    // ===== Initialize first slide =====
    slides[0].classList.add('active');
    updateUI(0);

    // ===== Detect active slide on scroll =====
    deck.addEventListener('scroll', () => {
        clearTimeout(scrollTimeout);
        scrollTimeout = setTimeout(() => {
            const scrollPos = deck.scrollTop;
            const viewHeight = window.innerHeight;

            let newIndex = Math.round(scrollPos / viewHeight);
            newIndex = Math.max(0, Math.min(newIndex, totalSlides - 1));

            if (newIndex !== activeIndex) {
                slides[activeIndex].classList.remove('active');
                activeIndex = newIndex;
                slides[activeIndex].classList.add('active');
                updateUI(activeIndex);
            }

            isScrolling = false;
        }, 80);

        // Hide keyboard hint after first scroll
        if (keyboardHint) {
            keyboardHint.classList.add('hidden');
        }
    }, { passive: true });

    // ===== Keyboard navigation =====
    document.addEventListener('keydown', (e) => {
        if (isScrolling) return;

        let targetIndex = activeIndex;

        switch(e.key) {
            case 'ArrowDown':
            case 'PageDown':
            case ' ':
                e.preventDefault();
                targetIndex = Math.min(activeIndex + 1, totalSlides - 1);
                break;
            case 'ArrowUp':
            case 'PageUp':
                e.preventDefault();
                targetIndex = Math.max(activeIndex - 1, 0);
                break;
            case 'Home':
                e.preventDefault();
                targetIndex = 0;
                break;
            case 'End':
                e.preventDefault();
                targetIndex = totalSlides - 1;
                break;
        }

        if (targetIndex !== activeIndex) {
            goToSlide(targetIndex);
        }
    });

    // ===== Dot navigation =====
    dots.forEach(dot => {
        dot.addEventListener('click', () => {
            const slideIndex = parseInt(dot.dataset.slide);
            goToSlide(slideIndex);
        });
    });

    // ===== Navigate to slide =====
    function goToSlide(index) {
        if (isScrolling || index === activeIndex) return;
        isScrolling = true;

        slides[activeIndex].classList.remove('active');
        activeIndex = index;
        slides[activeIndex].classList.add('active');

        deck.scrollTo({
            top: index * window.innerHeight,
            behavior: 'smooth'
        });

        updateUI(index);

        // Reset scrolling lock
        setTimeout(() => { isScrolling = false; }, 600);
    }

    // ===== Update progress, counter, dots =====
    function updateUI(index) {
        // Progress bar
        const progress = ((index + 1) / totalSlides) * 100;
        progressBar.style.width = progress + '%';

        // Counter
        currentSlideEl.textContent = String(index + 1).padStart(2, '0');

        // Dots
        dots.forEach((dot, i) => {
            dot.classList.toggle('active', i === index);
        });
    }

    // ===== Handle resize =====
    let resizeTimeout;
    window.addEventListener('resize', () => {
        clearTimeout(resizeTimeout);
        resizeTimeout = setTimeout(() => {
            deck.scrollTo({
                top: activeIndex * window.innerHeight,
                behavior: 'auto'
            });
        }, 150);
    });

    // ===== Touch swipe support =====
    let touchStartY = 0;
    let touchEndY = 0;

    deck.addEventListener('touchstart', (e) => {
        touchStartY = e.changedTouches[0].screenY;
    }, { passive: true });

    deck.addEventListener('touchend', (e) => {
        touchEndY = e.changedTouches[0].screenY;
        const diff = touchStartY - touchEndY;

        // Only handle deliberate swipes (> 50px)
        if (Math.abs(diff) > 50) {
            if (diff > 0) {
                // Swipe up - next slide
                goToSlide(Math.min(activeIndex + 1, totalSlides - 1));
            } else {
                // Swipe down - prev slide
                goToSlide(Math.max(activeIndex - 1, 0));
            }
        }
    }, { passive: true });

})();
