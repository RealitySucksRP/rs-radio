/*
 * RS Enhanced cap scaling
 * ---------------------------------------------------------------------------
 * This UI is already viewport-driven (min(23vw, 390px) and friends), so it
 * scales correctly on its own. What limits it on GTA V Enhanced is the pixel
 * CAP in those expressions: at 1440p/4K the viewport term grows but can be
 * clamped by the authored 390px cap, so the radio occupies a smaller share of the screen
 * than it did on Legacy.
 *
 * The fix is to scale the caps only. This deliberately does NOT use CSS zoom:
 * zoom scales viewport units as well (measured: 50vw -> 100vw at zoom 2),
 * which double-applies on a layout like this one and blows it up.
 *
 * Exposes --rs-scale on :root. The stylesheet multiplies its px caps by it,
 * so viewport terms are untouched.
 *
 * Legacy safety: at 1920x1080 the value is exactly 1, so every calc() resolves
 * to the original authored number and nothing changes. The 2.0 ceiling keeps
 * 3840x2160 at the same physical proportion as 1920x1080 instead of shrinking
 * the handset on 4K Enhanced clients.
 */
(function () {
    'use strict';

    var DESIGN_W = 1920;
    var DESIGN_H = 1080;
    var MAX = 2.0;

    function compute() {
        if (typeof window.RS_ENHANCED_FORCE === 'number') return window.RS_ENHANCED_FORCE;

        var max = typeof window.RS_ENHANCED_MAX === 'number' ? window.RS_ENHANCED_MAX : MAX;
        var w = window.innerWidth || DESIGN_W;
        var h = window.innerHeight || DESIGN_H;

        var s = Math.min(w / DESIGN_W, h / DESIGN_H);
        if (!isFinite(s) || s < 1) return 1;
        return s > max ? max : s;
    }

    function apply() {
        var s = compute();
        document.documentElement.style.setProperty('--rs-scale', String(s));
        document.documentElement.setAttribute('data-rs-scale', s.toFixed(3));
    }

    window.RSEnhanced = { apply: apply, get: compute };

    apply();
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', apply);
    }
    window.addEventListener('resize', apply);
})();
