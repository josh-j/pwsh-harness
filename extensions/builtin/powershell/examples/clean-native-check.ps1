# synopsis: Check native Git exit codes before continuing to another command.
# tags: git log patches LASTEXITCODE failure
git log -p
if ($LASTEXITCODE) {
    throw 'Git failed' 
}
git status
"Native result: $LASTEXITCODE"
