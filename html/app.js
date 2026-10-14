const resource = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'rs-radio';
const isBrowser = typeof GetParentResourceName !== 'function';
const app = document.getElementById('app');
const shell = document.getElementById('radio-shell');
const screen = document.getElementById('radio-screen');
const content = document.getElementById('screen-content');
const overlay = document.getElementById('roster-overlay');

const state = {
    channel: 0,
    channelLabel: 'OFFLINE',
    powered: false,
    battery: 100,
    volume: 55,
    assignment: { team: null, role: 'member', callsign: 'UNKNOWN' },
    channels: [],
    roster: [],
    distressBoard: [],
    profile: {
        volume: 55,
        favorites: [],
        recent: [],
        displayName: '',
        deafened: false,
        micClicks: true,
        allowMovement: true,
        overlayVisible: false,
        overlayMode: 'default',
        overlayScale: 100,
        overlayX: 78,
        overlayY: 8,
        radioPosition: 'right',
        radioX: 66,
        radioY: 2,
        radioScale: 100
    },
    ui: { showWindowLabels: false, scaleMin: 75, scaleMax: 120 },
    batteryConfig: { LowThreshold: 15 },
    defaultChannel: 200,
    playerId: null,
    tab: 'home',
    selected: null,
    entry: '',
    localTalking: false,
    distressActive: false,
    jammed: false,
    waypointEnabled: true,
    mutedPlayers: {},
    jammers: [],
    nearbyJammer: null,
    nearbyJammerDistance: null,
    jammerRange: 30,
    jammerConfig: { enabled: true, rangeMin: 10, rangeMax: 100, rangeStep: 5, defaultRange: 30 },
    voice: { provider: 'unknown', capabilities: { volume: true, deaf: true, perPlayerMute: true, serverOwnedChannels: false, serverOwnedPTT: false } }
};

const sound = {};
for (const name of ['click', 'on', 'off', 'denied', 'static', 'distress']) {
    sound[name] = new Audio(`sounds/radio_${name}.ogg`);
    sound[name].volume = name === 'static' ? .16 : name === 'distress' ? .4 : .32;
}
function play(name) {
    try { sound[name].currentTime = 0; sound[name].play()?.catch(() => {}); } catch (_) {}
}
let rpcSequence = 0;
async function nui(action, payload = {}) {
    if (isBrowser) return { ok: true, muted: state.mutedPlayers || {} };
    const requestId = `rsr-${Date.now().toString(36)}-${(++rpcSequence).toString(36)}`;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
        const response = await fetch(`https://${resource}/rpc`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ requestId, action, payload }),
            signal: controller.signal
        });
        const result = await response.json();
        if (result?.requestId && result.requestId !== requestId) return { ok: false, error: 'response_mismatch' };
        return result || { ok: false, error: 'empty_response' };
    } catch (error) {
        return { ok: false, error: error?.name === 'AbortError' ? 'rpc_timeout' : 'rpc_unavailable', requestId };
    } finally {
        clearTimeout(timeout);
    }
}

let closeRequestInFlight = false;
function requestClose() {
    if (closeRequestInFlight) return;
    closeRequestInFlight = true;
    flushProfilePreview();
    app.classList.remove('visible');
    app.setAttribute('aria-hidden', 'true');
    Promise.resolve(nui('close')).finally(() => { closeRequestInFlight = false; });
}

const esc = value => String(value ?? '').replace(/[&<>'"]/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
}[character]));
const checked = value => value ? 'checked' : '';

function profileValue(key, fallback) { return state.profile?.[key] ?? fallback; }
function teamLabel() {
    const team = state.assignment?.team;
    if (!team) return 'CITY NETWORK';
    return String(team).replaceAll('_', ' ').toUpperCase();
}
function conditionClass(value) {
    const safe = String(value || 'UNKNOWN').toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '');
    return safe || 'UNKNOWN';
}
function formatAge(seconds) {
    const value = Math.max(0, Math.round(seconds || 0));
    return value >= 60 ? `${Math.floor(value / 60)}m` : `${value}s`;
}
function distanceTo(member) {
    const selfMember = state.roster.find(entry => Number(entry.id) === Number(state.playerId));
    const selfCoords = selfMember?.coords;
    if (!member.coords || !selfCoords) return member.age > 999 ? '--' : `${member.age || 0}s`;
    const dx = member.coords.x - selfCoords.x;
    const dy = member.coords.y - selfCoords.y;
    const meters = Math.sqrt((dx * dx) + (dy * dy));
    return meters > 1000 ? `${(meters / 1000).toFixed(1)}km` : `${Math.round(meters)}m`;
}
function isMuted(id) {
    const muted = state.mutedPlayers || {};
    return muted[id] === true || muted[String(id)] === true || (Array.isArray(muted) && muted.map(Number).includes(Number(id)));
}
function isFavorite(channel) {
    const entry = state.channels.find(item => Number(item.id) === Number(channel));
    return entry?.favorite === true || (state.profile?.favorites || []).map(Number).includes(Number(channel));
}
function channelBadge(channel) {
    if (channel.favorite) return 'FAVORITE';
    if (channel.recommended) return 'RECOMMENDED';
    if (channel.recent) return 'RECENT';
    return channel.telemetry ? 'UNIT DATA' : channel.roster ? 'ROSTER' : 'VOICE';
}
function liveMembers() { return (state.roster || []).filter(member => !member.offline); }

function voiceStatusText() {
    if (state.profile?.deafened) return 'DEAFENED';
    if (state.voice?.capabilities?.volume === false) return 'CFX NATIVE';
    return `VOL ${Number(state.profile?.volume ?? state.volume ?? 0)}%`;
}

function renderHome() {
    const current = state.channels.find(entry => Number(entry.id) === Number(state.channel));
    const quick = [...state.channels]
        .filter(channel => !channel.locked)
        .sort((a, b) => Number(Boolean(b.favorite)) - Number(Boolean(a.favorite)) || Number(Boolean(b.recommended)) - Number(Boolean(a.recommended)) || Number(a.id) - Number(b.id))
        .slice(0, 4);
    const live = liveMembers();
    const traffic = state.traffic;
    return `
        <div class="home-stack">
            ${state.jammed ? '<div class="alert-strip">RF INTERFERENCE DETECTED · VOICE LINK SUSPENDED</div>' : ''}
            ${traffic ? `<section class="card traffic-card" role="status"><strong>${esc(traffic.banner || 'RADIO TRAFFIC')}</strong><div>${esc([traffic.code, traffic.callsign, traffic.title].filter(Boolean).join(' · '))}</div><p>${esc(traffic.body || '')}</p>${traffic.street ? `<small>${esc(traffic.street)}</small>` : ''}</section>` : ''}
            <section class="card hero-card">
                <div class="hero-kicker">${state.powered ? 'ACTIVE NETWORK' : 'RADIO READY'}</div>
                <div class="hero-line">
                    <div class="hero-frequency">${state.channel ? String(state.channel).padStart(3, '0') : '---'}</div>
                    <div class="hero-copy">
                        <strong>${esc(state.powered ? (state.channelLabel || current?.label || 'CONNECTED') : 'POWERED DOWN')}</strong>
                        <small>${esc(state.assignment?.callsign || 'NO CALLSIGN')} · ${voiceStatusText()}</small>
                    </div>
                    <span class="signal-pill ${state.jammed ? 'bad' : ''}">${state.jammed ? 'JAM' : state.powered ? 'LINK' : 'OFF'}</span>
                </div>
            </section>
            <div class="home-stats">
                <div class="stat"><b>${Math.max(0, Math.round(state.battery))}%</b><small>BATTERY</small></div>
                <div class="stat"><b>${live.length}</b><small>UNITS</small></div>
                <div class="stat"><b>${state.distressBoard?.length || 0}</b><small>ALERTS</small></div>
                <div class="stat"><b>${state.localTalking ? 'TX' : 'RX'}</b><small>RADIO</small></div>
            </div>
            <div class="section-label"><span>QUICK ACCESS</span><span>${quick.length} SAVED</span></div>
            <div class="quick-grid">
                ${quick.map(channel => `<button class="quick-channel" data-quick-channel="${Number(channel.id)}"><b>${String(channel.id).padStart(3, '0')}</b><span>${esc(channel.label)}</span></button>`).join('') || '<div class="empty">NO ACCESSIBLE CHANNELS</div>'}
            </div>
        </div>`;
}

function renderChannels() {
    if (!state.channels.length) return '<div class="empty">NO CONFIGURED FREQUENCIES</div>';
    return `
        <div class="direct-tune">
            <input id="direct-frequency" inputmode="numeric" maxlength="3" value="${esc(state.entry)}" placeholder="Direct tune 001-999" />
            <button id="direct-join">JOIN</button>
        </div>
        ${state.channels.map(channel => `
            <article class="channel-row ${channel.locked ? 'locked' : ''} ${Number(state.channel) === Number(channel.id) ? 'live' : ''}" data-channel="${Number(channel.id)}">
                <span class="freq">${String(channel.id).padStart(3, '0')}</span>
                <div>
                    <strong>${esc(channel.label)}</strong>
                    <small>${channelBadge(channel)}${channel.locked ? ' · LOCKED' : ''}</small>
                </div>
                <div class="channel-actions">
                    <button class="star-button ${channel.favorite ? 'active' : ''}" data-favorite="${Number(channel.id)}" title="Favorite">${channel.favorite ? '★' : '☆'}</button>
                    <button class="join-button">${Number(state.channel) === Number(channel.id) ? 'LIVE' : 'JOIN'}</button>
                </div>
            </article>`).join('')}`;
}

function renderUnits() {
    if (!state.roster.length) {
        const current = state.channels.find(entry => Number(entry.id) === Number(state.channel));
        if (current && !current.roster) return '<div class="empty">VOICE-ONLY FREQUENCY<br>UNIT ROSTER IS PRIVATE</div>';
        return '<div class="empty">NO OTHER UNITS<br>ON THIS FREQUENCY</div>';
    }
    return state.roster.map(member => `
        <article class="member ${member.talking ? 'talking' : ''} ${member.distress ? 'distress' : ''} ${member.offline ? 'offline' : ''} ${state.selected === member.id ? 'selected' : ''}" data-member="${Number(member.id)}">
            <div class="member-main">
                <strong>${esc(member.callsign || member.name)}</strong>
                <small>${esc(member.role || 'member')} · ${esc(member.name)}</small>
            </div>
            <div class="member-side">
                <div class="condition ${conditionClass(member.condition)}">${esc(member.jammed ? 'SIGNAL JAMMED' : member.condition || 'ONLINE')}${member.stale && !member.offline ? ' ?' : ''}</div>
                <small>${member.offline ? `LOST ${formatAge(member.age)}` : `${distanceTo(member)} · ${member.signal || 0}%`}</small>
            </div>
            <div class="location">${member.offline ? 'LAST SEEN · ' : ''}${esc(member.street || 'NO GPS')} · ${esc(member.zone || 'UNKNOWN')}</div>
        </article>`).join('');
}

function renderUnitDetail() {
    const member = state.roster.find(entry => Number(entry.id) === Number(state.selected)) || state.roster[0];
    if (!member) return '<div class="empty">SELECT A UNIT<br>TO VIEW RADIO DATA</div>';
    const vitals = member.vitals || {};
    return `
        <article class="unit-detail">
            <div class="detail-head">
                <div><strong>${esc(member.callsign || member.name)}</strong><small>${esc(member.role || 'member')} · ${esc(member.name || '')}</small></div>
                <div class="condition ${conditionClass(member.condition)}">${esc(member.condition || 'ONLINE')}</div>
            </div>
            <div class="detail-grid">
                <div class="detail-metric"><b>${member.signal ?? '--'}%</b><small>SIGNAL</small></div>
                <div class="detail-metric"><b>${distanceTo(member)}</b><small>DISTANCE</small></div>
                <div class="detail-metric"><b>${member.health ?? '--'}%</b><small>HEALTH</small></div>
                <div class="detail-metric"><b>${member.armor ?? '--'}%</b><small>ARMOR</small></div>
                <div class="detail-metric"><b>${vitals.hr ?? '--'}</b><small>HEART RATE</small></div>
                <div class="detail-metric"><b>${vitals.spo2 ?? '--'}</b><small>SPO₂</small></div>
            </div>
            <div class="section-label"><span>LAST POSITION</span><span>${member.offline ? formatAge(member.age) : 'LIVE'}</span></div>
            <div class="location">${esc(member.street || 'NO GPS')} · ${esc(member.zone || 'UNKNOWN')}</div>
            <div class="detail-actions">
                <button class="detail-action" data-back-units="true">BACK</button>
                ${Number(member.id) !== Number(state.playerId) && !member.offline && state.voice?.capabilities?.perPlayerMute !== false ? `<button class="detail-action" data-mute="${Number(member.id)}">${isMuted(member.id) ? 'UNMUTE' : 'MUTE'}</button>` : ''}
            </div>
        </article>`;
}

function renderDistress() {
    if (!state.distressBoard.length) return '<div class="empty">NO ACTIVE EMERGENCY SIGNALS<br>RECEIVED BY THIS RADIO</div>';
    return state.distressBoard.map(entry => `
        <article class="distress-card">
            <div class="distress-title">
                <strong>${esc(entry.callsign || entry.name || 'UNKNOWN')}</strong>
                <span data-expires="${Number(entry.expires || 0)}">${Math.max(0, Math.ceil(Number(entry.expires || 0) - (Date.now() / 1000)) || Number(entry.seconds) || 0)}s</span>
            </div>
            <small>${esc(entry.channelLabel || `FREQUENCY ${entry.channel}`)} · ${esc(entry.condition || 'UNKNOWN')}</small>
            <div class="distress-location">${esc(entry.street || 'UNKNOWN POSITION')} · ${esc(entry.zone || '')}</div>
            ${state.waypointEnabled && entry.coords ? `<button class="gps-button" data-waypoint='${esc(JSON.stringify(entry.coords))}'>SET GPS</button>` : ''}
        </article>`).join('');
}

function renderSettings() {
    const p = state.profile || {};
    const ui = state.ui || {};
    const jc = state.jammerConfig || {};
    const nearby = state.nearbyJammer;
    const allowed = (nearby?.allowedChannels || []).map(Number);
    const currentAllowed = state.channel > 0 && allowed.includes(Number(state.channel));
    const voiceCaps = state.voice?.capabilities || {};
    const volumeSetting = voiceCaps.volume === false
        ? `<div class="setting setting-note"><span>RADIO VOLUME</span><small>Managed by the current Cfx native voice stack. Channel-only volume override is not exposed by the documented server API.</small></div>`
        : `<label class="setting"><span>VOLUME ${Number(p.volume ?? state.volume)}%</span><input data-setting="volume" type="range" min="0" max="100" step="5" value="${Number(p.volume ?? state.volume)}" /></label>`;
    const displayNameSetting = ui.allowCustomDisplayName === false ? '' : `<label class="setting"><span>DISPLAY NAME</span><input id="setting-name" maxlength="32" value="${esc(p.displayName || '')}" placeholder="Use character name" /></label>`;
    const movementSetting = ui.allowMovementToggle === false ? '' : `<label class="setting toggle"><span>MOVE WHILE OPEN</span><input data-setting="allowMovement" type="checkbox" ${checked(p.allowMovement)} /></label>`;
    const radioScaleSetting = ui.allowScaleSettings === false ? '' : `<label class="setting"><span>RADIO SCALE ${Number(p.radioScale || 100)}%</span><input data-setting="radioScale" type="range" min="${ui.scaleMin || 75}" max="${ui.scaleMax || 120}" step="5" value="${Number(p.radioScale || 100)}" /></label>`;
    const overlayScaleSetting = ui.allowScaleSettings === false ? '' : `<label class="setting"><span>OVERLAY SCALE ${Number(p.overlayScale || 100)}%</span><input data-setting="overlayScale" type="range" min="60" max="160" step="5" value="${Number(p.overlayScale || 100)}" /></label>`;
    const positionSettings = ui.allowPositionSettings === false ? '' : `
        <label class="setting"><span>RADIO X ${Number(p.radioX || 0)}%</span><input data-setting="radioX" type="range" min="0" max="92" step="1" value="${Number(p.radioX || 0)}" /></label>
        <label class="setting"><span>RADIO Y ${Number(p.radioY || 0)}%</span><input data-setting="radioY" type="range" min="0" max="90" step="1" value="${Number(p.radioY || 0)}" /></label>
        <label class="setting"><span>OVERLAY X ${Number(p.overlayX || 0)}%</span><input data-setting="overlayX" type="range" min="0" max="95" step="1" value="${Number(p.overlayX || 0)}" /></label>
        <label class="setting"><span>OVERLAY Y ${Number(p.overlayY || 0)}%</span><input data-setting="overlayY" type="range" min="0" max="95" step="1" value="${Number(p.overlayY || 0)}" /></label>
        <div class="setting-buttons"><button data-preset="left">RADIO LEFT</button><button data-preset="right">RADIO RIGHT</button><button data-preset="reset">RESET LAYOUT</button><button data-profile-reset="true">RESET ALL</button></div>`;
    return `
        <div class="settings-grid">
            ${displayNameSetting}
            ${volumeSetting}
            <label class="setting toggle"><span>RADIO DEAFEN</span><input data-setting="deafened" type="checkbox" ${checked(p.deafened)} /></label>
            <label class="setting toggle"><span>MIC CLICKS</span><input data-setting="micClicks" type="checkbox" ${checked(p.micClicks)} /></label>
            ${movementSetting}
            <label class="setting toggle"><span>PLAYER OVERLAY</span><input data-setting="overlayVisible" type="checkbox" ${checked(p.overlayVisible)} /></label>
            <label class="setting"><span>OVERLAY MODE</span><select data-setting="overlayMode"><option value="default" ${p.overlayMode === 'default' ? 'selected' : ''}>ON RADIO</option><option value="always" ${p.overlayMode === 'always' ? 'selected' : ''}>ALWAYS</option><option value="never" ${p.overlayMode === 'never' ? 'selected' : ''}>NEVER</option></select></label>
            ${radioScaleSetting}${overlayScaleSetting}${positionSettings}
            ${jc.enabled ? `
                <section class="jammer-panel">
                    <div class="jammer-heading"><strong>RF CONTROL</strong><span>${nearby ? `${nearby.enabled ? 'ACTIVE' : 'DISABLED'} · ${Number(state.nearbyJammerDistance || 0).toFixed(1)}m` : 'NO JAMMER NEARBY'}</span></div>
                    <label class="setting"><span>RANGE ${Number(state.jammerRange || jc.defaultRange || 30)}m</span><input id="jammer-range" type="range" min="${Number(jc.rangeMin || 10)}" max="${Number(jc.rangeMax || 100)}" step="${Number(jc.rangeStep || 5)}" value="${Number(state.jammerRange || jc.defaultRange || 30)}" /></label>
                    <small class="jammer-copy">${nearby ? `ID ${esc(nearby.id)} · RANGE ${Number(nearby.range || 0)}m · PASS ${allowed.length ? allowed.join(', ') : 'NONE'}${state.channel > 0 ? ` · CH ${state.channel} ${currentAllowed ? 'PASSES' : 'BLOCKED'}` : ''}` : 'Deploy a jammer or move close to one to configure it.'}</small>
                    <div class="jammer-actions"><button data-jammer="place">DEPLOY</button><button data-jammer="refresh">REFRESH</button><button data-jammer="range" ${nearby ? '' : 'disabled'}>APPLY RANGE</button><button data-jammer="toggle" ${nearby ? '' : 'disabled'}>${nearby?.enabled ? 'TURN OFF' : 'TURN ON'}</button><button data-jammer="allow" ${nearby && state.channel > 0 ? '' : 'disabled'}>${currentAllowed ? 'BLOCK CURRENT' : 'PASS CURRENT'}</button><button data-jammer="remove" ${nearby?.canRemove ? '' : 'disabled'}>RECOVER</button></div>
                </section>` : ''}
        </div>`;
}

function bindContentActions() {
    content.querySelectorAll('[data-quick-channel]').forEach(button => { button.onclick = () => joinChannel(Number(button.dataset.quickChannel)); });
    const directInput = document.getElementById('direct-frequency');
    if (directInput) {
        directInput.oninput = () => { directInput.value = directInput.value.replace(/\D/g, '').slice(0, 3); state.entry = directInput.value; updateKeypadLabel(); };
        directInput.onkeydown = event => { if (event.key === 'Enter' && directInput.value) joinChannel(Number(directInput.value)); };
    }
    const directJoin = document.getElementById('direct-join');
    if (directJoin) directJoin.onclick = () => { if (state.entry) joinChannel(Number(state.entry)); else play('denied'); };
    content.querySelectorAll('[data-member]').forEach(element => {
        element.onclick = () => { state.selected = Number(element.dataset.member); state.tab = 'unitDetail'; play('click'); render(); };
    });
    content.querySelectorAll('[data-back-units]').forEach(button => { button.onclick = () => showTab('units'); });
    content.querySelectorAll('[data-mute]').forEach(button => {
        button.onclick = async event => {
            event.stopPropagation();
            const response = await nui('toggleMutePlayer', { id: Number(button.dataset.mute) });
            if (response?.muted) state.mutedPlayers = response.muted;
            play('click'); render();
        };
    });
    content.querySelectorAll('[data-channel]').forEach(element => {
        element.onclick = event => {
            if (event.target.closest('[data-favorite]')) return;
            const channel = state.channels.find(entry => Number(entry.id) === Number(element.dataset.channel));
            if (!channel || channel.locked) return play('denied');
            joinChannel(channel.id);
        };
    });
    content.querySelectorAll('[data-favorite]').forEach(button => {
        button.onclick = event => {
            event.stopPropagation();
            const channel = Number(button.dataset.favorite);
            const entry = state.channels.find(item => Number(item.id) === channel);
            if (!entry) return;
            entry.favorite = !entry.favorite;
            nui('favorite', { channel, favorite: entry.favorite });
            play('click'); render();
        };
    });
    content.querySelectorAll('[data-waypoint]').forEach(button => {
        button.onclick = () => { try { nui('waypoint', { coords: JSON.parse(button.dataset.waypoint) }); } catch (_) {} play('click'); };
    });
    content.querySelectorAll('[data-setting]').forEach(input => {
        const readValue = () => input.type === 'checkbox' ? input.checked : input.type === 'range' ? Number(input.value) : input.value;

        if (input.type === 'range') {
            input.oninput = () => {
                const key = input.dataset.setting;
                const value = readValue();
                updateSettingLabel(input);
                previewProfile({ [key]: value });
            };
            input.onchange = () => {
                const key = input.dataset.setting;
                const value = readValue();
                updateSettingLabel(input);
                previewProfile({ [key]: value }, true);
            };
        } else {
            input.onchange = () => {
                const key = input.dataset.setting;
                const value = readValue();
                updateProfile({ [key]: value });
            };
        }
    });
    const nameInput = document.getElementById('setting-name');
    if (nameInput) nameInput.onchange = () => updateProfile({ displayName: nameInput.value.trim() });
    content.querySelectorAll('[data-preset]').forEach(button => {
        button.onclick = () => {
            const preset = button.dataset.preset;
            if (preset === 'left') updateProfile({ radioPosition: 'left', radioX: 1, radioY: 2 });
            if (preset === 'right') updateProfile({ radioPosition: 'right', radioX: 66, radioY: 2 });
            if (preset === 'reset') updateProfile({ radioPosition: 'right', radioX: 66, radioY: 2, radioScale: 100, overlayX: 78, overlayY: 8, overlayScale: 100 });
            play('click');
        };
    });
    const jammerRange = document.getElementById('jammer-range');
    if (jammerRange) jammerRange.oninput = () => {
        state.jammerRange = Number(jammerRange.value);
        const label = jammerRange.closest('.setting')?.querySelector('span');
        if (label) label.textContent = `RANGE ${state.jammerRange}m`;
    };
    content.querySelectorAll('[data-jammer]').forEach(button => {
        button.onclick = () => {
            const action = button.dataset.jammer;
            const range = Number(document.getElementById('jammer-range')?.value || state.jammerRange || state.jammerConfig?.defaultRange || 30);
            state.jammerRange = range;
            if (action === 'place') nui('placeJammer', { range });
            else if (action === 'refresh') nui('requestJammerStatus');
            else if (action === 'range') nui('jammerAction', { action: 'range', value: range });
            else if (action === 'allow') nui('jammerAction', { action: 'allow', value: Number(state.channel) });
            else nui('jammerAction', { action });
            play('click');
        };
    });
    content.querySelectorAll('[data-profile-reset]').forEach(button => { button.onclick = () => { nui('resetProfile'); play('click'); }; });
}

function renderOverlay() {
    const mode = profileValue('overlayMode', 'default');
    const enabled = profileValue('overlayVisible', false);
    const shouldShow = mode !== 'never' && enabled && (mode === 'always' || state.powered);
    overlay.classList.toggle('visible', shouldShow);
    overlay.setAttribute('aria-hidden', shouldShow ? 'false' : 'true');
    overlay.style.left = `${Number(profileValue('overlayX', 78))}vw`;
    overlay.style.top = `${Number(profileValue('overlayY', 8))}vh`;
    overlay.style.transform = `scale(${Number(profileValue('overlayScale', 100)) / 100})`;
    overlay.innerHTML = `
        <header><strong>${esc(state.channelLabel || 'RADIO OFFLINE')}</strong><span>${state.jammed ? 'JAMMED' : String(state.channel || '---')}</span></header>
        ${liveMembers().map(member => `<div class="overlay-member ${member.talking ? 'talking' : ''} ${member.distress ? 'distress' : ''}"><b>${esc(member.callsign || member.name)}</b><span>${member.talking ? 'TX' : member.jammed ? 'JAM' : esc(member.condition || 'ONLINE')}</span></div>`).join('') || '<div class="overlay-empty">NO UNITS</div>'}`;
    fitPanel(overlay, Number(profileValue('overlayX', 78)), Number(profileValue('overlayY', 8)),
        Number(profileValue('overlayScale', 100)) / 100);
    if (shouldShow && app.classList.contains('visible')) {
        const handset = shell.getBoundingClientRect(), panel = overlay.getBoundingClientRect();
        if (panel.left < handset.right && panel.right > handset.left
            && panel.top < handset.bottom && panel.bottom > handset.top) {
            const margin = 8;
            const leftSpace = handset.left - margin * 2;
            const rightSpace = innerWidth - handset.right - margin * 2;
            const useLeft = leftSpace >= rightSpace;
            const space = Math.max(1, useLeft ? leftSpace : rightSpace);
            const scale = Math.min(panel.width, space) / overlay.offsetWidth;
            overlay.style.transform = `scale(${scale})`;
            overlay.style.left = `${useLeft ? Math.max(margin, handset.left - overlay.offsetWidth * scale - margin) : handset.right + margin}px`;
        }
    }
}
function fitPanel(panel, x, y, requestedScale) {
    const margin = 8;
    const width = panel.offsetWidth, height = panel.offsetHeight;
    if (!width || !height) return;
    const scale = Math.max(.1, Math.min(requestedScale,
        (innerWidth - margin * 2) / width, (innerHeight - margin * 2) / height));
    const left = Math.max(margin, Math.min(innerWidth * x / 100, innerWidth - width * scale - margin));
    const top = Math.max(margin, Math.min(innerHeight * y / 100, innerHeight - height * scale - margin));
    panel.style.left = `${left}px`; panel.style.top = `${top}px`;
    panel.style.transform = `scale(${scale})`;
}
function applyLayout() {
    fitPanel(shell, Number(profileValue('radioX', 66)), Number(profileValue('radioY', 2)),
        Number(profileValue('radioScale', 100)) / 100);
}
function navTabForCurrent() { return state.tab === 'unitDetail' ? 'units' : state.tab; }
function updateKeypadLabel() {
    const label = document.getElementById('keypad-entry');
    if (label) label.textContent = state.entry ? `FREQ ${state.entry}` : '';
}
function renderScreen() {
    screen.classList.toggle('powered-off', !state.powered);
    screen.classList.toggle('signal-jammed', state.jammed);
    document.getElementById('screen-team').textContent = teamLabel();
    document.getElementById('screen-signal').textContent = state.jammed ? 'LINK JAM' : `LINK ${state.powered ? '100' : '000'}`;
    document.getElementById('screen-battery').textContent = `BAT ${Math.max(0, Math.round(state.battery))}`;
    document.getElementById('screen-frequency').textContent = state.channel ? String(state.channel).padStart(3, '0') : '---';
    document.getElementById('screen-channel').textContent = state.powered ? state.channelLabel : 'RADIO OFFLINE';
    document.getElementById('screen-callsign').textContent = `${state.assignment?.callsign || 'NO CALLSIGN'} · ${voiceStatusText()}`;
    const talk = document.getElementById('screen-talk');
    talk.textContent = state.jammed ? 'JAM' : state.localTalking ? 'TX' : (state.powered ? 'RX' : 'OFF');
    talk.classList.toggle('talking', state.localTalking && !state.jammed);
    document.getElementById('screen-battery').classList.toggle('low', state.battery <= (state.batteryConfig?.LowThreshold ?? 15));
    const distressButton = document.getElementById('distress-button');
    distressButton.textContent = state.distressActive ? 'CANCEL' : 'SOS';
    distressButton.classList.toggle('active', state.distressActive);
    document.getElementById('last-sync').textContent = `RS LINK · ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    updateKeypadLabel();
    document.querySelectorAll('.tab').forEach(tab => tab.classList.toggle('active', tab.dataset.tab === navTabForCurrent()));
    content.innerHTML = state.tab === 'channels' ? renderChannels()
        : state.tab === 'units' ? renderUnits()
        : state.tab === 'unitDetail' ? renderUnitDetail()
        : state.tab === 'distress' ? renderDistress()
        : state.tab === 'settings' ? renderSettings()
        : renderHome();
    bindContentActions();
}
function render() {
    applyLayout();
    renderScreen();
    renderOverlay();
    document.querySelectorAll('.window-label').forEach(element => { element.style.display = state.ui?.showWindowLabels ? '' : 'none'; });
}
function showTab(tab) { state.tab = tab; play('click'); render(); }
function joinChannel(channel) {
    const configured = state.channels.find(entry => Number(entry.id) === Number(channel));
    if (configured?.locked) return play('denied');
    nui('join', { channel: Number(channel) });
    play('static');
    state.entry = '';
    render();
}
function togglePower() {
    if (state.powered) {
        nui('leave');
        state.powered = false;
        state.channel = 0;
        play('off');
    } else {
        const target = state.defaultChannel || state.channel || state.channels.find(channel => !channel.locked)?.id || 200;
        joinChannel(target);
        play('on');
    }
    render();
}
function sendDistress() { nui('distress'); play('click'); }
function updateProfile(patch) {
    patch = { ...pendingProfilePatch, ...patch };
    pendingProfilePatch = {};
    if (profilePreviewTimer) clearTimeout(profilePreviewTimer);
    profilePreviewTimer = 0;
    state.profile = { ...(state.profile || {}), ...patch };
    state.volume = state.profile.volume ?? state.volume;
    nui('profile', patch);
    render();
}

let profilePreviewTimer = 0;
let pendingProfilePatch = {};
function flushProfilePreview() {
    if (profilePreviewTimer) clearTimeout(profilePreviewTimer);
    profilePreviewTimer = 0;
    const patch = pendingProfilePatch;
    pendingProfilePatch = {};
    if (Object.keys(patch).length) nui('profile', patch);
}
function previewProfile(patch, sendNow = false) {
    state.profile = { ...(state.profile || {}), ...patch };
    state.volume = state.profile.volume ?? state.volume;
    applyLayout();
    renderOverlay();
    renderScreenHeaderOnly();

    if (profilePreviewTimer) clearTimeout(profilePreviewTimer);
    pendingProfilePatch = { ...pendingProfilePatch, ...patch };
    if (sendNow) flushProfilePreview();
    else profilePreviewTimer = setTimeout(flushProfilePreview, 275);
}

function renderScreenHeaderOnly() {
    const battery = document.getElementById('screen-battery');
    const callsign = document.getElementById('screen-callsign');
    if (battery) battery.textContent = `BAT ${Math.max(0, Math.round(state.battery))}`;
    if (callsign) {
        callsign.textContent = `${state.assignment?.callsign || 'NO CALLSIGN'} · ${voiceStatusText()}`;
    }
}

function updateSettingLabel(input) {
    const label = input.closest('.setting')?.querySelector('span');
    if (!label) return;
    const key = input.dataset.setting;
    if (input.type === 'range') {
        const names = { volume: 'VOLUME', radioScale: 'RADIO SCALE', overlayScale: 'OVERLAY SCALE', radioX: 'RADIO X', radioY: 'RADIO Y', overlayX: 'OVERLAY X', overlayY: 'OVERLAY Y' };
        const suffix = key === 'volume' || key === 'radioScale' || key === 'overlayScale' || key === 'radioX' || key === 'radioY' || key === 'overlayX' || key === 'overlayY' ? '%' : '';
        label.textContent = `${names[key] || key.toUpperCase()} ${Number(input.value)}${suffix}`;
    }
}

document.querySelectorAll('.hotspot').forEach(button => {
    button.onclick = async () => {
        const action = button.dataset.action;
        if (action === 'power') togglePower();
        if (action === 'volume') {
            const current = Number(state.profile?.volume ?? state.volume ?? 0);
            const requested = current >= 100 ? 20 : Math.min(100, current + 20);
            const response = await nui('volume', { volume: requested });
            if (response?.ok === false) { play('denied'); return; }
            const applied = Number(response?.volume ?? requested);
            state.volume = applied; state.profile.volume = applied; play('click'); render();
        }
        if (action === 'distress') sendDistress();
        if (action === 'close') requestClose();
    };
});
document.getElementById('distress-button').onclick = sendDistress;
document.querySelectorAll('.tab').forEach(tab => { tab.onclick = () => showTab(tab.dataset.tab); });

document.addEventListener('keydown', event => {
    // ---------------------------------------------------------------------
    // Browser default-action guard
    //
    // While this UI is open the client runs SetNuiFocus(true, true), so CEF --
    // not the game -- sees these keys first. F11 is CEF's FULLSCREEN toggle:
    // pressing a device's own open/close key while its UI was focused drove
    // the embedded browser through a fullscreen transition and took the client
    // down with it. Opening was always safe because focus is not set yet, and
    // Escape was always safe because it already calls preventDefault below.
    // That asymmetry was the entire bug.
    //
    // preventDefault suppresses only the BROWSER's default action. The Lua
    // RegisterKeyMapping command is dispatched by the command system over raw
    // input (SetNuiFocusKeepInput), so the key still closes the device -- it
    // just no longer toggles fullscreen on the way out. F5 (reload), F10 (menu
    // bar) and F12 (devtools) are the same class of browser default and are
    // swallowed here for the same reason, whichever F-key a device is bound to.
    // ---------------------------------------------------------------------
    if (event.key === 'F5' || event.key === 'F10' || event.key === 'F11' || event.key === 'F12') {
        event.preventDefault();
        return;
    }
    if (event.key === 'Escape') {
        event.preventDefault();
        if (!event.repeat) requestClose();
        return;
    }
    const active = document.activeElement;
    const typing = active && ['INPUT', 'SELECT', 'TEXTAREA'].includes(active.tagName);
    if (typing) return;
    if (/^[0-9]$/.test(event.key) && state.entry.length < 3 && state.tab !== 'settings') { state.entry += event.key; render(); }
    if (event.key === 'Enter' && state.entry) joinChannel(Number(state.entry));
    if (event.key === 'Backspace' && state.tab !== 'settings') { state.entry = state.entry.slice(0, -1); render(); }
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
        const tabs = ['home', 'channels', 'units', 'distress', 'settings'];
        const current = tabs.indexOf(navTabForCurrent());
        const direction = event.key === 'ArrowRight' ? 1 : -1;
        state.tab = tabs[(current + direction + tabs.length) % tabs.length];
        play('click'); render();
    }
});

window.addEventListener('message', async event => {
    const data = event.data || {};
    if (data.action === 'requestClose') {
        requestClose();
        return;
    }
    if (data.action === 'visible') {
        app.classList.toggle('visible', data.visible === true);
        app.setAttribute('aria-hidden', data.visible ? 'false' : 'true');
    }
    if (data.action === 'state') {
        Object.assign(state, data);
        state.profile = { ...state.profile, ...(data.profile || {}), displayName: data.profile?.displayName || '' };
        state.volume = state.profile.volume ?? data.volume ?? state.volume;
        if (!['home','channels','units','unitDetail','distress','settings'].includes(state.tab)) state.tab = 'home';
        const response = await nui('getMutedPlayers');
        if (response?.muted) state.mutedPlayers = response.muted;
    }
    if (data.action === 'joined') {
        if (data.voice) state.voice = data.voice;
        if (data.profile) state.profile = { ...state.profile, ...data.profile, displayName: data.profile.displayName || '' };
        state.localTalking = data.talking === true;
        Object.assign(state, { channel: data.channel, channelLabel: data.label, powered: true, battery: data.battery, volume: data.volume ?? state.volume, jammed: data.jammed === true });
        if (data.channels) state.channels = data.channels;
        if (data.volume !== undefined) state.profile.volume = data.volume;
    }
    if (data.action === 'left') Object.assign(state, { channel: 0, channelLabel: 'OFFLINE', powered: false, roster: [], jammed: false, localTalking: false, traffic: null });
    if (data.action === 'reset') {
        if (profilePreviewTimer) clearTimeout(profilePreviewTimer);
        profilePreviewTimer = 0; pendingProfilePatch = {};
        Object.assign(state, { channel: 0, powered: false, localTalking: false, jammed: false,
            roster: [], distressBoard: [], distressActive: false, traffic: null, nearbyJammer: null,
            channels: [], playerId: null, profile: {}, assignment: {} });
        app.classList.remove('visible');
    }
    if (data.action === 'traffic') {
        state.traffic = data;
        if (data.priority === 'emergency') play('distress');
    }
    if (data.action === 'roster') state.roster = data.roster || [];
    if (data.action === 'distressBoard') state.distressBoard = data.distressBoard || [];
    if (data.action === 'battery') state.battery = data.battery;
    if (data.action === 'volume') { state.volume = data.volume; state.profile.volume = data.volume; state.profile.deafened = data.deafened === true; }
    if (data.action === 'profile') { state.profile = { ...state.profile, ...(data.profile || {}), displayName: data.profile?.displayName || '' }; state.volume = state.profile.volume ?? state.volume; if (data.channels) state.channels = data.channels; }
    if (data.action === 'jammer') state.jammed = data.jammed === true;
    if (data.action === 'jammers') state.jammers = data.jammers || [];
    if (data.action === 'jammerStatus') { state.nearbyJammer = data.jammer || null; state.nearbyJammerDistance = data.distance ?? null; if (data.jammer?.range) state.jammerRange = Number(data.jammer.range); }
    if (data.action === 'localTalking') state.localTalking = data.talking === true;
    if (data.action === 'nativePttClick') play('click');
    if (data.action === 'memberTalking') { const member = state.roster.find(entry => Number(entry.id) === Number(data.id)); if (member) member.talking = data.talking === true; }
    if (data.action === 'distressState') { state.distressActive = data.active === true; if (data.active) play('distress'); }
    if (data.action === 'distressAlert') { play('distress'); screen.classList.add('distress-alert'); setTimeout(() => screen.classList.remove('distress-alert'), 1800); if (state.tab !== 'settings') state.tab = 'distress'; }
    if (data.action === 'denied') play('denied');
    render();
});

setInterval(() => {
    const sync = document.getElementById('last-sync');
    if (sync) sync.textContent = `RS LINK · ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
    document.querySelectorAll('[data-expires]').forEach(element => {
        const seconds = Math.max(0, Math.ceil(Number(element.dataset.expires || 0) - (Date.now() / 1000)));
        element.textContent = `${seconds}s`;
    });
}, 1000);

window.addEventListener('resize', () => { applyLayout(); renderOverlay(); });

if (isBrowser) {
    Object.assign(state, {
        powered: true,
        channel: 101,
        channelLabel: 'LSPD DISPATCH',
        battery: 78,
        playerId: 1,
        assignment: { team: 'lspd', role: 'officer', callsign: '2-LINCOLN-14' },
        channels: [
            { id: 101, label: 'LSPD DISPATCH', telemetry: true, roster: true, locked: false, favorite: true, recommended: true },
            { id: 102, label: 'BCSO DISPATCH', telemetry: true, roster: true, locked: true },
            { id: 110, label: 'EMS DISPATCH', telemetry: true, roster: true, locked: true },
            { id: 120, label: 'EMERGENCY INTEROP', telemetry: true, roster: true, locked: false, recommended: true },
            { id: 200, label: 'CITYWIDE PUBLIC', telemetry: false, roster: true, locked: false, favorite: true },
            { id: 201, label: 'SERVICES NET', telemetry: false, roster: true, locked: false },
            { id: 911, label: 'EMERGENCY NETWORK', telemetry: false, roster: true, locked: false }
        ],
        roster: [
            { id: 1, callsign: '2-LINCOLN-14', name: 'Alex Mercer', role: 'officer', condition: 'STABLE', health: 91, armor: 38, street: 'Mission Row', zone: 'Downtown', signal: 100, talking: true, age: 0, coords: {x: 0, y: 0}, vitals: { hr: 92, spo2: 98 } },
            { id: 2, callsign: 'ADAM-23', name: 'Mara Cole', role: 'officer', condition: 'STABLE', health: 100, armor: 52, street: 'Strawberry Ave', zone: 'Pillbox Hill', signal: 88, age: 2, coords: {x: 110, y: 42}, vitals: { hr: 84, spo2: 99 } },
            { id: 3, callsign: 'EMS-7', name: 'Dane Ross', role: 'paramedic', condition: 'INJURED', health: 62, armor: 0, street: 'Elgin Ave', zone: 'Textile City', signal: 71, distress: true, age: 4, coords: {x: 320, y: 140}, vitals: { hr: 118, spo2: 94 } }
        ],
        distressBoard: [
            { id: 3, channel: 120, channelLabel: 'EMERGENCY INTEROP', callsign: 'EMS-7', condition: 'INJURED', street: 'Elgin Ave', zone: 'Textile City', seconds: 48, expires: Math.floor(Date.now() / 1000) + 48, coords: {x: 320, y: 140} }
        ],
        jammerConfig: { enabled: true, rangeMin: 10, rangeMax: 100, rangeStep: 5, defaultRange: 30 },
        nearbyJammer: null,
        nearbyJammerDistance: null,
        jammerRange: 35
    });
    app.classList.add('visible');
    render();
}
