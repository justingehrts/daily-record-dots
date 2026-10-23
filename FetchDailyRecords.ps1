<#
    FetchDailyRecords.ps1
    Full Local Engine: Scrapes NOAA, Auto-K, Auto-Learn via NWS API,
    Direct Export to Graphics Folder, and Missing ID Logging.
#>

# --- CONFIGURATION ---
$scriptDir     = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = "C:\LOCAL\Scripts\daily-records" } # Fallback path if run interactively

$stationFile   = Join-Path $scriptDir "stations.csv"
$exportFolder  = Join-Path $scriptDir "exports"
$missingLog    = Join-Path $scriptDir "missing_log.txt"
$kmlErrorLog   = Join-Path $scriptDir "kml_error.log"
$runLog        = Join-Path $scriptDir "run_log.txt"
$kmlFolder     = "D:\WSI\DigitalMedia\Custom\KML" # Max reads KML/KMZ files from here
$navDataFolder = "D:\WSI\DigitalMedia\Custom\NavImportedData" # Copy of each CSV is also placed here for Max
$iconFolder    = Join-Path $scriptDir "icons"          # himax.png, himin.png, lomax.png, lomin.png

# Start each run with fresh logs
if (Test-Path $kmlErrorLog) { Remove-Item -Path $kmlErrorLog -Force -ErrorAction SilentlyContinue }
if (Test-Path $runLog)      { Remove-Item -Path $runLog -Force -ErrorAction SilentlyContinue }

# Writes a line to the console and to run_log.txt (never throws)
function Write-RunLog {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    try { Add-Content -Path $runLog -Value $line } catch { }
}
# Moves a finished temp file into place, replacing any existing file.
# (Move-Item -Force can fail with "Cannot create a file when that file already exists" in Windows PowerShell 5.1.)
function Publish-File {
    param([string]$Temp, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination)) {
        [System.IO.File]::Move($Temp, $Destination)
        return
    }
    try {
        # Atomic swap on NTFS
        [System.IO.File]::Replace($Temp, $Destination, $null)
    } catch {
        # Fall back to overwriting in place, then clean up the temp file
        [System.IO.File]::Copy($Temp, $Destination, $true)
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    }
}

Write-RunLog "Starting. PowerShell $($PSVersionTable.PSVersion); script dir: $scriptDir"
Write-RunLog "Stations file exists: $(Test-Path $stationFile); KML folder exists: $(Test-Path $kmlFolder); icons folder exists: $(Test-Path $iconFolder)"

# Create exports folder if it doesn't exist
if (-not (Test-Path $exportFolder)) { New-Item -ItemType Directory -Path $exportFolder | Out-Null }

# Needed to build KMZ (zip) files
Add-Type -AssemblyName System.IO.Compression

# Enable TLS 1.2 for modern NWS API compatibility
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 1. LOAD STATION DATABASE ---
$stationMap = @{}
if (Test-Path $stationFile) {
    # Explicit -Header so the first station row is never mistaken for column names
    # (stations.csv has no header row; a header row, if present, is skipped below)
    Import-Csv -Path $stationFile -Header LOCATIONID,LOCATIONNAME,LATITUDE,LONGITUDE | ForEach-Object {
        # Cast to [string] first to safely handle blank rows in the CSV
        $rawId = [string]$_.LOCATIONID

        if (-not [string]::IsNullOrWhiteSpace($rawId) -and $rawId.Trim().ToUpper() -ne "LOCATIONID") {
            $code = $rawId.Trim().ToUpper()
            
            if ($code -and -not [double]::TryParse($code, [ref]$null)) {
                $stationMap[$code] = @{
                    LOCATIONID   = $code
                    LOCATIONNAME = ([string]$_.LOCATIONNAME).Trim()
                    LATITUDE     = ([string]$_.LATITUDE).Trim()
                    LONGITUDE    = ([string]$_.LONGITUDE).Trim()
                }
            }
        }
    }
}

# --- 2. HELPER: NWS AUTO-LEARN FUNCTION ---
function Learn-Station {
    param([string]$Code)
    $Code = $Code.Trim().ToUpper()
    $attempts = if ($Code.Length -eq 3) { @("K$Code", $Code) } else { @($Code) }

    foreach ($id in $attempts) {
        $url = "https://api.weather.gov/stations/$id"
        try {
            $res = Invoke-RestMethod -Uri $url -UserAgent "WBNS-Weather-Bot (justin.gehrts@10tv.com)" -TimeoutSec 4 -ErrorAction Stop
            if ($res.geometry.coordinates) {
                $lon  = $res.geometry.coordinates[0]
                $lat  = $res.geometry.coordinates[1]
                $rawName = if ($res.properties.name) { $res.properties.name } else { $id }
                $name = $rawName.Replace(',', '')

                $newStn = [PSCustomObject]@{
                    LOCATIONID   = $Code
                    LOCATIONNAME = $name
                    LATITUDE     = $lat
                    LONGITUDE    = $lon
                }

                # Save to memory and append to CSV
                $stationMap[$Code] = @{
                    LOCATIONID   = $Code
                    LOCATIONNAME = $name
                    LATITUDE     = $lat
                    LONGITUDE    = $lon
                }
                
                $csvLine = "$Code,$name,$lat,$lon"
                Add-Content -Path $stationFile -Value $csvLine
                
                return $newStn
            }
        } catch {
            # Continue to next attempt if API fails
        }
    }
    return $null
}

# --- 3. SCRAPE & PROCESS ---
$days     = @("d1", "d2", "d3", "d4", "d5", "d6", "d7")
$types    = @("himax", "lomax", "himin", "lomin")
$baseUrl  = "https://www.wpc.ncep.noaa.gov/exper/ndfd/"
$allMissing = [System.Collections.Generic.HashSet[string]]::new()
$failedDownloads = 0
$csvCount = 0
$kmzCount = 0
$navCount = 0

foreach ($day in $days) {
    foreach ($type in $types) {
        # Cache-busting URL parameter
        $randomVal = Get-Random -Minimum 100000 -Maximum 999999
        $noaaUrl   = "$baseUrl$day.$type.txt?v=$randomVal"
        
        $rawText = $null
        try {
            $rawText = Invoke-RestMethod -Uri $noaaUrl -UserAgent "Mozilla/5.0" -TimeoutSec 10 -ErrorAction Stop
        } catch {
            Write-RunLog "DOWNLOAD FAILED $day.$type : $($_.Exception.Message)"
            $failedDownloads++
            continue
        }

        if (-not $rawText -or $rawText.Length -lt 10) {
            Write-RunLog "SKIPPED $day.$type : response empty or too short"
            $failedDownloads++
            continue
        }

        $lines     = $rawText -split "`n"
        $results   = [System.Collections.Generic.List[psobject]]::new()
        $inSection = $false

        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line -match '^-{5,}$') { 
                $inSection = -not $inSection 
                continue 
            }

            if ($inSection -and $line.Length -gt 0) {
                $parts = $line -split '\s+'
                $id    = $parts[0].ToUpper()

                $found    = $false
                $lookupId = $id

                # Match direct or Auto-K
                if ($stationMap.ContainsKey($id)) { 
                    $found = $true 
                } elseif ($id.Length -eq 3 -and $stationMap.ContainsKey("K$id")) { 
                    $lookupId = "K$id"
                    $found    = $true 
                }

                if ($found) {
                    $stn = $stationMap[$lookupId]
                    $results.Add([PSCustomObject]@{
                        LOCATIONID   = $stn.LOCATIONID
                        LOCATIONNAME = $stn.LOCATIONNAME
                        LATITUDE     = $stn.LATITUDE
                        LONGITUDE    = $stn.LONGITUDE
                    })
                } else {
                    # Attempt Auto-Learn
                    if (-not [double]::TryParse($id, [ref]$null) -and $id.Length -ge 3) {
                        $learned = Learn-Station -Code $id
                        if ($learned) {
                            $results.Add($learned)
                        } else {
                            [void]$allMissing.Add($id)
                        }
                    }
                }
            }
        }

        # --- EXPORT ---
        $fileName   = Join-Path $exportFolder ("{0}_{1}.csv" -f $day.ToUpper(), $type.ToUpper())
        $csvText    = "LOCATIONID,LOCATIONNAME,LATITUDE,LONGITUDE`n"
        foreach ($item in $results) {
            $csvText += ("{0},{1},{2},{3}`n" -f $item.LOCATIONID, $item.LOCATIONNAME, $item.LATITUDE, $item.LONGITUDE)
        }

        # Delete legacy CSV if present
        $legacyCsv = $fileName.Replace('.txt', '.csv')
        if (Test-Path $legacyCsv) { Remove-Item -Path $legacyCsv -Force }

        Set-Content -Path $fileName -Value $csvText -Encoding UTF8 -Force
        (Get-Item $fileName).LastWriteTime = Get-Date
        $csvCount++

        # Also copy the CSV to Max's NavImportedData folder (failure must not stop the run)
        try {
            if (-not (Test-Path $navDataFolder)) { New-Item -ItemType Directory -Path $navDataFolder -Force -ErrorAction Stop | Out-Null }
            $navFile = Join-Path $navDataFolder (Split-Path $fileName -Leaf)
            $navTmp  = "$navFile.tmp"
            Copy-Item -Path $fileName -Destination $navTmp -Force -ErrorAction Stop
            Publish-File -Temp $navTmp -Destination $navFile
            $navCount++
        } catch {
            Write-RunLog ("CSV COPY FAILED {0}_{1}: {2}" -f $day.ToUpper(), $type.ToUpper(), $_.Exception.Message)
        }

        # --- KMZ EXPORT (for Max) ---
        # Failure here (e.g. drive unavailable) must never stop the CSV export or the rest of the run
        try {
            if (-not (Test-Path $kmlFolder)) { New-Item -ItemType Directory -Path $kmlFolder -Force -ErrorAction Stop | Out-Null }

            $label    = "{0} {1}" -f $day.ToUpper(), $type.ToUpper()
            $stamp    = Get-Date -Format "yyyy-MM-dd HH:mm"
            $iconFile = Join-Path $iconFolder "$type.png"
            $hasIcon  = Test-Path $iconFile

            $kml      = [System.Text.StringBuilder]::new()
            [void]$kml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
            [void]$kml.AppendLine('<kml xmlns="http://www.opengis.net/kml/2.2">')
            [void]$kml.AppendLine('<Document>')
            [void]$kml.AppendLine("<name>$label</name>")
            if ($hasIcon) {
                # Icon is bundled inside the KMZ, so the file is self-contained
                [void]$kml.AppendLine("<Style id=`"dot`"><IconStyle><Icon><href>icons/$type.png</href></Icon></IconStyle></Style>")
            }
            foreach ($item in $results) {
                $pmName = [System.Security.SecurityElement]::Escape($item.LOCATIONID)
                $pmDesc = [System.Security.SecurityElement]::Escape(("{0} - {1} (updated {2})" -f $item.LOCATIONNAME, $label, $stamp))
                # KML coordinate order is lon,lat
                $coords = "{0},{1},0" -f $item.LONGITUDE, $item.LATITUDE
                $styleRef = if ($hasIcon) { "<styleUrl>#dot</styleUrl>" } else { "" }
                [void]$kml.AppendLine("<Placemark><name>$pmName</name><description>$pmDesc</description>$styleRef<Point><coordinates>$coords</coordinates></Point></Placemark>")
            }
            [void]$kml.AppendLine('</Document>')
            [void]$kml.AppendLine('</kml>')

            # Write to a temp file then rename, so Max never reads a half-written file
            $kmzFile = Join-Path $kmlFolder ("{0}_{1}.kmz" -f $day.ToUpper(), $type.ToUpper())
            $kmzTmp  = "$kmzFile.tmp"
            $fs  = [System.IO.File]::Open($kmzTmp, [System.IO.FileMode]::Create)
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry  = $zip.CreateEntry("doc.kml")
                $stream = $entry.Open()
                $bytes  = (New-Object System.Text.UTF8Encoding($false)).GetBytes($kml.ToString())
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Dispose()

                if ($hasIcon) {
                    $entry  = $zip.CreateEntry("icons/$type.png")
                    $stream = $entry.Open()
                    $bytes  = [System.IO.File]::ReadAllBytes($iconFile)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Dispose()
                }
            } finally {
                $zip.Dispose()
                $fs.Dispose()
            }
            Publish-File -Temp $kmzTmp -Destination $kmzFile
            $kmzCount++

            # Remove a plain .kml of the same name left by an earlier version, so Max doesn't see duplicates
            $oldKml = [System.IO.Path]::ChangeExtension($kmzFile, ".kml")
            if (Test-Path $oldKml) { Remove-Item -Path $oldKml -Force -ErrorAction SilentlyContinue }
        } catch {
            # Leave any existing KMZ in place and carry on, but record why it failed
            $msg = "{0}  {1}_{2}: {3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $day.ToUpper(), $type.ToUpper(), $_.Exception.Message
            Write-RunLog "KMZ FAILED $msg"
            try { Add-Content -Path $kmlErrorLog -Value $msg } catch { }
        }
    }
}

# --- 4. WRITE MISSING LOG ---
if ($allMissing.Count -gt 0) {
    Set-Content -Path $missingLog -Value ($allMissing -join "`n") -Force
} else {
    if (Test-Path $missingLog) { Remove-Item -Path $missingLog -Force }
}

Write-RunLog "Done. Downloads failed/skipped: $failedDownloads of 28; CSVs written: $csvCount (copied to NavImportedData: $navCount); KMZs written: $kmzCount; missing station IDs: $($allMissing.Count)"