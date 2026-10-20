# synopsis: Combine a Windows directory with a child component using the Path API.
# tags: System.IO.Path Combine Temp
$root = [System.IO.Path]::Combine('C:\Windows', 'Temp')
$root
