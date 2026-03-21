// ===== PULSE — WebGL Animated Background =====
// Subtle particle mesh with on-brand green accent

(function() {
    'use strict';

    const canvas = document.createElement('canvas');
    canvas.id = 'webgl-bg';
    canvas.style.cssText = 'position:fixed;top:0;left:0;width:100vw;height:100vh;z-index:0;pointer-events:none;';
    document.body.prepend(canvas);

    const gl = canvas.getContext('webgl', { alpha: true, antialias: true, premultipliedAlpha: false });
    if (!gl) return;

    // ===== Shaders =====
    const vertSrc = `
        attribute vec2 aPosition;
        attribute float aAlpha;
        attribute float aSize;
        varying float vAlpha;
        void main() {
            vAlpha = aAlpha;
            gl_Position = vec4(aPosition, 0.0, 1.0);
            gl_PointSize = aSize;
        }
    `;

    const fragSrc = `
        precision mediump float;
        varying float vAlpha;
        uniform vec3 uColor;
        void main() {
            float d = length(gl_PointCoord - vec2(0.5));
            if (d > 0.5) discard;
            float fade = smoothstep(0.5, 0.1, d);
            gl_FragColor = vec4(uColor, vAlpha * fade);
        }
    `;

    const linVertSrc = `
        attribute vec2 aPosition;
        attribute float aAlpha;
        varying float vAlpha;
        void main() {
            vAlpha = aAlpha;
            gl_Position = vec4(aPosition, 0.0, 1.0);
        }
    `;

    const linFragSrc = `
        precision mediump float;
        varying float vAlpha;
        uniform vec3 uColor;
        void main() {
            gl_FragColor = vec4(uColor, vAlpha);
        }
    `;

    function compile(src, type) {
        const s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        return s;
    }

    function link(vs, fs) {
        const p = gl.createProgram();
        gl.attachShader(p, compile(vs, gl.VERTEX_SHADER));
        gl.attachShader(p, compile(fs, gl.FRAGMENT_SHADER));
        gl.linkProgram(p);
        return p;
    }

    const pointProg = link(vertSrc, fragSrc);
    const lineProg = link(linVertSrc, linFragSrc);

    // ===== Particles — scale for device =====
    const isMobile = window.innerWidth < 768;
    const isTablet = window.innerWidth < 1024 && !isMobile;
    const COUNT = isMobile ? 30 : isTablet ? 50 : 80;
    const CONNECTION_DIST = isMobile ? 0.25 : 0.18;
    const particles = [];

    for (let i = 0; i < COUNT; i++) {
        particles.push({
            x: Math.random() * 2 - 1,
            y: Math.random() * 2 - 1,
            vx: (Math.random() - 0.5) * 0.0008,
            vy: (Math.random() - 0.5) * 0.0008,
            alpha: Math.random() * 0.25 + 0.05,
            size: Math.random() * 2.5 + 1.0,
            baseAlpha: Math.random() * 0.25 + 0.05
        });
    }

    // Buffers
    const pointData = new Float32Array(COUNT * 4); // x, y, alpha, size
    const pointBuf = gl.createBuffer();

    const maxLines = COUNT * COUNT;
    const lineData = new Float32Array(maxLines * 6); // 2 verts * (x, y, alpha)
    const lineBuf = gl.createBuffer();

    // Attributes
    const pPosLoc = gl.getAttribLocation(pointProg, 'aPosition');
    const pAlphaLoc = gl.getAttribLocation(pointProg, 'aAlpha');
    const pSizeLoc = gl.getAttribLocation(pointProg, 'aSize');
    const pColorLoc = gl.getUniformLocation(pointProg, 'uColor');

    const lPosLoc = gl.getAttribLocation(lineProg, 'aPosition');
    const lAlphaLoc = gl.getAttribLocation(lineProg, 'aAlpha');
    const lColorLoc = gl.getUniformLocation(lineProg, 'uColor');

    // Color: read from CSS --green variable, updates on theme change
    let color = [0.0, 1.0, 0.529];

    function hexToRgb01(hex) {
        hex = hex.trim().replace('#', '');
        if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
        return [
            parseInt(hex.slice(0,2), 16) / 255,
            parseInt(hex.slice(2,4), 16) / 255,
            parseInt(hex.slice(4,6), 16) / 255
        ];
    }

    function syncColor() {
        var val = getComputedStyle(document.documentElement).getPropertyValue('--green').trim();
        if (val && val[0] === '#') color = hexToRgb01(val);
    }

    syncColor();
    window.addEventListener('themechange', syncColor);

    // Mouse interaction
    let mouseX = 999, mouseY = 999;
    document.addEventListener('mousemove', (e) => {
        mouseX = (e.clientX / window.innerWidth) * 2 - 1;
        mouseY = -((e.clientY / window.innerHeight) * 2 - 1);
    }, { passive: true });

    function resize() {
        const dpr = Math.min(window.devicePixelRatio, isMobile ? 1 : 2);
        canvas.width = window.innerWidth * dpr;
        canvas.height = window.innerHeight * dpr;
        gl.viewport(0, 0, canvas.width, canvas.height);
    }

    window.addEventListener('resize', resize, { passive: true });
    resize();

    // ===== Scroll-based opacity =====
    let scrollOpacity = 1;
    const deckEl = document.getElementById('deck');
    if (deckEl) {
        deckEl.addEventListener('scroll', () => {
            // Keep full opacity throughout deck
            scrollOpacity = 1;
        }, { passive: true });
    }

    // ===== Animation Loop =====
    let time = 0;

    function frame() {
        requestAnimationFrame(frame);
        time += 0.016;

        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE);

        // Update particles
        for (let i = 0; i < COUNT; i++) {
            const p = particles[i];

            // Gentle sine drift
            p.x += p.vx + Math.sin(time * 0.3 + i) * 0.00005;
            p.y += p.vy + Math.cos(time * 0.2 + i * 0.7) * 0.00005;

            // Wrap
            if (p.x < -1.1) p.x = 1.1;
            if (p.x > 1.1) p.x = -1.1;
            if (p.y < -1.1) p.y = 1.1;
            if (p.y > 1.1) p.y = -1.1;

            // Mouse proximity glow
            const dx = p.x - mouseX;
            const dy = p.y - mouseY;
            const dist = Math.sqrt(dx * dx + dy * dy);
            const mouseBoost = dist < 0.3 ? (1 - dist / 0.3) * 0.3 : 0;

            // Pulse alpha
            p.alpha = (p.baseAlpha + Math.sin(time * 0.5 + i * 0.3) * 0.03 + mouseBoost) * scrollOpacity;

            const idx = i * 4;
            pointData[idx] = p.x;
            pointData[idx + 1] = p.y;
            pointData[idx + 2] = p.alpha;
            pointData[idx + 3] = p.size * (1 + mouseBoost * 2);
        }

        // Draw points
        gl.useProgram(pointProg);
        gl.uniform3fv(pColorLoc, color);

        gl.bindBuffer(gl.ARRAY_BUFFER, pointBuf);
        gl.bufferData(gl.ARRAY_BUFFER, pointData, gl.DYNAMIC_DRAW);

        gl.enableVertexAttribArray(pPosLoc);
        gl.vertexAttribPointer(pPosLoc, 2, gl.FLOAT, false, 16, 0);
        gl.enableVertexAttribArray(pAlphaLoc);
        gl.vertexAttribPointer(pAlphaLoc, 1, gl.FLOAT, false, 16, 8);
        gl.enableVertexAttribArray(pSizeLoc);
        gl.vertexAttribPointer(pSizeLoc, 1, gl.FLOAT, false, 16, 12);

        gl.drawArrays(gl.POINTS, 0, COUNT);

        // Draw connections
        let lineCount = 0;
        for (let i = 0; i < COUNT; i++) {
            for (let j = i + 1; j < COUNT; j++) {
                const dx = particles[i].x - particles[j].x;
                const dy = particles[i].y - particles[j].y;
                const dist = Math.sqrt(dx * dx + dy * dy);

                if (dist < CONNECTION_DIST) {
                    const alpha = (1 - dist / CONNECTION_DIST) * 0.06 * scrollOpacity;
                    const idx = lineCount * 6;
                    lineData[idx] = particles[i].x;
                    lineData[idx + 1] = particles[i].y;
                    lineData[idx + 2] = alpha;
                    lineData[idx + 3] = particles[j].x;
                    lineData[idx + 4] = particles[j].y;
                    lineData[idx + 5] = alpha;
                    lineCount++;
                }
            }
        }

        if (lineCount > 0) {
            gl.useProgram(lineProg);
            gl.uniform3fv(lColorLoc, color);

            gl.bindBuffer(gl.ARRAY_BUFFER, lineBuf);
            gl.bufferData(gl.ARRAY_BUFFER, lineData.subarray(0, lineCount * 6), gl.DYNAMIC_DRAW);

            gl.enableVertexAttribArray(lPosLoc);
            gl.vertexAttribPointer(lPosLoc, 2, gl.FLOAT, false, 12, 0);
            gl.enableVertexAttribArray(lAlphaLoc);
            gl.vertexAttribPointer(lAlphaLoc, 1, gl.FLOAT, false, 12, 8);

            gl.drawArrays(gl.LINES, 0, lineCount * 2);
        }
    }

    requestAnimationFrame(frame);
})();
