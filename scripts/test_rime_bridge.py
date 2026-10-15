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
probe_binary = None


def compile_probe(directory):
    # Extend only a disposable copy: the shared probe remains the legacy driver.
    source = (root / 'native/rime_probe.mm').read_text()
    anchor = '        if (input[@"commit_index"] || input[@"commit_key"]) {'
    assert source.count(anchor) == 1, 'Native probe commit entry point changed'
    extension = r'''
        for (NSDictionary *step in input[@"result_steps"] ?: @[]) {
          if (step[@"epoch"]) api->set_property(s, "_jev_epoch", [step[@"epoch"] UTF8String]);
          for (NSNumber *key in step[@"keys"] ?: @[]) api->process_key(s, [key intValue], 0);
          api->set_property(s, "_jev_result", [step[@"wire"] UTF8String]);
          NSString *name = step[@"name"];
          output[[name stringByAppendingString:@"_snapshot_before_iteration"]] = snapshot(api, s);
          recordResult(api, s, limit, output, name);
          output[[name stringByAppendingString:@"_snapshot"]] = snapshot(api, s);
        }
'''
    generated = directory / 'rime_bridge_probe.mm'
    source = source.replace('api->set_option(s, "ascii_mode", False);',
                            'api->set_option(s, "ascii_mode", [input[@"ascii_mode"] boolValue]);')
    extension += r'''
        NSMutableArray *keySteps = [NSMutableArray array];
        for (NSDictionary *step in input[@"key_steps"] ?: @[]) {
          NSMutableDictionary *observed = [NSMutableDictionary dictionary];
          observed[@"accepted"] = @(api->process_key(s, [step[@"key"] intValue], [step[@"modifiers"] intValue]));
          RIME_STRUCT(RimeContext, pageContext);
          if (api->get_context(s, &pageContext)) {
            [observed addEntriesFromDictionary:state(api, s, pageContext)];
            observed[@"count"] = @(pageContext.menu.num_candidates);
            api->free_context(&pageContext);
          }
          RIME_STRUCT(RimeCommit, keyCommit);
          if (api->get_commit(s, &keyCommit)) {
            observed[@"committed"] = keyCommit.text ? [NSString stringWithUTF8String:keyCommit.text] : @"";
            api->free_commit(&keyCommit);
          }
          [keySteps addObject:observed];
        }
        output[@"key_steps"] = keySteps;
'''
    generated.write_text(source.replace(anchor, extension + anchor))
    binary = directory / 'rime_bridge_probe'
    subprocess.run([
        'clang++', '-std=c++17', '-fobjc-arc', '-I', str(root / 'native/include'),
        str(generated), fw + '/librime.1.dylib', '-Wl,-rpath,' + fw,
        '-framework', 'Foundation', '-o', str(binary),
    ], check=True, timeout=30)
    return binary


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
            [str(probe_binary), str(user), str(user / 'shared')],
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


def v2_wire(snapshot, indices, groups, count=8):
    candidates = snapshot['candidates']
    keys = '\n'.join(candidate['key'] for candidate in candidates[:count])
    return '|'.join(['v2', snapshot['epoch'], snapshot['input'].encode().hex(),
                     ','.join(candidates[i]['key'] for i in indices), str(min(count, len(candidates))),
                     keys.encode().hex(), ','.join('+'.join(group) for group in groups)])


def placed_plan(row, indices, wire, name='reordered'):
    baseline = row['candidates']
    targets = [row['snapshot']['candidates'][i]['text'] for i in indices]
    selected = [text for text in targets if text != baseline[0]]
    assert len(set(targets)) == len(targets), row['id']
    expected = [baseline[0]] + selected + [text for text in baseline[1:] if text not in selected]
    assert len(row[name]) == len(baseline) == 128, row['id']
    assert Counter(row[name]) == Counter(baseline), row['id']
    assert row[name] == expected, (row['id'], name, row[name][:14], expected[:14])
    assert row[name + '_applied'] == wire, (row['id'], 'v2 marker must equal the whole wire')
    refreshed = row[name + '_state']
    assert refreshed['page'] == refreshed['highlight'] == 0, row['id']
    assert refreshed['highlighted_text'] == baseline[0], row['id']
    assert refreshed['page_candidates'] == expected[:len(refreshed['page_candidates'])], row['id']
    assert refreshed['input'] == row['sampling_after']['input'], row['id']
    assert refreshed['caret'] == row['sampling_after']['caret'], row['id']
    # Even after placement, subsequent model callbacks see the original keys and IDs.
    snapshot = row[name + '_snapshot']
    assert snapshot == row['snapshot'], (row['id'], 'original baseline snapshot changed')
    initial = row[name + '_snapshot_before_iteration']['candidates']
    assert initial == row['snapshot']['candidates'][:len(initial)], row['id']
    return expected


def dual_model_tests(discovery, protected_fixture, submissions):
    start = len(rows)
    snapshot = discovery['snapshot']
    base = {'pinyin': 'sj', 'limit': 128}
    for local in ['local', 'tev-0.8b', 'tev-4b']:
        for priority in [['jev', local], [local, 'jev']]:
            high, low = priority
            scenarios = [
                ('both-first', [0], [priority]),
                ('first-high', [0, 11], [[high], [low]]),
                ('first-low', [0, 11], [[low], [high]]),
                ('different', [11, 5] if high == 'jev' else [5, 11], [[high], [low]]),
                ('same', [11], [priority]),
            ]
            for label, indices, groups in scenarios:
                wire = v2_wire(snapshot, indices, groups, count=24)
                for action, commit_args, submitted in submissions:
                    row = probe(dict(base, **commit_args, id=f'v2-{high}-{low}-{label}-{action}',
                                     result_steps=[{'name': 'reordered', 'wire': wire}]))
                    expected = placed_plan(row, indices, wire)
                    committed(row, expected[submitted])

    valid = v2_wire(snapshot, [11, 5], [['jev'], ['local']], count=24)
    same = v2_wire(snapshot, [11], [['local', 'jev']], count=24)
    single = v2_wire(snapshot, [11], [['local']], count=24)
    # A callback from the second model must use the original signed baseline,
    # even when the first callback already moved its target to slot 2.
    callbacks = probe(dict(base, id='v2-progressive-callbacks-repeat-clear-reapply', commit_key=ord('3'),
                          result_steps=[{'name': 'single', 'wire': single},
                                        {'name': 'reordered', 'wire': valid},
                                        {'name': 'merged', 'wire': same},
                                        {'name': 'repeated', 'wire': same},
                                        {'name': 'restored', 'wire': ''},
                                        {'name': 'reapplied', 'wire': valid}]))
    placed_plan(callbacks, [11], single, 'single')
    placed_plan(callbacks, [11, 5], valid)
    for name in ['merged', 'repeated']:
        placed_plan(callbacks, [11], same, name)
    restored(callbacks)
    expected = placed_plan(callbacks, [11, 5], valid, 'reapplied')
    committed(callbacks, expected[2])

    fields = valid.split('|')
    invalid = {}
    def bad(label, index, value):
        parts = fields.copy()
        parts[index] = value
        invalid[label] = '|'.join(parts)
    bad('old-epoch', 1, 'old-probe')
    bad('wrong-input', 2, 'other'.encode().hex())
    bad('wrong-signature', 5, '00')
    bad('reordered-signature', 5, '\n'.join(c['key'] for c in reversed(snapshot['candidates'])).encode().hex())
    bad('missing-target', 3, snapshot['candidates'][11]['key'] + ',missing')
    bad('duplicate-targets', 3, ','.join([snapshot['candidates'][11]['key']] * 2))
    bad('three-targets', 3, ','.join(snapshot['candidates'][i]['key'] for i in [11, 5, 3]))
    bad('empty-targets', 3, '')
    bad('trailing-target', 3, fields[3] + ',')
    for value in ['0', '25', '-1', 'eight']:
        bad('invalid-count-' + value, 4, value)
    for label, value in [('unknown', 'jev,other'), ('case', 'Jev,local'), ('disabled', 'off,local'),
                         ('two-jevs', 'jev,jev'), ('two-locals', 'local,tev-4b'),
                         ('duplicate-label', 'jev+jev,local'), ('reused-label', 'jev+local,local'),
                         ('three-providers', 'jev+local,tev-0.8b'), ('empty-group', 'jev,'),
                         ('missing-group', 'jev'), ('extra-group', 'jev,local,tev-4b'),
                         ('empty-label', 'jev+,local')]:
        bad('source-' + label, 6, value)
    invalid['target-outside-signed-window'] = v2_wire(snapshot, [11], [['jev']], count=8)
    invalid['no-sources'] = v2_wire(snapshot, [11], [[]], count=24)
    invalid['merged-two-locals'] = v2_wire(snapshot, [11], [['local', 'tev-4b']], count=24)
    invalid['unknown-version'] = valid.replace('v2|', 'v3|', 1)
    invalid['extra-field'] = valid + '|extra'
    # Every invalid payload arrives after a valid reorder, proving restoration
    # and numeric commit behavior rather than just an initially empty marker.
    for label, wire in invalid.items():
        row = probe(dict(base, id='v2-late-invalid-' + label, commit_key=ord('2'),
                         result_steps=[{'name': 'reordered', 'wire': valid}, {'name': 'restored', 'wire': wire}]))
        placed_plan(row, [11, 5], valid)
        restored(row)
        committed(row, row['candidates'][1])

    epoch = probe(dict(base, id='v2-epoch-changed-before-result', commit_key=ord('3'),
                       result_steps=[{'name': 'reordered', 'wire': valid},
                                     {'name': 'restored', 'epoch': 'next', 'wire': valid}]))
    placed_plan(epoch, [11, 5], valid)
    restored(epoch)
    committed(epoch, epoch['candidates'][2])
    changed = probe(dict(base, id='v2-input-changed-before-late-result', commit_key=ord('1'),
                         result_steps=[{'name': 'reordered', 'wire': valid},
                                       {'name': 'changed', 'keys': [0xff08, 0xff08] + list(map(ord, 'youxiang')), 'wire': ''},
                                       {'name': 'late', 'wire': valid}]))
    placed_plan(changed, [11, 5], valid)
    assert changed['late'] == changed['changed']
    assert not changed['late_applied']
    assert changed['late_state']['input'] == 'youxiang'
    committed(changed, changed['changed'][0])

    # Real Rime table candidates remain protected even with a valid v2 signature.
    table_base = probe({'id': 'v2-protected-discovery', 'pinyin': 'cap', 'limit': 128}, protected_fixture)
    table_wire = v2_wire(table_base['snapshot'], [0], [['jev', 'local']])
    table = probe({'id': 'v2-protected-candidates', 'pinyin': 'cap', 'limit': 128, 'commit_key': ord('1'),
                   'result_steps': [{'name': 'reordered', 'wire': table_wire}]}, protected_fixture)
    restored(table, 'reordered')
    committed(table, table['candidates'][0])

    # Partial composition retains its confirmed prefix with two recommendations.
    partial_case = {'pinyin': 'qicheyouxiang', 'caret': 5, 'confirm_prefix': True, 'limit': 128}
    partial_base = probe(dict(partial_case, id='v2-partial-discovery'))
    partial_wire = v2_wire(partial_base['snapshot'], [2, 4], [['jev'], ['tev-4b']])
    for key in ['1', '2', '3']:
        row = probe(dict(partial_case, id='v2-partial-key-' + key, commit_key=ord(key),
                         result_steps=[{'name': 'reordered', 'wire': partial_wire}]))
        expected = placed_plan(row, [2, 4], partial_wire)
        committed(row, '汽车' + expected[int(key) - 1])
    print('v2: dual placement, whole-wire marker, dedup, callback baseline, late invalidation and numeric commits PASS', flush=True)
    return len(rows) - start, len(invalid)


def punctuation_paging_tests():
    key = lambda value, modifiers=0: {'key': ord(value), 'modifiers': modifiers}
    for recommendation in ({}, {'promote_index': 2, 'provider': 'jev'}):
        row = probe(dict(id=f'punctuation-paging-{bool(recommendation)}', pinyin='sj', limit=128,
                         key_steps=[key(','), key('.'), key('.'), key(','), key(',')],
                         commit_key=ord('2'), **recommendation))
        assert [step['page'] for step in row['key_steps']] == [0, 1, 2, 1, 0]
        assert all(step['accepted'] and step['input'] == 'sj' and not step.get('committed')
                   for step in row['key_steps'])
        expected = row.get('reordered', row['candidates'])
        committed(row, expected[1])
    final = probe(dict(id='punctuation-last-page', pinyin='sj', limit=128,
                      key_steps=[key('.')] * 18, commit_key=ord('2')))
    assert final['key_steps'][-1]['page'] == final['key_steps'][-2]['page'] == 15
    assert all(step['input'] == 'sj' and not step.get('committed') for step in final['key_steps'])
    committed(final, final['candidates'][121])
    single = probe(dict(id='punctuation-single-candidate', pinyin='qiche',
                        key_steps=[key(','), key('.')], commit_key=ord(' ')))
    assert all(step['page'] == 0 and step['input'] == 'qiche' and not step.get('committed')
               for step in single['key_steps'])
    committed(single, '汽车')
    for punctuation, text in [(',', '，'), ('.', '。')]:
        normal = probe(dict(id=f'punctuation-no-menu-{ord(punctuation)}', pinyin='',
                            key_steps=[key(punctuation)]))
        assert normal['key_steps'][0].get('committed') == text
        ascii_row = probe(dict(id=f'punctuation-ascii-{ord(punctuation)}', pinyin='', ascii_mode=True,
                               key_steps=[key(punctuation)]))
        assert not ascii_row['key_steps'][0]['accepted'] and not ascii_row['key_steps'][0].get('committed')
    modified = probe(dict(id='punctuation-modifier-keys', pinyin='sj',
                          key_steps=[key('.', 1), key(',', 1), key('.', 4), key(',', 4)]))
    assert all(step['page'] == 0 for step in modified['key_steps'])
    print('Punctuation paging PASS: previous/next, first/last/single boundaries, post-page selection, punctuation and English fallback', flush=True)


def main(protected_fixture):
    punctuation_paging_tests()
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
        ('key-1', {'commit_key': ord('1')}, 0),
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

        for action, commit_args, submitted_index in [submissions[3], submissions[5]]:
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

    dual_cases, invalid_cases = dual_model_tests(discovery, protected_fixture, submissions)
    return {
        'passed': True, 'status': 'passed', 'probe_cases': len(rows), 'candidate_count': 128,
        'recommendation_source': 'controlled property injection; no model, cloud, or UI calls',
        'providers': ['local', 'jev', 'tev-0.8b', 'tev-4b'],
        'placement': 'original first preserved; unique requested targets occupy slots 2/3 in priority order',
        'v2_probe_cases': dual_cases, 'v2_late_invalid_payloads': invalid_cases,
        'v2_whole_wire_marker': True, 'v2_original_callback_baseline': True, 'legacy_six_field_preserved': True,
        'target_ranks': [1, 2, 3, index + 1], 'submission_methods': [action for action, _, _ in submissions],
        'noresult_unchanged': True, 'stale_unchanged': True, 'nonexistent_target_rejected': True,
        'disable_restores': True, 'stale_after_valid_restores': True, 'repeat_and_reapply_stable': True,
        'partial_composition_preserved': True, 'sj_target_rank': index + 1, 'sj_promoted_commit': '睡觉',
        'initial_snapshot_count': len(discovery['snapshot_before_iteration']['candidates']),
        'sampled_snapshot_count': len(sample), 'sample_raw_count': discovery['sample_raw_count'],
        'sample_batches': discovery['sample_batches'], 'sampling_state_unchanged': True,
        'navigated_state': navigated['sampling_before'], 'partial_sample_raw_count': partial_raw_count,
        'default_score_limit': 8, 'max_score_limit': 24, 'fresh_copy_per_case': True,
        'punctuation_paging': True, 'paging_boundary_no_commit': True,
        'no_menu_punctuation_preserved': True, 'ascii_punctuation_preserved': True,
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
            probe_binary = compile_probe(Path(directory))
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
    print(f"Real Rime bridge PASS: {len(rows)} isolated probes; legacy and dual-model v2 placement; "
          'direct/key commits, 128-candidate order/count, fallback, reapply, partial composition and sampling 8/24/64. '
          'Recommendations were injected; no model or UI acceptance is claimed.')
