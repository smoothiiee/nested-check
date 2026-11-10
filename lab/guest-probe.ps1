$ErrorActionPreference = 'Stop'
$result = [ordered]@{ stage = 'windows-specialize'; success = $false }
$port = $null
try {
    $port = [IO.Ports.SerialPort]::new('COM1', 115200)
    $port.Open()
    $port.WriteLine('RESEARCHHV_WINDOWS_PROBE_STARTED')
    $os = Get-CimInstance Win32_OperatingSystem
    $result.os = $os.Caption
    $result.version = $os.Version
    $result.architecture = $os.OSArchitecture
    $result.cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfLogicalProcessors, VirtualizationFirmwareEnabled, VMMonitorModeExtensions)
    $result.cpuid = @(& C:\Lab\cpuid.exe)
    if ($LASTEXITCODE -ne 0) { throw 'CPUID probe failed' }
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard
        $result.vbsStatus = $dg.VirtualizationBasedSecurityStatus
    } catch { $result.vbsStatus = 'Unavailable' }
    $result.success = $true
} catch {
    $result.error = $_.Exception.Message
} finally {
    $json = $result | ConvertTo-Json -Depth 5 -Compress
    $json | Set-Content C:\Lab\result.json -Encoding UTF8
    if ($port -and $port.IsOpen) {
        $port.WriteLine('RESEARCHHV_RESULT ' + $json)
        $port.WriteLine('RESEARCHHV_WINDOWS_PROBE_FINISHED')
        $port.Close()
    }
    & shutdown.exe /s /t 5 /f
}
