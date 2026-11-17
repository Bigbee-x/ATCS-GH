#!/usr/bin/env python3
"""Matched, resumable multi-process evaluation of immutable corridor bundles.

Every controller receives identical SUMO routes/seeds, crossing clearance and
boarding services. A candidate is never installed by this evaluator.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'ai'))
from corridor_bundle import settings, sha256
ROUTES = {'morning':'corridor_routes.rou.xml', 'evening':'corridor_routes_evening.rou.xml', 'offpeak':'corridor_routes_offpeak.rou.xml'}
DEVELOPMENT = [('morning',42),('evening',179),('offpeak',316)]
AUDIT = DEVELOPMENT + [('morning',997)]
REGRESSION = [(scenario,seed) for scenario in ROUTES for seed in (20261114,20261115,20261116)]
# The first holdout exposed a yellow-transition bug. Once used to fix runtime
# behaviour, those cases are regression tests, not unseen promotion evidence.
HOLDOUT = [(scenario,seed) for scenario in ROUTES for seed in (20261121,20261122,20261123)]
SOURCES = ['ai/corridor_env.py','ai/corridor_controller.py','ai/occupancy.py','scripts/corridor_runtime.py',
           'scripts/crossing_safety.py','scripts/trotro_service.py','scripts/diagnose_corridor.py',
           'visualizer/assets/transit/stations.json','simulation/corridor.net.xml','ai/dqn_agent.py']


def run_case(job):
    name, model_dir, graded, scenario, seed, output, duration = job
    route = ROOT/'simulation'/ROUTES[scenario]
    config = settings(model_dir) if model_dir else {}
    signature = {'name':name,'scenario':scenario,'seed':seed,'duration':duration,'graded':graded,
        'sumo_distribution':version('eclipse-sumo'),
        'config':config,'route':sha256(route),'sources':{p:sha256(ROOT/p) for p in SOURCES},
        'models':{j:sha256(model_dir/f'best_{j}.pth') for j in ('J0','J1','J2')} if model_dir else {}}
    fingerprint=hashlib.sha256(json.dumps(signature,sort_keys=True).encode()).hexdigest()
    destination=output/name/f'{scenario}-{seed}.json'
    if destination.exists():
        result=json.loads(destination.read_text())
        if result.get('fingerprint') == fingerprint: return name,scenario,seed,result,True
    destination.parent.mkdir(parents=True,exist_ok=True)
    command=[sys.executable,str(ROOT/'scripts/diagnose_corridor.py'),'--controller','adaptive' if model_dir else 'fixed',
             '--route',str(route),'--seed',str(seed),'--duration',str(duration),'--output',str(destination)]
    if model_dir: command.extend(['--model-dir',str(model_dir)])
    if graded is not None: command.append('--graded-exit-capacity' if graded else '--no-graded-exit-capacity')
    with destination.with_suffix('.log').open('w') as log:
        process=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    if process.returncode: raise RuntimeError(f'{name}/{scenario}/{seed} failed; inspect {destination.with_suffix(".log")}')
    result=json.loads(destination.read_text())
    result['fingerprint']=fingerprint
    result['evaluation_inputs']=signature
    destination.write_text(json.dumps(result,indent=2)+'\n')
    return name,scenario,seed,result,False


def summarize(results):
    summary={}
    shipped=results.get('shipped',{})
    fixed=results.get('fixed',{})
    for name, cases in results.items():
        ratios=[]; violations=[]; fixed_ratios=[]
        for case,result in cases.items():
            ref=shipped.get(case)
            baseline=fixed.get(case)
            if result['collisions'] or result['teleports']:
                violations.append(f'{case}: {result["collisions"]} colliding vehicles / {result["teleports"]} teleports')
            if ref:
                ratio=result['mean_stopped_vehicles']/max(ref['mean_stopped_vehicles'],1e-9)
                ratios.append(ratio)
                if ratio>1.000001: violations.append(f'{case}: stopped vehicles {ratio:.4f}x shipped')
                if result['arrived'] < ref['arrived']*.995: violations.append(f'{case}: completed trips fell by more than 0.5%')
            if baseline:
                ratio=result['mean_stopped_vehicles']/max(baseline['mean_stopped_vehicles'],1e-9)
                fixed_ratios.append(ratio)
                if ratio>=1: violations.append(f'{case}: does not beat matched fixed timer')
        summary[name]={'cases':len(cases),'mean_ratio_to_shipped':sum(ratios)/len(ratios) if ratios else None,
            'worst_ratio_to_shipped':max(ratios) if ratios else None,
            'mean_ratio_to_fixed':sum(fixed_ratios)/len(fixed_ratios) if fixed_ratios else None,
            'passes_comparisons':bool(cases) and name not in ('fixed','shipped') and set(cases)==set(shipped) and not violations,
            'eligible':bool(cases) and name not in ('fixed','shipped') and set(cases)==set(shipped)==set(fixed) and not violations,
            'violations':violations}
    return summary


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',required=True)
    p.add_argument('--candidate',action='append',default=[],help='name=/path/to/immutable/bundle')
    p.add_argument('--suite',choices=['development','audit','regression','holdout'],default='audit')
    p.add_argument('--workers',type=int,default=3)
    p.add_argument('--duration',type=int,default=7200)
    p.add_argument('--graded-study',action='store_true')
    p.add_argument('--no-fixed',action='store_true',help='Compare only to shipped for candidate screening')
    args=p.parse_args()
    if not 1<=args.workers<=4: p.error('Use 1–4 workers to bound local CPU/RAM usage')
    output=Path(args.output).resolve(); output.mkdir(parents=True,exist_ok=True)
    configs={'shipped':(ROOT/'ai/checkpoints/corridor',False)}
    if not args.no_fixed: configs['fixed']=(None,None)
    if args.graded_study: configs['graded']=(ROOT/'ai/checkpoints/corridor',True)
    for item in args.candidate:
        name,directory=item.split('=',1)
        if not name.replace('-','').replace('_','').isalnum() or name in configs: p.error(f'Invalid/duplicate name {name}')
        path=Path(directory).resolve(); config=settings(path)
        configs[name]=(path,config['graded_exit_capacity'])
    cases={'development':DEVELOPMENT,'audit':AUDIT,'regression':REGRESSION,'holdout':HOLDOUT}[args.suite]
    jobs=[(name,path,graded,scenario,seed,output,args.duration) for name,(path,graded) in configs.items() for scenario,seed in cases]
    results={name:{} for name in configs}
    started=time.monotonic()
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures=[pool.submit(run_case,job) for job in jobs]
        for future in as_completed(futures):
            name,scenario,seed,result,cached=future.result()
            results[name][f'{scenario}-{seed}']=result
            print(json.dumps({'completed':sum(len(c) for c in results.values()),'total':len(jobs),'name':name,
                'case':f'{scenario}-{seed}','mean_stopped':result['mean_stopped_vehicles'],
                'arrived':result['arrived'],'collisions':result['collisions'],'teleports':result['teleports'],'cached':cached}),flush=True)
    report={'suite':args.suite,'duration':args.duration,'wall_seconds':round(time.monotonic()-started,2),
            'scope':'Screening only; deployment also requires the full audit and an independent holdout, all at 7200 seconds.',
            'criteria':'Zero collisions/teleports; no stopped-vehicle regression in any case; arrivals >=99.5% shipped; beat matched fixed timer when included.',
            'summary':summarize(results),'cases':{name:{case:{k:r[k] for k in ('mean_stopped_vehicles','arrived','collisions','teleports','completed_mean_trip_seconds','unfinished_mean_age_seconds','model_hashes')} for case,r in rows.items()} for name,rows in results.items()}}
    (output/f'summary-{args.suite}.json').write_text(json.dumps(report,indent=2)+'\n')
    print('EVALUATION COMPLETE '+json.dumps(report['summary']),flush=True)

if __name__=='__main__':main()
