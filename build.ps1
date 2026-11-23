# Recupere l'emploi du temps des groupes de TP sur GPU (gpu-lr.fr) et ecrit data.json.
# Lance toutes les heures par GitHub Actions (.github/workflows/update.yml).
# Identifiants lus dans les variables d'environnement GPU_LOGIN / GPU_PASSWORD (secrets GitHub).
# Seul l'emploi du temps est publie : jamais les notes, absences ou infos du compte.

$ErrorActionPreference = 'Stop'

# ---- Groupes publies : groupe de TD -> ses groupes de TP. Ajouter une ligne pour ouvrir un groupe. ----
$Groups = [ordered]@{
    'S1A' = @('S1TP1', 'S1TP2')
    'S1B' = @('S1TP3', 'S1TP4')
    'S1C' = @('S1TP5', 'S1TP6')
    'S1D' = @('S1TP7', 'S1TP8')
}
$Filiere     = 'S1'
$WeeksBefore = 1
$WeeksAfter  = 12

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutFile  = Join-Path $Here 'data.json'
$Base     = 'https://www.gpu-lr.fr'
$LoginUrl = "$Base/sat/index.php?page_param=accueilsatellys.php&cat=0&numpage=1&niv=0&clef=/"
$StudUrl  = "$Base/gpu/index.php?page_param=fpetudiant.php&cat=0&numpage=1&niv=2&clef=/10192/10194/"
$GroupUrl = "$Base/gpu/index.php?page_param=fpgroupes.php&cat=0&numpage=1&niv=2&clef=/10192/10195/"

$login = $env:GPU_LOGIN; $pass = $env:GPU_PASSWORD
$etu   = if ($env:GPU_ETUDIANT) { $env:GPU_ETUDIANT } else { $login }
if (-not $login -or -not $pass) { throw 'Secrets GPU_LOGIN / GPU_PASSWORD manquants' }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Paris = try { [TimeZoneInfo]::FindSystemTimeZoneById('Europe/Paris') } catch { [TimeZoneInfo]::FindSystemTimeZoneById('Romance Standard Time') }
$Inv   = [Globalization.CultureInfo]::InvariantCulture

function Get-Text($resp) {
    $ms = New-Object IO.MemoryStream
    $resp.RawContentStream.Position = 0
    $resp.RawContentStream.CopyTo($ms)
    [Text.Encoding]::UTF8.GetString($ms.ToArray())
}
function Get-Web($url, $body) {
    $p = @{ Uri = $url; WebSession = $script:GpuSession; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($body) { $p.Method = 'Post'; $p.Body = $body }
    Get-Text (Invoke-WebRequest @p)
}
function Remove-Accents([string]$s) {
    $n = $s.Normalize([Text.NormalizationForm]::FormD)
    -join ($n.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}
function ConvertTo-UtcIso([datetime]$local) {
    $u = [TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($local, 'Unspecified'), $Paris)
    $u.ToString("yyyy-MM-dd'T'HH:mm:00'Z'", $Inv)
}
function Get-Monday([datetime]$d) { $d.Date.AddDays(-(([int]$d.DayOfWeek + 6) % 7)) }
function Get-IsoWeek([datetime]$d) { $Inv.Calendar.GetWeekOfYear($d, 'FirstFourDayWeek', 'Monday') }
function Get-Iso($v) {
    # pwsh 7 transforme les dates JSON en DateTime : on revient toujours a la meme chaine UTC
    if ($v -is [datetime]) { return $v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:00'Z'", $Inv) }
    [string]$v
}
function Get-CleanText([string]$s) { ([Net.WebUtility]::HtmlDecode($s) -replace '\s+', ' ').Trim() }

$Months = @{ janvier=1; fevrier=2; mars=3; avril=4; mai=5; juin=6; juillet=7; aout=8; septembre=9; octobre=10; novembre=11; decembre=12 }

# ---------- page de groupe : une "bulle" par cours ----------
function ConvertFrom-GroupPage([string]$html) {
    $seen = @{}
    $chunks = [regex]::Split($html, '<div id="Bulle')
    foreach ($c in ($chunks | Select-Object -Skip 1)) {
        if ($c -notmatch '^(\d+)"') { continue }
        $id = $Matches[1]
        if ($seen[$id]) { continue }
        $rows = @{}
        $first = $null
        foreach ($m in [regex]::Matches($c, '<td nowrap>\s*(.*?)\s*</td>\s*<td>(.*?)</td>', 'Singleline')) {
            $k = Remove-Accents (Get-CleanText $m.Groups[1].Value)
            $v = Get-CleanText $m.Groups[2].Value
            if (-not $first) { $first = @($k, $v) }
            $rows[$k] = $v
            if ($k -like 'Memo*') { break }
        }
        if (-not $first -or $first[1] -notmatch '(\d+)h(\d+)\s*a\s*(\d+)h(\d+)') { continue }
        $h1=[int]$Matches[1]; $m1=[int]$Matches[2]; $h2=[int]$Matches[3]; $m2=[int]$Matches[4]
        if ((Remove-Accents $rows['Le']) -notmatch '(\d+)\s+(\w+)\s+(\d{4})') { continue }
        $mon = $Months[$Matches[2].ToLower()]; if (-not $mon) { continue }
        $day = [datetime]::new([int]$Matches[3], $mon, [int]$Matches[1])
        $seen[$id] = $true

        $type   = ($first[0] -replace '\s*de$', '').Trim(); if ($type -eq '-') { $type = '' }
        $module = $rows['Module']
        $ue = ""; $code = $module
        if ($module -match '^(UE\S*)\s+(.+)$') { $ue = $Matches[1]; $code = $Matches[2].Trim() }
        $roomsRaw = $rows['Salle(s)']
        $rooms  = @([regex]::Matches($roomsRaw, '[A-Za-z]+-[0-9A-Za-z]+') | ForEach-Object Value)
        $room   = if ($rooms.Count) { $rooms -join ' / ' } else { $roomsRaw.Trim('-', ' ') }
        $profs  = (($rows['Enseignant(s)'] -split '-') | Where-Object { $_ }) -join ' / '
        $memo   = ''; foreach ($k in $rows.Keys) { if ($k -like 'Memo*') { $memo = $rows[$k] } }

        [pscustomobject]@{
            id = "g$id"
            start = ConvertTo-UtcIso $day.AddHours($h1).AddMinutes($m1)
            end   = ConvertTo-UtcIso $day.AddHours($h2).AddMinutes($m2)
            code = $code; type = $type; group = $rows['Groupe']; room = $room; prof = $profs; memo = $memo
            ue = $ue; num = [string]$rows['Numero']
            local = $day
        }
    }
}

# ---------- export VCal (noms complets des matieres + semaines pas encore publiees) ----------
function ConvertFrom-QP([string]$s) {
    $s = $s -replace "=\r?\n", ''
    $bytes = New-Object Collections.Generic.List[byte]
    for ($i = 0; $i -lt $s.Length; $i++) {
        if ($s[$i] -eq '=' -and $i + 2 -lt $s.Length -and $s.Substring($i+1,2) -match '^[0-9A-Fa-f]{2}$') {
            $bytes.Add([Convert]::ToByte($s.Substring($i+1,2),16)); $i += 2
        } else { foreach ($b in [Text.Encoding]::UTF8.GetBytes([string]$s[$i])) { $bytes.Add($b) } }
    }
    [Text.Encoding]::UTF8.GetString($bytes.ToArray())
}
function Get-Field($block, $name) { if ($block -match "(?m)^$name(?:;[^:\r\n]*)?:(.*?)\r?$") { $Matches[1] } else { '' } }
function ConvertFrom-Vcs([string]$text) {
    foreach ($b in ($text -split 'BEGIN:VEVENT') | Select-Object -Skip 1) {
        $parts = (Get-Field $b 'SUMMARY') -split '\s*/\s*'
        $desc  = ConvertFrom-QP (Get-Field $b 'DESCRIPTION')
        $prof = ''; $name = ''
        if ($desc -match 'Prof:(.*?)\s+Spe:') { $prof = $Matches[1].Trim() }
        if ($desc -match 'Spe:(.*?)\\')       { $name = ($Matches[1] -replace '\s+', ' ').Trim() }
        $toIso = { param($v) [DateTime]::ParseExact($v.Trim(), "yyyyMMdd'T'HHmmss'Z'", $Inv).ToString("yyyy-MM-dd'T'HH:mm:00'Z'", $Inv) }
        $s = & $toIso (Get-Field $b 'DTSTART')
        [pscustomobject]@{
            id = ''; start = $s; end = & $toIso (Get-Field $b 'DTEND')
            code = $parts[0]; type = $(if ($parts.Count -gt 1 -and $parts[1] -ne '-') { $parts[1] } else { '' })
            group = $(if ($parts.Count -gt 2) { $parts[2] } else { '' })
            room = (Get-Field $b 'LOCATION').Trim(); prof = ($prof -replace '/', ' / '); memo = ''; name = $name
        }
    }
}

# ---------- connexion ----------
$null = Invoke-WebRequest -UseBasicParsing -Uri $LoginUrl -SessionVariable GpuSession
$script:GpuSession = $GpuSession
$null = Get-Web $LoginUrl @{ modeconnect = 'connect'; util = $login; acct_pass = $pass }
if ((Get-Web $StudUrl) -notmatch 'Inscrit dans les groupes') { throw 'Connexion GPU refusee' }
Write-Host 'Connecte a GPU'

# ---------- tables GPU : noms des profs et des modules ----------
# lignes <tr> : <a onclick="return Valide('table','CODE')"> puis des <P class="Police2G">&nbsp;valeur</P>
function Get-GpuTable($table) {
    $html = Get-Web "$Base/gpu/info_table.php?table=$table&champ=$table&filiere=$Filiere"
    foreach ($m in [regex]::Matches($html, "Valide\('$table','([^']+)'\)(.*?)</tr>", 'Singleline')) {
        $code = ($m.Groups[1].Value -split '\s+')[-1]
        $vals = @([regex]::Matches($m.Groups[2].Value, '<P class="Police2G">(.*?)</P>', 'Singleline') | ForEach-Object { Get-CleanText $_.Groups[1].Value })
        [pscustomobject]@{ code = $code; vals = $vals }
    }
}
$profs = @{}
foreach ($r in Get-GpuTable 'enseignant') {
    $n = (@($r.vals | Where-Object { $_ }) -join ' ').Trim()
    if ($n) { $profs[$r.code] = $n }
}
$moduleNames = @{}
foreach ($r in Get-GpuTable 'matiere') { if ($r.vals[0]) { $moduleNames[$r.code] = $r.vals[0] } }
Write-Host "$($profs.Count) profs, $($moduleNames.Count) modules"
# shortcut: on ne publie que les profs presents dans l'emploi du temps (filtre plus bas), pas toute la liste

# ---------- donnees precedentes (on garde les semaines passees) ----------
$old = $null
if (Test-Path $OutFile) { try { $old = [IO.File]::ReadAllText($OutFile) | ConvertFrom-Json } catch { } }
$names = @{}
if ($old -and $old.names) { foreach ($p in $old.names.PSObject.Properties) { $names[$p.Name] = $p.Value } }

$mon0  = Get-Monday ([TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $Paris))
$weeks = @(-$WeeksBefore..$WeeksAfter | ForEach-Object { $mon0.AddDays(7 * $_) })
$firstFetched = $weeks[0]

# VCal : une requete par semaine
$vcs = @{}
foreach ($w in $weeks) {
    $t = Get-Web "$Base/gpu/gpu2vcs.php?semaine=$(Get-IsoWeek $w)&prof_etu=ETU&etudiant=$etu&enseignantedt="
    $evs = @()
    if ($t -match 'BEGIN:VCALENDAR') { $evs = @(ConvertFrom-Vcs $t) }
    foreach ($e in $evs) { if ($e.name) { $names[$e.code] = $e.name } }
    $vcs[$w.ToString('yyyy-MM-dd')] = $evs
    Start-Sleep -Milliseconds 300
}

function Get-GroupWeek($g, $w) {
    $body = @{ mode='edt'; semaine="$(Get-IsoWeek $w)"; liste='-1'; aff_edtabs='-1'; ansemaine="$($w.AddDays(3).Year)";
               idedtselect='0'; left='0'; top='0'; taillepolice='15'; filiere=$Filiere; groupe=$g }
    ConvertFrom-GroupPage (Get-Web $GroupUrl $body) | Where-Object { $_.local -ge $w -and $_.local -lt $w.AddDays(7) }
}
$tdWeeks = @{}
$out = [ordered]@{}
foreach ($td in $Groups.Keys) {
    foreach ($tp in $Groups[$td]) {
        $list = New-Object Collections.Generic.List[object]
        # les semaines plus anciennes que la semaine derniere ne sont plus publiees (l'appli ne remonte pas plus loin)
        foreach ($w in $weeks) {
            $evs = @(Get-GroupWeek $tp $w)
            $src = 'gpu'
            if ($evs.Count) {
                # la page d'un TP oublie parfois les cours de son groupe de TD (vu pour S1TP3) : on complete
                $k = "$td|$($w.ToString('yyyy-MM-dd'))"
                if (-not $tdWeeks.ContainsKey($k)) { $tdWeeks[$k] = @(Get-GroupWeek $td $w) }
                $ids = @($evs | ForEach-Object { $_.id })
                $evs += @($tdWeeks[$k] | Where-Object { $ids -notcontains $_.id })
            } else {
                # semaine non publiee sur la page groupe : on prend l'export VCal s'il contient ce TP
                $v = @($vcs[$w.ToString('yyyy-MM-dd')])
                if ($v | Where-Object { $_.group -eq $tp }) {
                    $evs = @($v | Where-Object { @($Filiere, $td, $tp) -contains $_.group })
                    $src = 'vcal'
                }
            }
            foreach ($e in $evs) {
                $list.Add([ordered]@{ id=$e.id; start=$e.start; end=$e.end; code=$e.code; type=$e.type; group=$e.group; room=$e.room; prof=$e.prof; memo=$e.memo; ue=$e.ue; num=$e.num })
            }
            Write-Host ("{0} semaine {1} : {2} cours ({3})" -f $tp, (Get-IsoWeek $w), $evs.Count, $src)
            Start-Sleep -Milliseconds 300
        }
        $out[$tp] = @($list | Sort-Object { $_.start })
    }
}

$total = ($out.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
if ($total -eq 0) { throw 'Aucun cours recupere : on ne remplace pas data.json' }

foreach ($k in $moduleNames.Keys) { if (-not $names[$k]) { $names[$k] = $moduleNames[$k] } }
# Noms tronques dans GPU, corriges a la main (source : Moodle)
$names['SAE1.1'] = "Étude d'exécution d'un ouvrage de bâtiment"
$usedProfs = [ordered]@{}
foreach ($e in ($out.Values | ForEach-Object { $_ })) {
    foreach ($c in ($e.prof -split ' / ')) { if ($c -and $profs[$c]) { $usedProfs[$c] = $profs[$c] } }
}

$data = [ordered]@{
    updated = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv)
    groups  = $Groups
    names   = $names
    profs   = $usedProfs
    events  = $out
}
[IO.File]::WriteAllText($OutFile, ($data | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false))
Write-Host "OK : $total cours ecrits dans data.json"
