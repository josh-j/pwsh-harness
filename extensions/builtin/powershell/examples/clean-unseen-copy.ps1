# synopsis: Copy a literal file path to a UNC network share.
# tags: Copy-Item LiteralPath Destination
Copy-Item -LiteralPath "C:\temp\new.txt" -Destination "\\srv\share\reports"
