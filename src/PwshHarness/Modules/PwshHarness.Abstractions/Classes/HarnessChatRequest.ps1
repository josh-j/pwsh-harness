#Requires -Version 7.6
# A provider-neutral chat request. Hosts add transient note properties (budget, tools, profile) while a turn runs.
[NoRunspaceAffinity()]
class HarnessChatRequest : HarnessRecord {
    [HarnessMessage[]]$Messages
    [string]$Model
    [hashtable]$Config
    [object]$State
    [string]$Prompt

    HarnessChatRequest([HarnessMessage[]]$messages, [string]$model, [hashtable]$config, [object]$state, [string]$prompt) {
        $this.Messages = $messages
        $this.Model = $model
        $this.Config = $config
        $this.State = $state
        $this.Prompt = $prompt
    }
}
