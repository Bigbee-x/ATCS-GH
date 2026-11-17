"""Versioned, integrity-checked corridor policies and their observation contract.

Unversioned shipped models retain the legacy occupancy scale. New bundles carry
their own feature settings; experiments must never change a module global to
change the meaning of a deployed model's inputs.
"""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
JUNCTION_IDS = ('J0', 'J1', 'J2')
OBSERVATION_SCHEMA = 'sumo_full_lane_bounded_v1'


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def settings(directory):
    directory = Path(directory)
    path = directory / 'manifest.json'
    if not path.exists():
        return {'occupancy_feature': 'legacy', 'graded_exit_capacity': False,
                'observation_schema': OBSERVATION_SCHEMA, 'unversioned': True}
    manifest = json.loads(path.read_text())
    if manifest.get('schema_version') != 1 or manifest.get('state_size') != 46 or manifest.get('action_size') != 5:
        raise ValueError('Incompatible corridor policy dimensions/version')
    if manifest.get('observation_schema') != OBSERVATION_SCHEMA:
        raise ValueError('Policy observation contract does not match this runtime')
    if manifest.get('occupancy_feature') not in ('legacy', 'fullness'):
        raise ValueError('Missing or invalid occupancy feature contract')
    if type(manifest.get('graded_exit_capacity')) is not bool:
        raise ValueError('Missing exit-capacity setting')
    if manifest.get('network_sha256') != sha256(ROOT / 'simulation/corridor.net.xml'):
        raise ValueError('Policy lane topology does not match the corridor network')
    for jid in JUNCTION_IDS:
        if manifest.get('models', {}).get(jid) != sha256(directory / f'best_{jid}.pth'):
            raise ValueError(f'{jid} checkpoint does not match its feature manifest')
    return manifest


def write_manifest(directory, occupancy_feature, graded_exit_capacity=False, **metadata):
    directory = Path(directory)
    manifest = {**metadata, 'schema_version':1, 'state_size':46, 'action_size':5,
                'observation_schema': OBSERVATION_SCHEMA,
                'occupancy_feature':occupancy_feature, 'graded_exit_capacity':graded_exit_capacity,
                'network_sha256':sha256(ROOT / 'simulation/corridor.net.xml'),
                'models':{jid:sha256(directory / f'best_{jid}.pth') for jid in JUNCTION_IDS}}
    path = directory / 'manifest.json'
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(manifest, indent=2)+'\n')
    temporary.replace(path)
    return manifest
