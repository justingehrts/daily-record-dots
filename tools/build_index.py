#!/usr/bin/env python3
"""Write site/index.html: a plain list of the 28 KMZ links and the last status, so the site root is not a 404."""
import argparse, html, json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from records_status import RECORD_FILES


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--site', default='site')
    a = ap.parse_args()
    site = Path(a.site)
    try:
        st = json.loads((site / 'status.json').read_text(encoding='utf-8'))
    except Exception:
        st = {}
    rows = '\n'.join(f'<li><a href="{f}">{f}</a></li>' for f in RECORD_FILES)
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Record dots</title></head>
<body style="font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem">
<h1>Record dots</h1>
<p>Forecast record and near-record temperature dots (KMZ), rebuilt hourly from the NOAA WPC lists.
Last build: <b>{html.escape(str(st.get('generatedUtc', 'unknown')))}</b>.
Stations without a known location: <b>{html.escape(str(st.get('missingCount', 'unknown')))}</b>.
See <a href="status.json">status.json</a>.</p>
<ul>
{rows}
</ul>
</body></html>
"""
    (site / 'index.html').write_text(page, encoding='utf-8')
    (site / '.nojekyll').write_text('', encoding='utf-8')


if __name__ == '__main__':
    main()
