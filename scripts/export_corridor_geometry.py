#!/usr/bin/env python3
"""Export read-only SUMO geometry for the metre-scale Godot scenes.

Use --single for intersection.net.xml; default is corridor.net.xml. --check detects stale assets.
No simulation inputs, lane IDs, or model manifests are modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'simulation/corridor.net.xml'
TARGET = ROOT / 'visualizer/assets/network/corridor.json'


def export(corridor=True):
    source = SOURCE if corridor else ROOT / 'simulation/intersection.net.xml'
    routes = ROOT / ('simulation/corridor_routes.rou.xml' if corridor else 'simulation/routes.rou.xml')
    root = ET.parse(source).getroot()
    origin = root.find("junction[@id='J0']")
    ox, oy = float(origin.get('x')), float(origin.get('y'))
    def shape(raw):
        return [[round(ox-float(p.split(',')[0]), 4), round(float(p.split(',')[1])-oy, 4)] for p in raw.split()]
    edges = []
    for edge in root.findall('edge'):
        lanes = [dict(id=l.get('id'), width=float(l.get('width', '3.2')),
                      length=float(l.get('length')), pedestrian=l.get('allow') == 'pedestrian',
                      shape=shape(l.get('shape'))) for l in edge.findall('lane')]
        edges.append(dict(id=edge.get('id'), kind=edge.get('function', 'road'),
                          source=edge.get('from', ''), target=edge.get('to', ''), lanes=lanes))
    junctions = {j.get('id'): dict(center=[ox-float(j.get('x')), float(j.get('y'))-oy],
                 shape=shape(j.get('shape'))) for j in root.findall('junction') if j.get('id') in ('J0','J1','J2')}
    types = {}
    for t in ET.parse(routes).getroot().findall('vType'):
        if t.get('vClass') == 'pedestrian': continue
        types[t.get('id')] = dict(length=float(t.get('length','5')), width=float(t.get('width','1.8')), height=float(t.get('height','1.5')))
    return dict(schema=1, units='metres', source=str(source.relative_to(ROOT)),
                sha256=hashlib.sha256(source.read_bytes()).hexdigest(), origin=[ox,oy],
                junctions=junctions, edges=edges, vehicle_types=types)

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--single', action='store_true', help='Export the single-junction network')
    args=parser.parse_args()
    target = TARGET if not args.single else TARGET.with_name('single.json')
    data=export(not args.single)
    if args.check:
        assert json.loads(target.read_text()) == data, f'Stale {target.name}: rerun this command without --check'
        print(f'{target.stem} geometry matches SUMO, including every lane and crossing.')
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(data, separators=(',',':'))+'\n')
        print(f'Exported {len(data["edges"])} edges to {target}')
