# Count function lines in lib/*.sh and print File,Func,Lines sorted by Lines desc
$results = @()
Get-ChildItem -Path lib -Filter *.sh | ForEach-Object {
  $lines = Get-Content -LiteralPath $_.FullName -Encoding UTF8
  for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*function\s+([A-Za-z0-9_]+)\s*\(\)') {
      $name = $matches[1]
      $count = 0
      for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        $count++
        if ($lines[$j] -match '^\s*}\s*$') { break }
      }
      $results += [PSCustomObject]@{ File = $_.Name; Func = $name; Lines = $count }
    }
  }
}
$results | Sort-Object -Property Lines -Descending | Format-Table File,Func,Lines -AutoSize
