import json
from rime_jev.providers import JevProvider,DecisionRequest,Candidate

def request():
    return DecisionRequest('budget','汽车','youxiang',(Candidate('a','油箱'),Candidate('b','邮箱')),500)

def test_corrupt_ledger_does_not_reset_spending_or_read_credentials(tmp_path):
    path=tmp_path/'budget.json';path.write_text('{broken-private-marker')
    calls=[]
    p=JevProvider('confirmed.ref',budget_path=path,secret_reader=lambda ref:calls.append(ref))
    result=p.decide(request()).to_dict('budget')
    assert result['status']=='unavailable'
    assert result['error']=='budget_unavailable'
    assert not calls
    assert 'private-marker' not in json.dumps(result)
    assert path.read_text()=='{broken-private-marker'

def test_restart_honours_existing_spending_and_next_day_resets(tmp_path):
    path=tmp_path/'budget.json';path.write_text(json.dumps({'date':'2026-10-10','spent_usd':.25,'reserved_usd':0}))
    p=JevProvider('confirmed.ref',budget_path=path,date_provider=lambda:'2026-10-10')
    assert p.decide(request()).error=='budget_exhausted'
    assert p.budget_snapshot()['spent_usd']==.25
    q=JevProvider('confirmed.ref',budget_path=path,date_provider=lambda:'2026-10-11')
    assert q.budget_snapshot()['spent_usd']==0
    assert q.budget_snapshot()['remaining_usd']==.25

def test_negative_or_future_ledger_is_not_treated_as_unused_budget(tmp_path):
    path=tmp_path/'budget.json'
    for value in [{'date':'2026-10-10','spent_usd':-1,'reserved_usd':0},{'date':'2026-10-11','spent_usd':0,'reserved_usd':0}]:
        path.write_text(json.dumps(value))
        p=JevProvider('confirmed.ref',budget_path=path,date_provider=lambda:'2026-10-10')
        assert p.decide(request()).error=='budget_unavailable'
