#!/usr/bin/env python3
"""Legacy 0.2 model-first experiment; not the 0.2.4 second-slot UI policy.

Requires separately prepared synthetic snapshots and an explicit evaluation budget.
Never run automatically during installation.
"""
import argparse, collections, hashlib, json, math, os, statistics, sys, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from rime_jev.providers import LocalProvider,JevProvider,DecisionRequest

def write(path,value): path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n')
def percentile(xs,p):
    return sorted(xs)[min(len(xs)-1,math.ceil(len(xs)*p)-1)] if xs else None

def selected(r,threshold,deadline=True):
    base=r['baseline']
    a=r.get('answer',{})
    if a.get('status')!='ready' or a.get('choice_id')=='none':return base
    if deadline and a.get('elapsed_ms',1e9)+260>600:return base
    probs=a.get('probabilities') or {};ranked=sorted(probs.values(),reverse=True)
    if len(ranked)<2 or ranked[0]<threshold or ranked[0]-ranked[1]<0.15:return base
    return next((c['text'] for c in r['candidates'] if c['id']==a['choice_id']),base)

def summary(rows,threshold):
    scored=[r for r in rows if r['scoring']=='accuracy']
    baseline=sum(r['baseline']==r['target'] for r in scored)
    actual=sum(selected(r,threshold)==r['target'] for r in scored)
    quality=sum(selected(r,threshold,False)==r['target'] for r in scored)
    regressions=sum(r['baseline']==r['target'] and selected(r,threshold)!=r['target'] for r in scored)
    lat=[r['answer']['elapsed_ms'] for r in rows if r.get('answer',{}).get('status')=='ready']
    return {'cases':len(rows),'scored':len(scored),'baseline_correct':baseline,'model_policy_correct_ignoring_deadline':quality,'correct_with_600ms_window':actual,'regressions':regressions,'threshold':threshold,'margin':0.15,'candidate_coverage':sum(any(c['text']==r['target'] for c in r['candidates']) for r in scored),'statuses':dict(collections.Counter(r.get('answer',{}).get('status',r.get('skip')) for r in rows)), 'latency_ms':{'p50':percentile(lat,.5),'p95':percentile(lat,.95),'p99':percentile(lat,.99)},'within_promote_window':sum(x+260<=600 for x in lat),'within_annotation_window':sum(x+260<=1500 for x in lat)}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--provider',choices=['local','jev'],required=True);ap.add_argument('--run',default='');args=ap.parse_args()
    if args.run and not args.run.replace('-','').isalnum(): raise SystemExit('Invalid run name')
    wd=ROOT/'work/evaluation';prefix=args.provider+('-'+args.run if args.run else '');path=wd/f'{prefix}-results.jsonl'
    if path.exists():raise SystemExit('Results exist; do not silently consume another evaluation attempt.')
    cases=[json.loads(x) for x in (ROOT/'evaluation/cases.jsonl').read_text().splitlines()]
    baseline={r['id']:r for r in map(json.loads,(wd/'candidates.jsonl').read_text().splitlines())}
    budgetpath=wd/'budget.json';budget=json.loads(budgetpath.read_text());began=time.monotonic()
    provider=LocalProvider(ROOT/'work/models/this-that-model-1.2') if args.provider=='local' else JevProvider('typesafe_api_key',budget_path=wd/'jev-request-budget.json',daily_budget_usd=2.0)
    if args.provider=='local':
        provider.start();budget['local_forward_calls']+=1;write(budgetpath,budget)
        if not provider.wait_until_ready(90):raise SystemExit('Local model unavailable')
    else:
        provider.start()
    threshold=None;results=[];failures=0
    with path.open('x') as out:
        for split in ['calibration','acceptance']:
            for case in [r for r in cases if r['split']==split]:
                b=baseline[case['id']];s=b.get('snapshot',{});cands=s.get('candidates',[])[:8]
                row={**case,'baseline':next(iter(b['candidates']),None),'candidates':cands}
                if case.get('scoring')=='retain_order_control':row['skip']='retain_order_control'
                elif len(cands)<2 or s.get('protected') or (cands and cands[0]['text']!=row['baseline']):row['skip']='ineligible'
                else:
                    field='local_forward_calls' if args.provider=='local' else 'jev_requests'
                    cap=budget['limits']['local' if args.provider=='local' else 'jev']
                    if budget[field]>=cap or budget['jev_cost_usd_estimate']>=budget['limits']['usd'] or time.monotonic()-began>7200:raise SystemExit('Evaluation budget reached')
                    budget[field]+=1;write(budgetpath,budget)
                    request=DecisionRequest.from_payload({'id':case['id'],'state':{'context':case['context'][-80:],'pinyin':case['pinyin']},'candidates':[{'id':c['id'],'text':c['text']} for c in cands],'max_age_ms':8000})
                    answer=provider.decide(request).to_dict(case['id']);row['answer']=answer
                    failures=failures+1 if answer.get('status') in ['error','unavailable'] else 0
                    if failures>=3: raise SystemExit('Repeated service failure; evaluation stopped without retry')
                    if args.provider=='jev':
                        tokens=(answer.get('usage') or {}).get('input_tokens',0)
                        budget['jev_input_tokens']+=tokens
                        budget['jev_cost_usd_estimate']+=(tokens or 1000)*.042/1_000_000
                        write(budgetpath,budget)
                        time.sleep(.25)
                out.write(json.dumps(row,ensure_ascii=False)+'\n');out.flush();results.append(row)
                if len(results)%25==0:print(json.dumps({'provider':args.provider,'completed':len(results),'elapsed_s':round(time.monotonic()-began,1)}),flush=True)
            if split=='calibration':
                scores=[]
                for t in [.55,.65,.75,.85,.95]:
                    v=summary(results,t);scores.append((v['correct_with_600ms_window']-2*v['regressions'],t,v))
                _,threshold,cal=max(scores,key=lambda x:(x[0],x[1]))
                write(wd/f'{prefix}-calibration.json',{'frozen_threshold':threshold,'candidates':[x[2] for x in scores]})
                print('THRESHOLD_FROZEN',args.provider,threshold,flush=True)
    provider.shutdown()
    report={'provider':args.provider,'run':args.run,'repeated_holdout_regression':bool(args.run),'dataset_sha256':hashlib.sha256((ROOT/'evaluation/cases.jsonl').read_bytes()).hexdigest(),'calibration':summary([r for r in results if r['split']=='calibration'],threshold),'acceptance':summary([r for r in results if r['split']=='acceptance'],threshold),'elapsed_s':time.monotonic()-began,'budget':budget,'scope':'synthetic offline comparison; does not establish live input-method acceptance'}
    write(wd/f'{prefix}-summary.json',report);print(json.dumps(report,ensure_ascii=False),flush=True)
if __name__=='__main__':main()
