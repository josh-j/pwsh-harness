#Requires -Version 7.6
# One conversation message. Role stays a string so JSON writers and hashtable lookups keep their spelling.
[NoRunspaceAffinity()]
class HarnessMessage : HarnessRecord {
    [ValidateSet('system', 'user', 'assistant', ErrorMessage = 'Invalid message role.')][string]$Role
    [string]$Content

    HarnessMessage([string]$role, [string]$content) {
        $this.Role = $role
        $this.Content = $content
    }
}
