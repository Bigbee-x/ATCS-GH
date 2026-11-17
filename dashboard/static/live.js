import {LiveModel, ARMS, JUNCTION_NAMES, finite, formatTime, phaseLabel, decisionLabel} from './live-model.mjs';

const model = new LiveModel();
const $ = id => document.getElementById(id);
const text = (id, value) => { if ($(id)) $(id).textContent = value; };
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const number = (n, digits = 0) => finite(n) === null ? '—' : n.toLocaleString('en', {minimumFractionDigits: digits, maximumFractionDigits: digits});
const seconds = n => finite(n) === null ? '—' : `${number(n, 1)}s`;
const colors = {J0: '#21765b', J1: '#9c793f', J2: '#717aa0'};
const lampColors = {green: '#21765b', yellow: '#b47a28', red: '#ba534a', unknown: '#c4cec3'};
const lamp = value => Object.hasOwn(lampColors, value) ? value : 'unknown';
const action = n => ['HOLD', 'NS THROUGH', 'NS LEFT', 'EW THROUGH', 'EW LEFT'][n] || '—';
let socket = null, socketOpen = false, endpoint = null, session = null;
let retryTimer = null, connecting = false, generation = 0, renderPending = false;
let selected = 'J0', windowSeconds = 300, chartSignature = '', tabsSignature = '';
let displayedPacket = null;

function renderSoon() {
    if (renderPending) return;
    renderPending = true;
    requestAnimationFrame(() => { renderPending = false; render(); });
}

async function discoverAndConnect(force = false) {
    if (connecting) return;
    connecting = true;
    try {
        const response = await fetch('/api/live-config', {cache: 'no-store', signal: AbortSignal.timeout(4000)});
        if (!response.ok) throw new Error('Dashboard server unavailable');
        const config = await response.json();
        if (!config.available) {
            if (socket) closeSocket();
            text('sourceEndpoint', 'No active simulation');
            renderSoon();
            return;
        }
        const changed = endpoint !== config.ws_url || (session && session !== config.session_id);
        if (changed && endpoint) {
            model.reset();
            model.event('connection', 'Following the newly started simulation');
            chartSignature = '';
        }
        endpoint = config.ws_url;
        session = config.session_id;
        text('sourceEndpoint', endpoint);
        if (force || changed || !socket || socket.readyState === WebSocket.CLOSED) openSocket();
    } catch (error) {
        // A dashboard HTTP interruption must not terminate a healthy traffic socket.
        if (!socketOpen) text('connectionDetail', 'Dashboard unavailable; retrying connection');
    } finally {
        connecting = false;
    }
}

function closeSocket() {
    generation += 1;
    if (socket) socket.close();
    socket = null;
    socketOpen = false;
    model.disconnected();
}

function openSocket() {
    clearTimeout(retryTimer);
    closeSocket();
    const token = generation;
    try { socket = new WebSocket(endpoint); }
    catch { retryTimer = setTimeout(() => discoverAndConnect(), 3000); return; }
    socket.onopen = () => { if (token === generation) { socketOpen = true; renderSoon(); } };
    socket.onmessage = event => {
        if (token !== generation) return;
        try {
            const packet = JSON.parse(event.data);
            const previouslyReady = model.connectionReady;
            if (model.ingest(packet)) {
                if (!previouslyReady && model.connectionReady) model.event('connection', 'Live traffic observations received');
                renderSoon();
            }
        } catch (error) {
            model.event('data', 'An unreadable traffic packet was ignored');
            renderSoon();
        }
    };
    socket.onclose = () => {
        if (token !== generation) return;
        socketOpen = false;
        model.disconnected();
        model.event('connection', 'Traffic connection lost; reconnecting');
        renderSoon();
        retryTimer = setTimeout(() => discoverAndConnect(), 3000);
    };
    socket.onerror = () => { if (token === generation) socket.close(); };
}

function render() {
    const status = model.status(socketOpen);
    document.body.dataset.stream = status.key;
    $('connectionStatus').className = `connection-status ${status.key}`;
    $('connectionStatus').innerHTML = `<span class="status-dot"></span>${esc(status.label)}`;
    text('connectionDetail', status.detail);
    text('simulationTime', formatTime(model.time));
    text('scenarioName', model.scenario ? model.scenario.replaceAll('_', ' ') : 'Scenario not reported');
    const modes = {ai: 'Adaptive AI', baseline: 'Fixed timer', demo: 'Demo controller'};
    text('controlMode', modes[model.controlMode] || 'Awaiting controller');
    document.querySelector('.decision-mark').textContent = {ai:'AI', baseline:'FT', demo:'DM'}[model.controlMode] || '—';
    text('networkTitle', model.mode === 'corridor' ? 'Corridor overview.' : model.mode === 'single' ? 'Junction overview.' : 'Traffic overview.');
    text('networkSubtitle', model.mode === 'corridor' ? 'N6 Nsawam Road · Accra · Three junctions, one live picture.' : 'Your road network, signals and AI decisions in one place.');
    text('mapNetworkName', model.mode === 'corridor' ? 'N6 CORRIDOR' : 'ACHIMOTA');
    const m = model.metrics;
    text('kpiActive', number(m.active_vehicles));
    text('kpiQueue', number(m.current_stopped_vehicles));
    text('kpiWait', seconds(m.current_mean_wait_seconds));
    text('kpiCompleted', number(m.vehicles_completed));
    text('kpiActiveDetail', 'Whole network, including parking bays');
    text('kpiQueueDetail', 'Incoming roads · speed below 0.1 m/s');
    text('kpiWaitDetail', finite(m.incoming_vehicles) !== null ? `Across ${number(m.incoming_vehicles)} incoming vehicles` : 'Current incoming vehicles · awaiting measurement');
    text('kpiCompletedDetail', 'Reached their destination this run');
    $('kpiWait').title = 'Sum of current SUMO waiting counters divided by ALL incoming vehicles. This is not completed-trip delay.';
    const rate = model.throughput();
    text('flowRate', rate ? number(rate.value, 1) : '—');
    text('flowRateDetail', rate ? `Arrivals over ${number(rate.seconds)} simulated seconds` : 'Requires a full minute of observed simulation time');
    text('sourceAge', model.receivedAt === null ? 'No snapshot yet' : `Last packet ${number(Math.max(0, (Date.now() - model.receivedAt) / 1000), 1)}s ago`);
    text('sourcePackets', `${number(model.packets)} updates`);
    const ids = Object.keys(model.junctions).sort();
    if (!ids.includes(selected)) selected = ids[0] || 'J0';
    const tabKey = `${ids.join(',')}:${selected}`;
    if (tabsSignature !== tabKey) {
        tabsSignature = tabKey;
        $('junctionTabs').innerHTML = ids.map(id => `<button type="button" data-junction="${id}" aria-pressed="${id === selected}" class="${id === selected ? 'active' : ''}">${id} · ${esc(JUNCTION_NAMES[id] || id)}</button>`).join('');
    }
    if (ids.length) { renderMap(ids); renderJunction(model.junctions[selected]); }
    else clearJunctions();
    const signature = `${model.time}:${model.history.length}:${windowSeconds}:${model.mode}:${model.packets}`;
    if (signature !== chartSignature) { chartSignature = signature; renderChart('queue', ids); renderChart('wait', ids); }
    $('eventList').innerHTML = model.events.length ? model.events.map(e => `<li><span class="event-time">${formatTime(e.time)}</span><span class="event-message">${esc(e.message)}</span><span class="event-kind">${esc(e.kind)}</span></li>`).join('') : '<li class="empty-state">Events will appear as the simulator reports them.</li>';
    $('exportButton').disabled = !model.history.length;
    $('rawButton').disabled = !model.lastPacket;
    displayedPacket = model.lastPacket;
}

function clearJunctions() {
    text('junctionTitle', 'Select a junction'); text('junctionPhase', '—'); text('junctionTimer', '—');
    text('junctionSubtitle', 'Waiting for a measured junction snapshot.');
    $('corridorMap').innerHTML = '<div class="network-empty"><span>The network appears when traffic data arrives.</span></div>';
    $('signalGrid').innerHTML = '<div class="empty-state compact">Waiting for observed signal states.</div>';
    $('approachRows').innerHTML = '<div class="empty-state compact">Waiting for approach measurements.</div>';
    text('decisionReason', 'Waiting for a controller observation.');
    text('decisionMeta', 'Live demand and decision details will appear here.'); text('detectorAge', '—');
}

function renderMap(ids) {
    const ordered = [...ids].reverse();
    let svg = '<svg viewBox="0 0 450 250" role="img" aria-label="Junction schematic with actual main signal states"><defs><pattern id="mapDots" width="15" height="15" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r=".65" fill="#dbe3d6"/></pattern></defs><rect width="450" height="250" fill="url(#mapDots)"/><path d="M95 28V233" stroke="#e1e8da" stroke-width="24"/><path d="M95 28V233" stroke="#a8b69e" stroke-dasharray="3 6"/><text x="87" y="17" font-size="9" fill="#7a8d72">N ↑</text>';
    ordered.forEach((id, index) => {
        const y = ordered.length === 1 ? 125 : 57 + index * 77;
        const j = model.junctions[id], active = id === selected;
        const queue = ARMS.map(arm => finite(j.queues?.[arm]));
        const total = queue.every(n => n !== null) ? queue.reduce((a,b) => a+b,0) : null;
        svg += `<g data-junction="${id}" role="button" tabindex="0" aria-label="Inspect ${id} ${esc(JUNCTION_NAMES[id] || '')}" aria-pressed="${active}" style="cursor:pointer"><rect x="44" y="${y - 31}" width="388" height="63" rx="10" fill="${active ? '#edf4e5' : '#ffffffc9'}" stroke="${active ? '#c3d4b1' : '#e5ebdf'}"/><path d="M60 ${y}H131" stroke="#e1e8da" stroke-width="16"/><circle cx="95" cy="${y}" r="15" fill="${active ? '#21765b' : '#fff'}" stroke="#21765b" stroke-width="1.5"/><text x="95" y="${y+3}" text-anchor="middle" font-size="9" font-weight="600" fill="${active ? '#fff' : '#21765b'}">${id}</text>`;
        for (const [arm, dx, dy] of [['north',0,-23],['east',25,0],['south',0,23],['west',-25,0]]) {
            const state = lamp(j.signals?.[arm]?.main);
            svg += `<circle cx="${95+dx}" cy="${y+dy}" r="3.7" fill="${lampColors[state]}"><title>${esc(arm)} main: ${state}</title></circle>`;
        }
        svg += `<text x="153" y="${y-5}" font-size="13" font-weight="550" fill="#293d2c">${esc(JUNCTION_NAMES[id] || id)}</text><text x="153" y="${y+13}" font-size="9" fill="#7b8c74">${esc(phaseLabel(j))}</text><text x="410" y="${y-3}" text-anchor="end" font-size="18" fill="#324b32">${number(total)}</text><text x="410" y="${y+13}" text-anchor="end" font-size="8" fill="#7b8c74">STOPPED</text></g>`;
    });
    $('corridorMap').innerHTML = svg + '</svg>';
}

function renderJunction(j) {
    text('junctionTitle', `${selected} · ${JUNCTION_NAMES[selected] || 'Junction'}`);
    text('junctionSubtitle', `Observed signals · queue sample ${formatTime(j.statsTime)}`);
    text('junctionPhase', phaseLabel(j));
    // SUMO retains the preceding green timer during yellow clearance. It isn't
    // the duration of the yellow aspect, so don't label it as such.
    text('junctionTimer', j.in_yellow ? 'Transition' : finite(j.phase_timer) !== null ? `${number(j.phase_timer)}s elapsed` : '—');
    $('signalGrid').innerHTML = ARMS.map(arm => {
        const crossing = j.crossing_green?.[arm];
        const arrow = j.signals?.[arm]?.arrow;
        const arrowState = typeof arrow === 'boolean' ? (arrow ? 'green' : 'off') : lamp(arrow);
        const aspects = [['Main',lamp(j.signals?.[arm]?.main)], ['Left',arrowState], ['Walk',typeof crossing === 'boolean' ? (crossing ? 'green' : 'red') : 'unknown']];
        return `<div class="signal-card" data-arm="${arm}"><h4>${arm}</h4><div class="signal-lights">${aspects.map(([label,state]) => `<span class="signal-aspect" title="${label}: ${state}" aria-label="${arm} ${label}: ${state}"><span class="signal-light ${state}" data-aspect="${label.toLowerCase()}" data-state="${state}"></span><small>${label}</small></span>`).join('')}</div></div>`;
    }).join('');
    const largest = Math.max(1, ...ARMS.map(arm => finite(j.queues?.[arm]) ?? 0));
    $('approachRows').innerHTML = ARMS.map(arm => {
        const q = finite(j.queues?.[arm]), wait = finite(j.approaches?.[arm]?.mean_wait_seconds);
        return `<div class="approach-row" data-arm="${arm}"><span class="approach-name">${arm[0].toUpperCase()+arm.slice(1)}</span><div class="approach-bar" title="${number(q)} stopped vehicles"><span style="width:${q === null ? 0 : q/largest*100}%"></span></div><span class="approach-value">${number(q)}</span><span class="approach-wait">${seconds(wait)}</span></div>`;
    }).join('');
    const control = j.control || {};
    text('decisionReason', control.reason ? decisionLabel(control.reason) : model.controlMode === 'baseline' ? 'Following the fixed signal schedule.' : 'No controller explanation reported for this junction.');
    text('detectorAge', finite(control.sample_time) !== null ? `Sample ${formatTime(control.sample_time)}` : 'No detector sample');
    const pills = [];
    if (finite(control.proposed_action) !== null) pills.push(`DQN: ${action(control.proposed_action)}`);
    if (finite(control.applied_action) !== null) pills.push(`Applied: ${action(control.applied_action)}`);
    if (finite(control.oldest_demand_seconds) !== null) pills.push(`Oldest demand: ${seconds(control.oldest_demand_seconds)}`);
    if (finite(control.decision_time) !== null) pills.push(`Decision: ${formatTime(control.decision_time)}`);
    const blocked = Array.isArray(control.blocked_exits) ? control.blocked_exits.length : null;
    if (blocked !== null) pills.push(`${blocked} blocked exit${blocked === 1 ? '' : 's'}`);
    if (finite(model.transit.boarded_total) !== null && model.transit.enabled) pills.push(`${number(model.transit.boarded_total)} passengers boarded this run`);
    $('decisionMeta').innerHTML = pills.length ? pills.map(p => `<span class="pill">${esc(p)}</span>`).join('') : '<span>No additional controller diagnostics reported.</span>';
}

function chartSeries(kind, ids) {
    const points = model.history.filter(p => p.time >= (model.time ?? 0) - windowSeconds);
    return {points, series: ids.map(id => ({name:id, color:colors[id] || '#21765b', values:points.map(p => p.junctions[id]?.[kind] ?? null)}))};
}

function renderChart(kind, ids) {
    const {points, series} = chartSeries(kind, ids);
    const svg = $(`${kind}Chart`), empty = $(`${kind}ChartEmpty`);
    $(`${kind}Legend`).innerHTML = series.map(s => `<span><i style="background:${s.color}"></i>${s.name}</span>`).join('');
    const values = series.flatMap(s => s.values).filter(v => finite(v) !== null);
    empty.hidden = values.length > 0;
    if (!values.length) { svg.innerHTML = ''; return; }
    const rawMax = Math.max(1, ...values), unit = 10 ** Math.floor(Math.log10(rawMax));
    const top = Math.ceil(rawMax / unit) * unit;
    const minT = points[0].time, maxT = Math.max(minT + 5, points.at(-1).time);
    const x = time => 36 + (time - minT)/(maxT-minT)*508;
    const y = value => 160 - value/top*145;
    let html = '';
    for (let i=0; i<=4; i++) {
        const value = top*i/4, py = y(value);
        html += `<line class="chart-grid-line" x1="36" y1="${py}" x2="544" y2="${py}"/><text x="29" y="${py+3}" text-anchor="end">${number(value, value%1 ? 1 : 0)}</text>`;
    }
    for (const ratio of [0,.5,1]) {
        const time = minT + (maxT-minT)*ratio;
        html += `<text x="${x(time)}" y="181" text-anchor="${ratio===0?'start':ratio===1?'end':'middle'}">${formatTime(time)}</text>`;
    }
    for (const s of series) {
        let path = '', previous = null;
        s.values.forEach((value, i) => {
            if (finite(value) === null) { previous = null; return; }
            const move = previous === null || points[i].breakBefore || points[i].time - previous > 15;
            path += `${move?'M':'L'}${x(points[i].time).toFixed(2)},${y(value).toFixed(2)} `;
            previous = points[i].time;
        });
        html += `<path class="chart-path" d="${path}" stroke="${s.color}"/>`;
        if (s.values.length === 1 && finite(s.values[0]) !== null) html += `<circle cx="${x(points[0].time)}" cy="${y(s.values[0])}" r="3" fill="${s.color}"/>`;
    }
    // Native tooltips expose actual samples, with no invented interpolation values.
    points.forEach((point,i) => {
        const summary = series.map(s => `${s.name}: ${number(s.values[i], kind==='wait'?1:0)}${kind==='wait'?'s':''}`).join(' · ');
        html += `<rect x="${x(point.time)-Math.max(1,250/points.length)}" y="10" width="${Math.max(2,508/points.length)}" height="152" fill="transparent"><title>${formatTime(point.time)} · ${esc(summary)}</title></rect>`;
    });
    svg.innerHTML = html;
}

function chooseJunction(event) {
    const button = event.target.closest('[data-junction]');
    if (button && model.junctions[button.dataset.junction]) { selected = button.dataset.junction; renderSoon(); }
}
$('junctionTabs').addEventListener('click', chooseJunction);
$('corridorMap').addEventListener('click', chooseJunction);
$('corridorMap').addEventListener('keydown', event => { if (['Enter',' '].includes(event.key)) { event.preventDefault(); chooseJunction(event); } });
document.querySelectorAll('[data-window]').forEach(button => button.addEventListener('click', () => {
    windowSeconds = Number(button.dataset.window);
    document.querySelectorAll('[data-window]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    renderSoon();
}));
$('reconnectButton').addEventListener('click', () => {
    // An in-flight discovery request must not swallow a manual reconnect.
    // Reopen the last verified endpoint immediately; discovery can still move
    // the connection if the user has just launched a different simulation.
    if (endpoint) { openSocket(); renderSoon(); }
    discoverAndConnect();
});
$('rawButton').addEventListener('click', () => {
    $('rawData').textContent = JSON.stringify(displayedPacket, null, 2);
    $('rawDialog').showModal();
});
$('rawClose').addEventListener('click', () => $('rawDialog').close());
$('rawDialog').addEventListener('click', event => { if (event.target === $('rawDialog')) $('rawDialog').close(); });
$('exportButton').addEventListener('click', () => {
    const fields = ['time', 'active_vehicles', 'current_stopped_vehicles', 'current_mean_wait_seconds', 'incoming_vehicles', 'vehicles_completed'];
    const rows = [fields.join(','), ...model.history.map(point => fields.map(key => finite(point[key]) ?? '').join(','))];
    const url = URL.createObjectURL(new Blob([rows.join('\n') + '\n'], {type:'text/csv;charset=utf-8'}));
    const link = document.createElement('a'); link.href = url; link.download = `trafiq-observed-session-${Math.floor(model.time ?? 0)}.csv`; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
});
render();
discoverAndConnect();
setInterval(() => discoverAndConnect(), 5000);
setInterval(renderSoon, 1000);
document.addEventListener('visibilitychange', () => { if (!document.hidden) { discoverAndConnect(); renderSoon(); } });
window.addEventListener('beforeunload', closeSocket);
