$udid1 = '308e6361884208deb815e12efc230a028ddc4b1a'
$udid2 = '00008030-001229C01146402E'

Write-Host "=== OLD REGEX (BUGGY): ^\w+-\w+ ===" -ForegroundColor Red
Write-Host "UDID1 ($udid1) matches: $($udid1 -match '^\w+-\w+')"
Write-Host "UDID2 ($udid2) matches: $($udid2 -match '^\w+-\w+')"
Write-Host ""

Write-Host "=== NEW FILTER (FIXED): Trim() -ne '' ===" -ForegroundColor Green
Write-Host "UDID1 ($udid1) matches: $($udid1.Trim() -ne '')"
Write-Host "UDID2 ($udid2) matches: $($udid2.Trim() -ne '')"
