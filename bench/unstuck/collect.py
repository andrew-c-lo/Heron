"""Pulls stuck screens Heron captured while you played (Heron/Evals/unstuck/) into the eval data as the
"fresh" set: screens the strategies were never tuned on.
  rescue    you clicked inside the window: a target box around your click
  resolved  a macro step fired within 10 s with no help: wait (a weak label)
  unresolved / no label: left out until someone labels it
Run:  bench/unstuck/run.sh collect   (then: run.sh candidates, run.sh eval)"""
import json, os, shutil, glob

home = os.environ.get('HERON_HOME') or os.path.expanduser('~/Library/Application Support/Heron')
src = os.path.join(home, 'Evals', 'unstuck')
data = os.path.join(os.path.dirname(__file__), 'data')
labels_path = os.path.join(data, 'labels.json')
D = json.load(open(labels_path))
L = D['labels']
added = {'rescue': 0, 'resolved': 0, 'skipped': 0}
for meta in sorted(glob.glob(os.path.join(src, '*.json'))):
    png = meta[:-5] + '.png'
    if not os.path.exists(png):
        continue
    name = os.path.basename(png)
    if name in L:
        continue
    m = json.load(open(meta))
    out = m.get('outcome')
    if out == 'rescue':
        x, y = m['tap']
        label = {'action': 'target', 'boxes': [[x - 30, y - 30, 60, 60]], 'source': 'rescue', 'set': 'fresh',
                 'note': f"your click {m.get('after')} s after it got stuck"}
    elif out == 'resolved':
        label = {'action': 'wait', 'source': 'resolved', 'set': 'fresh',
                 'note': f"step {m.get('step')} fired {m.get('after')} s later with no help"}
    else:
        added['skipped'] += 1
        continue
    shutil.copy(png, os.path.join(data, 'screens', name))
    L[name] = label
    added[m['outcome']] += 1
json.dump(D, open(labels_path, 'w'), indent=1)
print(f"added {added['rescue']} rescue and {added['resolved']} resolved screens; {added['skipped']} unresolved left out")
