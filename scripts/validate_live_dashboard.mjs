#!/usr/bin/env node
// Browser-level checks against a running, real SUMO dashboard. No mock traffic.
// node scripts/validate_live_dashboard.mjs --url http://127.0.0.1:5081 --out /private/tmp/dashboard-qa
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {formatTime, phaseLabel, decisionLabel} from '../dashboard/static/live-model.mjs';

const require = createRequire(import.meta.url);
let playwright;
try { playwright = require('playwright'); }
catch { playwright = require(process.env.TRAFIQ_PLAYWRIGHT_PATH || process.env.ATCS_PLAYWRIGHT_PATH || '/Users/osborn/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'); }
const argument = (name, fallback) => process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : fallback;
const url = argument('--url', 'http://127.0.0.1:5050');
const out = path.resolve(argument('--out', '/private/tmp/dashboard-qa'));
const chrome = argument('--chrome', process.env.TRAFIQ_CHROME || process.env.ATCS_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
await mkdir(out, {recursive: true});
const browser = await playwright.chromium.launch({headless: true, executablePath: chrome});
const context = await browser.newContext({viewport: {width: 1440, height: 1000}, deviceScaleFactor: 1, acceptDownloads: true});
const page = await context.newPage();
const errors = [], frames = [];
let connections = 0;
page.on('pageerror', error => errors.push(error.message));
page.on('websocket', ws => {
    connections += 1;
    ws.on('framereceived', ({payload}) => {
        try {
            const packet = JSON.parse(String(payload));
            if (['vehicle_update', 'state_update'].includes(packet.type)) frames.push(packet);
        } catch { /* Non-data frames are not traffic observations. */ }
    });
});

const numeric = value => value === '—' ? null : Number(value.replaceAll(',', '').replace(/s$/, ''));
const round = value => Math.round(value * 10) / 10;
const expectNumber = (actual, expected, label, digits = 0) => {
    assert.equal(numeric(actual), typeof expected === 'number' ? (digits === 1 ? round(expected) : expected) : null, label);
};

async function live() {
    await page.waitForFunction(() => document.body.dataset.stream === 'live', null, {timeout: 30000});
}

async function capture() {
    // Inspect data snapshots the same packet used by the DOM's last render.
    // Capture in one JS task, so a new WebSocket event cannot interleave.
    return page.evaluate(() => {
        const text = id => document.getElementById(id).textContent.trim();
        document.getElementById('rawButton').click();
        const packet = JSON.parse(text('rawData'));
        const result = {
            packet, clock: text('simulationTime'), active: text('kpiActive'),
            stopped: text('kpiQueue'), wait: text('kpiWait'), completed: text('kpiCompleted'),
            title: text('junctionTitle'), phase: text('junctionPhase'), reason: text('decisionReason'),
            dialogOpen: document.getElementById('rawDialog').open,
            approaches: [...document.querySelectorAll('#approachRows [data-arm]')].map(row => ({
                arm: row.dataset.arm, stopped: row.querySelector('.approach-value').textContent,
                wait: row.querySelector('.approach-wait').textContent,
            })),
            signals: [...document.querySelectorAll('#signalGrid [data-arm] .signal-light')].map(light => ({
                arm: light.closest('[data-arm]').dataset.arm,
                aspect: light.dataset.aspect, state: light.dataset.state,
            })),
        };
        document.getElementById('rawClose').click();
        return result;
    });
}

function verifySnapshot(observed, selected) {
    const packet = observed.packet, m = packet.traffic_metrics;
    assert.equal(packet.telemetry_schema, 2, 'Browser must receive the actual measured telemetry schema');
    assert.ok(m && Number.isFinite(m.sample_time));
    assert.equal(observed.clock, formatTime(packet.sim_time), 'Clock uses the displayed snapshot');
    expectNumber(observed.active, m.active_vehicles, 'Active vehicles');
    expectNumber(observed.stopped, m.current_stopped_vehicles, 'Stopped vehicles');
    expectNumber(observed.wait, m.current_mean_wait_seconds, 'True current mean wait', 1);
    expectNumber(observed.completed, m.vehicles_completed, 'Actual completed trips');
    assert.equal(observed.dialogOpen, true, 'Raw data inspector opens');
    const source = frames.findLast(frame => frame.type === packet.type && frame.sim_time === packet.sim_time && frame.run_id === packet.run_id);
    assert.ok(source, 'Inspected packet was received over the real WebSocket');
    assert.deepEqual(packet, source, 'Data inspector does not transform or invent source fields');
    const junction = packet.junctions ? packet.junctions[selected] : packet;
    const approaches = junction.approaches ?? packet.traffic_metrics.approaches;
    assert.ok(junction, `Observed ${selected} data exists`);
    assert.ok(observed.title.startsWith(selected), 'Selected junction title');
    assert.equal(observed.phase, phaseLabel(junction), 'Phase is taken from selected junction');
    if (junction.control?.reason) assert.equal(observed.reason, decisionLabel(junction.control.reason), 'AI explanation follows the controller');
    assert.equal(observed.approaches.length, 4);
    for (const approach of observed.approaches) {
        expectNumber(approach.stopped, junction.queues[approach.arm], `${selected} ${approach.arm} queue`);
        expectNumber(approach.wait, approaches[approach.arm].mean_wait_seconds, `${selected} ${approach.arm} mean wait`, 1);
    }
    assert.equal(observed.signals.length, 12);
    for (const signal of observed.signals) {
        const arrow = junction.signals[signal.arm].arrow;
        const value = signal.aspect === 'walk' ? (junction.crossing_green[signal.arm] ? 'green' : 'red')
            : signal.aspect === 'left' ? (typeof arrow === 'boolean' ? (arrow ? 'green' : 'off') : arrow)
            : junction.signals[signal.arm].main;
        assert.equal(signal.state, value, `${selected} ${signal.arm} ${signal.aspect} signal`);
    }
}

async function noOverflow(width) {
    const bounds = await page.evaluate(() => ({body: document.body.scrollWidth,
        document: document.documentElement.scrollWidth, viewport: innerWidth}));
    assert.equal(bounds.viewport, width);
    assert.ok(bounds.body <= width + 1 && bounds.document <= width + 1,
        `Horizontal overflow at ${width}px: ${JSON.stringify(bounds)}`);
}

try {
    await page.goto(url, {waitUntil: 'networkidle'});
    await live();
    await page.waitForFunction(() => document.querySelectorAll('#queueChart path.chart-path').length > 0 &&
        [...document.querySelectorAll('#queueChart path.chart-path')].some(path => path.getAttribute('d').includes('L')), null, {timeout: 30000});
    const config = await (await context.request.get(`${url}/api/live-config`)).json();
    assert.equal(config.available, true);
    const initial = await capture();
    verifySnapshot(initial, 'J0');
    const ids = initial.packet.junctions ? Object.keys(initial.packet.junctions) : ['J0'];
    for (const id of ids) {
        await page.locator(`#junctionTabs [data-junction="${id}"]`).click();
        await page.waitForFunction(selected => document.getElementById('junctionTitle').textContent.startsWith(selected), id);
        verifySnapshot(await capture(), id);
    }
    await page.locator('[data-window="900"]').click();
    assert.equal(await page.locator('[data-window="900"]').getAttribute('aria-pressed'), 'true');
    assert.ok(await page.locator('#waitChart path.chart-path').count(), 'Wait charts contain measured samples');
    assert.equal(await page.locator('#waitChartEmpty').isVisible(), false);
    assert.equal(await page.locator('#queueChartEmpty').isVisible(), false);

    const downloadPromise = page.waitForEvent('download');
    await page.locator('#exportButton').click();
    const download = await downloadPromise;
    const exportPath = path.join(out, download.suggestedFilename());
    await download.saveAs(exportPath);
    const lines = (await readFile(exportPath, 'utf8')).trim().split('\n');
    const fields = lines.shift().split(',');
    assert.deepEqual(fields, ['time', 'active_vehicles', 'current_stopped_vehicles', 'current_mean_wait_seconds', 'incoming_vehicles', 'vehicles_completed']);
    assert.ok(lines.length >= 2, 'Export contains observed history');
    for (const line of lines) {
        const values = line.split(',').map(value => value === '' ? null : Number(value));
        const candidates = frames.filter(frame => frame.sim_time === values[0] && frame.traffic_metrics);
        assert.ok(candidates.some(frame => fields.slice(1).every((field, i) => values[i+1] === (frame.traffic_metrics[field] ?? null))),
            `Exported row ${values[0]} must match a real received snapshot`);
    }

    await page.locator('#junctionTabs [data-junction="J0"]').click();
    await noOverflow(1440);
    await page.screenshot({path: path.join(out, 'live-dashboard-desktop.png'), fullPage: true});
    await page.setViewportSize({width: 768, height: 1024});
    await noOverflow(768);
    await page.setViewportSize({width: 390, height: 844});
    await noOverflow(390);
    await page.screenshot({path: path.join(out, 'live-dashboard-mobile.png'), fullPage: true});
    await page.locator('#rawButton').click();
    assert.equal(await page.locator('#rawDialog').isVisible(), true);
    await noOverflow(390);
    await page.locator('#rawClose').click();

    // Disconnect only this isolated browser. The SUMO/Godot simulation continues.
    const before = await capture();
    await context.setOffline(true);
    await page.waitForFunction(() => document.body.dataset.stream !== 'live', null, {timeout: 18000});
    assert.notEqual(await page.locator('#kpiActive').textContent(), '—', 'Last measured data remains visible during an interruption');
    await context.setOffline(false);
    await page.locator('#reconnectButton').click();
    await live();
    await page.waitForFunction(previous => document.getElementById('simulationTime').textContent !== previous, before.clock, {timeout: 15000});
    verifySnapshot(await capture(), 'J0');
    assert.ok(connections >= 2, 'Reconnect creates a fresh data connection');
    assert.deepEqual(errors, [], 'No browser JavaScript errors');
    const result = {url, mode: initial.packet.mode, source: config.ws_url,
        first_time: initial.packet.sim_time, final_time: frames.at(-1).sim_time,
        observed_packets: frames.length, connections, export_rows: lines.length, junctions_checked: ids,
        viewports_checked: [1440, 768, 390], errors};
    await writeFile(path.join(out, 'dashboard-validation.json'), JSON.stringify(result, null, 2));
    console.log('LIVE DASHBOARD PASS', JSON.stringify(result));
} catch (error) {
    await page.screenshot({path: path.join(out, 'dashboard-failure.png'), fullPage: true}).catch(() => {});
    console.error(error);
    process.exitCode = 1;
} finally {
    await browser.close();
}
