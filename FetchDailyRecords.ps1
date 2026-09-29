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

# Create exports folder if it doesn't exist
if (-not (Test-Path $exportFolder)) { New-Item -ItemType Directory -Path $exportFolder | Out-Null }

# Enable TLS 1.2 for modern NWS API compatibility
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 1. LOAD STATION DATABASE ---
$stationMap = @{}
if (Test-Path $stationFile) {
    Import-Csv -Path $stationFile | ForEach-Object {
        # Cast to [string] first to safely handle blank rows in the CSV
        $rawId = [string]$_.LOCATIONID
        
        if (-not [string]::IsNullOrWhiteSpace($rawId)) {
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

foreach ($day in $days) {
    foreach ($type in $types) {
        # Cache-busting URL parameter
        $randomVal = Get-Random -Minimum 100000 -Maximum 999999
        $noaaUrl   = "$baseUrl$day.$type.txt?v=$randomVal"
        
        $rawText = $null
        try {
            $rawText = Invoke-RestMethod -Uri $noaaUrl -UserAgent "Mozilla/5.0" -TimeoutSec 10 -ErrorAction Stop
        } catch {
            continue
        }

        if (-not $rawText -or $rawText.Length -lt 10) { continue }

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
    }
}

# --- 4. WRITE MISSING LOG ---
if ($allMissing.Count -gt 0) {
    Set-Content -Path $missingLog -Value ($allMissing -join "`n") -Force
} else {
    if (Test-Path $missingLog) { Remove-Item -Path $missingLog -Force }
}