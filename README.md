# daily-record-dots

Pulls the forecast **record and near-record temperature** lists from the National Digital Forecast Database (NDFD), as published on the NOAA Weather Prediction Center (WPC) website, and turns them into map-ready CSVs and KMZ files of station locations. One CSV and one KMZ file are produced for every forecast day and record type. If you don't want to build all the pieces from scratch, you can download the `Record Dots Base` scene from the WBNS Shared locker on Max Cloud.

The script can be run on demand or unattended on a schedule (using Windows Task Scheduler on Core 2).

## Hosted pipeline (GitHub Actions + Pages)

The KMZs are built and published by GitHub, not by a Windows machine. The workflow `.github/workflows/record-dots.yml` ("Build and publish record dots") runs `FetchDailyRecords.ps1` under PowerShell 7 on a GitHub Linux runner, checks that all 28 files exist, and deploys them to GitHub Pages:

```
https://justingehrts.github.io/daily-record-dots/D1_HIMAX.kmz   (D1..D7 x HIMAX, LOMAX, HIMIN, LOMIN = 28 files)
https://justingehrts.github.io/daily-record-dots/status.json
```

`status.json` looks like `{"generatedUtc": "...", "kmz": 28, "scriptSummary": "...", "missing": ["TAHC1", ...], "missingCount": 1}`. `missing` lists the station IDs that have no location yet (see "Updating the station list" below).

A failed or partial run never replaces the last good site: anything that wasn't rebuilt is copied from the live site first (`tools/carry_over.py`), the run ends red so you hear about it, and if even that can't produce a complete set, the run stops before deploying. The Windows-local engine described further down is the older way of running the same script; a snapshot of it is kept on the `archive/windows-local-engine` branch.

### One-time setup
1. Settings > Pages > **Source: GitHub Actions**.
2. Settings > Secrets and variables > Actions > **Secrets** > New repository secret `NWS_CONTACT` = a contact email address. NWS asks automated tools to identify an owner; it is sent in the `User-Agent` of API requests.
3. Set up the hourly trigger below, or start a run by hand: Actions tab > Build and publish record dots > Run workflow.

### cron-job.org setup (hourly trigger)
GitHub's own `schedule:` is unreliable, so the workflow only keeps a slow daily backup schedule and a cron-job.org job starts it every hour.

1. **Make a token:** GitHub > your photo > Settings > Developer settings > Personal access tokens > **Fine-grained tokens** > Generate new token. Repository access: *Only select repositories* > `daily-record-dots`. Repository permissions: **Actions: Read and write**, nothing else. Choose the longest expiration and put a calendar reminder a week before it ends; the trigger stops working when it expires. Copy the token (it starts with `github_pat_`; it is shown once). Never commit it or paste it into the repo.
2. **Create the job** at cron-job.org:
   - URL: `https://api.github.com/repos/justingehrts/daily-record-dots/actions/workflows/record-dots.yml/dispatches`
   - Schedule: every hour at minute 20 (any minute works)
   - Request method: `POST`; request body: `{"ref":"main"}`
   - Headers:

     | Name | Value |
     | --- | --- |
     | `Authorization` | `Bearer github_pat_...your token...` |
     | `Accept` | `application/vnd.github+json` |
     | `X-GitHub-Api-Version` | `2022-11-28` |
     | `Content-Type` | `application/json` |

   - Turn on failure notifications. GitHub answers **HTTP 204** on success; `401` = token wrong or expired; `403`/`404` = the token doesn't cover this repo or the workflow file name is wrong.
3. Use the **Test run** button once, then check the Actions tab for a run with event `workflow_dispatch`.

### Updating the station list
Stations the script can't place are listed in `status.json` under `missing` (and in `missing_log.txt` in the workflow's run). The script already tries `stations.csv`, then the NWS API, then the Iowa Mesonet API; whatever is left needs a row added by hand. Newly learned stations are saved back to `stations.csv` automatically.

1. Find the station on the [Iowa Mesonet networks page](https://mesonet.agron.iastate.edu/sites/networks.php): pick the network (for example `CA_COOP`), then the station, and note its name, latitude and longitude. (`https://mesonet.agron.iastate.edu/api/1/station/<ID>.json` shows the same data.)
2. On GitHub open `stations.csv`, click the pencil (Edit), add one line at the end, and commit to `main`:

   ```
   TAHC1,Tahoe City CA,39.1677,-120.1429
   ```

   Format: `ID,name,latitude,longitude`. No commas inside the name, west longitudes are negative.
3. The commit starts a new build automatically (changes to `stations.csv` trigger the workflow), and the station's dot appears in the next KMZ set.

A station you decide not to track can simply be left alone; it only costs a lookup attempt each run. Offline stations and forecast-office (`WFO`) entries are skipped by the Mesonet fallback on purpose, so they stay in the missing list.

A weekly review of the missing list is logged to Justin's project manager as a to-do when anything is missing.

## Files

| File | Purpose |
| --- | --- |
| `FetchDailyRecords.ps1` | The main engine. Downloads the WPC lists, looks up each station's lat/lon, and writes the CSVs and KMZ files. |
| `station_manager.ps1` | Small on-demand WPF form for manually adding stations the script couldn't find. |
| `stations.csv` | Station lookup: `LOCATIONID,LOCATIONNAME,LATITUDE,LONGITUDE` (one station per line; a header row is optional and ignored). Grows automatically as stations are auto-learned. |
| `missing_log.txt` | Written by the script: station IDs that could not be resolved. Read by `station_manager.ps1`. Deleted when nothing is missing. |
| `run_log.txt` | Written by the script on every run: PowerShell version, folders, each failed download, and totals (CSVs/KMZs written, missing IDs). Look here first if nothing is being written. |
| `kml_error.log` | Written by the script only if a KMZ couldn't be created; lists the error for each file. Recreated on every run. |
| `exports\` | Created by the script. Holds the output CSVs. |
| `icons\` | The four dot icons (`himax.png`, `himin.png`, `lomax.png`, `lomin.png`) that the script bundles into each KMZ. Keep this folder next to the script. |
| `D:\WSI\DigitalMedia\Custom\NavImportedData\` | A copy of each CSV is also written here for Max (set by `$navDataFolder` at the top of `FetchDailyRecords.ps1`). |
| `D:\WSI\DigitalMedia\Custom\KML\record-dots\` | Where the script writes the KMZ files for Max (set by `$kmlFolder` at the top of `FetchDailyRecords.ps1`). |

## How `FetchDailyRecords.ps1` works

1. **Load the station database.** `stations.csv` is read into an in-memory lookup keyed by upper-cased station ID. Rows with a blank or purely numeric ID are ignored.

2. **Download the WPC lists.** For each forecast day `d1`–`d7` and each record type, the script fetches:

   ```
   https://www.wpc.ncep.noaa.gov/exper/ndfd/<day>.<type>.txt
   ```

   That is 7 days × 4 types = 28 files per run. A random query string is appended to defeat caching. Each request has a 10 second timeout; a file that fails to download (or is nearly empty) is skipped, and the rest of the run continues.

   | Type | Presumed meaning |
   | --- | --- |
   | `himax` | Forecast high temperature at/near a record high |
   | `lomax` | Forecast high temperature at/near a record low maximum |
   | `himin` | Forecast low temperature at/near a record high minimum |
   | `lomin` | Forecast low temperature at/near a record low |

   > These meanings are inferred from the file names — please correct them if they're off.

3. **Parse the station IDs.** The station list in each file sits between lines made of dashes (`-----`). The first whitespace-delimited token on each line in that section is the station ID.

4. **Match each ID to a location**, in this order:
   1. Exact match in `stations.csv`.
   2. If the ID is 3 letters, try again with a `K` prefix (e.g. `CMH` → `KCMH`).
   3. **Auto-learn:** if the ID is non-numeric and at least 3 characters, query the NWS API (`https://api.weather.gov/stations/<id>`, trying `K<id>` first for 3-letter IDs). If the API returns coordinates, the station is used immediately and appended to `stations.csv`, so it is found locally next time. If the NWS API has nothing (typical for COOP sites like `TAHC1`), the [Iowa Environmental Mesonet](https://mesonet.agron.iastate.edu/sites/networks.php) station API (`https://mesonet.agron.iastate.edu/api/1/station/<id>.json`) is tried the same way; offline stations and `WFO` office entries are skipped and left as missing, and each Mesonet hit is noted in `run_log.txt`.
   4. Otherwise the ID is recorded as **missing**.

5. **Write one CSV per day/type** to `exports\`, named `<DAY>_<TYPE>.csv` (e.g. `D1_HIMAX.csv`, `D7_LOMIN.csv`). Each file has a header row and one row per matched station:

   ```
   LOCATIONID,LOCATIONNAME,LATITUDE,LONGITUDE
   ```

   Existing files are overwritten on every run, and their timestamp is set to the time of the run. Each CSV is also copied to `D:\WSI\DigitalMedia\Custom\NavImportedData\`; if that copy fails, the failure is logged and the run continues.

   **Also write one KMZ file per day/type** to `D:\WSI\DigitalMedia\Custom\KML\record-dots\` (created if missing), with the same names (`D1_HIMAX.kmz`, ..., `D7_LOMIN.kmz`). Each KMZ bundles a `doc.kml` (one placemark per matched station, with the ID as the name and the station name and update time in the description) and the dot icon for that record type from `icons\`, so each file is self-contained. Each file is written to a temporary file and then renamed, so Max never sees a half-written file. If the KML folder can't be written to, the CSVs and the rest of the run are unaffected.

6. **Write the missing log.** All unresolved IDs (de-duplicated across all 28 files) are written to `missing_log.txt`, one per line. If nothing is missing, any old log is deleted.

## Adding missing stations (`station_manager.ps1`)

When `missing_log.txt` lists stations, right-click `station_manager.ps1` and select 'Run with PowerShell' to open the **Weather Station Manager** window:

1. Pick an ID from the *Select Missing* drop-down (it is filled from `missing_log.txt`; you can also type any ID).
2. Enter the station name, latitude and longitude.
3. Click **Save Station**. The station is appended to `stations.csv` (commas are stripped from the name so the CSV stays valid) and removed from the drop-down.

Newly added stations are picked up on the next run of `FetchDailyRecords.ps1`.

## Max integration

Place the files on your Core 2 (TVDC-2) system. If you wish to follow this readme explicitly, place them in `C:\LOCAL\Scripts\daily-records`

## Running it

**On demand:**

Right-click `FetchDailyRecords.ps1` and select `Run with PowerShell`.

**Scheduled (Windows Task Scheduler):** create a task whose action is:

- General tab: Name your script. Run whether the user is logged on or not, and do not store password. Run with highest privileges.
- Triggers tab: Choose when you want it to run and how often. For example, you can have it run hourly, or you can have multiple time triggers for specific times each day. 
- Actions tab: Start a program (`C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`); arguments: `-ExecutionPolicy Bypass -File "C:\LOCAL\Scripts\daily-records\FetchDailyRecords.ps1"`; start in: `C:\LOCAL\Scripts\daily-records`
- Settings tab: Allow to be run on demand, stop the task if it runs for longer than 1 hour, force it to stop if a running task does not end when requested

## Getting the KMZ files to the on-air Max computer

The script runs on `wbns-tvdc-2` and writes the 28 KMZs to `D:\WSI\DigitalMedia\Custom\KML\record-dots` on that machine (the folder is created if it doesn't exist). The on-air Max computer is a different machine, so a `file:///D:/...` address would point at *its own* `D:` drive and won't work. Max's KML layer doesn't list files; you type the address of each file and it loads whatever is there.

**Use the network share:** `D:\WSI\DigitalMedia` is shared as `\\WBNS-TVDC-2\DigitalMedia`, so each file is reachable from the on-air Max computer at, for example:

```
\\WBNS-TVDC-2\DigitalMedia\Custom\KML\record-dots\D2_HIMIN.kmz
```

Enter that address (with the right file name) in the KML layer's URL field in Max. This has been confirmed to load. The address of each file never changes (`D1_HIMAX.kmz` through `D7_LOMIN.kmz`), so you only enter it once per layer, and the script overwrites the files on every run.

The on-air Max computer's account needs read access to the share. If you ever need `http://`/`https://` addresses instead, the files would have to be served by a web server (for example IIS with the `.kmz` MIME type `application/vnd.google-earth.kmz` added) or cloud storage; that would need a small script change.

## Updating the layer in Max

**Important!** While this script automatically updates the sites, _you must still manually update the scene in Max._

1. In your scene, select the layer with the day/record type you want to update.
2. In the Properties tab, go to the Plot Locations section and click the **edit pencil**.
3. Select all the locations on the _right-hand side_ of the dialog box and click the **left-facing arrow** to remove them.
4. On the _left-hand side_ of the dialog box, select all the locations and click the **right-facing arrow**.
5. Click **OK**.

## Requirements and notes

- Windows with PowerShell 5.1 or later (`station_manager.ps1` uses WPF).
- Outbound HTTPS access to `www.wpc.ncep.noaa.gov` and `api.weather.gov`.
- The script forces TLS 1.2 for the NWS API.
- NWS API requests identify themselves with a contact address in the `-UserAgent` string in `Learn-Station`; keep this current, as NWS may use it to contact you about heavy use.
- Because `stations.csv` is appended to automatically, it will grow over time. Names have commas stripped so they don't break the CSV.

## Troubleshooting

- Run the script from an open PowerShell window (not right-click) so the output stays on screen, then read `run_log.txt`.
- `DOWNLOAD FAILED` lines mean the WPC files couldn't be fetched from that machine (network, proxy or firewall). Nothing is written for a file that fails to download, so the previous CSV/KMZ stays in place.
- `KMZ FAILED` lines (also in `kml_error.log`) mean the CSV was written but the KMZ couldn't be, e.g. the KML folder isn't writable.
