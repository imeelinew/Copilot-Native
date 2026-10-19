#!/usr/bin/env python3
"""Check the reviewed snapshot against source; never update hashes automatically."""
import hashlib
import json
import os
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SNAPSHOT = REPO / 'Copilot Native/Resources/ProjectFacts.json'

def validate():
    data = json.loads(SNAPSHOT.read_text())
    facts = data['facts']
    ids = {f['id'] for f in facts}
    assert len(ids) == len(facts), 'Duplicate fact IDs'
    roots = {name: Path.home() / 'Dev' / name for name in ('mobile-shop', 'datapilot-rebuild')}
    covered = set()
    for fact in facts:
        assert fact['content'] and fact['boundary'] and fact['questions'] and fact['sources'], fact['id']
        assert all(id in ids for id in fact['related_ids']), fact['id']
        assert all(next(x for x in facts if x['id'] == id)['project_id'] == fact['project_id']
                   for id in fact['related_ids']), 'Cross-project evidence link'
        for source in fact['sources']:
            root = roots[fact['project_id']].resolve()
            path = (root / source['path']).resolve()
            assert path.is_relative_to(root), path
            assert not any(x.startswith('.env') for x in path.parts), path
            assert hashlib.sha256(path.read_bytes()).hexdigest() == source['sha256'], f'Stale: {fact["id"]} {path}'
            lines = path.read_text().splitlines()
            assert 0 < source['line'] <= len(lines), source
            if source.get('anchor'):
                assert source['anchor'] in '\n'.join(lines[source['line'] - 1:]), source
            covered.add((fact['project_id'], source['path']))
    print(f'PASS: {len(facts)} reviewed facts, {sum(len(f["questions"]) for f in facts)} question phrasings, '
          f'{len(covered)} source files; hashes, locations, boundaries and relationships valid')
    # Keep a readable coverage map alongside the executable app resource.
    lines = ['# 项目源码知识覆盖', '', '本快照经过源码核对；哈希校验只会拒绝过期证据，不会自动认可改动。', '',
             '代码只能证明实现，个人职责、团队分工、上线效果与性能数字未获确认。', '']
    for project in roots:
        lines += [f'## {project}', '']
        for fact in facts:
            if fact['project_id'] != project:
                continue
            lines += [f'### {fact["id"]} {fact["title"]}', '',
                      '可覆盖提问：' + '；'.join(fact['questions']), '', fact['content'], '',
                      '**边界：** ' + fact['boundary'], '',
                      '依据：' + '、'.join(f'{s["path"]}:{s["line"]}' for s in fact['sources']), '']
    if '--write-report' in os.sys.argv:
        (REPO / 'knowledge/project-coverage.md').write_text('\n'.join(lines))

if __name__ == '__main__':
    validate()
