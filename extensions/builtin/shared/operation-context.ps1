#Requires -Version 7.6
function Get-PackOperationDirectory {
    param($State)
    $root = [IO.Path]::GetFullPath($State.Config.ContextPath)
    [IO.File]::Exists($root) ? [IO.Path]::GetDirectoryName($root) : $root
}
function Resolve-PackOperationPath {
    param($State, [string]$Path)
    $script:Harness.OperationControl.ResolvePath((Get-PackOperationDirectory $State), $Path)
}
function Get-PackRunSettings {
    param($State, [switch]$Agent)
    $timeoutSetting = $Agent ? 'Agent.CommandTimeoutSeconds' : 'RunTimeoutSeconds'
    [pscustomobject]@{
        ContextPath      = [string]$State.Config.ContextPath
        WorkingDirectory = Get-PackOperationDirectory $State
        TimeoutSeconds   = $State.Config[$timeoutSetting]
        TimeoutSetting   = $timeoutSetting
    }
}
function Invoke-PackService {
    param([string]$Name, [object[]]$Arguments, [switch]$Required)
    if (-not $script:Harness.Services.Contains($Name)) {
        if ($Required) {
            throw "Required pack service is unavailable: $Name"
        }
        return
    }
    $result = $script:Harness.Services.Invoke($Name, $Arguments)
    if ($result.Error) {
        throw $result.Error
    }
    $result.Value
}
