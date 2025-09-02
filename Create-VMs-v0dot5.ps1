
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory=$true)][string]$VCenter,
  [Parameter(Mandatory=$true)][string]$CsvPath
)

$ErrorActionPreference = 'Stop'

# ---- Preconditions ----
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) { throw "VMware PowerCLI not installed. Install-Module VMware.PowerCLI" }
if (-not (Test-Path -Path $CsvPath)) { throw "CSV not found at '$CsvPath'." }

Set-PowerCLIConfiguration -InvalidCertificateAction Warn -DefaultVIServerMode Single -Confirm:$false | Out-Null
$IsDryRun = ($WhatIfPreference -eq $true)

# ---- Helpers ----
function Norm { param($x) if ($null -eq $x) {return $null} $s=[string]$x; $s=$s.Trim(); if($s.Length -eq 0){return $null}; return $s }
function Parse-Bool { param($x,[bool]$Default=$true) $s=Norm $x; if($null -eq $s){return $Default}; switch -Regex ($s.ToLower()){ '^(true|1|yes|y)$'{return $true}; '^(false|0|no|n)$'{return $false}; default{ return $Default } } }
function Resolve-GuestId {
  param([string]$OsString)
  $os = Norm $OsString; if ($null -eq $os) { return $null }
  $map = @{
    'windows server 2022'='windows2022srv_64Guest'; 'windows 2022'='windows2022srv_64Guest'; 'win2022'='windows2022srv_64Guest'
    'windows server 2019'='windows2019srv_64Guest'; 'windows 2019'='windows2019srv_64Guest'; 'win2019'='windows2019srv_64Guest'
    'ubuntu'='ubuntu64Guest'; 'ubuntu 22.04'='ubuntu64Guest'; 'ubuntu 24.04'='ubuntu64Guest'
    'rhel 8'='rhel8_64Guest'; 'rhel8'='rhel8_64Guest'; 'rhel 9'='rhel9_64Guest'; 'rhel9'='rhel9_64Guest'
  }
  $k = $os.ToLower(); if ($map.ContainsKey($k)) { return $map[$k] }; return $os
}
function Get-DcExact { param([string]$Name) $n=Norm $Name; if($null -eq $n){throw "Datacenter name is empty."}
  $dc = Get-Datacenter -Name $n -ErrorAction Stop | Where-Object { $_.Name -eq $n }
  if ($null -eq $dc) { throw "Datacenter '$n' not found." }; return $dc
}
function Get-ClusterExact { param([string]$Name,$LocationDc)
  $n=Norm $Name; if($null -eq $n){throw "ClusterName is empty."}
  $clusters=@(Get-Cluster -Name $n -Location $LocationDc -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq $n})
  if($clusters.Count -eq 0){throw "Cluster '$n' not found in datacenter '$($LocationDc.Name)'."}
  if($clusters.Count -gt 1){throw "Cluster '$n' is ambiguous in '$($LocationDc.Name)'. Matches: $($clusters.Name -join ', ')." }
  return $clusters[0]
}
function Get-ClusterDefaultResourcePool { param($Cluster)
  Get-ResourcePool -Location $Cluster -Name 'Resources' -ErrorAction Stop
}

# Single datastore by name (scoped to DC)
function Get-DatastoreExact { param([string]$Name,$Scope)
  $n=Norm $Name; if($null -eq $n){return $null}
  $ds = if($Scope){@(Get-Datastore -Name $n -Location $Scope -ErrorAction SilentlyContinue)} else {@(Get-Datastore -Name $n -ErrorAction SilentlyContinue)}
  $ds = $ds | Where-Object { $_.Name -eq $n }
  if($ds.Count -eq 0){throw "Datastore '$n' not found or not accessible."}
  if($ds.Count -gt 1){throw "Datastore '$n' is ambiguous. Matches: $($ds.Name -join ', ')." }
  return $ds[0]
}

# Datastore CLUSTER (StoragePod) by name (scoped to DC)
function Get-DatastoreClusterExact { param([string]$Name,$Scope)
  $n=Norm $Name; if($null -eq $n){return $null}
  $pods = if($Scope){@(Get-DatastoreCluster -Name $n -Location $Scope -ErrorAction SilentlyContinue)} else {@(Get-DatastoreCluster -Name $n -ErrorAction SilentlyContinue)}
  $pods = $pods | Where-Object { $_.Name -eq $n }
  if($pods.Count -eq 0){throw "DatastoreCluster '$n' not found or not accessible."}
  if($pods.Count -gt 1){throw "DatastoreCluster '$n' is ambiguous. Matches: $($pods.Name -join ', ')." }
  return $pods[0]
}

# Resolve a network to VSS/VDS/NSX. If NsxSegmentId is supplied, match by segment UUID/ID.
function Resolve-NetworkTarget {
  param([string]$Name,[string]$NsxSegmentId)

  $n = Norm $Name
  $sid = Norm $NsxSegmentId
  if ($sid) { $sid = $sid.ToLower() }

  # 1) Exact by NSX segment ID if provided
  if ($sid) {
    $vdpgAll = @(Get-VDPortgroup -ErrorAction SilentlyContinue)
    foreach ($pg in $vdpgAll) {
      $cfg = $pg.ExtensionData.Config
      $segId = $null
      if ($cfg -and $cfg.PSObject.Properties.Name -contains 'SegmentId' -and $cfg.SegmentId) { $segId = $cfg.SegmentId }
      elseif ($cfg -and $cfg.PSObject.Properties.Name -contains 'LogicalSwitchUuid' -and $cfg.LogicalSwitchUuid) { $segId = $cfg.LogicalSwitchUuid }
      if ($segId -and ($segId.ToString().ToLower() -eq $sid)) {
        return @{ Type='NSX'; Object=$pg; Name=$pg.Name; SegmentId=$segId }
      }
    }
  }

  # 2) Name-based lookup (can still be NSX)
  if ($n) {
    $vdpgs = @(Get-VDPortgroup -Name $n -ErrorAction SilentlyContinue)
    if ($vdpgs.Count -gt 0) {
      foreach ($pg in $vdpgs) {
        $cfg = $pg.ExtensionData.Config
        $isNsx = $false
        if ($cfg) {
          if ($cfg.PSObject.Properties.Name -contains 'BackingType' -and $cfg.BackingType -match 'nsx') { $isNsx = $true }
          if ($cfg.PSObject.Properties.Name -contains 'SegmentId' -and $cfg.SegmentId) { $isNsx = $true }
          if ($cfg.PSObject.Properties.Name -contains 'LogicalSwitchUuid' -and $cfg.LogicalSwitchUuid) { $isNsx = $true }
        }
        if ($isNsx) { return @{ Type='NSX'; Object=$pg; Name=$pg.Name } }
      }
      # Not NSX — still VDS
      return @{ Type='VDS'; Object=$vdpgs[0]; Name=$vdpgs[0].Name }
    }

    $vsspg = Get-VirtualPortGroup -Name $n -ErrorAction SilentlyContinue
    if ($vsspg) { return @{ Type='VSS'; Object=$vsspg; Name=$vsspg.Name } }
  }

  # 3) Fallback (let Set-NetworkAdapter try by name)
  return @{ Type='Name'; Object=$null; Name=$n }
}

function Wait-VMState {
  param([VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VM,[string]$Desired='PoweredOn',[int]$TimeoutSec=240)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  do {
    $vm = Get-VM -Id $VM.Id -ErrorAction SilentlyContinue
    if ($vm -and $vm.PowerState -eq $Desired) { return $true }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  return $false
}

# ---- Connect & Load ----
$null = Connect-VIServer -Server $VCenter -ErrorAction Stop
Write-Verbose "Connected to vCenter '$VCenter'."
$rows = Import-Csv -Path $CsvPath
if (-not $rows -or $rows.Count -eq 0) { throw "CSV '$CsvPath' is empty." }

$dcCache = @{}
$results = @()

foreach ($row in $rows) {
  try {
    foreach ($c in 'Datacenter','ClusterName','Folder','VMName','Template','Network','vCPU','MemoryGB','DiskGB') {
      if (-not ($row.PSObject.Properties.Name -contains $c)) { throw "Row missing required column '$c'." }
      if ([string]::IsNullOrWhiteSpace([string]$row.$c)) { throw "Row for VM '$($row.VMName)' has empty required column '$c'." }
    }

    # Normalize
    $dcName    = Norm $row.Datacenter
    $clusterNm = Norm $row.ClusterName
    $folder    = Norm $row.Folder
    $vmName    = Norm $row.VMName
    $tmplName  = Norm $row.Template
    $netName   = Norm $row.Network
    $cpu       = [int](Norm $row.vCPU)
    $memGB     = [int](Norm $row.MemoryGB)
    $diskGB    = [int](Norm $row.DiskGB)
    $guestId   = Resolve-GuestId -OsString (Norm $row.OSType)
    $dsName    = Norm $row.Datastore
    $dscName   = $null; if ($row.PSObject.Properties.Name -contains 'DatastoreCluster') { $dscName = Norm $row.DatastoreCluster }
    $powerOn   = Parse-Bool $row.PowerOn $true
    $nsxSegId  = $null; if ($row.PSObject.Properties.Name -contains 'NsxSegmentId') { $nsxSegId = Norm $row.NsxSegmentId }

    Write-Host "Processing VM '$vmName' (DC=$dcName, Cluster=$clusterNm)..." -ForegroundColor Yellow

    # Skip if exists
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
      Write-Warning "VM '$vmName' already exists. Skipping."
      $results += [pscustomobject]@{
        VMName=$vmName; Action='Skipped (exists)'; Datacenter=$dcName; Cluster=$clusterNm; Folder=$folder; Network=$netName;
        CPU=$cpu; MemoryGB=$memGB; DiskGB=$diskGB; Template=$tmplName; Datastore=$dsName; DatastoreCluster=$dscName; Notes=''
      }
      continue
    }

    # DC/Cluster/Pool
    if (-not $dcCache.ContainsKey($dcName)) { $dcCache[$dcName] = Get-DcExact -Name $dcName }
    $dc      = $dcCache[$dcName]
    $cluster = Get-ClusterExact -Name $clusterNm -LocationDc $dc
    $rp      = Get-ClusterDefaultResourcePool -Cluster $cluster

    # Template
    $template  = Get-Template -Name $tmplName -ErrorAction Stop

    # Storage (prefer DatastoreCluster if both provided)
    $ds  = $null
    $dsc = $null
    if ($dscName) { $dsc = Get-DatastoreClusterExact -Name $dscName -Scope $dc }
    if ($dsName -and -not $dsc) { $ds = Get-DatastoreExact -Name $dsName -Scope $dc }
    $storageNote = ''
    if ($dscName -and $dsName -and $dsc) { $storageNote = "Using DatastoreCluster '$($dsc.Name)' (overrode Datastore '$dsName')." }

    # Network target (NSX/VDS/VSS/Name)
    $netTarget = Resolve-NetworkTarget -Name $netName -NsxSegmentId $nsxSegId

    # Dry run
    if ($IsDryRun) {
      $dsOut = $null; if ($ds) { $dsOut = $ds.Name }
      $dscOut = $null; if ($dsc) { $dscOut = $dsc.Name }
      $notes = ''
      if ($netTarget.Type -eq 'NSX') { $notes = 'NSX segment' } elseif ($netTarget.Type -eq 'VDS') { $notes = 'VDS portgroup' } elseif ($netTarget.Type -eq 'VSS') { $notes = 'VSS portgroup' }
      if ($storageNote) { $notes = ($notes ? "$notes; " : '') + $storageNote }
      $results += [pscustomobject]@{
        VMName=$vmName; Action='Would Create (WhatIf)'; Datacenter=$dcName; Cluster=$clusterNm; Folder=$folder; Network=$netName;
        CPU=$cpu; MemoryGB=$memGB; DiskGB=$diskGB; Template=$template.Name; Datastore=$dsOut; DatastoreCluster=$dscOut; Notes=$notes
      }
      Write-Host "WHATIF: Would create VM '$vmName' from template '$($template.Name)'" -ForegroundColor Cyan
      continue
    }

    # ---- Clone (minimal params; choose storage param) ----
    $newVm = $null
    if ($PSCmdlet.ShouldProcess("New-VM Template+Cluster '$vmName'")) {
      if ($dsc) {
        $newVm = New-VM -Name $vmName -Template $template -ResourcePool $rp -DatastoreCluster $dsc -Confirm:$false
      } elseif ($ds) {
        $newVm = New-VM -Name $vmName -Template $template -ResourcePool $rp -Datastore $ds -Confirm:$false
      } else {
        $newVm = New-VM -Name $vmName -Template $template -ResourcePool $rp -Confirm:$false
      }
    }
    if ($null -eq $newVm) { throw "New-VM returned no VM object for '$vmName'." }

    # ---- Folder path & move (InventoryLocation) ----
    $rootFolder   = Get-Folder -Id $dc.ExtensionData.VmFolder
    $targetFolder = $rootFolder
    if ($folder) {
      $segments = $folder -split '/'
      foreach ($seg in $segments) {
        $existing = Get-Folder -Name $seg -Location $targetFolder -ErrorAction SilentlyContinue
        if (-not $existing) { $existing = New-Folder -Name $seg -Location $targetFolder -ErrorAction Stop }
        $targetFolder = $existing
      }
    }
    try { Move-VM -VM $newVm -InventoryLocation $targetFolder -Confirm:$false | Out-Null }
    catch { Write-Warning "Move-VM into folder '$folder' failed for '$vmName': $($_.Exception.Message)" }

    # ---- CPU/Memory after clone (still powered off) ----
    try {
      if ($cpu -gt 0 -or $memGB -gt 0) {
        Set-VM -VM $newVm -NumCpu $cpu -MemoryGB $memGB -Confirm:$false | Out-Null
      }
    } catch { Write-Warning "Set-VM CPU/Memory failed for '$vmName': $($_.Exception.Message)" }

    # ---- Expand first disk (expand only, still powered off) ----
    $firstDisk = Get-HardDisk -VM $newVm | Sort-Object CapacityGB | Select-Object -First 1
    if ($firstDisk -and $diskGB -gt [int]$firstDisk.CapacityGB) {
      Set-HardDisk -HardDisk $firstDisk -CapacityGB $diskGB -Confirm:$false | Out-Null
    } elseif ($firstDisk -and $diskGB -lt [int]$firstDisk.CapacityGB) {
      Write-Warning "Requested DiskGB ($diskGB) < template primary disk ($([int]$firstDisk.CapacityGB)). Not shrinking."
    }

    # ---- Set Guest OS type BEFORE any power-on ----
    if ($guestId) {
      try { Set-VM -VM $newVm -GuestId $guestId -Confirm:$false | Out-Null }
      catch { Write-Warning "Set-VM -GuestId '$guestId' failed for '$vmName': $($_.Exception.Message)" }
    }

    # ---- NIC wiring ----
    # VSS/Name  -> wire before power-on
    # NSX/VDS   -> wire after power-on (these often require PoweredOn)
    $needsPoweredOnAttach = ($true -eq (@('NSX','VDS') -contains (Resolve-NetworkTarget -Name $netName -NsxSegmentId $nsxSegId).Type))
    # reuse computed netTarget
    if ($netTarget.Type -eq 'VSS' -or $netTarget.Type -eq 'Name') {
      $nic = Get-NetworkAdapter -VM $newVm | Select-Object -First 1
      if ($nic -and $netTarget.Name) {
        if ($nic.NetworkName -ne $netTarget.Name) {
          Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $netTarget.Name -Confirm:$false | Out-Null
        }
        $nic2 = Get-NetworkAdapter -VM $newVm | Select-Object -First 1
        Set-NetworkAdapter -NetworkAdapter $nic2 -Connected:$true -StartConnected:$true -Confirm:$false | Out-Null
      } else {
        Write-Warning "No NIC found or network name empty for '$vmName'."
      }
    }

    # ---- Power on & post-power-on wiring for NSX/VDS ----
    if ($powerOn) {
      Start-VM -VM $newVm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
      if ($netTarget.Type -eq 'NSX' -or $netTarget.Type -eq 'VDS') {
        if (-not (Wait-VMState -VM $newVm -Desired 'PoweredOn' -TimeoutSec 240)) {
          Write-Warning "VM '$vmName' did not reach PoweredOn within timeout; skipping NSX/VDS NIC wiring."
        } else {
          $nic3 = Get-NetworkAdapter -VM $newVm | Select-Object -First 1
          if ($nic3) {
            if ($netTarget.Object) {
              if ($nic3.NetworkName -ne $netTarget.Name) {
                Set-NetworkAdapter -NetworkAdapter $nic3 -Portgroup $netTarget.Object -Confirm:$false | Out-Null
              }
              Set-NetworkAdapter -NetworkAdapter $nic3 -Connected:$true -StartConnected:$true -Confirm:$false | Out-Null
            } elseif ($netTarget.Name) {
              if ($nic3.NetworkName -ne $netTarget.Name) {
                Set-NetworkAdapter -NetworkAdapter $nic3 -NetworkName $netTarget.Name -Confirm:$false | Out-Null
              }
              Set-NetworkAdapter -NetworkAdapter $nic3 -Connected:$true -StartConnected:$true -Confirm:$false | Out-Null
            }
          } else {
            Write-Warning "No NIC found on '$vmName' to rewire (VDS/NSX phase)."
          }
        }
      }
    } else {
      if ($netTarget.Type -eq 'NSX' -or $netTarget.Type -eq 'VDS') {
        Write-Warning "Target '$($netTarget.Name)' is NSX/VDS and typically requires PoweredOn to attach. PowerOn=false; leaving NIC unchanged."
      }
    }

    # ---- Summarize ----
    $dsOut  = $null; if ($ds)  { $dsOut  = $ds.Name }
    $dscOut = $null; if ($dsc) { $dscOut = $dsc.Name }
    $note = ''
    if ($storageNote) { $note = $storageNote }
    if ($netTarget.Type -eq 'NSX') { $note = ($note ? "$note; " : '') + 'NSX segment connected post-power-on' }
    elseif ($netTarget.Type -eq 'VDS') { $note = ($note ? "$note; " : '') + 'VDS PG connected post-power-on' }

    $results += [pscustomobject]@{
      VMName=$vmName; Action='Created'; Datacenter=$dcName; Cluster=$clusterNm; Folder=$folder; Network=$netName;
      CPU=$cpu; MemoryGB=$memGB; DiskGB=$diskGB; Template=$template.Name; Datastore=$dsOut; DatastoreCluster=$dscOut; Notes=$note
    }
    Write-Host "✔ Created VM '$vmName'." -ForegroundColor Green
  }
  catch {
    $results += [pscustomobject]@{
      VMName=(Norm $row.VMName); Action='Failed'; Datacenter=(Norm $row.Datacenter); Cluster=(Norm $row.ClusterName); Folder=(Norm $row.Folder); Network=(Norm $row.Network);
      CPU=(Norm $row.vCPU); MemoryGB=(Norm $row.MemoryGB); DiskGB=(Norm $row.DiskGB); Template=(Norm $row.Template);
      Datastore=(Norm $row.Datastore); DatastoreCluster=(Norm $row.DatastoreCluster); Notes=$_.Exception.Message
    }
    Write-Error "VM '$((Norm $row.VMName))' failed: $($_.Exception.Message)"
  }
}

$results | Format-Table -AutoSize
return $results

# Optional: Disconnect
# Disconnect-VIServer -Confirm:$false | Out-Null
