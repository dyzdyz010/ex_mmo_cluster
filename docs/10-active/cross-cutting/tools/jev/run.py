"""只测试：在冻结情境集上跑 Jev（英文 + 中文对照）与 LLM 对照，写 results.json 并打印汇总。
用法：python run.py [jev] [llm]   （不带参数 = 两者都跑；LLM 每条一次询问，花额度）"""
import json, statistics, sys, time, urllib.request
from jev import ask, ENV

cases = json.load(open('cases.json', encoding='utf-8'))['cases']
which = set(sys.argv[1:]) or {'jev', 'llm'}


def judge(case, answer):
    """(是否正确, 置信度)。noul 以 0.5 为界，置信度取离 0.5 的那一侧概率。"""
    if case['question']['type'] == 'choice':
        return answer['choice'] == case['expected'], answer['confidence']
    p = answer['noul']
    return (p >= 0.5) == case['expected'], max(p, 1 - p)


def llm(case):
    q = case['question']
    options = list(q['criteria']) if q['type'] == 'choice' else ['true', 'false']
    prompt = ("Situation: %s\nQuestion: %s\nCriteria: %s\nAnswer with exactly one of: %s. Output only that word."
              % (case['state'], q['instructions'], json.dumps(q.get('criteria', {})), ', '.join(options)))
    body = {'model': ENV['NPC_LLM_MODEL'], 'input': prompt, 'reasoning': {'effort': 'low'}, 'store': False}
    req = urllib.request.Request(ENV['NPC_LLM_URL'], data=json.dumps(body).encode(), headers={
        'authorization': 'Bearer ' + ENV['NPC_LLM_KEY'], 'content-type': 'application/json', 'user-agent': 'voxim-npc-eval/1'})
    t = time.perf_counter()
    r = json.load(urllib.request.urlopen(req, timeout=180))
    text = ''.join(c.get('text', '') for o in r['output'] if o.get('type') == 'message' for c in o['content']).strip().strip('.').lower()
    expected = case['expected'] if isinstance(case['expected'], str) else str(case['expected']).lower()
    return {'text': text, 'correct': text == expected, 'seconds': time.perf_counter() - t, 'usage': r.get('usage')}


rows = []
for case in cases:
    row = {'id': case['id'], 'group': case['group'], 'expected': case['expected']}
    if 'jev' in which:
        for lang, state, question in [('en', case['state'], case['question'])] + \
                ([('zh', case['zh']['state'], case['zh']['question'])] if 'zh' in case else []):
            answers, usage, seconds = ask(state, {'q': question})
            if 'error' in answers:
                row['jev_' + lang] = {'error': answers}
                continue
            correct, confidence = judge(case, answers['q'])
            row['jev_' + lang] = {'correct': correct, 'confidence': round(confidence, 3), 'seconds': round(seconds, 3),
                                  'tokens': usage['input_tokens'], 'answer': answers['q'].get('choice', answers['q'].get('noul'))}
    if 'llm' in which:
        row['llm'] = llm(case)
    rows.append(row)
    print(row['id'], {k: (v.get('correct'), v.get('confidence', '')) for k, v in row.items() if isinstance(v, dict)}, flush=True)

json.dump(rows, open('results-%s.json' % '-'.join(sorted(which)), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)


def summary(key, subset):
    got = [r[key] for r in subset if key in r and 'correct' in r[key]]
    if not got:
        return None
    out = {'n': len(got), 'accuracy': round(sum(g['correct'] for g in got) / len(got), 3),
           'p50_s': round(statistics.median(g['seconds'] for g in got), 2)}
    if 'confidence' in got[0]:
        for threshold in (0.6, 0.85):
            passed = [g for g in got if g['confidence'] >= threshold]
            out['conf>=%s' % threshold] = {'auto_rate': round(len(passed) / len(got), 3),
                                            'errors_among_auto': sum(not g['correct'] for g in passed)}
        out['tokens_avg'] = round(statistics.mean(g['tokens'] for g in got))
    return out


print('\n=== summary ===')
for group in ['activity', 'wake', 'guard', 'weak', 'hard', 'all']:
    subset = rows if group == 'all' else [r for r in rows if r['group'] == group]
    print(group, {k: summary(k, subset) for k in ['jev_en', 'llm']})
paired = [r for r in rows if 'jev_zh' in r]
print('zh-vs-en (same 12 cases)', {k: summary(k, paired) for k in ['jev_en', 'jev_zh']})
print('wrong:', [(r['id'], k, r[k].get('answer', r[k].get('text')), r[k].get('confidence')) for r in rows for k in ['jev_en', 'jev_zh', 'llm']
                 if k in r and r[k].get('correct') is False])
