"""Adds Turkish translations to a string catalog without touching its formatting.

    python3 -I tools/add-turkish.py Freeband/Resources/Localizable.xcstrings <<EOF
    {"English key": "Türkçesi", "%lld of %@": "%2$@ içinde %1$lld"}
    EOF

Keys are the catalog's keys: interpolations appear as %@ and %lld. New keys go to the end.
"""
import json, sys
path = sys.argv[1]
raw = open(path, encoding='utf-8').read()
d = json.loads(raw)
def dump(o): return json.dumps(o, indent=2, ensure_ascii=False)
assert dump(d) == raw.rstrip('\n'), 'catalog does not round-trip; not touching it'
for en, tr in json.load(sys.stdin).items():
    d['strings'].setdefault(en, {}).setdefault('localizations', {})['tr'] = {'stringUnit': {'state': 'translated', 'value': tr}}
open(path, 'w', encoding='utf-8').write(dump(d) + ('\n' if raw.endswith('\n') else ''))
