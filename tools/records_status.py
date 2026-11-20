#!/usr/bin/env python3
"""Check the record-dot KMZs and write site/status.json.

    python tools/records_status.py --site site --run-log run_log.txt --missing-log missing_log.txt

A complete set is the 28 files D1_HIMAX.kmz ... D7_LOMIN.kmz (7 days x 4 types) in the site folder.
If the set is incomplete, the partial KMZs are removed so tools/carry_over.py restores the last complete set
from the live site instead of mixing old and new files.

status.json: {"generatedUtc", "kmz", "scriptSummary", "missing", "missingCount"}
  missing = station IDs the script could not find a location for (they get no dot until added to stations.csv)
"""
import argparse, datetime, json, sys
from pathlib import Path

RECORD_FILES = [f'D{d}_{t}.kmz' for d in range(1, 8) for t in ('HIMAX', 'LOMAX', 'HIMIN', 'LOMIN')]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--site', default='site')
    ap.add_argument('--run-log', default='run_log.txt')
    ap.add_argument('--missing-log', default='missing_log.txt')
    a = ap.parse_args()
    site = Path(a.site)
    have = sorted(p.name for p in site.glob('*.kmz')) if site.is_dir() else []
    absent = sorted(set(RECORD_FILES) - set(have))
    if absent:
        print(f'::error::Only {len(have) - len(set(have) - set(RECORD_FILES))} of 28 record-dot KMZs were produced '
              f'(missing: {", ".join(absent[:6])}...). Keeping the last published record dots instead.')
        for p in site.glob('*.kmz'):
            p.unlink()
        return 1
    summary = ''
    rl = Path(a.run_log)
    if rl.exists():
        done = [l for l in rl.read_text(encoding='utf-8', errors='replace').splitlines() if 'Done.' in l]
        summary = done[-1][21:].strip() if done else ''
    ml = Path(a.missing_log)
    missing = sorted({l.strip() for l in ml.read_text(encoding='utf-8', errors='replace').splitlines() if l.strip()}) if ml.exists() else []
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    status = {'generatedUtc': now, 'kmz': len(RECORD_FILES), 'scriptSummary': summary,
              'missing': missing, 'missingCount': len(missing)}
    (site / 'status.json').write_text(json.dumps(status, indent=2), encoding='utf-8')
    print(f'Record dots: 28 of 28 KMZs. {summary}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
