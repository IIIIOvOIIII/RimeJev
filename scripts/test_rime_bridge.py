#!/usr/bin/env python3
"""Real librime/Lua regression on synthetic public data; no model or UI calls."""
import hashlib
import json
import shutil
import subprocess
import tempfile
import time
from collections import Counter
from pathlib import Path

from prepare_bridge_fixture import FIXTURE, SQUIRREL, prepare_fixture

root = Path(__file__).resolve().parents[1]
fw = str(SQUIRREL / 'Frameworks')
evidence = root / 'work/evidence'
evidence.mkdir(parents=True, exist_ok=True)
rows = []
logs = []
fixture = None


def source_hashes():
    paths = [root / name for name in ('native/rime_probe.mm', 'native/include/rime_api.h',
                                     'scripts/test_rime_bridge.py', 'scripts/prepare_bridge_fixture.py')]
    paths += sorted((root / 'rime/lua/jev').rglob('*.lua')) + sorted(FIXTURE.glob('*'))
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths if path.is_file()}


def probe(case, fixture_override=None):
    # Every session gets its own compiled synthetic data and current public Lua.
    with tempfile.TemporaryDirectory(prefix='rime-test-', dir=root / 'work') as directory:
        user = Path(directory) / 'Rime'
        shutil.copytree(fixture_override or fixture, user)
        proc = subprocess.run(
            [str(root / 'work/rime_probe'), str(user), str(user / 'shared')],
            input=json.dumps(case) + '\n', capture_output=True, text=True, timeout=10,
        )
    logs.append(f"[{case['id']}]\n{proc.stderr}")
    (evidence / 'bridge-tests.log').write_text('\n'.join(logs))
    proc.check_returncode()
    row = json.loads(proc.stdout)
    row['probe_case'] = case
    rows.append(row)
    (evidence / 'bridge-probe-rows.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2))
    assert row['schema_ok'], case['id']
    assert not any(x in proc.stderr for x in ['LuaTranslation::Next error', '加载失败', 'initialize  error']), case['id']
    return row


def sampling_unchanged(row):
    assert set(row['sampling_before']) == {'page', 'highlight', 'caret', 'input'}
    assert row['sampling_before'] == row['sampling_after'], row['id']
    batches = row['sample_batches']
    assert row['sample_raw_count'] <= 64 and len(batches) <= 8
    assert sum(batch['raw_count'] for batch in batches) == row['sample_raw_count']
    offset = 0
    for i, batch in enumerate(batches):
        assert batch['start'] == offset and 0 <= batch['raw_count'] <= 8
        assert batch['snapshot_count'] <= 24
        if i < len(batches) - 1:
            assert batch['raw_count'] == 8 and batch['snapshot_count'] < 24
        offset += batch['raw_count']
    assert row['sampled_candidates'] == row['candidates'][:row['sample_raw_count']]


def placed_second(row, index, name='reordered'):
    baseline = row['candidates']
    sampled = row['sampled_snapshot'] if row['probe_case'].get('sample_candidates') else row['snapshot']
    target = sampled['candidates'][index]
    assert not sampled['protected'], row['id']
    assert row['target'] == target, row['id']
    # These fixtures have a unique target; never deduplicate the original list.
    assert baseline.count(target['text']) == 1, row['id']
    original_rank = baseline.index(target['text'])
    expected = baseline.copy()
    if original_rank > 0:
        expected.insert(1, expected.pop(original_rank))
    assert len(baseline) == len(row[name]) == 128, row['id']
    assert row[name][24:] == baseline[24:], (row['id'], 'tail changed')
    assert Counter(row[name]) == Counter(baseline), row['id']
    assert row[name] == expected, (row['id'], name, original_rank + 1, row[name][:14], expected[:14])
    assert row[name + '_applied'] == target['key'], row['id']
    refreshed = row[name + '_state']
    assert refreshed['page'] == refreshed['highlight'] == 0, row['id']
    assert refreshed['highlighted_text'] == baseline[0], row['id']
    assert refreshed['page_candidates'] == expected[:len(refreshed['page_candidates'])], row['id']
    assert refreshed['input'] == row['sampling_after']['input'], row['id']
    assert refreshed['caret'] == row['sampling_after']['caret'], row['id']
    return expected


def restored(row, name='restored'):
    assert row[name] == row['candidates'], (row['id'], name)
    assert not row[name + '_applied'], row['id']
    refreshed = row[name + '_state']
    assert refreshed['page'] == refreshed['highlight'] == 0, row['id']
    assert refreshed['highlighted_text'] == row['candidates'][0], row['id']
    assert refreshed['page_candidates'] == row['candidates'][:len(refreshed['page_candidates'])], row['id']
    assert refreshed['input'] == row['sampling_after']['input'], row['id']
    assert refreshed['caret'] == row['sampling_after']['caret'], row['id']


def committed(row, expected):
    assert row['commit_accepted'], row['id']
    assert row.get('committed') == expected, (row['id'], row.get('committed'), expected)


def genuine_types(snapshot):
    # The public bridge's identity key includes the original candidate type.
    return {bytes.fromhex(candidate['key']).decode().split('\x1f')[4]
            for candidate in snapshot['candidates']}


def main(protected_fixture):
    subprocess.run([
        'clang++', '-std=c++17', '-fobjc-arc', '-I', str(root / 'native/include'),
        str(root / 'native/rime_probe.mm'), fw + '/librime.1.dylib', '-Wl,-rpath,' + fw,
        '-framework', 'Foundation', '-o', str(root / 'work/rime_probe'),
    ], check=True, timeout=30)
    sj = {'pinyin': 'sj', 'limit': 128, 'sample_candidates': True}
    discovery = probe(dict(sj, id='sj-discovery'))
    sampling_unchanged(discovery)
    sample = discovery['sampled_snapshot']['candidates']
    index = next(i for i, candidate in enumerate(sample) if candidate['text'] == '睡觉')
    assert index + 1 == 12, ('fixture target must exercise rank 12', index + 1)
    assert discovery['candidates'].index('睡觉') + 1 == 12
    assert len(sample) == 24 and not discovery['sampled_snapshot']['protected']
    assert genuine_types(discovery['sampled_snapshot']) == {'phrase'}
    assert discovery['candidates'][-1] == '深层合成候选一二八'
    assert discovery['sample_raw_count'] > 0 and '睡觉' in discovery['sampled_candidates']
    assert '睡觉' not in [candidate['text'] for candidate in discovery['snapshot_before_iteration']['candidates']]

    # X11 Page_Down and Down leave both the page and highlight away from zero.
    navigated = probe(dict(sj, id='sj-navigated', navigation_keys=[0xff56, 0xff54]))
    sampling_unchanged(navigated)
    assert navigated['sampling_before']['page'] > 0 and navigated['sampling_before']['highlight'] > 0
    assert navigated['sample_raw_count'] > 0
    assert len(navigated['sampled_snapshot']['candidates']) == 24
    assert any(candidate['text'] == '睡觉' for candidate in navigated['sampled_snapshot']['candidates'])

    exhausted = probe(dict(id='short-list-sampling-exhaustion', pinyin='qiche', limit=128, sample_candidates=True))
    sampling_unchanged(exhausted)
    assert exhausted['candidates'] == ['汽车']
    assert exhausted['sample_raw_count'] == len(exhausted['sampled_snapshot']['candidates']) == 1

    # Table candidates must remain protected; never weaken the public bridge's
    # guard simply to make a synthetic fixture promotable. This also exercises
    # the 64-raw-candidate scan cap: one Chinese entry marks the snapshot as
    # protected, while artificial ASCII entries cannot fill its Chinese rows.
    protected = probe(dict(id='table-translator-protected-sampling-cap', pinyin='cap', limit=128,
                           sample_candidates=True, promote_index=0), protected_fixture)
    sampling_unchanged(protected)
    assert len(protected['candidates']) == 128
    assert protected['sampled_snapshot']['protected']
    assert genuine_types(protected['sampled_snapshot']) == {'table'}
    assert [candidate['text'] for candidate in protected['sampled_snapshot']['candidates']] == ['边界']
    assert protected['sample_raw_count'] == 64 and len(protected['sample_batches']) == 8
    assert protected['promotion_count'] == 1
    restored(protected, 'reordered')

    youxiang = {'pinyin': 'youxiang', 'limit': 128}
    expanded = dict(sj, score_limit=24, promote_index=index)
    # process_key exercises Rime's key handling; it does not synthesize OS/UI events.
    submissions = [
        ('select-first', {'commit_index': 0}, 0),
        ('select-second', {'commit_index': 1}, 1),
        ('select-third', {'commit_index': 2}, 2),
        ('space', {'commit_key': ord(' ')}, 0),
        ('key-2', {'commit_key': ord('2')}, 1),
        ('key-3', {'commit_key': ord('3')}, 2),
    ]
    partial_raw_count = None
    for provider in ['local', 'jev', 'tev-0.8b', 'tev-4b']:
        decision_limit = 23 if provider.startswith('tev-') else 24
        expanded = dict(sj, score_limit=decision_limit, promote_index=index)
        for label, case, target_index in [
            ('first-hit', youxiang, 0),
            ('already-second', youxiang, 1),
            ('third', youxiang, 2),
            ('deep-rank12', expanded, index),
        ]:
            for action, commit_args, submitted_index in submissions:
                row = probe(dict(case, **commit_args, id=f'{provider}-{label}-{action}',
                                 provider=provider, promote_index=target_index))
                expected = placed_second(row, target_index)
                assert row['provider'] == provider
                if case.get('sample_candidates'):
                    sampling_unchanged(row)
                    assert row['score_limit'] == row['promotion_count'] == decision_limit
                    assert row['sampled_snapshot'] == discovery['sampled_snapshot']
                    assert row['candidates'] == discovery['candidates']
                else:
                    assert row['score_limit'] == row['promotion_count'] == 8
                    assert row['candidates'].index(row['target']['text']) == target_index
                if label == 'third':
                    assert row['target']['text'] == '油箱'
                committed(row, expected[submitted_index])

        default = probe(dict(sj, id=f'{provider}-sj-default-eight', provider=provider, promote_index=index))
        sampling_unchanged(default)
        assert default['sampled_snapshot'] == discovery['sampled_snapshot']
        assert default['candidates'] == discovery['candidates']
        assert default['score_limit'] == default['promotion_count'] == 8
        assert 'reordered' not in default and 'committed' not in default
        capped = probe(dict(expanded, id=f'{provider}-sj-score-limit-cap', provider=provider, score_limit=128))
        sampling_unchanged(capped)
        assert capped['score_limit'] == capped['promotion_count'] == 24
        placed_second(capped, index)

        for action, commit_args, submitted_index in submissions[3:5]:
            noresult = probe(dict(youxiang, **commit_args, id=f'{provider}-noresult-{action}', provider=provider))
            assert 'reordered' not in noresult
            committed(noresult, noresult['candidates'][submitted_index])
            stale = probe(dict(expanded, **commit_args, id=f'{provider}-stale-{action}', provider=provider, stale=True))
            sampling_unchanged(stale)
            restored(stale, 'reordered')
            committed(stale, stale['candidates'][submitted_index])

        missing = probe(dict(youxiang, id=f'{provider}-nonexistent-target', provider=provider,
                             promote_index=2, invalid_target=True, commit_key=ord('2')))
        restored(missing, 'reordered')
        committed(missing, missing['candidates'][1])

        for label, invalidation in [('disable-clear', {'clear_after': True}), ('stale-after-valid', {'stale_after': True})]:
            row = probe(dict(expanded, **invalidation, id=f'{provider}-{label}', provider=provider, commit_key=ord('2')))
            sampling_unchanged(row)
            placed_second(row, index)
            restored(row)
            committed(row, row['candidates'][1])

        for label, case, target_index in [('first', youxiang, 0), ('deep', expanded, index)]:
            row = probe(dict(case, id=f'{provider}-repeat-reapply-{label}', provider=provider,
                             promote_index=target_index, repeat_result=True, clear_after=True,
                             reapply_after_clear=True, commit_key=ord('2')))
            for name in ['reordered', 'repeated', 'reapplied']:
                placed_second(row, target_index, name)
            restored(row)
            committed(row, row['reapplied'][1])

        for action, commit_args, submitted_index in submissions:
            partial = probe(dict(
                **commit_args, id=f'{provider}-partial-{action}', provider=provider,
                pinyin='qicheyouxiang', caret=5, confirm_prefix=True,
                sample_candidates=True, promote_index=2, limit=128,
            ))
            sampling_unchanged(partial)
            # All synthetic suffix candidates cover the active segment; unlike
            # the previous private fixture this reaches the 24-candidate cap.
            assert len(partial['sampled_snapshot']['candidates']) == 24
            assert partial['snapshot']['pinyin'] == 'youxiang'
            expected = placed_second(partial, 2)
            committed(partial, '汽车' + expected[submitted_index])
            partial_raw_count = partial['sample_raw_count']
        print(f'{provider}: placement, submissions, restoration, reapply, partial composition PASS', flush=True)

    return {
        'passed': True, 'status': 'passed', 'probe_cases': len(rows), 'candidate_count': 128,
        'recommendation_source': 'controlled property injection; no model, cloud, or UI calls',
        'providers': ['local', 'jev', 'tev-0.8b', 'tev-4b'], 'placement': 'original first preserved; other target moves to second',
        'target_ranks': [1, 2, 3, index + 1], 'submission_methods': [action for action, _, _ in submissions],
        'noresult_unchanged': True, 'stale_unchanged': True, 'nonexistent_target_rejected': True,
        'disable_restores': True, 'stale_after_valid_restores': True, 'repeat_and_reapply_stable': True,
        'partial_composition_preserved': True, 'sj_target_rank': index + 1, 'sj_promoted_commit': '睡觉',
        'initial_snapshot_count': len(discovery['snapshot_before_iteration']['candidates']),
        'sampled_snapshot_count': len(sample), 'sample_raw_count': discovery['sample_raw_count'],
        'sample_batches': discovery['sample_batches'], 'sampling_state_unchanged': True,
        'navigated_state': navigated['sampling_before'], 'partial_sample_raw_count': partial_raw_count,
        'default_score_limit': 8, 'max_score_limit': 24, 'fresh_copy_per_case': True,
        'protected_table_guard': True, 'protected_sample_raw_count': protected['sample_raw_count'],
        'short_list_sample_raw_count': exhausted['sample_raw_count'],
        'genuine_candidate_types': {'script_translator': sorted(genuine_types(discovery['sampled_snapshot'])),
                                    'table_translator': sorted(genuine_types(protected['sampled_snapshot']))},
    }


if __name__ == '__main__':
    started = time.monotonic()
    report = {'passed': False, 'status': 'running', 'source_sha256': source_hashes()}
    (evidence / 'bridge-tests.json').write_text(json.dumps(report, indent=2))
    try:
        with tempfile.TemporaryDirectory(prefix='bridge-fixture-', dir=root / 'work') as directory:
            fixture = Path(directory) / 'Rime'
            build = prepare_fixture(fixture)
            logs.append('[synthetic-fixture-build]\n' + build['stdout'] + build['stderr'])
            protected_fixture = Path(directory) / 'TableRime'
            protected_build = prepare_fixture(protected_fixture, 'table_translator')
            logs.append('[protected-table-fixture-build]\n' + protected_build['stdout'] + protected_build['stderr'])
            report['fixture'] = {
                'kind': 'synthetic', 'source': 'tests/fixtures/rime',
                'translator': 'script_translator', 'private_data_used': False,
                'shared_data': 'empty isolated directory', 'build_command': build['command'],
            }
            report.update(main(protected_fixture))
    except Exception as exc:
        report.update(status='failed', passed=False, probe_cases=len(rows), error=repr(exc),
                      last_case=rows[-1]['id'] if rows else None)
        raise
    finally:
        report['elapsed_seconds'] = round(time.monotonic() - started, 3)
        (evidence / 'bridge-tests.log').write_text('\n'.join(logs))
        (evidence / 'bridge-probe-rows.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2))
        (evidence / 'bridge-tests.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(f"Real Rime bridge PASS: {len(rows)} isolated probes; all providers place existing targets second; "
          'direct/key commits, 128-candidate order/count, fallback, reapply, partial composition and sampling 8/24/64. '
          'Recommendations were injected; no model or UI acceptance is claimed.')
