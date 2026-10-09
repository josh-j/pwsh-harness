git status
if (-not $?) {
    throw 'Git failed' 
}
