#!/usr/bin/env node
// Semantic regressions for real telemetry; run with node --test this file.
import test from 'node:test';
import assert from 'node:assert/strict';
import {LiveModel, finite, formatTime, phaseLabel} from '../dashboard/static/live-model.mjs';

function packet(time, changes = {}) {
    return {
        type: 'vehicle_update', mode: 'corridor', run_id: 'run-a', control_mode: 'ai', sim_time: time,
        telemetry_schema: 2,
        traffic_metrics: {
            active_vehicles: 50, incoming_vehicles: 16, current_stopped_vehicles: 6,
            // (2*3 + 10*12 + 4*4.5) / 16 = 9, not the junction mean of 6.5.
            current_mean_wait_seconds: 9, vehicles_completed: 100, sample_time: time,
        },
        junctions: {
            J0: {phase: 0, sample_time: time, incoming_vehicles: 2, avg_wait: 3,
                queues: {north: 1, east: 0, south: 0, west: 0}},
            J1: {phase: 3, sample_time: time, incoming_vehicles: 10, avg_wait: 12,
                queues: {north: 1, east: 1, south: 0, west: 1}},
            J2: {phase: 0, sample_time: time, incoming_vehicles: 4, avg_wait: 4.5,
                queues: {north: 0, east: 1, south: 1, west: 0}},
        },
        ...changes,
    };
}

test('numbers must be finite measurements, not strings or missing placeholders', () => {
    for (const value of [undefined, null, '', '0', NaN, Infinity, -Infinity]) assert.equal(finite(value), null);
    assert.equal(finite(0), 0);
    assert.equal(formatTime(null), '—');
    assert.equal(formatTime(3661), '01:01:01');
});

test('uses canonical weighted vehicle wait and actual totals without averaging junction means', () => {
    const model = new LiveModel();
    model.ingest(packet(100), 1000);
    assert.equal(model.metrics.current_mean_wait_seconds, 9);
    assert.equal(model.metrics.incoming_vehicles, 16);
    assert.equal(model.metrics.current_stopped_vehicles, 6);
    assert.equal(model.metrics.active_vehicles, 50);
    assert.equal(model.metrics.vehicles_completed, 100);
    assert.equal(model.history[0].junctions.J1.wait, 12);
});

test('missing or invalid fields in a new measurement do not inherit old values', () => {
    const model = new LiveModel();
    model.ingest(packet(100));
    model.ingest(packet(101, {traffic_metrics: {active_vehicles: 0,
        current_mean_wait_seconds: '8.2', incoming_vehicles: -1, sample_time: 101}}));
    assert.equal(model.metrics.active_vehicles, 0);
    for (const key of ['current_mean_wait_seconds', 'incoming_vehicles', 'vehicles_completed', 'current_stopped_vehicles'])
        assert.equal(model.metrics[key], null, key);
});

test('junction wait is weighted from measured approach sums, including zero-vehicle arms', () => {
    const model = new LiveModel();
    model.ingest(packet(100, {junctions: {J0: {avg_wait: 999, approaches: {
        north: {vehicles: 2, waiting_sum_seconds: 6},
        east: {vehicles: 10, waiting_sum_seconds: 120},
        south: {vehicles: 4, waiting_sum_seconds: 18},
        west: {vehicles: 0, waiting_sum_seconds: 0},
    }}}}));
    assert.equal(model.junctions.J0.currentWait, 9);
    assert.equal(model.history[0].junctions.J0.wait, 9);
});

test('single-junction nested approach telemetry supplies current waits and chart samples', () => {
    const model = new LiveModel();
    const approaches = {
        north: {vehicles: 2, stopped: 1, waiting_sum_seconds: 6, mean_wait_seconds: 3},
        east: {vehicles: 10, stopped: 3, waiting_sum_seconds: 120, mean_wait_seconds: 12},
        south: {vehicles: 4, stopped: 2, waiting_sum_seconds: 18, mean_wait_seconds: 4.5},
        west: {vehicles: 0, stopped: 0, waiting_sum_seconds: 0, mean_wait_seconds: 0},
    };
    const update = {type: 'vehicle_update', sim_time: 20, mode: 'single', telemetry_schema: 2,
        avg_wait: 570.44, queues: {north: 1, east: 3, south: 2, west: 0},
        traffic_metrics: {approaches, current_mean_wait_seconds: 9, incoming_vehicles: 16,
            current_stopped_vehicles: 6, active_vehicles: 50, vehicles_completed: 10, sample_time: 20}};
    model.ingest(update);
    assert.equal(model.mode, 'single');
    assert.deepEqual(model.junctions.J0.approaches, approaches);
    assert.equal(model.junctions.J0.currentWait, 9);
    assert.equal(model.history[0].junctions.J0.wait, 9);
    assert.equal(model.history[0].junctions.J0.queue, 6);
    assert.equal(model.junctions.J0.approaches.east.mean_wait_seconds, 12);
});

test('legacy single-junction episode score is never drawn as current mean wait', () => {
    const model = new LiveModel();
    model.ingest({type: 'state_update', sim_time: 100, mode: 'ai', avg_wait: 570.44,
        vehicles_completed: 15, queues: {north: 1, east: 2, south: 3, west: 4}});
    assert.equal(model.metrics.current_mean_wait_seconds, null);
    assert.equal(model.history[0].junctions.J0.wait, null);
    assert.equal(model.metrics.current_stopped_vehicles, 10);
    assert.equal(model.metrics.vehicles_completed, 15);
});

test('an empty corridor packet is missing queue data, not a measured empty road', () => {
    const model = new LiveModel();
    model.ingest({type: 'state_update', mode: 'corridor', sim_time: 10, junctions: {}});
    assert.equal(model.metrics.current_stopped_vehicles, null);
    assert.equal(model.metrics.active_vehicles, null);
});

test('per-second traffic updates advance values; a same-time full state replaces the sample', () => {
    const model = new LiveModel();
    model.ingest(packet(60), 1000);
    model.ingest(packet(61), 2000);
    const full = packet(61, {type: 'state_update'});
    full.traffic_metrics.vehicles_completed = 105;
    model.ingest(full, 2100);
    assert.equal(model.time, 61);
    assert.equal(model.history.length, 2);
    assert.equal(model.history.at(-1).vehicles_completed, 105);
    assert.equal(model.junctions.J2.statsTime, 61);
});

test('socket handshake and mode acknowledgements cannot report live traffic', () => {
    const model = new LiveModel();
    assert.equal(model.status(false, 1000).key, 'offline');
    assert.equal(model.status(true, 1000).key, 'waiting');
    model.ingest({type: 'mode_changed', control_mode: 'ai'}, 1100);
    assert.equal(model.status(true, 1100).key, 'waiting');
    model.ingest(packet(60), 1200);
    assert.equal(model.status(true, 1200).key, 'live');
});

test('reconnecting requires a new traffic packet before showing live again', () => {
    const model = new LiveModel();
    model.ingest(packet(60), 1000);
    model.disconnected();
    assert.equal(model.status(false, 1100).key, 'offline');
    assert.equal(model.status(true, 1200).key, 'waiting');
    model.ingest({type: 'mode_changed', control_mode: 'ai'}, 1250);
    assert.equal(model.status(true, 1250).key, 'waiting');
    model.ingest(packet(62), 1300);
    assert.equal(model.status(true, 1300).key, 'live');
});

test('silent and repeatedly frozen feeds are marked stale while values remain visible', () => {
    const model = new LiveModel();
    model.ingest(packet(60), 1000);
    assert.equal(model.status(true, 10000).key, 'stale');
    model.ingest(packet(60), 15000);
    assert.equal(model.status(true, 15000).key, 'stale');
    assert.equal(model.metrics.active_vehicles, 50);
    model.ingest(packet(61), 15100);
    assert.equal(model.status(true, 15100).key, 'live');
});

test('throughput requires an observed minute and uses completed-trip differences', () => {
    const model = new LiveModel();
    for (const [time, completed] of [[0, 1000], [59, 1036], [60, 1037]]) {
        const update = packet(time);
        update.traffic_metrics.vehicles_completed = completed;
        model.ingest(update, time * 1000);
        if (time < 60) assert.equal(model.throughput(), null);
    }
    assert.deepEqual(model.throughput(), {value: 37, seconds: 60});
    assert.notEqual(model.throughput().value, model.metrics.vehicles_completed);
});

test('rate explicitly reports the observed elapsed interval when snapshots are sparse', () => {
    const model = new LiveModel();
    const first = packet(0), last = packet(65);
    first.traffic_metrics.vehicles_completed = 10;
    last.traffic_metrics.vehicles_completed = 23;
    model.ingest(first); model.ingest(last);
    assert.deepEqual(model.throughput(), {value: 12, seconds: 65});
});

test('new run IDs reset histories and rates even if the new clock is later', () => {
    const model = new LiveModel();
    model.ingest(packet(0)); model.ingest(packet(60));
    assert.ok(model.throughput());
    model.ingest(packet(100, {run_id: 'run-b'}));
    assert.equal(model.history.length, 1);
    assert.equal(model.runId, 'run-b');
    assert.equal(model.throughput(), null);
});

test('clock rewind and explicit restart cannot connect unrelated chart runs', () => {
    const model = new LiveModel();
    model.ingest(packet(300)); model.ingest(packet(360));
    model.ingest(packet(1));
    assert.equal(model.history.length, 1);
    assert.equal(model.history[0].time, 1);
    model.ingest({type: 'sim_restart', run_id: 'run-c'});
    assert.equal(model.history.length, 0);
    assert.equal(model.time, null);
    assert.equal(model.throughput(), null);
    assert.equal(model.status(true).key, 'waiting');
});

test('disconnect gaps survive replacement by a same-timestamp full state', () => {
    const model = new LiveModel();
    model.ingest(packet(60));
    model.disconnected();
    model.ingest(packet(90));
    model.ingest(packet(90, {type: 'state_update'}));
    assert.equal(model.history.length, 2);
    assert.equal(model.history.at(-1).breakBefore, true);
    model.ingest(packet(91));
    assert.equal(model.history.at(-1).breakBefore, false);
});

test('completion retains final data instead of clearing the dashboard', () => {
    const model = new LiveModel();
    model.ingest(packet(120), 1000);
    model.ingest({type: 'sim_complete'}, 1100);
    assert.equal(model.status(true, 1100).key, 'complete');
    assert.equal(model.history.length, 1);
    assert.equal(model.metrics.vehicles_completed, 100);
});

test('switching corridor to single-junction removes unrelated junction state', () => {
    const model = new LiveModel();
    model.ingest(packet(100));
    model.ingest({type: 'state_update', sim_time: 101, mode: 'ai', phase: 3,
        traffic_metrics: {active_vehicles: 11, vehicles_completed: 5}});
    assert.deepEqual(Object.keys(model.junctions), ['J0']);
    assert.equal(model.mode, 'single');
    assert.equal(model.history.length, 1);
});

test('partial phase updates cannot retain a stale phase label', () => {
    const model = new LiveModel();
    model.ingest(packet(100, {junctions: {J0: {phase: 0, phase_name: 'NS_THROUGH'}}}));
    model.ingest(packet(101, {junctions: {J0: {phase: 3}}}));
    assert.equal(phaseLabel(model.junctions.J0), 'EW through');
});

test('invalid messages cannot fabricate a live clock or telemetry point', () => {
    const model = new LiveModel();
    for (const value of [null, {}, {type: 'vehicle_update', sim_time: '20'},
        {type: 'state_update', sim_time: -1}, {type: 'unknown', sim_time: 10}])
        assert.equal(model.ingest(value), false);
    assert.equal(model.time, null);
    assert.equal(model.history.length, 0);
    assert.equal(model.status(true).key, 'waiting');
});
