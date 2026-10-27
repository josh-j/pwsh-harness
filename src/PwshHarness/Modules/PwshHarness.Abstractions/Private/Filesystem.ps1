#Requires -Version 7.6
$script:NativePathStat = $IsWindows ? $null : [System.Management.Automation.PSObject].Assembly.GetType('System.Management.Automation.Platform+Unix').GetMethod('GetLStat')
$script:NoFollowOpen = $IsWindows ? $null : ([Microsoft.Win32.SafeHandles.SafeFileHandle].GetMethods([Reflection.BindingFlags]'NonPublic,Static') |
        Where-Object {
            $p = $_.GetParameters()
            $_.Name -eq 'Open' -and $_.ReturnType -eq [Microsoft.Win32.SafeHandles.SafeFileHandle] -and $p.Count -eq 6 -and
            $p[0].ParameterType -eq [string] -and $p[1].ParameterType.IsEnum -and $p[2].ParameterType -eq [int] -and
            $p[3].ParameterType -eq [bool] -and $p[4].ParameterType -eq [bool].MakeByRefType() -and ($p[1].ParameterType.GetEnumNames() -contains 'O_NOFOLLOW')
        } | Select-Object -First 1)
$script:NoFollowFlags = $script:NoFollowOpen ? [Enum]::Parse($script:NoFollowOpen.GetParameters()[1].ParameterType, 'O_RDONLY,O_CLOEXEC,O_NOFOLLOW') : $null
. (Join-Path $PSScriptRoot '../Public/ConvertTo-HarnessSlashPath.ps1')
. (Join-Path $PSScriptRoot '../Public/Get-HarnessPathComparison.ps1')
. (Join-Path $PSScriptRoot '../Public/Get-HarnessPathSnapshot.ps1')
. (Join-Path $PSScriptRoot '../Public/Get-HarnessSha256.ps1')
. (Join-Path $PSScriptRoot '../Public/Read-HarnessFileByte.ps1')
. (Join-Path $PSScriptRoot '../Public/Read-HarnessTextFile.ps1')
. (Join-Path $PSScriptRoot '../Public/Test-HarnessLinkItem.ps1')
. (Join-Path $PSScriptRoot '../Public/Write-HarnessAtomicFile.ps1')
