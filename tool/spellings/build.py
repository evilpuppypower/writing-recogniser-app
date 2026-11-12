"""Builds the app's spelling table (American, British, Canadian) from
VarCon's varcon.txt: argv[1] in, argv[2] out."""
import collections, os, re, sys

groups = []
for line in open(sys.argv[1], encoding='latin-1'):
    line = line.rstrip('\n')
    if not line or line.startswith('#'):
        continue
    line = line.split('|')[0].strip()
    pref = {}
    for part in line.split(' / '):
        if ': ' not in part:
            continue
        tags, word = part.split(': ', 1)
        word = word.strip()
        for t in tags.split():
            if len(t) == 1 and t in 'ABZC':
                pref.setdefault(t, word)
    if 'A' not in pref or 'B' not in pref:
        continue
    # VarCon's rules: no Z means B; no C means Z.
    z = pref.get('Z', pref['B'])
    r = (pref['A'], pref['B'], pref.get('C', z))
    if any(' ' in w or not w.isascii() for w in r):
        continue
    groups.append(r)
# Only words that always convert the same way (no word with two meanings
# spelt differently).
rows_of = collections.defaultdict(set)
for r in groups:
    for w in set(r):
        rows_of[w.lower()].add(r)
rows = {r for r in groups
        if len(set(r)) > 1 and all(len(rows_of[w.lower()]) == 1 for w in set(r))}
# Words matching the owner's private patterns (PRIVACY_PATTERNS_FILE, one
# regular expression a line, kept outside the repo) are left out: this
# repo is public (see tool/privacy_check.sh).
patterns_file = os.environ.get('PRIVACY_PATTERNS_FILE')
if patterns_file:
    pats = [re.compile(l.strip(), re.I) for l in open(patterns_file)
            if l.strip() and not l.startswith('#')]
    rows = {r for r in rows if not any(p.search('\t'.join(r)) for p in pats)}
with open(sys.argv[2], 'w') as f:
    f.write('\n'.join('\t'.join(r) for r in sorted(rows)) + '\n')
print(len(rows), 'rows')
