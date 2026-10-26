#Requires -Version 7.6
# Marker base for the Abstractions data contracts, so generic walkers (freezing, event snapshots) can treat them as records.
# SourceVersion identifies the class sources the process loaded; the module reloads the types only when it changes.
[NoRunspaceAffinity()]
class HarnessRecord {
    static [string]$SourceVersion
}
