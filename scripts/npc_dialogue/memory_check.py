"""只测试：正常批写、同容器冷重启与 Hindsight 对话召回；自测完全离线。"""
import argparse
import copy
import hashlib
import json
import re
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from urllib.parse import quote
from urllib.request import urlopen

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
CONTAINER = 'voxim-npc-life-demo-20261011'
API = 'http://127.0.0.1:18908'
BASELINE = 1_243_611
CAP = 2_000_000
DECISION_GUARD = 350_000
FIELDS = ('conversation_id', 'turn', 'speaker_id', 'speaker_epoch', 'speaker_kind',
          'speaker_name', 'target_id', 'at_ms', 'text')

# 解析已冻结的经历正文；不凭关键词相似度猜测说话者或原话。
SOURCE = re.compile(r'At (?P<at>\S+) \(UTC\), (?P<perspective>I said|I heard): actor (?P<speaker>\d+) '
                    r'\((?P<name>.*?), epoch (?P<epoch>\d+), kind (?P<kind>\d+)\) '
                    r'said to actor (?P<target>\d+) in conversation (?P<conversation>\d+), '
                    r'turn (?P<turn>\d+): (?P<text>"(?:\\.|[^"\\])*")\. '
                    r'This is a character\'s statement, not verified world facts\.')


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def save(path, value):
    """每个文件只写一次；轮询使用追加日志，失败证据不会被后续采样覆盖。"""
    with Path(path).open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


def key(speech):
    return speech['conversation_id'], speech['turn']


def check_recall(cid, expected, authority, recall, documents):
    """证明召回事实确实引用本人的正确源文档；语义理解留给明确的离线复核。"""
    assert recall['memory_retrieval'] in ('hindsight_once', 'direct_hindsight_adapter_once'), 'not the production single-recall route'
    truth = {key(s): s for s in authority}
    facts = recall['memories']
    assert facts and len({f['id'] for f in facts}) == len(facts), 'missing or duplicate recalled facts'
    sources, links = {}, {}
    for document in documents:
        document_id = document['id']
        assert document['bank_id'] == f'npc-life-{cid}', 'document bank mismatch'
        linked = [f['id'] for f in facts if f.get('document_id') == document_id]
        assert linked, 'document was not referenced by actual recall'
        assert document['memory_unit_count'] > 0, 'document has no extracted facts'
        for match in SOURCE.finditer(document['original_text'] or ''):
            row = dict(conversation_id=int(match['conversation']), turn=int(match['turn']),
                       speaker_id=int(match['speaker']), speaker_epoch=int(match['epoch']),
                       speaker_kind=int(match['kind']), speaker_name=match['name'],
                       target_id=int(match['target']),
                       at_ms=round(datetime.fromisoformat(match['at'].replace('Z', '+00:00')).timestamp() * 1000),
                       text=json.loads(match['text']))
            identity = key(row)
            if identity not in truth:
                continue
            assert all(row[f] == truth[identity][f] for f in FIELDS), f'speech source mismatch {identity}'
            assert match['perspective'] == ('I said' if row['speaker_id'] == cid else 'I heard'), 'perspective mismatch'
            assert identity not in sources, f'duplicate retained speech source {identity}'
            sources[identity] = document_id
            links[identity] = linked
    matches = []
    for event in expected:
        identity = key(event)
        assert identity in sources, f'no recalled source for NPC {cid}, speech {identity}'
        matches.append(dict(source=list(identity), speaker_id=event['speaker_id'],
                            document_id=sources[identity], fact_ids=links[identity]))
    assert matches, 'zero expected speech checks'
    return dict(cid=cid, source_provenance_passed=True, matches=matches)


def tokens(status):
    return sum(row['input_tokens'] + row['output_tokens'] for row in status['usage'].values())


def usage_report(fixtures, decision_tokens, baselines, statuses):
    memory = {}
    for index, cid in enumerate(fixtures['npcs']):
        before, current = baselines[str(cid)], statuses[str(cid)]
        assert before['stats']['bank_id'] == current['stats']['bank_id'] == f'npc-life-{cid}', 'status bank mismatch'
        difference = tokens(current) - tokens(before)
        assert difference >= 0, 'usage counter decreased; bank reset or wrong baseline'
        # 已发生的失败轮费用由 fixtures 账本带入；新 bank 默认没有已计费用。
        accounted = fixtures.get('memory_accounted_tokens', {}).get(str(cid), tokens(before) if index == 0 else 0)
        assert isinstance(accounted, int) and 0 <= accounted <= tokens(before), 'invalid previously accounted memory tokens'
        for scope, row in current['usage'].items():
            old_failures = before['usage'].get(scope, {}).get('failed', 0) if index == 0 or accounted > 0 else 0
            assert row['failed'] <= old_failures, f'new failed Hindsight request {cid}/{scope}'
        for field in ('failed_operations', 'failed_consolidation'):
            old_failures = before['stats'][field] if index == 0 or accounted > 0 else 0
            assert current['stats'][field] <= old_failures, f'new failed Hindsight {field}'
        charged = tokens(current) - accounted
        memory[str(cid)] = dict(before=tokens(before), after=tokens(current), delta=difference,
                                already_in_cumulative_before=accounted, charged_tokens=charged)
    total = fixtures['cumulative_tokens_before'] + decision_tokens + sum(r['charged_tokens'] for r in memory.values())
    return dict(cumulative_before=fixtures['cumulative_tokens_before'], decision_tokens=decision_tokens,
                prior_runs=fixtures.get('prior_runs', []), memory=memory,
                cumulative_tokens=total, cap=fixtures['cumulative_token_cap'],
                within_budget=total <= fixtures['cumulative_token_cap'])


def settled(status):
    stats = status['stats']
    return (stats['pending_operations'] == 0 and stats['pending_consolidation'] == 0 and
            not any(o['status'] in ('pending', 'processing') for o in status['operations']))


def checkpoint(row, cid):
    life, stored = row['life'], row['stored']
    assert life['error'] is None and life['unsaved_speech'] == 0, 'Life error or unsaved speech'
    assert stored and stored['state']['cid'] == cid, 'persistent identity missing'
    assert stored['state'] == life['state'], 'persistent/in-memory canonical state mismatch'
    return stored['state']


def semantic_audit(bundle, review):
    assert review['evidence_sha256'] == digest(bundle), 'review belongs to different evidence'
    assert review.get('reviewer') and review.get('reviewed_at'), 'review identity/time missing'
    rows = review['items']
    expected = {(proof['cid'], *match['source']): match
                for proof in bundle['proofs'] for match in proof['matches']}
    actual = {(item['cid'], *item['source']): item for item in rows}
    assert len(actual) == len(rows) and actual.keys() == expected.keys(), 'review coverage mismatch'
    for identity, item in actual.items():
        assert item['fact_id'] in expected[identity]['fact_ids'], 'review fact has no source link'
        assert item['speaker_id'] == expected[identity]['speaker_id'], 'review speaker mismatch'
        assert all(item.get(k) is True for k in ('content_supported', 'speaker_correct', 'statement_not_world_fact')), 'semantic review did not pass'
        assert item.get('note'), 'review must explain the actual fact/source correspondence'
    assert bundle['usage']['within_budget'], 'token cap exceeded'
    return dict(accepted=True, scope='memory_only', source=bundle.get('source'),
                source_provenance_passed=True, semantic_review_passed=True,
                canonical_preserved=True, evidence_sha256=digest(bundle), usage=bundle['usage'])


def source_plan(source):
    import verify
    fixtures = read(source / 'fixtures.json')
    assert len(fixtures['npcs']) == len(set(fixtures['npcs'])) == 2, 'two distinct NPCs required'
    assert BASELINE <= fixtures['cumulative_tokens_before'] < CAP and fixtures['cumulative_token_cap'] == CAP, 'invalid cumulative ledger/cap'
    assert fixtures['decision_guard'] == DECISION_GUARD, 'unexpected decision observation guard'
    errors = read(source / 'errors.json')
    clients = read(source / 'clients.json')
    rows = read(source / 'scene.json')
    verified = verify.authority_events(rows)
    authority = []
    for event in verified:
        delivered = [r for r in rows if r['event'] == 'dialogue.speech' and key(r) == key(event)]
        speech = {field: delivered[0][field] for field in FIELDS}
        assert all(all(r[f] == speech[f] for f in FIELDS) for r in delivered), 'source details mismatch'
        authority.append(dict(speech, recipients=event['recipients']))
    first, second = fixtures['npcs']
    candidates = [s for s in authority if (s['speaker_id'], s['target_id']) == (first, second)]
    pair = None
    for opening in sorted(candidates, key=lambda s: s['at_ms']):
        answers = [s for s in authority if s['conversation_id'] == opening['conversation_id'] and
                   s['turn'] > opening['turn'] and (s['speaker_id'], s['target_id']) == (second, first)]
        if answers:
            pair = [opening, min(answers, key=lambda s: s['turn'])]
            break
    assert pair and all(set(fixtures['npcs']) <= set(s['recipients']) for s in pair), 'reciprocal NPC sources missing'
    receipts = {}
    for cid in fixtures['npcs']:
        observed = read(source / f'before-restore-{cid}.json')
        assert observed['life']['cid'] == cid, 'NPC observation identity mismatch'
        heard = observed['body']['dialogue']
        receipts[str(cid)] = []
        for speech in pair:
            received = [r for r in heard if key(r) == key(speech)]
            assert len(received) == 1 and all(received[0][f] == speech[f] for f in FIELDS), 'NPC did not receive the authoritative sample'
            receipts[str(cid)].append(received[0])
    requests, started = read(source / 'requests.json'), read(source / 'started.json')
    completed_ids = {(r['pid'], r['at_ms']) for r in requests}
    started_ids = {(r['pid'], r['at_ms']) for r in started}
    assert len(completed_ids) == len(requests) and len(started_ids) == len(started), 'duplicate decision trace identity'
    assert completed_ids == started_ids, 'unfinished decision token accounting'
    counts = {cid: 0 for cid in fixtures['npcs']}
    calls = {cid: [] for cid in fixtures['npcs']}
    decision_tokens = 0
    for row in requests:
        cid = json.loads(row['request']['input'])['self']['entity_id']
        assert cid in counts and row['status'] == 'ok', 'unexpected/failed decision request'
        counts[cid] += 1
        decision_tokens += row['usage']['total_tokens']
        calls[cid].extend(json.loads(call['arguments']) for call in row['calls'] if call['name'] == 'say')
    assert all(0 < count <= 16 for count in counts.values()), 'per-NPC model request cap exceeded'
    for speech in pair:
        assert any(call['text'].strip() == speech['text'] and call['target_id'] == speech['target_id'] and
                   call.get('conversation_id') in (None, 0, speech['conversation_id'])
                   for call in calls[speech['speaker_id']]), 'speech lacks independent speaker model source'
    baselines = {str(cid): read(source / f'memory-before-{cid}.json') for cid in fixtures['npcs']}
    minimum_usage = usage_report(fixtures, decision_tokens, baselines, baselines)
    assert minimum_usage['within_budget'], 'cumulative token cap exceeded before memory verification'
    provenance = dict(path=str(source), errors=errors,
                      client_replay={role: {k: row[k] for k in ('replay', 'exit_code', 'started_utc', 'ended_utc') if k in row}
                                     for role, row in clients.items()},
                      budget_stop=decision_tokens >= fixtures['decision_guard'],
                      decision_guard=fixtures['decision_guard'])
    return dict(scope='memory_only', source=provenance, fixtures=fixtures, authority=authority,
                expected=pair, npc_receipts=receipts, baselines=baselines, minimum_usage=minimum_usage,
                decision_tokens=decision_tokens, decision_counts=counts)


def api_get(path):
    # 只读当前18908服务的公开接口；不读取环境、凭证或LLM原始trace。
    with urlopen(API + path, timeout=30) as response:
        return json.load(response)


def execute(source, out, timeout):
    import run as dialogue_run
    import service
    demo, server = dialogue_run.demo, dialogue_run.server
    assert demo.CONTAINER == CONTAINER and demo.URL == 'http://voxim-npc-life-loop-20261011:8888'
    assert demo.SERVER.resolve() == ROOT / '.demo/observe/npc-life-20261011/server'
    service.preflight(required=True)
    plan = source_plan(source)
    fixtures, npcs = plan['fixtures'], plan['fixtures']['npcs']
    save(out / 'plan.json', dict(plan, classification='Test-only'))
    version = api_get('/version')
    save(out / 'hindsight-version.json', version)
    assert version['api_version'] == '0.10.3' and version['features']['store_document_text']

    def registrations():
        records = demo.rpc('for r <- NpcServer.Registry.list(), do: %{cid: r.cid, name: r.name, brain: r.brain, enabled: r.enabled, running: r.running, life_url: get_in(r.params,["life","url"])}')
        by_id = {r['cid']: r for r in records}
        for cid in npcs:
            r = by_id[cid]
            assert r['running'] and r['enabled'] and r['brain'] == 'settler' and r['life_url'] == demo.URL, 'restore both NPCs to registered settler first'
        assert not any(r['enabled'] and r['brain'] in ('llm', 'life') for r in records), 'external decision brain is still enabled'
        return records

    def sample(stage):
        rows = {str(cid): dialogue_run.snapshot(cid) for cid in npcs}
        statuses = {str(cid): dialogue_run.status(cid) for cid in npcs}
        record = dict(stage=stage, at=time.time(), snapshots=rows, statuses=statuses)
        # 先记录原始计数与错误，预算/持久化断言失败也不能丢掉本次证据。
        with (out / 'polls.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + '\n')
        budget = usage_report(fixtures, plan['decision_tokens'], plan['baselines'], statuses)
        record['usage'] = budget
        assert budget['within_budget'], 'cumulative token cap exceeded; no further operation started'
        for cid in npcs:
            checkpoint(rows[str(cid)], cid)
        return record

    def wait_idle(stage, drain=False):
        deadline = time.monotonic() + timeout
        while True:
            record = sample(stage)
            if all(row['life']['job'] is None and (not drain or
                   row['life']['pending_episodes'] == row['life']['pending_fragments'] == 0)
                   for row in record['snapshots'].values()) and all(settled(s) for s in record['statuses'].values()):
                return record
            if time.monotonic() >= deadline:
                raise TimeoutError(stage + ': Life/Hindsight work unfinished')
            time.sleep(3)

    save(out / 'registry-before.json', registrations())
    # 先等已在途任务完成，再逐NPC封存尾部；busy不能被误认为flush已执行。
    before = wait_idle('before-flush')
    save(out / 'before.json', before)
    for cid in npcs:
        sample(f'budget-before-flush-{cid}')
        result = demo.ok(demo.rpc(f'NpcServer.Life.flush({cid})'))
        save(out / f'flush-{cid}.json', result)
        assert result['status'] in ('started', 'empty'), 'flush did not execute'
        wait_idle(f'after-flush-{cid}')
    retained = wait_idle('retain-complete', drain=True)
    save(out / 'retained.json', retained)
    for cid in npcs:
        assert retained['snapshots'][str(cid)]['life']['retained'] > 0, 'nothing retained'
        assert checkpoint(retained['snapshots'][str(cid)], cid) == checkpoint(before['snapshots'][str(cid)], cid), 'canonical mind/World cursor changed during flush'
    save(out / 'registry-before-restart.json', registrations())
    identity = server.execution_identity(demo.SERVER, CONTAINER)
    identity['npc_loaded_beam_md5'] = demo.rpc(demo.NPC_MD5)
    save(out / 'execution-before.json', identity)
    save(out / 'restart.json', server.restart(demo.SERVER, CONTAINER, out / 'server-restart.log', 120))

    # 容器正式readiness后，等待注册表自动恢复与Life持久加载；不替换脑、不补写任何心智。
    deadline = time.monotonic() + timeout
    while True:
        available = demo.rpc('for r <- NpcServer.Registry.list(), do: %{cid: r.cid,running: r.running}')
        ready = demo.rpc('Enum.map(' + json.dumps(npcs) + ',fn cid -> case NpcServer.Life.observe(cid) do {:ok,%{state: s}} -> %{cid: cid,ready: s != nil}; _ -> %{cid: cid,ready: false} end end)')
        if all(any(r['cid'] == cid and r['running'] for r in available) for cid in npcs) and all(r['ready'] for r in ready):
            break
        if time.monotonic() >= deadline:
            raise TimeoutError('NPC/Life did not recover after restart')
        time.sleep(2)
    save(out / 'registry-after.json', registrations())
    after = wait_idle('after-restart', drain=True)
    save(out / 'after.json', after)
    for cid in npcs:
        assert checkpoint(after['snapshots'][str(cid)], cid) == checkpoint(retained['snapshots'][str(cid)], cid), 'cold restart changed canonical mind/World cursor'
        assert after['snapshots'][str(cid)]['life']['retained'] == retained['snapshots'][str(cid)]['life']['retained'], 'retained count changed on restart'
    identity = server.execution_identity(demo.SERVER, CONTAINER)
    identity['npc_loaded_beam_md5'] = demo.rpc(demo.NPC_MD5)
    save(out / 'execution-after.json', identity)

    recalls, documents, proofs = {}, {}, []
    for cid in npcs:
        sample(f'budget-before-recall-{cid}')
        names = '、'.join(s['speaker_name'] for s in plan['expected'])
        query = f'我刚才与{names}在附近公开交谈时，彼此分别说了什么、向谁说？召回带发言人来源的具体对话；角色说过的话不等于事情已完成。'
        save(out / f'query-{cid}.json', dict(cid=cid, query=query))
        recalled = demo.ok(demo.rpc(f'NpcServer.Life.context({cid},{dialogue_run.packed(query)})'))
        save(out / f'recall-{cid}.json', recalled)
        docs = []
        for document_id in sorted({r['document_id'] for r in recalled['memories'] if r.get('document_id')}):
            document = api_get(f'/v1/default/banks/npc-life-{cid}/documents/' + quote(document_id, safe=''))
            docs.append({k: document[k] for k in ('id', 'bank_id', 'original_text', 'content_hash', 'memory_unit_count')})
        save(out / f'documents-{cid}.json', docs)
        recalls[str(cid)], documents[str(cid)] = recalled, docs
        proofs.append(check_recall(cid, plan['expected'], plan['authority'], recalled, docs))
    final = wait_idle('final', drain=True)
    save(out / 'final.json', final)
    for cid in npcs:
        assert checkpoint(final['snapshots'][str(cid)], cid) == checkpoint(retained['snapshots'][str(cid)], cid), 'recall changed canonical mind/World cursor'
    bundle = dict(scope='memory_only', source=plan['source'], expected=plan['expected'], authority=plan['authority'], proofs=proofs,
                  recalls=recalls, documents=documents, usage=final['usage'],
                  canonical={str(cid): checkpoint(retained['snapshots'][str(cid)], cid) for cid in npcs})
    save(out / 'evidence.json', bundle)
    save(out / 'review-template.json', dict(evidence_sha256=digest(bundle), reviewer='', reviewed_at='', items=[
        dict(cid=p['cid'], source=m['source'], speaker_id=m['speaker_id'], fact_id=None,
             candidate_fact_ids=m['fact_ids'], content_supported=False, speaker_correct=False,
             statement_not_world_fact=False, note='') for p in proofs for m in p['matches']]))
    result = dict(accepted=False, scope='memory_only', source=plan['source'],
                  source_provenance_passed=True, canonical_preserved=True,
                  semantic_review_pending=True, usage=final['usage'], evidence_sha256=digest(bundle))
    save(out / 'verdict.json', result)
    return result


def audit(evidence, review):
    """离线重算来源链和重启检查，再接纳绑定该证据的逐句语义复核。"""
    bundle = read(evidence / 'evidence.json')
    plan = read(evidence / 'plan.json')
    assert len(bundle['proofs']) == 2 and {p['cid'] for p in bundle['proofs']} == set(plan['fixtures']['npcs']), 'two NPC proofs required'
    for proof in bundle['proofs']:
        cid = proof['cid']
        assert check_recall(cid, bundle['expected'], bundle['authority'], bundle['recalls'][str(cid)],
                            bundle['documents'][str(cid)]) == proof, 'source proof changed'
        canonical = bundle['canonical'][str(cid)]
        for stage in ('before', 'retained', 'after', 'final'):
            assert checkpoint(read(evidence / f'{stage}.json')['snapshots'][str(cid)], cid) == canonical, 'canonical restart evidence mismatch'
    restart = read(evidence / 'restart.json')
    before, stopped, after = [restart['container_' + name] for name in ('before', 'stopped', 'after')]
    assert before['Id'] == stopped['Id'] == after['Id'] and before['Image'] == after['Image'], 'container/image changed'
    assert before['State']['Running'] and not stopped['State']['Running'] and after['State']['Running'], 'cold restart not demonstrated'
    assert before['State']['StartedAt'] != after['State']['StartedAt'], 'container was not restarted'
    final = read(evidence / 'final.json')
    assert all(settled(s) for s in final['statuses'].values()), 'Hindsight work still pending'
    assert usage_report(plan['fixtures'], plan['decision_tokens'], plan['baselines'], final['statuses']) == bundle['usage'], 'usage evidence mismatch'
    return semantic_audit(bundle, review)


def capture_failure(out):
    """失败后只读一次公开观察面；不重试任务，也不把尚在途用量当最终值。"""
    if not (out / 'plan.json').exists():
        return
    import run as dialogue_run
    plan = read(out / 'plan.json')
    record = dict(at=time.time(), final_usage_known=False, snapshots={}, statuses={}, errors={})
    for cid in plan['fixtures']['npcs']:
        for field, fetch in (('snapshots', dialogue_run.snapshot), ('statuses', dialogue_run.status)):
            try:
                record[field][str(cid)] = fetch(cid)
            except BaseException as error:
                record['errors'][f'{field}/{cid}'] = type(error).__name__
    try:
        record['usage'] = usage_report(plan['fixtures'], plan['decision_tokens'], plan['baselines'], record['statuses'])
        record['final_usage_known'] = (all(settled(s) for s in record['statuses'].values()) and
                                       len(record['snapshots']) == 2 and
                                       all(row['life']['job'] is None for row in record['snapshots'].values()))
    except (AssertionError, KeyError) as error:
        record['errors']['usage'] = type(error).__name__
    save(out / 'failure-observation.json', record)


def assert_readonly(before, after):
    """只读取证不能启动 Life、遗留后台付费工作、改变存储或增加模型用量。"""
    for capture in (before, after):
        for row in capture['registry']:
            assert row['brain'] == 'settler' and not row['life'], 'Life/paid brain must remain disabled'
        assert all(r['life'] == ['error', 'life_not_running'] for r in capture['snapshots'].values()), 'Life worker is running'
        assert all(settled(s) for s in capture['statuses'].values()), 'backend work is still pending'
    assert before['snapshots'].keys() == after['snapshots'].keys(), 'NPC identities changed'
    for cid in before['snapshots']:
        assert before['snapshots'][cid]['stored'] == after['snapshots'][cid]['stored'], 'persistent row changed'
        assert before['statuses'][cid]['usage'] == after['statuses'][cid]['usage'], 'new paid usage during readonly evidence'


def readonly(source, out, restart=False):
    """预算停止后的部分证明；只读存量、可选同容器冷重启、每库一次本地检索。"""
    import run as dialogue_run
    import service
    demo, server = dialogue_run.demo, dialogue_run.server
    assert demo.CONTAINER == CONTAINER and demo.URL == 'http://voxim-npc-life-loop-20261011:8888'
    service.preflight(required=True)
    plan = source_plan(source)
    npcs = plan['fixtures']['npcs']
    save(out / 'plan.json', dict(plan, classification='Test-only', scope='memory_readonly_partial'))
    save(out / 'hindsight-version.json', api_get('/version'))

    def capture():
        registry = demo.rpc('for r <- NpcServer.Registry.list(), r.cid in ' + json.dumps(npcs) +
                            ', do: %{cid: r.cid,brain: r.brain,life: Map.get(r.params,"life",false)}')
        assert {r['cid'] for r in registry} == set(npcs), 'NPC registration missing'
        snapshots = {str(cid): demo.rpc(f'%{{life: NpcServer.Life.observe({cid}),stored: DataService.NpcMemory.get({cid},"life","state")}}') for cid in npcs}
        for cid in npcs:
            assert snapshots[str(cid)]['stored']['state']['cid'] == cid, 'persistent identity mismatch'
        return dict(at=time.time(), registry=registry, snapshots=snapshots,
                    statuses={str(cid): dialogue_run.status(cid) for cid in npcs})

    before = capture()
    save(out / 'before.json', before)
    assert_readonly(before, before)
    if restart:
        save(out / 'execution-before.json', server.execution_identity(demo.SERVER, CONTAINER))
        save(out / 'restart.json', server.restart(demo.SERVER, CONTAINER, out / 'server-restart.log', 120))
        after_restart = capture()
        save(out / 'after-restart.json', after_restart)
        assert_readonly(before, after_restart)
        save(out / 'execution-after.json', server.execution_identity(demo.SERVER, CONTAINER))
    proofs, errors = [], []
    for cid in npcs:
        # 这些公开 GET 仅取数据库存量；不创建文档、触发 refresh 或启动 Life。
        base = f'/v1/default/banks/npc-life-{cid}'
        listed = api_get(base + '/documents?limit=100&offset=0')
        facts = api_get(base + '/memories/list?limit=100&offset=0')
        save(out / f'document-list-{cid}.json', listed)
        save(out / f'facts-{cid}.json', facts)
        assert len(listed['items']) == listed['total'] and len(facts['items']) == facts['total'], 'incomplete stored evidence'
        docs = [api_get(base + '/documents/' + quote(d['id'], safe='')) for d in listed['items']]
        save(out / f'documents-{cid}.json', docs)
        query = '我与LifeBuilder和松岚最近公开交谈时，彼此分别说了什么、向谁说？区分发言来源与未完成的提议。'
        save(out / f'query-{cid}.json', dict(cid=cid, query=query))
        raw = demo.ok(demo.rpc(f'NpcServer.Life.Hindsight.recall(%{{url: "{demo.URL}",bank: "npc-life-{cid}"}},{dialogue_run.packed(query)},System.system_time(:millisecond))'))
        save(out / f'adapter-recall-{cid}.json', raw)
        recalled = dict(memory_retrieval='direct_hindsight_adapter_once', memories=raw['results'],
                        memory_truth=raw['truth'], recall_latency_ms=raw['latency_ms'])
        save(out / f'recall-{cid}.json', recalled)
        document_ids = {f.get('document_id') for f in recalled['memories']}
        try:
            proofs.append(check_recall(cid, plan['expected'], plan['authority'], recalled,
                                       [d for d in docs if d['id'] in document_ids]))
        except AssertionError as error:
            errors.append(dict(cid=cid, reason=str(error)))
    after = capture()
    save(out / 'after.json', after)
    assert_readonly(before, after)
    usage = usage_report(plan['fixtures'], plan['decision_tokens'], plan['baselines'], after['statuses'])
    pending = {cid: row['stored']['pending'] for cid, row in after['snapshots'].items()}
    save(out / 'pending-not-retained.json', pending)
    result = dict(accepted=False, scope='memory_readonly_partial', source=plan['source'],
                  paid_budget_passed=usage['within_budget'], usage=usage, additional_paid_tokens=0,
                  life_disabled=True, stored_preserved=True, cold_restart_verified=restart,
                  source_provenance_passed=len(proofs) == len(npcs), proofs=proofs, errors=errors,
                  semantic_review_pending=True, pending_not_retained={cid: len(rows) for cid, rows in pending.items()})
    save(out / 'verdict.json', result)
    return result


class MemoryCheckTests(unittest.TestCase):
    def setUp(self):
        self.speech = dict(conversation_id=100, turn=1, speaker_id=20, speaker_epoch=7,
                           speaker_kind=1, speaker_name='甲', target_id=21,
                           at_ms=1_000, text='我们先观察工坊。')
        self.doc = dict(id='speech:100:1:fragment:speech:100:1', bank_id='npc-life-21',
                        memory_unit_count=1, original_text='At 1970-01-01T00:00:01.000Z (UTC), I heard: actor 20 '
                        '(甲, epoch 7, kind 1) said to actor 21 in conversation 100, turn 1: '
                        '"我们先观察工坊。". This is a character\'s statement, not verified world facts.')
        self.recall = dict(memory_retrieval='hindsight_once', memories=[
            dict(id='fact-1', document_id=self.doc['id'], text='Actor 20 proposed observing the workshop.')])

    def test_recall_requires_real_fact_document_and_exact_speech_source(self):
        result = check_recall(21, [self.speech], [self.speech], self.recall, [self.doc])
        self.assertEqual(result['matches'][0]['fact_ids'], ['fact-1'])
        self.assertEqual(result['matches'][0]['source'], [100, 1])
        for field, value in [('original_text', self.doc['original_text'].replace('actor 20 (', 'actor 99 (')),
                             ('bank_id', 'npc-life-99')]:
            with self.assertRaises(AssertionError):
                check_recall(21, [self.speech], [self.speech], self.recall, [dict(self.doc, **{field: value})])

    def test_document_without_recalled_fact_is_not_recall_evidence(self):
        with self.assertRaises(AssertionError):
            check_recall(21, [self.speech], [self.speech], dict(self.recall, memories=[]), [self.doc])

    def test_new_bank_preparation_tokens_are_charged_in_full(self):
        def status(cid, amount):
            return dict(stats=dict(bank_id=f'npc-life-{cid}', failed_operations=0, failed_consolidation=0),
                        usage=dict(retain=dict(input_tokens=amount, output_tokens=0, failed=0)))
        fixtures = dict(npcs=[20, 21], cumulative_tokens_before=BASELINE + 21_230, cumulative_token_cap=CAP)
        baselines = {'20': status(20, 500), '21': status(21, 60)}
        current = {'20': status(20, 540), '21': status(21, 90)}
        result = usage_report(fixtures, 200, baselines, current)
        self.assertEqual(result['cumulative_tokens'], BASELINE + 21_230 + 200 + 40 + 90)
        self.assertEqual(result['memory']['21']['charged_tokens'], 90)
        reused = dict(fixtures, memory_accounted_tokens={'20': 500, '21': 60})
        self.assertEqual(usage_report(reused, 200, baselines, current)['memory']['21']['charged_tokens'], 30)
        with self.assertRaises(AssertionError):
            usage_report(dict(fixtures, memory_accounted_tokens={'21': 100}), 200, baselines, current)
        current['21']['usage']['retain']['failed'] = 1
        baselines['21']['usage']['retain']['failed'] = 1
        with self.assertRaises(AssertionError):
            usage_report(fixtures, 200, baselines, current)

    def test_semantic_review_requires_supported_fact_speaker_and_all_claims(self):
        proof = check_recall(21, [self.speech], [self.speech], self.recall, [self.doc])
        bundle = dict(proofs=[proof], usage=dict(within_budget=True))
        item = dict(cid=21, source=[100, 1], speaker_id=20, fact_id='fact-1',
                    content_supported=True, speaker_correct=True, statement_not_world_fact=True,
                    note='事实明确记为 actor 20 提出观察工坊，而非已完成观察。')
        review = dict(evidence_sha256=digest(bundle), reviewer='offline-test', reviewed_at='2026-10-11', items=[item])
        self.assertTrue(semantic_audit(bundle, review)['accepted'])
        for field, value in [('speaker_id', 21), ('fact_id', 'unrelated'), ('content_supported', False), ('note', '')]:
            invalid = copy.deepcopy(review)
            invalid['items'][0][field] = value
            with self.assertRaises(AssertionError):
                semantic_audit(bundle, invalid)
        with self.assertRaises(AssertionError):
            semantic_audit(bundle, dict(review, items=[]))

    def test_unsaved_speech_or_persistent_identity_mismatch_is_failure(self):
        state = dict(cid=21, world_id='world', cursor=7)
        row = dict(life=dict(state=state, error=None, unsaved_speech=0), stored=dict(state=state))
        self.assertEqual(checkpoint(row, 21), state)
        for bad in [dict(row, stored=dict(state=dict(state, cursor=6))),
                    dict(row, life=dict(row['life'], unsaved_speech=1))]:
            with self.assertRaises(AssertionError):
                checkpoint(bad, 21)

    def source_fixture(self, directory):
        source = Path(directory)
        speeches = [self.speech, dict(self.speech, turn=2, speaker_id=21, speaker_name='乙',
                                     target_id=20, text='我愿意先观察。', at_ms=2000)]
        fixtures = dict(npcs=[20, 21], cumulative_tokens_before=BASELINE,
                        cumulative_token_cap=CAP, decision_guard=DECISION_GUARD)
        save(source / 'fixtures.json', fixtures)
        save(source / 'errors.json', ["RuntimeError('decision token guard')"])
        save(source / 'clients.json', {role: dict(replay='interrupted', exit_code=0) for role in ('a', 'b')})
        rows = []
        requests = []
        for speech in speeches:
            rows.append(dict(speech, event='dialogue.result', reason='ok', recipients=2))
            rows.extend(dict(speech, event='dialogue.speech', receiver_id=cid) for cid in fixtures['npcs'])
            requests.append(dict(pid=str(speech['speaker_id']), at_ms=speech['at_ms'] - 500,
                                 status='ok', request=dict(input=json.dumps(dict(self=dict(entity_id=speech['speaker_id'])))),
                                 usage=dict(total_tokens=185_831), calls=[dict(name='say', arguments=json.dumps(
                                     dict(text=speech['text'], target_id=speech['target_id'], conversation_id=100)))]))
        save(source / 'scene.json', rows)
        save(source / 'requests.json', requests)
        save(source / 'started.json', [dict(pid=r['pid'], at_ms=r['at_ms']) for r in requests])
        for cid in fixtures['npcs']:
            save(source / f'before-restore-{cid}.json', dict(life=dict(cid=cid), body=dict(dialogue=speeches)))
            save(source / f'memory-before-{cid}.json', dict(
                stats=dict(bank_id=f'npc-life-{cid}', failed_operations=0, failed_consolidation=0), usage={}))
        return source

    def test_paid_stop_can_verify_existing_memory_without_green_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = source_plan(self.source_fixture(directory))
            self.assertEqual(plan['scope'], 'memory_only')
            self.assertEqual(plan['decision_tokens'], 371_662)
            self.assertTrue(plan['source']['budget_stop'])
            self.assertEqual(plan['source']['client_replay']['a']['replay'], 'interrupted')
            self.assertEqual(plan['source']['errors'], ["RuntimeError('decision token guard')"])

    def test_incomplete_model_accounting_and_total_cap_still_reject(self):
        for failure in ('unfinished', 'cap'):
            with tempfile.TemporaryDirectory() as directory:
                source = self.source_fixture(directory)
                if failure == 'unfinished':
                    path = source / 'started.json'
                    value = read(path) + [dict(pid='new', at_ms=3000)]
                else:
                    path = source / 'fixtures.json'
                    value = dict(read(path), cumulative_tokens_before=CAP - 100)
                path.write_text(json.dumps(value), encoding='utf-8')
                with self.assertRaisesRegex(AssertionError, 'unfinished decision|cumulative token cap'):
                    source_plan(source)

    def test_readonly_requires_disabled_life_idle_backend_and_no_usage_change(self):
        row = dict(life=['error', 'life_not_running'], stored=dict(state=dict(cid=20), pending=[]))
        status = dict(stats=dict(pending_operations=0, pending_consolidation=0),
                      operations=[], usage=dict(retain=dict(input_tokens=5, output_tokens=1)))
        snapshot = dict(snapshots={'20': row}, statuses={'20': status},
                        registry=[dict(cid=20, brain='settler', life=False)])
        assert_readonly(snapshot, snapshot)
        for field in ('paid', 'pending', 'life'):
            changed = copy.deepcopy(snapshot)
            if field == 'paid':
                changed['statuses']['20']['usage']['retain']['input_tokens'] += 1
            elif field == 'pending':
                changed['statuses']['20']['stats']['pending_operations'] = 1
            else:
                changed['registry'][0]['life'] = True
            with self.assertRaises(AssertionError):
                assert_readonly(snapshot, changed)


def self_test():
    result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(MemoryCheckTests))
    return 0 if result.wasSuccessful() else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest='mode', required=True)
    modes.add_parser('self-test', help='只运行离线契约自测')
    plan_parser = modes.add_parser('plan', help='只读已有 live 产物，检查来源及用量前提')
    plan_parser.add_argument('--source', type=Path, required=True)
    run_parser = modes.add_parser('run', help='执行真实 flush、同容器重启和召回，生成待审证据')
    run_parser.add_argument('--source', type=Path, required=True)
    run_parser.add_argument('--out', type=Path, required=True)
    run_parser.add_argument('--timeout', type=int, default=900, help='每个后台阶段的最长等待秒数')
    readonly_parser = modes.add_parser('readonly', help='Life 关闭后只读存量并各库一次本地 recall，始终为部分证明')
    readonly_parser.add_argument('--source', type=Path, required=True)
    readonly_parser.add_argument('--out', type=Path, required=True)
    readonly_parser.add_argument('--restart', action='store_true', help='同容器正式冷重启；不启动 Life')
    audit_parser = modes.add_parser('audit', help='离线核对证据与人工/代理语义复核结果')
    audit_parser.add_argument('--evidence', type=Path, required=True)
    audit_parser.add_argument('--review', type=Path, required=True)
    audit_parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.mode == 'self-test':
        return self_test()
    if args.mode == 'plan':
        print(json.dumps(source_plan(args.source.resolve()), ensure_ascii=False, indent=2))
        return 0
    args.out = args.out.resolve()
    if args.mode == 'run' and args.timeout <= 0:
        parser.error('--timeout must be positive')
    args.out.mkdir(parents=True, exist_ok=False)
    try:
        if args.mode == 'run':
            result = execute(args.source.resolve(), args.out, args.timeout)
        elif args.mode == 'readonly':
            result = readonly(args.source.resolve(), args.out, args.restart)
        else:
            result = audit(args.evidence.resolve(), read(args.review))
        if args.mode == 'audit':
            save(args.out / 'verdict.json', result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except BaseException as error:
        # 只保留本脚本静态断言文字；外部异常不输出请求体、环境或凭证。
        result = dict(accepted=False, scope='memory_only', error_type=type(error).__name__,
                      reason=str(error) if isinstance(error, (AssertionError, TimeoutError)) else 'operation failed; see preserved evidence')
        save(args.out / 'failure.json', result)
        if args.mode == 'run':
            try:
                capture_failure(args.out)
            except BaseException as capture_error:
                save(args.out / 'failure-observation-error.json', dict(error_type=type(capture_error).__name__))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 1


if __name__ == '__main__':
    if not __debug__:
        raise SystemExit('Do not run this test harness with Python -O/PYTHONOPTIMIZE.')
    raise SystemExit(main())
