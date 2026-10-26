#Requires -Version 7.6
# A generic tool call: identity plus frozen data arguments. This record grants no authority.
[NoRunspaceAffinity()]
class HarnessToolCall : HarnessRecord {
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$', Options = 'None', ErrorMessage = 'Tool call identity must be 1–128 ASCII letters, digits, underscores or hyphens.')][string]$Id
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$', Options = 'None', ErrorMessage = 'Tool call identity must be 1–128 ASCII letters, digits, underscores or hyphens.')][string]$Name
    [Collections.IDictionary]$Arguments

    HarnessToolCall([string]$id, [string]$name, [Collections.IDictionary]$arguments) {
        $this.Id = $id
        $this.Name = $name
        $this.Arguments = $arguments
    }
}
