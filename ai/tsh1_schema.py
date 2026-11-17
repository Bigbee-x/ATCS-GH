"""Single-junction observation ABI, usable without SUMO or TraCI installed.

The conformance test compares these constants against TrafficEnv before a
hardware adapter or checkpoint is accepted. Corridor policies use a different
46-value ABI and must not consume this 41-value vector.
"""
TL_ID = 'J0'
INCOMING_EDGES = ['ACH_N2J','ACH_S2J','AGG_E2J','GUG_W2J']
INCOMING_LANES = [f'{edge}_{lane}' for edge in INCOMING_EDGES for lane in (1,2)]
WALKING_AREAS = [f':J0_w{i}' for i in range(4)]
NUM_PHASES = 8
STATE_SIZE = 41
MAX_QUEUE_LANE = 75.0
MAX_SPEED = 13.89
MAX_WAIT = 1200.0
MAX_QUEUE = 150.0
MAX_PHASE_T = 96.0
MAX_PED_QUEUE = 15.0
