// Pure telemetry state: missing measurements remain null, never synthetic zeroes.
export const ARMS = ['north', 'east', 'south', 'west'];
export const PHASES = ['NS through', 'NS left', 'NS yellow', 'EW through', 'EW left', 'EW yellow'];
export const JUNCTION_NAMES = {J0: 'Achimota', J1: 'Asylum Down', J2: 'Tesano'};
export const finite = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
const count = value => finite(value) !== null && value >= 0 ? value : null;
const object = value => value && typeof value === 'object' && !Array.isArray(value) ? value : {};

export function formatTime(value) {
    if (finite(value) === null) return '—';
    const seconds = Math.floor(Math.max(0, value));
    return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
        .map(part => String(part).padStart(2, '0')).join(':');
}

export function phaseLabel(junction) {
    const name = junction?.phase_name;
    if (typeof name === 'string') return name.replaceAll('_', ' ');
    return PHASES[junction?.phase] || 'Awaiting phase';
}

export class LiveModel {
    constructor() { this.reset(); }
    reset() {
        this.time = null;
        this.mode = null;
        this.controlMode = null;
        this.scenario = null;
        this.runId = null;
        this.junctions = {};
        this.metrics = {};
        this.metricsTime = null;
        this.transit = {};
        this.history = [];
        this.events = [];
        this.lastDecisions = {};
        this.lastPacket = null;
        this.receivedAt = null;
        this.advancedAt = null;
        this.packets = 0;
        this.complete = false;
        this.gapPending = false;
        this.connectionReady = false;
    }
    event(kind, message, time = this.time) {
        this.events.unshift({kind, message, time});
        this.events.length = Math.min(this.events.length, 24);
    }
    disconnected() { this.gapPending = true; this.connectionReady = false; }
    ingest(packet, now = Date.now()) {
        if (!packet || typeof packet !== 'object') return false;
        if (packet.type === 'sim_restart') {
            this.reset();
            this.runId = packet.run_id ?? packet.run ?? null;
            this.event('run', 'A new simulation run has started', 0);
            return true;
        }
        if (packet.type === 'mode_changed') {
            if (typeof packet.control_mode === 'string') this.controlMode = packet.control_mode;
            return true;
        }
        if (packet.type === 'sim_complete') {
            this.complete = true;
            this.event('run', 'Simulation completed. Final observations retained.');
            return true;
        }
        if (!['vehicle_update', 'state_update'].includes(packet.type)) return false;
        const t = finite(packet.sim_time) ?? finite(packet.step);
        if (t === null || t < 0) return false;
        const incomingRun = packet.run_id ?? packet.run ?? null;
        const mode = packet.mode === 'corridor' || packet.junctions ? 'corridor' : 'single';
        const restarted = (this.time !== null && t < this.time) ||
            (this.runId !== null && incomingRun !== null && this.runId !== incomingRun) ||
            (this.mode !== null && this.mode !== mode);
        if (restarted) {
            this.reset();
            this.event('run', 'New run detected; observation history reset', t);
        }
        if (this.time === null || t > this.time) this.advancedAt = now;
        this.receivedAt = now;
        this.connectionReady = true;
        this.time = t;
        this.mode = mode;
        this.complete = false;
        if (incomingRun !== null) this.runId = incomingRun;
        if (typeof packet.control_mode === 'string') this.controlMode = packet.control_mode;
        if (typeof packet.scenario === 'string') this.scenario = packet.scenario;
        this.lastPacket = packet;
        this.packets += 1;

        const incoming = mode === 'corridor' ? object(packet.junctions) : {J0: packet};
        for (const [id, value] of Object.entries(incoming)) {
            if (!/^J\d+$/.test(id)) continue;
            const raw = {...object(value)}, previous = this.junctions[id] || {};
            // Single-junction telemetry nests its measured approaches under the
            // canonical network metrics. Expose the same junction shape to views.
            if (mode === 'single' && !raw.approaches && packet.traffic_metrics?.approaches)
                raw.approaches = packet.traffic_metrics.approaches;
            const merged = {...previous, ...raw};
            if (raw.phase !== undefined && raw.phase !== previous.phase && raw.phase_name === undefined)
                delete merged.phase_name;
            if (raw.queues || raw.approaches) merged.statsTime = finite(raw.sample_time) ?? t;
            if (raw.signals) merged.signalsTime = finite(raw.signal_time) ?? t;
            if (raw.approaches) {
                const arms = ARMS.map(arm => raw.approaches[arm]);
                const measured = arms.every(arm => count(arm?.vehicles) !== null && count(arm?.waiting_sum_seconds) !== null);
                const vehicles = measured ? arms.reduce((sum, arm) => sum + arm.vehicles, 0) : 0;
                merged.currentWait = measured ? arms.reduce((sum, arm) => sum + arm.waiting_sum_seconds, 0) / Math.max(vehicles, 1) : null;
            } else if (packet.telemetry_schema >= 2 && raw.avg_wait !== undefined) {
                merged.currentWait = count(raw.avg_wait);
            }
            this.junctions[id] = merged;
            const control = object(raw.control);
            if (control.reason && control.decision_time !== undefined) {
                const key = `${control.decision_time}:${control.applied_action}:${control.reason}`;
                if (this.lastDecisions[id] !== key) {
                    this.lastDecisions[id] = key;
                    this.event('decision', `${id} · ${decisionLabel(control.reason)}`, finite(control.decision_time) ?? t);
                }
            }
        }
        this.transit = packet.transit ?? this.transit;
        const telemetry = object(packet.traffic_metrics);
        const fields = ['active_vehicles', 'current_stopped_vehicles', 'current_mean_wait_seconds',
            'incoming_vehicles', 'vehicles_completed'];
        const hasTelemetry = fields.some(key => count(telemetry[key]) !== null);
        if (hasTelemetry) {
            // Each canonical telemetry sample is complete. Do not carry old values
            // across a missing field and silently claim they were measured now.
            this.metrics = Object.fromEntries(fields.map(key => [key, count(telemetry[key])]));
            this.metricsTime = finite(telemetry.sample_time) ?? t;
        } else if (packet.type === 'state_update') {
            // Older servers supply an honest subset. Legacy avg_wait is not used:
            // the single-junction value is an episode score, not mean vehicle wait.
            const all = Object.values(this.junctions);
            const queues = all.flatMap(j => ARMS.map(arm => count(j.queues?.[arm])));
            this.metrics = {active_vehicles: null, incoming_vehicles: null,
                current_mean_wait_seconds: null,
                current_stopped_vehicles: queues.length && queues.every(v => v !== null)
                    ? queues.reduce((sum, n) => sum + n, 0) : null,
                vehicles_completed: count(packet.vehicles_completed)};
            this.metricsTime = t;
        }
        if (hasTelemetry || packet.type === 'state_update') {
            const byJunction = Object.fromEntries(Object.entries(this.junctions).map(([id, j]) => {
                const values = ARMS.map(arm => count(j.queues?.[arm]));
                return [id, {queue: values.every(n => n !== null) ? values.reduce((a,b) => a+b,0) : null,
                    wait: count(j.currentWait)}];
            }));
            const point = {time: t, ...this.metrics, junctions: byJunction, breakBefore: this.gapPending};
            this.gapPending = false;
            const last = this.history.at(-1);
            if (last?.time === t) {
                point.breakBefore = point.breakBefore || last.breakBefore;
                this.history[this.history.length - 1] = point;
            } else this.history.push(point);
            this.history = this.history.filter(p => p.time >= t - 1800).slice(-2000);
        }
        return true;
    }
    status(socketOpen, now = Date.now()) {
        if (!socketOpen) return {key: 'offline', label: 'Disconnected', detail: 'Waiting for the simulation server. Last values are retained.'};
        if (!this.connectionReady) return {key: 'waiting', label: 'Awaiting data', detail: 'Socket open. Waiting for a simulation snapshot.'};
        if (this.complete) return {key: 'complete', label: 'Run complete', detail: 'Final observations from this run.'};
        const age = (now - this.receivedAt) / 1000;
        if (age > 8 || (now - this.advancedAt) / 1000 > 12)
            return {key: 'stale', label: 'Data paused', detail: `No advancing simulation data · last packet ${Math.floor(age)}s ago`};
        return {key: 'live', label: 'Live simulation', detail: 'Receiving measured SUMO traffic data'};
    }
    throughput() {
        const latest = this.history.at(-1);
        if (!latest || count(latest.vehicles_completed) === null) return null;
        const start = this.history.findLast(point => point.time <= latest.time - 60 && count(point.vehicles_completed) !== null);
        if (!start || latest.vehicles_completed < start.vehicles_completed) return null;
        return {value: (latest.vehicles_completed - start.vehicles_completed) * 60 / (latest.time - start.time),
            seconds: latest.time - start.time};
    }
}

export function decisionLabel(reason) {
    return ({minimum_green: 'Finishing minimum green', min_green: 'Finishing minimum green',
        yellow_clearance: 'Clearing the junction', no_serviceable_demand: 'No movement ready to release',
        serve_oldest_demand: 'Serving the longest waiting movement', starvation_guard: 'Serving the longest waiting movement',
        max_green: 'Rotating after maximum green', maximum_green: 'Rotating after maximum green',
        balance_queue_pressure: 'Balancing approaching queues', maintain_green_flow: 'Keeping the current flow moving',
        empty_or_blocked_movement: 'Redirecting from an empty or blocked movement',
        dqn_decision: 'Following the DQN decision', dqn: 'Following the DQN decision',
        serve_waiting_approach: 'Serving the longest waiting movement', manual_override: 'Manual signal override'})[reason]
        || String(reason).replaceAll('_', ' ');
}
