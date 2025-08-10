<#
.SYNOPSIS
  Add-PerformanceCounter.ps1

.DESCRIPTION
  Streams Windows performance counters to a Power BI PushStreaming dataset.

.PARAMETER DatasetId
  Id (GUID) of the Power BI streaming dataset.

.PARAMETER TableName
  Table name within the streaming dataset (e.g., RealtimeData).

.PARAMETER Token
  Bearer token for Power BI REST API.

.EXAMPLE
  .\Add-PerformanceCounter.ps1 -DatasetId xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx -TableName RealtimeData -Token $token
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DatasetId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TableName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Token
)

# --- REST target --------------------------------------------------------------
$endpoint = "https://api.powerbi.com/v1.0/myorg/datasets/$DatasetId/tables/$TableName/rows"
$headers  = @{
  Authorization = "Bearer $Token"
  "Content-Type" = "application/json"
}

# --- Static machine info ------------------------------------------------------
$computerName        = $env:COMPUTERNAME
$cnLower             = $computerName.ToLower()

# Processor
$processorName = (Get-CimInstance Win32_Processor).Name

# Disk (C:)
$disk               = Get-Disk | Select-Object -First 1
$diskName           = $disk.FriendlyName
$diskTotalSizeBytes = [int64]$disk.Size

# Optional friendly NIC names (strings only — never objects)
$ethernetName = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Wireless|Wi-?Fi|802\.11' } |
                 Select-Object -ExpandProperty InterfaceDescription -First 1)
$wlanName     = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11' } |
                 Select-Object -ExpandProperty InterfaceDescription -First 1)
if ($null -eq $ethernetName) { $ethernetName = "" }
if ($null -eq $wlanName)     { $wlanName     = "" }

# --- Counters we poll each loop ----------------------------------------------
$performanceCounter = @(
  '\Processor Information(*)\% Processor Time',
  '\Processor Information(*)\% of Maximum Frequency',
  '\Thermal Zone Information(*)\Temperature',
  '\Memory\Available Bytes',
  '\Memory\Committed Bytes',
  '\Memory\% Committed Bytes In Use',
  '\Network Interface(*)\Bytes Received/sec',
  '\Network Interface(*)\Bytes Sent/sec',
  '\LogicalDisk(C:)\Free Megabytes',
  '\LogicalDisk(C:)\% Free Space',
  '\LogicalDisk(C:)\Disk Read Bytes/sec',
  '\LogicalDisk(C:)\Disk Write Bytes/sec',
  '\Process(*)\% Processor Time'
)

# Payload map we reuse across iterations
[hashtable]$payload = @{}

while ($true) {
    # Sample all counters (2s cadence)
    $pc = Get-Counter -Counter $performanceCounter -SampleInterval 2
    $timestampUTC    = $pc.Timestamp.ToUniversalTime()
    $timestampString = $timestampUTC.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') # keeps visuals “live”
    $id              = $timestampUTC.ToFileTimeUtc()

    # Reset payload
    $payload.Clear()
    $payload['Id']                    = $id
    $payload['Timestamp']             = $timestampString
    $payload['Server']                = $computerName
    $payload['Processor']             = $processorName
    $payload['Disk']                  = $diskName
    $payload['Disk total size bytes'] = $diskTotalSizeBytes
    # ensure these are ALWAYS strings (schema expects String)
    $payload['Ethernet']              = [string]$ethernetName
    $payload['WLAN']                  = [string]$wlanName

    # Running totals and helpers
    $numberOfProcesses = -1  # ignore _Total
    [int64]$ethRx = 0; [int64]$ethTx = 0
    [int64]$wlanRx = 0; [int64]$wlanTx = 0

    foreach ($cs in ($pc | Select-Object -ExpandProperty CounterSamples)) {
        # case-insensitive matching convenience
        $path = $cs.Path.ToLower()
        $val  = $cs.CookedValue
        if (-not $val) { $val = 0 }

        # --- CPU (total + cores) --------------------------------------------
        if     ($path -eq "\\$cnLower\processor information(0,_total)\% processor time") { $payload['CPU usage percent']   = [Math]::Round($val,2) }
        elseif ($path -eq "\\$cnLower\processor information(0,0)\% processor time")      { $payload['CPU 0 usage percent'] = [Math]::Round($val,2) }
        elseif ($path -eq "\\$cnLower\processor information(0,1)\% processor time")      { $payload['CPU 1 usage percent'] = [Math]::Round($val,2) }
        elseif ($path -eq "\\$cnLower\processor information(0,2)\% processor time")      { $payload['CPU 2 usage percent'] = [Math]::Round($val,2) }
        elseif ($path -eq "\\$cnLower\processor information(0,3)\% processor time")      { $payload['CPU 3 usage percent'] = [Math]::Round($val,2) }
        elseif ($path -eq "\\$cnLower\processor information(0,_total)\% of maximum frequency") { $payload['CPU max frequency percent'] = [Math]::Round($val,2) }

        # --- Temperature (counter; Kelvin→°C) --------------------------------
        elseif ($path -like "\\$cnLower\thermal zone information(*)\temperature") {
            $payload['Temperature'] = [Math]::Round(($val - 273.15), 2)
        }

        # --- Memory ----------------------------------------------------------
        elseif ($path -eq "\\$cnLower\memory\available bytes")              { $payload['Memory available bytes'] = [int64]$val }
        elseif ($path -eq "\\$cnLower\memory\committed bytes")              { $payload['Memory used bytes']      = [int64]$val }
        elseif ($path -eq "\\$cnLower\memory\% committed bytes in use")     { $payload['Memory used percent']    = [Math]::Round($val,2) }

        # --- Network (generic: sum all NICs; classify WLAN vs Ethernet) -----
        elseif ($path -like "\\$cnLower\network interface(*)\bytes received/sec") {
            $rx = [int64]([math]::Round($val,0))
            $inst = [regex]::Match($cs.Path, 'network interface\((.+?)\)\\bytes received/sec', 'IgnoreCase').Groups[1].Value
            if ($inst -match 'wireless|wi-?fi|802\.11|wlan') { $wlanRx += $rx } else { $ethRx += $rx }
        }
        elseif ($path -like "\\$cnLower\network interface(*)\bytes sent/sec") {
            $tx = [int64]([math]::Round($val,0))
            $inst = [regex]::Match($cs.Path, 'network interface\((.+?)\)\\bytes sent/sec', 'IgnoreCase').Groups[1].Value
            if ($inst -match 'wireless|wi-?fi|802\.11|wlan') { $wlanTx += $tx } else { $ethTx += $tx }
        }

        # --- Disk (C:) -------------------------------------------------------
        elseif ($path -eq "\\$cnLower\logicaldisk(c:)\free megabytes")      { $payload['Disk free bytes']         = [int64]($val * 1024 * 1024) }
        elseif ($path -eq "\\$cnLower\logicaldisk(c:)\% free space")        { $payload['Disk free space percent'] = [Math]::Round($val,0) }
        elseif ($path -eq "\\$cnLower\logicaldisk(c:)\disk read bytes/sec") { $payload['Disk read bytes/sec']      = [int64]([Math]::Round($val,0)) }
        elseif ($path -eq "\\$cnLower\logicaldisk(c:)\disk write bytes/sec"){ $payload['Disk write bytes/sec']     = [int64]([Math]::Round($val,0)) }

        # --- Processes (count non-_Total) -----------------------------------
        elseif ($path -like "\\$cnLower\process(*)\% processor time") {
            $numberOfProcesses++   # increments for each concrete process instance
        }
    }

    # Commit network totals & processes (always present)
    $payload['Ethernet bytes received/sec'] = $ethRx
    $payload['Ethernet bytes sent/sec']     = $ethTx
    $payload['WLAN bytes received/sec']     = $wlanRx
    $payload['WLAN bytes sent/sec']         = $wlanTx
    $payload['Processes']                   = $numberOfProcesses

    # WMI temperature fallback (if counter missing / 0)
    if (-not $payload.ContainsKey('Temperature') -or $payload['Temperature'] -eq $null -or $payload['Temperature'] -eq 0) {
        try {
            $t = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
                 Select-Object -First 1 -ExpandProperty CurrentTemperature
            if ($t) {
                $payload['Temperature'] = [Math]::Round(($t / 10) - 273.15, 2)
            }
        } catch { }
    }

    # ---- SAFETY: ensure Ethernet/WLAN are strings (never hashtables/objects) ----
    if ($payload['Ethernet'] -isnot [string]) { $payload['Ethernet'] = "" }
    if ($payload['WLAN']     -isnot [string]) { $payload['WLAN']     = "" }

    # Send to Power BI (correct wrapper)
    $body = @{ rows = @($payload) } | ConvertTo-Json -Depth 6
    Write-Host $body
    $null = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 15
}
