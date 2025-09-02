$dvpgs = Get-VDPortgroup

$results = @()
foreach ($dvpg in $dvpgs) {
    if($dvpg.ExtensionData.Config.BackingType -eq "nsx") {
        $tmp = [pscustomobject]@{
            Name = $dvpg.Name
            TransportZoneUuid = $dvpg.ExtensionData.Config.TransportZoneUuid
            TransportZoneName = $dvpg.ExtensionData.Config.TransportZoneName
            LogicalSwitchUuid = $dvpg.ExtensionData.Config.LogicalSwitchUuid
            SegmentId = $dvpg.ExtensionData.Config.SegmentId
            VNI = $dvpg.ExtensionData.Config.DefaultPortConfig.VNI.Value
        }
        $results+=$tmp
    }
}
$results