git log -p
if ($LASTEXITCODE) {
    throw 'Git failed' 
}
git status
"Native result: $LASTEXITCODE"
