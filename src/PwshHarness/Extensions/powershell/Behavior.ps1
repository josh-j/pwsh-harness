function Add-PowerShellBehaviorPrompt {
    [CmdletBinding()]
    param($Request)
    $mode = $Request.Config.Behavior
    if ($Request.PSObject.Properties['AgentTools']) {
        return
    }
    if ($mode -eq 'code') {
        return
    }
    $system = $Request.Messages[0]
    # Replace the built-in script-first prompt; retain user-supplied prompts and profile addenda.
    if ($system.Content.StartsWith($script:PackBehaviorPrompts.code, [StringComparison]::Ordinal)) {
        $system.Content = $script:PackBehaviorPrompts[$mode] + $system.Content.Substring($script:PackBehaviorPrompts.code.Length)
    }
    $system.Content += "`n" + $(if ($mode -eq 'auto') {
            'Behavior auto: decide whether this request needs PowerShell. For scripting tasks, return one complete PowerShell fence. Otherwise answer directly in prose or markdown; no script or fence is required.'
        }
        else {
            'Behavior chat: answer conversationally in prose or markdown. Write PowerShell only when the user explicitly asks for it; otherwise no script or fence is required.'
        })
}
function Invoke-PowerShellBehaviorCommand {
    [CmdletBinding()]
    param($Context)
    if ($Context.Arguments) {
        $mode = $Context.Arguments.Trim().ToLowerInvariant()
        if ($mode -notin @('code', 'auto', 'chat')) {
            throw "Unknown behavior '$($Context.Arguments)'. Choose code, auto, or chat."
        }
        $Context.State.Settings.Set('Behavior', $mode)
    }
    "Behavior: $($Context.State.Config.Behavior)`ncode — Always request a validated PowerShell script.`nauto — Choose a script or a direct answer for the request.`nchat — Converse; write PowerShell only when explicitly asked."
}
