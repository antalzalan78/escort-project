$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$jsonPath = Join-Path $projectDir 'availability.json'

if (-not (Test-Path -LiteralPath $jsonPath)) {
  throw "availability.json was not found."
}

$availability = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ''
Write-Host 'MILAN - Availability updater' -ForegroundColor Yellow
Write-Host 'Press Enter to keep the current value.' -ForegroundColor DarkGray
Write-Host ''

$currentState = if ($availability.available) { 'available' } else { 'by appointment' }
$stateAnswer = Read-Host "Taking new bookings? Y/N (current: $currentState)"
if ($stateAnswer -match '^[YyJj]$') { $availability.available = $true }
if ($stateAnswer -match '^[Nn]$')   { $availability.available = $false }

$choices = @{
  '0' = @{ active = $false; en = 'Off';       nl = 'Vrij' }
  '1' = @{ active = $true;  en = 'Day';       nl = 'Overdag' }
  '2' = @{ active = $true;  en = 'Evening';   nl = 'Avond' }
  '3' = @{ active = $true;  en = 'Day & Eve'; nl = 'Dag & avond' }
}

$dayNames = [ordered]@{
  mon = 'Monday'
  tue = 'Tuesday'
  wed = 'Wednesday'
  thu = 'Thursday'
  fri = 'Friday'
  sat = 'Saturday'
  sun = 'Sunday'
}

Write-Host ''
Write-Host '0 = Off, 1 = Day, 2 = Evening, 3 = Day & Evening' -ForegroundColor Cyan

foreach ($dayKey in $dayNames.Keys) {
  $day = $availability.days.$dayKey
  $answer = Read-Host "$($dayNames[$dayKey]) (current: $($day.en))"
  if ($choices.ContainsKey($answer)) {
    $choice = $choices[$answer]
    $day.active = $choice.active
    $day.en = $choice.en
    $day.nl = $choice.nl
  }
}

$availability.updated = (Get-Date).ToString('yyyy-MM-dd')
$json = $availability | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'Availability saved. Uploading to the website...' -ForegroundColor Green

Push-Location $projectDir
try {
  git add availability.json
  git diff --cached --quiet
  if ($LASTEXITCODE -eq 0) {
    Write-Host 'Nothing changed.' -ForegroundColor DarkGray
    exit 0
  }

  git commit -m "Update availability"
  if ($LASTEXITCODE -ne 0) { throw 'Git commit failed.' }

  git push
  if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }

  Write-Host ''
  Write-Host 'Done. The live website will update in a few minutes.' -ForegroundColor Green
}
finally {
  Pop-Location
}
