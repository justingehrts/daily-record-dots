# daily-record-dots

Pulls the forecast **record and near-record temperature** lists from the National Digital Forecast Database (NDFD), as published on the NOAA Weather Prediction Center (WPC) website, and turns them into map-ready CSVs of station locations. One CSV is produced for every forecast day and record type.

The script can be run on demand or unattended on a schedule (using Windows Task Scheduler on Core 2).

## Files

| File | Purpose |
| --- | --- |
| `FetchDailyRecords.ps1` | The main engine. Downloads the WPC lists, looks up each station's lat/lon, and writes the CSVs. |
| `station_manager.ps1` | Small on-demand WPF form for manually adding stations the script couldn't find. |
| `stations.csv` | Station lookup: `LOCATIONID,LOCATIONNAME,LATITUDE,LONGITUDE` (one station per line, no header row needed). Grows automatically as stations are auto-learned. |
| `missing_log.txt` | Written by the script: station IDs that could not be resolved. Read by `station_manager.ps1`. Deleted when nothing is missing. |
| `exports\` | Created by the script. Holds the output CSVs. |

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
   3. **Auto-learn:** if the ID is non-numeric and at least 3 characters, query the NWS API (`https://api.weather.gov/stations/<id>`, trying `K<id>` first for 3-letter IDs). If the API returns coordinates, the station is used immediately and appended to `stations.csv`, so it is found locally next time.
   4. Otherwise the ID is recorded as **missing**.

5. **Write one CSV per day/type** to `exports\`, named `<DAY>_<TYPE>.csv` (e.g. `D1_HIMAX.csv`, `D7_LOMIN.csv`). Each file has a header row and one row per matched station:

   ```
   LOCATIONID,LOCATIONNAME,LATITUDE,LONGITUDE
   ```

   Existing files are overwritten on every run, and their timestamp is set to the time of the run.

6. **Write the missing log.** All unresolved IDs (de-duplicated across all 28 files) are written to `missing_log.txt`, one per line. If nothing is missing, any old log is deleted.

## Adding missing stations (`station_manager.ps1`)

When `missing_log.txt` lists stations, right-click `station_manager.ps1` and select 'Run with Powershell' to open the **Weather Station Manager** window:

1. Pick an ID from the *Select Missing* drop-down (it is filled from `missing_log.txt`; you can also type any ID).
2. Enter the station name, latitude and longitude.
3. Click **Save Station**. The station is appended to `stations.csv` (commas are stripped from the name so the CSV stays valid) and removed from the drop-down.

Newly added stations are picked up on the next run of `FetchDailyRecords.ps1`.

## Max integration

Place the files on your Core 2 (TVDC-2) system. If you wish to follow this readme explicitly, place them in _C:\LOCAL\Scripts\daily-records_

## Running it

Both scripts locate their files relative to the script's own folder. If run interactively (where `$PSScriptRoot` is empty) they fall back to `C:\LOCAL\Scripts\daily-records`.

**On demand:**

Right-click 'FetchDailyRecords.ps1' and select 'Run with PowerShell.'

**Scheduled (Windows Task Scheduler):** create a task whose action is:

- General tab: Name your script. Run whether the user is logged on or not, and do not store password. Run with highest privileges.
- Triggers tab: Choose when you want it to run and how often. For example, you can have it run hourly, or you can have multiple time triggers for specific times each day. 
- Actions tab: Start a program ( 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' ); arguments: '-ExecutionPolicy Bypass -File "C:\LOCAL\Scripts\daily-records\FetchDailyRecords.ps1" '; start in: `C:\LOCAL\Scripts\daily-records`
- Settings tab: Allow to be run on demand, stop the task if it runs for longer than 1 hour, force it to stop if a running task does not end when requested

## Requirements and notes

- Windows with PowerShell 5.1 or later (`station_manager.ps1` uses WPF).
- Outbound HTTPS access to `www.wpc.ncep.noaa.gov` and `api.weather.gov`.
- The script forces TLS 1.2 for the NWS API.
- NWS API requests identify themselves with a contact address in the `-UserAgent` string in `Learn-Station`; keep this current, as NWS may use it to contact you about heavy use.
- Because `stations.csv` is appended to automatically, it will grow over time. Names have commas stripped so they don't break the CSV.
