"""仅测试：复用原浸泡采样器；主请求保护将按同 VM 的请求起点核对。"""
import importlib.util
from collections import Counter, defaultdict, deque
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parents[1].parent / 'Voxim/Saved/CapabilityLibrary-20261008'
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location('npc_soak_sampler_base', HERE / 'sampler7.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


class Sampler(base.Sampler):
    """请求保护与既有权威快照、token 保护共同使用原采样生命周期。"""

    def guard_decisions(self):
        """完成数只做观测；按同 VM 的请求起点核对主额度，复用既有 token 保护。"""
        responses = self.decisions
        self.decisions = defaultdict(deque)
        try:
            known_tokens = super().guard_decisions()
        finally:
            self.decisions = responses
        for queue in responses.values():
            self.trailing(queue, base.now().timestamp() - 3600 + base.CLOCK_SLACK_S)

        mono = base.rpc('Jason.encode!(System.monotonic_time(:microsecond))')
        rows = [json.loads(line) for line in base.TRACE.read_text(encoding='utf-8').splitlines()] if base.TRACE.exists() else []
        window_us = (3600 - base.CLOCK_SLACK_S) * 1_000_000
        starts = Counter(self.cids[str(row['cid'])] for row in rows if not row['design']
                         and 0 <= mono - row['m0_us'] < window_us)
        for name, count in starts.items():
            if count > base.DECISION_LIMIT:
                self.remove(name, f'{count} main request starts in {window_us // 1_000_000}s '
                            f'(> {base.DECISION_LIMIT})', base.now().isoformat())
        base.append(base.RUN / 'request-budget-samples.jsonl',
                    {'utc': base.now().isoformat(), 'server_monotonic_us': mono,
                     'completed_request_starts': dict(starts), 'limit': base.DECISION_LIMIT,
                     'window_seconds': window_us // 1_000_000, 'known_design_tokens': known_tokens,
                     'design_token_limit': base.DESIGN_TOKEN_LIMIT})
        return known_tokens
