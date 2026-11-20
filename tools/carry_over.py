#!/usr/bin/env python3
"""Fill gaps in site/ from the live site, so a failed or partial run never makes files disappear.

    python tools/carry_over.py --site site --base https://OWNER.github.io/REPO --report carry_report.json

For each of the 28 KMZs and status.json that this run did not produce, fetch the last published copy.
  200 -> saved (counted as carried; the run ends red afterwards)
  404 -> never published (fine on the very first run)
  anything else after retries -> exit 2 BEFORE deploying, because deploying would drop a file that exists
"""
import argparse, json, sys, time, urllib.error, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from records_status import RECORD_FILES


def fetch(url, tries=4):
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'record-dots-carry-over/1.0'})
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as ex:
            if ex.code == 404:
                return 404, b''
            last = f'HTTP {ex.code}'
        except Exception as ex:
            last = str(ex)
        time.sleep(2 ** i)
    return None, last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--site', default='site')
    ap.add_argument('--base', required=True)
    ap.add_argument('--report', default='carry_report.json')
    a = ap.parse_args()
    site, base = Path(a.site), a.base.rstrip('/')
    gaps = [p for p in RECORD_FILES + ['status.json'] if not (site / p).is_file()]
    carried, never, broken = [], [], []
    for p in gaps:
        status, body = fetch(f'{base}/{p}')
        if status == 200:
            (site / p).write_bytes(body)
            carried.append(p)
        elif status == 404:
            never.append(p)
        else:
            broken.append({'file': p, 'error': str(body)})
    Path(a.report).write_text(json.dumps({'missing': len(gaps), 'carried': carried, 'neverPublished': never, 'broken': broken}, indent=2))
    for p in carried:
        print(f'::warning::{p} was not rebuilt; kept the last published copy.')
    print(f'{len(gaps)} file(s) missing from this run: {len(carried)} carried over, {len(never)} never published, {len(broken)} unreachable.')
    if broken:
        print(f'::error::Could not fetch {len(broken)} existing file(s) from the live site (e.g. {broken[0]["file"]}: {broken[0]["error"]}). Not deploying, so nothing is lost.')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
