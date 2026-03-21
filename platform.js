// ===== PULSE — Platform Interactions =====

(function() {
    'use strict';

    // ===== Pod Data =====
    const podData = {
        repair: {
            name: 'Repair',
            compound: 'BPC-157 + TB-500',
            category: 'Recovery',
            price: '$149',
            desc: 'BPC-157 (Body Protection Compound) is a pentadecapeptide derived from human gastric juice, shown to accelerate healing in tendons, ligaments, muscles, and the GI tract. TB-500 (Thymosin Beta-4) promotes cell migration and blood vessel formation, supporting systemic recovery. Together, they form the gold standard recovery stack for active individuals.',
            details: [
                { label: 'Cycle', value: '30 days' },
                { label: 'Dose', value: '250mcg / 500mcg' },
                { label: 'Frequency', value: '1x daily' },
                { label: 'Timing', value: 'Morning or post-workout' },
                { label: 'Route', value: 'Subcutaneous' },
                { label: 'Storage', value: 'Refrigerated' }
            ],
            effects: ['Joint repair', 'Gut healing', 'Anti-inflammatory', 'Tendon recovery', 'Muscle repair', 'Wound healing']
        },
        growth: {
            name: 'Growth',
            compound: 'CJC-1295 + Ipamorelin',
            category: 'Performance',
            price: '$179',
            desc: 'CJC-1295 is a growth hormone-releasing hormone (GHRH) analog that extends GH pulse duration. Ipamorelin is a selective growth hormone secretagogue that triggers a clean GH release without cortisol or prolactin spikes. The combination creates sustained, physiological GH elevation — improving body composition, sleep depth, recovery, and cellular repair.',
            details: [
                { label: 'Cycle', value: '30 days' },
                { label: 'Dose', value: '100mcg / 200mcg' },
                { label: 'Frequency', value: '1x daily (PM)' },
                { label: 'Timing', value: '30 min before sleep' },
                { label: 'Route', value: 'Subcutaneous' },
                { label: 'Storage', value: 'Refrigerated' }
            ],
            effects: ['Lean mass', 'Deep sleep', 'Recovery', 'Anti-aging', 'Fat metabolism', 'Skin quality']
        },
        shred: {
            name: 'Shred',
            compound: 'Tesamorelin',
            category: 'Body Comp',
            price: '$199',
            desc: 'Tesamorelin is an FDA-approved GHRH analog specifically studied for visceral adipose tissue reduction. Unlike generic GH secretagogues, Tesamorelin has been shown in clinical trials to selectively reduce trunk fat while preserving lean mass. It improves body composition with a clean metabolic profile — no appetite suppression, no muscle wasting.',
            details: [
                { label: 'Cycle', value: '30 days' },
                { label: 'Dose', value: '2mg' },
                { label: 'Frequency', value: '1x daily' },
                { label: 'Timing', value: 'Morning, fasted' },
                { label: 'Route', value: 'Subcutaneous' },
                { label: 'Storage', value: 'Refrigerated' }
            ],
            effects: ['Visceral fat loss', 'Body recomp', 'Metabolic health', 'Lean preservation', 'Triglyceride reduction']
        },
        vitality: {
            name: 'Vitality',
            compound: 'Epithalon (Epitalon)',
            category: 'Longevity',
            price: '$219',
            desc: 'Epithalon is a synthetic tetrapeptide based on Epithalamin, a natural peptide produced by the pineal gland. It activates telomerase — the enzyme responsible for maintaining telomere length. Shorter telomeres are associated with aging and age-related disease. Epithalon supports cellular regeneration, melatonin regulation, and healthspan extension.',
            details: [
                { label: 'Cycle', value: '20 days on / 10 off' },
                { label: 'Dose', value: '5mg' },
                { label: 'Frequency', value: '1x daily' },
                { label: 'Timing', value: 'Evening' },
                { label: 'Route', value: 'Subcutaneous' },
                { label: 'Storage', value: 'Room temp / Refrigerated' }
            ],
            effects: ['Telomere support', 'Cell regeneration', 'Healthspan', 'Melatonin regulation', 'Anti-aging', 'Sleep quality']
        },
        sleep: {
            name: 'Sleep',
            compound: 'DSIP (Delta Sleep-Inducing Peptide)',
            category: 'Recovery',
            price: '$129',
            desc: 'DSIP is a neuropeptide that modulates sleep architecture, specifically promoting delta wave (deep) sleep — the phase critical for physical recovery, growth hormone release, and memory consolidation. It reduces cortisol, normalizes disrupted sleep patterns, and improves next-day readiness without sedation or dependency.',
            details: [
                { label: 'Cycle', value: '30 days' },
                { label: 'Dose', value: '100mcg' },
                { label: 'Frequency', value: '1x nightly' },
                { label: 'Timing', value: '30 min before bed' },
                { label: 'Route', value: 'Subcutaneous' },
                { label: 'Storage', value: 'Refrigerated' }
            ],
            effects: ['Deep sleep', 'Cortisol reduction', 'Recovery', 'HGH release', 'Stress reduction', 'Sleep architecture']
        },
        endurance: {
            name: 'Endurance',
            compound: 'BPC-157 + MOTSc',
            category: 'Performance',
            price: '$189',
            desc: 'MOTSc is a mitochondrial-derived peptide that activates AMPK — the master regulator of cellular energy. It enhances exercise capacity, improves metabolic flexibility, and supports cardiovascular performance. Paired with BPC-157 for systemic recovery support, this stack is designed for athletes and endurance enthusiasts pushing cardiovascular limits.',
            details: [
                { label: 'Cycle', value: '30 days' },
                { label: 'Dose', value: '250mcg / 5mg' },
                { label: 'Frequency', value: '1x daily (AM)' },
                { label: 'Timing', value: 'Pre-training or morning' },
                { label: 'Route', value: 'Subcutaneous' },
                { label: 'Storage', value: 'Refrigerated' }
            ],
            effects: ['Cardio output', 'Mitochondria', 'Endurance', 'AMPK activation', 'Metabolic flexibility', 'Recovery']
        }
    };

    // ===== Pod Filtering =====
    const filterBtns = document.querySelectorAll('.pod-filter');
    const podCards = document.querySelectorAll('.pod-card');

    filterBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            // Update active state
            filterBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');

            const filter = btn.dataset.filter;

            podCards.forEach(card => {
                if (filter === 'all' || card.dataset.category === filter) {
                    card.classList.remove('pod-hidden');
                    card.style.opacity = '0';
                    card.style.transform = 'translateY(16px)';
                    requestAnimationFrame(() => {
                        card.style.transition = 'opacity 0.4s ease, transform 0.4s ease';
                        card.style.opacity = '1';
                        card.style.transform = 'translateY(0)';
                    });
                } else {
                    card.classList.add('pod-hidden');
                }
            });
        });
    });

    // ===== Pod Modal =====
    const modal = document.getElementById('podModal');
    const modalBody = document.getElementById('podModalBody');
    const modalClose = document.getElementById('podModalClose');
    const selectBtns = document.querySelectorAll('.pod-select-btn');

    function openModal(podId) {
        const pod = podData[podId];
        if (!pod) return;

        const detailsHTML = pod.details.map(d => `
            <div class="pod-modal-detail">
                <span class="pod-modal-detail-label">${d.label}</span>
                <span class="pod-modal-detail-value">${d.value}</span>
            </div>
        `).join('');

        const effectsHTML = pod.effects.map(e => `
            <span class="pod-modal-effect">${e}</span>
        `).join('');

        modalBody.innerHTML = `
            <div class="pod-modal-header">
                <div class="pod-modal-icon">
                    <svg width="28" height="28" viewBox="0 0 28 28" fill="none">
                        <circle cx="14" cy="14" r="12" stroke="#00FF87" stroke-width="1.5"/>
                        <path d="M8 14 Q11 8, 14 14 Q17 20, 20 14" stroke="#00FF87" stroke-width="1.5" fill="none" stroke-linecap="round"/>
                    </svg>
                </div>
                <div>
                    <h3 class="pod-modal-title">${pod.name}</h3>
                    <span class="pod-modal-compound">${pod.compound}</span>
                </div>
            </div>
            <p class="pod-modal-desc">${pod.desc}</p>
            <div class="pod-modal-section-title">Protocol Details</div>
            <div class="pod-modal-details">
                ${detailsHTML}
            </div>
            <div class="pod-modal-section-title">Benefits</div>
            <div class="pod-modal-effects">
                ${effectsHTML}
            </div>
            <div class="pod-modal-cta">
                <span class="pod-modal-price">${pod.price}<span class="pod-modal-price-per">/mo</span></span>
                <button class="pod-modal-add-btn" onclick="document.getElementById('podModal').classList.remove('active')">Add to Protocol</button>
            </div>
        `;

        modal.classList.add('active');
        document.body.style.overflow = 'hidden';
    }

    function closeModal() {
        modal.classList.remove('active');
        document.body.style.overflow = '';
    }

    selectBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            openModal(btn.dataset.pod);
        });
    });

    if (modalClose) {
        modalClose.addEventListener('click', closeModal);
    }

    if (modal) {
        modal.addEventListener('click', (e) => {
            if (e.target === modal) closeModal();
        });
    }

    // ESC to close
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeModal();
    });

    // ===== Pod card click-to-expand (mobile) =====
    if (window.innerWidth < 768) {
        podCards.forEach(card => {
            card.addEventListener('click', (e) => {
                if (e.target.closest('.pod-select-btn')) return;
                const btn = card.querySelector('.pod-select-btn');
                if (btn) openModal(btn.dataset.pod);
            });
        });
    }

})();
