#Requires -Version 7.6
function New-HarnessViewState {
    <# .SYNOPSIS
    Create frontend state independently of the engine session.
    #>
    [CmdletBinding()]
    param($Session, $HarnessHost)
    $editor = [pscustomobject]@{
        Cursor       = 0
        History      = [Collections.Generic.List[string]]::new()
        HistoryIndex = 0
        Paste        = $false
    }
    $draft = @{ Buffer = [Text.StringBuilder]::new(); Snapshot = ''; Dirty = $false; HasText = $false }
    $editor | Add-Member ScriptProperty Text {
        if ($draft.Dirty) {
            $draft.Snapshot = $draft.Buffer.ToString(); $draft.Dirty = $false
        }
        $draft.Snapshot
    }.GetNewClosure() {
        param($value)
        $draft.Snapshot = [string]$value
        $draft.HasText = $draft.Snapshot -match '\S'
        $null = $draft.Buffer.Clear().Append($draft.Snapshot); $draft.Dirty = $false
    }.GetNewClosure()
    $editor | Add-Member ScriptMethod InsertText {
        param([string]$value)
        $null = $draft.Buffer.Insert($this.Cursor, $value)
        $this.Cursor += $value.Length; $draft.Dirty = $true
        $draft.HasText = $draft.HasText -or $value -match '\S'
    }.GetNewClosure()
    $editor | Add-Member ScriptMethod HasText { $draft.HasText }.GetNewClosure()
    [pscustomobject]@{
        Commands            = @()
        Highlighters        = (New-TuiHighlightContext ($HarnessHost ? $HarnessHost.Highlighters.Snapshot() : @()))
        Completion          = [pscustomobject]@{ Text = ''; Selected = 0; Closed = $false }
        Editor              = $editor
        Viewport            = [pscustomobject]@{
            ScrollOffset = 0
            MaxScroll    = 0
            PaneHeight   = 10
            Width        = 0
        }
        StatusBar           = [pscustomobject]@{
            Mode                  = 'APPROVE'
            Steps                 = ''
            Plan                  = ''
            Text                  = 'Ready'
            ExtensionNotice       = ''
            Profile               = ''
            Model                 = ''
            Behavior              = 'auto'
            Target                = ''
            Repo                  = 'context:none'
            UsageText             = ''
            StatusText            = ''
            StatusItems           = @{}
            Tokens                = 0
            Budget                = 0
            Validation            = 'none'
            Ascii                 = $false
            LogText               = 'log:memory'
            Inline                = $false
            ContinueAfterAction   = $true
            ReviewOnEmptyEnter    = $true
            ToolPreviewLines      = 4
            ConfiguredExpandTools = $false
        }
        Spinner             = [pscustomobject]@{
            Index = 0
        }
        Panels              = [pscustomobject]@{
            ShowDiff           = $false
            ShowDiagnostics    = $true
            SelectedDiagnostic = 0
            CodeLine           = 1
            ExpandTools        = $false
        }
        SessionView         = [pscustomobject]@{
            SessionId         = if ($Session) {
                $Session.SessionId
            }
            else {
                ''
            }
            Records           = [Collections.Generic.List[object]]::new()
            ToolCalls         = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
            Busy              = $false
            StreamingText     = ''
            LastResult        = $null
            Diagnostics       = @()
            Trimmed           = 0
            Operation         = $null
            RetryPrompt       = ''
            ResumeRun         = $false
            PromptShown       = $false
            BusySince         = 0L
            NextPromptSummary = ''
        }
        ValidatedArchives   = @()
        RenderCache         = [pscustomobject]@{ Width = 0; Height = 0; Ascii = $false; Expanded = $false; ReviewMode = $false; PreviewLines = 4; Start = 0; Records = @(); Transcript = $null; Streaming = $null }
        ValidatedTranscript = $null
        PreparedLayout      = $null
        InputRevision       = 0L
        RenderInterrupted   = $false
        ReviewMode          = $false
        Quit                = $false
        Reload              = $null
        ReloadPending       = $false
        AutoSend            = ''
        LastControlC        = -2000L
        Renderer            = 'Default'
        Dirty               = $true
    }
}
