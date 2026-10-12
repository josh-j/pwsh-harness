# synopsis: Check the success flag immediately after a native Git status command.
# tags: git status native success
git status
if (-not $?) {
    throw 'Git failed' 
}
