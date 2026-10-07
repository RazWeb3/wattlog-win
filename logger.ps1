# wattlog 第1段 — ゼロインストール バッテリー電力ロガー（PowerShell ネイティブ）
# 起動: wattlog.cmd をダブルクリック（1放電・残量 / 2放電・時間 / 3充電・残量 / 4充電・時間 を選ぶ）または
#       powershell -NoProfile -ExecutionPolicy Bypass -File logger.ps1 -Mode discharge -StopAt 10
#
# パラメータ:
#   -Mode <discharge|charge>  計測モード（省略時メニュー）
#   -Interval <秒>            サンプリング間隔（既定 5）
#   -StopAt <%>               discharge: 以下で停止（既定10） / charge: 以上で停止（既定100）
#                             ※charge は100%に届かなくても charging フラグOFF（満充電宣言）で自動停止
#   -Duration <分>            経過分数で自動停止（省略可）
#   -Out <dir>                出力先（既定 ./logs）
#   -Label <text>             ファイル名ラベル
#   -KeepAwake <on|off>       アイドルスリープ防止（既定 on）。蓋閉じは未検証
#   -FromCsv <path>           計測せず既存CSVからHTMLだけ再生成（UI変更後の確認用）。指定時は他モード無視
#   -Note <text>              計測条件の自由メモ（音量/WiFi/バックグラウンド等）。電源プラン・輝度は自動取得
#   -Conf <path>              設定ファイル（既定は logger.ps1 と同階層の wattlog.conf。無ければ無視）
#
# 設定ファイル: `key=value`・1行1項・`#`でコメント。優先順位は CLI引数 > 設定ファイル > メニュー入力 > 組み込み既定。
#   書ける鍵: interval / stopat / duration / out / label / keepawake / lang
#   mode と note は回替わりの条件なので対象外（毎回メニューで聞く）
#
# CSV と HTML はサンプル毎に逐次書き込む。強制終了（窓を閉じる等）でも直前までのデータは残る。
param(
  [string]$Mode = '',
  [double]$Interval = 0,
  [double]$StopAt = -1,
  [double]$Duration = -1,
  [string]$Out = 'logs',
  [string]$Label = '',
  [string]$KeepAwake = 'on',
  [string]$FromCsv = '',
  [string]$Note = '',
  [string]$Lang = '',
  [string]$Conf = ''
)
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------- 設定ファイル（wattlog.conf / -Conf） ----------
# CLI引数 > 設定ファイル > メニュー入力 > 組み込み既定 の順で上書きする。
# mode / note は計測回ごとの条件なので設定ファイルで固定しない（誠実性: 毎回明示させる）。
# 報告文言は言語テーブル生成後（T が使えるようになってから）に出す。ここでは検出のみ。
$CONF_NUM = @('interval', 'stopat', 'duration')
$CONF_TXT = @('out', 'label')
$CONF_ENUM = @{ keepawake = @('on', 'off'); lang = @('ja', 'en') }
$CONF_DENY = @('mode', 'note')

function Read-Conf($path) {
  $map = @{}; $issues = @()
  $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
  for ($i = 0; $i -lt $lines.Count; $i++) {
    # Get-Content -Encoding UTF8 でも先頭に BOM(U+FEFF)が残る場合がある
    $ln = ([string]$lines[$i]).Replace([string][char]0xFEFF, '').Trim()
    if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
    $kv = $ln -split '=', 2
    if ($kv.Count -lt 2) { $issues += @{ kind = 'syntax'; key = $ln; line = ($i + 1) }; continue }
    $k = $kv[0].Trim().ToLower(); $v = $kv[1].Trim()
    if ($CONF_DENY -contains $k) { $issues += @{ kind = 'perRun'; key = $k; line = ($i + 1) }; continue }
    if (-not (($CONF_NUM + $CONF_TXT + @($CONF_ENUM.Keys)) -contains $k)) {
      $issues += @{ kind = 'unknown'; key = $k; line = ($i + 1) }; continue
    }
    if ($CONF_NUM -contains $k) {
      $d = 0.0
      $ok = [double]::TryParse($v, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)
      if (-not $ok) { $issues += @{ kind = 'badNumber'; key = $k; val = $v; line = ($i + 1); fatal = $true }; continue }
      $map[$k] = $d
    } elseif ($CONF_ENUM.Keys -contains $k) {
      $allow = $CONF_ENUM[$k]
      if ($allow -notcontains $v.ToLower()) {
        $issues += @{ kind = 'badEnum'; key = $k; val = $v; allow = ($allow -join '|'); line = ($i + 1); fatal = $true }; continue
      }
      $map[$k] = $v.ToLower()
    } else {
      if ($v -eq '') { $issues += @{ kind = 'empty'; key = $k; line = ($i + 1) }; continue }
      $map[$k] = $v
    }
  }
  return [pscustomobject]@{ map = $map; issues = @($issues) }
}

$script:confPath = ''
$script:confKeys = @()
$script:confIssues = @()
$script:confFatal = $null
if ($Conf) {
  $script:confPath = if ([System.IO.Path]::IsPathRooted($Conf)) { $Conf } else { Join-Path $PSScriptRoot $Conf }
} else {
  $dc = Join-Path $PSScriptRoot 'wattlog.conf'
  if (Test-Path -LiteralPath $dc) { $script:confPath = $dc }
}
if ($script:confPath) {
  if (Test-Path -LiteralPath $script:confPath -PathType Container) {
    # `-Conf conf` のようにディレクトリを渡されたとき、Get-Content の例外をそのまま出さない
    $script:confFatal = @{ key = 'err.confDir'; arg = $script:confPath }
  } elseif (-not (Test-Path -LiteralPath $script:confPath)) {
    $script:confFatal = @{ key = 'err.confNoFile'; arg = $script:confPath }
  } else {
    $c = Read-Conf $script:confPath
    $script:confIssues = $c.issues
    $pnOf = @{ interval = 'Interval'; stopat = 'StopAt'; duration = 'Duration'; out = 'Out';
               label = 'Label'; keepawake = 'KeepAwake'; lang = 'Lang' }
    foreach ($k in ($c.map.Keys | Sort-Object)) {
      $pn = $pnOf[$k]
      # CLIで明示した値は設定ファイルより優先（上書きしない）
      if ($PSBoundParameters.ContainsKey($pn)) { continue }
      Set-Variable -Name $pn -Value $c.map[$k] -Scope Script
      $script:confKeys += $k
    }
  }
}

function Fmt($v, $d) {
  if ($null -eq $v -or [double]::IsNaN([double]$v)) { return '' }
  return ([double]$v).ToString("F$d", $inv)
}
function FmtDur($sec) {
  if ($null -eq $sec -or [double]::IsNaN([double]$sec)) { return '-' }
  $s = [long][math]::Round([double]$sec)
  if ($s -lt 0) { $s = 0 }
  $h = [long][math]::Floor($s / 3600)
  $m = [long][math]::Floor(($s % 3600) / 60)
  $ss = [long]($s % 60)
  if ($h -gt 0) { return (T 'dur.hm' @($h, $m)) }
  if ($m -gt 0) { return (T 'dur.ms' @($m, $ss)) }
  return (T 'dur.s' $ss)
}
function Esc($s) {
  return ([string]$s).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}
function JsStr($s) {
  $t = [string]$s
  $t = $t.Replace('\', '\\').Replace('"', '\"').Replace("`r", ' ').Replace("`n", ' ')
  return '"' + $t + '"'
}
# ---------- 停止理由（CSV には機械可読コードで保存 / 文言は生成時に引く） ----------
# 保存行: `# stop: <code> k=v k=v`。文言を CSV に焼くと後から言語差し替えが出来ないため
# コードのみ永続化し、ラベルはここで毎回組み立てる（-FromCsv で復元できる＝再生成で失わない）。
function ArgOf($a, $k) { if ($a -and $a.ContainsKey($k)) { return $a[$k] } return '-' }
function Stop-Label($code, $a) {
  if (-not $code) { return (T 'stop.unknown' '-') }
  switch ($code) {
    'threshold_discharge' { return (T 'stop.th_dis' @((ArgOf $a 'pct'), (ArgOf $a 'stopat'))) }
    'threshold_charge'    { return (T 'stop.th_chg' @((ArgOf $a 'pct'), (ArgOf $a 'stopat'))) }
    'charge_done'         { return (T 'stop.chg_done' (ArgOf $a 'pct')) }
    'full_from_start'     { return (T 'stop.full_start' (ArgOf $a 'pct')) }
    'duration'            { return (T 'stop.duration' @((FmtDur ([double](ArgOf $a 'elapsed_s'))), (ArgOf $a 'minutes'))) }
    'running'             { return (T 'stop.running') }
    'missing'             { return (T 'stop.missing') }
    default               { return (T 'stop.unknown' $code) }
  }
}
function Stop-Line($code, $a) {
  if (-not $code) { return '' }
  $t = ''
  if ($a) { $t = ' ' + (($a.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') }
  return "# stop: $code$t"
}
function Stop-Parse($line) {
  $code = ($line -replace '^#\s*stop:\s*', '').Trim()
  $toks = @($code -split '\s+' | Where-Object { $_ -ne '' })
  $args2 = @{}
  if ($toks.Count -gt 1) {
    for ($i = 1; $i -lt $toks.Count; $i++) {
      if ($toks[$i] -match '^([^=]+)=(.*)$') { $args2[$Matches[1]] = $Matches[2] }
    }
  }
  return @($toks[0], $args2)
}
function TsLabel($d) { return $d.ToString('yyyyMMdd-HHmmss', $inv) }
function IsoLocal($d) { return $d.ToString('yyyy-MM-ddTHH:mm:ss', $inv) }
# 有効値とその出所を CSV 先頭に機械可読で残す（# params:）。
# 設定ファイル導入後は「この計測どの設定で回したか」がコマンドラインだけでは復元できないため。
function Params-Line {
  $p = "mode=$Mode interval=$(Fmt $Interval 1) stopat=$(Fmt $StopAt 1)"
  if ($Duration -gt 0) { $p += " duration=$(Fmt $Duration 1)" }
  $p += " keepawake=$KeepAwake lang=$script:Lang"
  if ($script:src['label'] -ne 'default' -and $Label) { $p += " label=$Label" }
  if ($script:src['out'] -ne 'default' -and $Out) { $p += " out=$Out" }
  # 既定値でないものだけ（mode はファイル名に出る）
  $ov = @($script:src.GetEnumerator() | Where-Object { $_.Value -ne 'default' -and $_.Key -ne 'mode' } |
          Sort-Object Key | ForEach-Object { "$($_.Key):$($_.Value)" })
  if ($ov.Count -gt 0) { $p += " source=$($ov -join ' ')" }
  return "# params: $p"
}
# 設定ファイルが効いた計測なら、そのパスをCSVに残す（source=k:conf だけではどのファイルか復元できない）
function Config-Line {
  if ($script:confKeys.Count -eq 0) { return '' }
  return "# config: $script:confPath"
}

# ---------- 言語テーブル（-Lang en|ja / 既定は OS の表示言語） ----------
# 文言はここに一元化する。CSV には日本語を焼かずコードのみ保存（Stop-Label は $L を参照）。
$script:Lang = if ($Lang) { $Lang.ToLower() }
               elseif ((Get-UICulture).Name -match '^ja') { 'ja' } else { 'en' }
if ($script:Lang -ne 'ja' -and $script:Lang -ne 'en') { $script:Lang = 'en' }
$script:L = if ($script:Lang -eq 'ja') {
  @{
    'menu.title'      = 'wattlog: 計測を選んでください'
    'menu.disLevel'   = '  1) 放電（バッテリー駆動）: 残量 {0}%{1} で自動停止'
    'menu.disTime'    = '  2) 放電（バッテリー駆動）: 時間を指定して自動停止／残量 {0}%{1} に達したらその時点で終了'
    'menu.chgLevel'   = '  3) 充電（電源接続）: 残量 {0}%{1} または充電完了で自動停止'
    'menu.chgTime'    = '  4) 充電（電源接続）: 時間を指定して自動停止／残量 {0}%{1}・充電完了でその時点で終了'
    'menu.pick'       = '番号（1-4）'
    'menu.pickBad'    = '番号は 1-4 のいずれかです。1) 放電（残量停止）で開始します'
    'menu.note'       = '計測条件のメモ（音量/WiFi/バックグラウンド等。電源プラン・輝度は自動取得）'
    'menu.notePrompt' = 'メモ（Enter でスキップ）'
    'menu.duration'   = '自動停止する経過時間（分）。Enter で時間停止なし（残量閾値で停止）'
    'menu.durationPrompt' = '分（Enter でスキップ）'
    'menu.durationBad' = '入った値が分数ではありません: {0}（数字だけで入力。Enter だけなら時間停止なし）'
    'err.duration'    = '経過時間が3回数字ではありませんでした（{0}）。計測を開始せず終了します'
    'src.default'     = '（既定）'
    'src.conf'        = '（設定ファイル）'
    'src.cli'         = '（CLI引数）'
    'err.mode'        = '--Mode は discharge|charge'
    'err.keepAwake'   = '-KeepAwake は on|off'
    'err.confNoFile'  = '設定ファイルが見つかりません: {0}'
    'err.confDir'     = '設定ファイルのパスがディレクトリです: {0}'
    'conf.loaded'     = '設定ファイル: {0}（適用: {1}）'
    'conf.syntax'     = '設定ファイル {0}行目: key=value 形式でないので無視 ({1})'
    'conf.unknown'    = '設定ファイル {0}行目: 不明な鍵 ''{1}'' を無視'
    'conf.perRun'     = '設定ファイル {0}行目: {1} は計測回ごとの条件なので設定ファイルでは固定できません（起動時に聞きます）'
    'conf.badNumber'  = '設定ファイル {0}行目: {1} の値が数値ではありません: {2}'
    'conf.badEnum'    = '設定ファイル {0}行目: {1} は {2} のいずれかです: {3}'
    'conf.empty'      = '設定ファイル {0}行目: {1} が空なので無視'
    'cond.plan'       = '電源プラン={0}'
    'cond.bright'     = '輝度={0}%'
    'cond.brightNa'   = '輝度=取得不可'
    'cond.na'         = '不明'
    'cond.none'       = '（条件記録なし）'
    'stop.th_dis'     = '残量 {0}% が停止閾値 {1}% 以下'
    'stop.th_chg'     = '残量 {0}% が停止閾値 {1}% 以上'
    'stop.chg_done'   = '残量 {0}% / 充電完了（充電フラグOFF）'
    'stop.full_start' = '残量 {0}% / 満充電（充電不要・開始時から）'
    'stop.duration'   = '経過 {0} が指定時間 {1} 分に到達'
    'stop.running'    = '計測中'
    'stop.missing'    = '（このCSVに停止理由の記録なし＝強制終了の可能性）'
    'stop.unknown'    = '停止コード {0}'
    'csv.noDev'       = '（このCSVに端末情報記録なし）'
    'csv.regen'       = '/ CSV から再生成'
    'err.noCsv'       = 'CSV が見つかりません: {0}'
    'err.noRows'      = 'CSV にデータ行がありません: {0}'
    'html.regen'      = 'HTML 再生成: {0}'
    'sum.samples'     = 'サンプル数 {0} / モード {1} / 残量 {2}%→{3}% / 累積 {4} Wh'
    'dur.hm'          = '{0}時間{1}分'
    'dur.ms'          = '{0}分{1}秒'
    'dur.s'           = '{0}秒'
    'dev.threads'     = '({0}コア{1}スレッド)'
    'dev.display'     = '表示 {0}'
    'dev.npuNone'     = 'NPU なし'
    'dev.cycles'      = 'サイクル {0}回'
    'dev.unavail'     = '（端末情報 取得不可）'
    'svg.empty'       = 'データなし'
    'svg.sep'         = ' ・ '
    'card.model'      = '機種'
    'card.device'     = '端末情報'
    'card.cond'       = '計測条件'
    'w.note'          = '移動中央値 約{0}秒'
    'w.clip'          = '（上限は99パーセンタイルでクリップ）'
    'chart.pct'       = '残量'
    'chart.w'         = '瞬時消費電力'
    'chart.wh'        = '累積消費電力量'
    'page.h1'         = 'wattlog 計測結果'
    'page.sub'        = 'システム全体の消費電力と残量の推移 / 生成 {0}'
    'sum.loading'     = '区間を集計中…'
    'btn.copy'        = 'サマリをコピー'
    'btn.shot'        = 'スクショ用'
    'btn.shotTip'     = '左カラムのスクロールを解除し操作UIを隠します。Escで戻ります'
    'btn.copyTbl'     = '表をコピー'
    'btn.copyTblHtml' = 'HTMLコピー'
    'tile.avgw'       = '平均 W'
    'tile.wh'         = '累積 Wh'
    'tile.perpt'      = '1%あたり'
    'meta.open'       = '計測情報（クリックで開閉）'
    'meta.mode'       = 'モード'
    'meta.start'      = '開始'
    'meta.end'        = '終了'
    'meta.samples'    = 'サンプル数'
    'meta.elapsed'    = '経過'
    'meta.interval'   = '間隔'
    'meta.pctStart'   = '開始残量'
    'meta.pctEnd'     = '終了残量'
    'meta.pctDelta'   = '残量変化'
    'meta.cumWh'      = '累積Wh'
    'meta.avgW'       = '平均W'
    'meta.stop'       = '停止理由'
    'meta.fullWh'     = '満充電容量'
    'meta.wsrc'       = 'W取得経路'
    'tbl.title'       = '経過時間と電池残量'
    'tbl.unit'        = '(記事貼り付け用の表)'
    'tbl.step'        = '間隔:'
    'tbl.s15'         = '15分'
    'tbl.s30'         = '30分'
    'tbl.s1h'         = '1時間'
    'tbl.loading'     = '表を描画中…'
    'foot'            = 'wattlog 第1段 / ゼロインストール・インラインSVG。この HTML 単体で開いてスクリーンショット可能。'
    'wsrc.note'       = 'rate(直接)={0} / pct(算出)={1} / 取得不可={2}'
    'run.start'       = 'wattlog 開始: mode={0} interval={1}s stop-at={2}%{3}'
    'run.keepawake'   = 'keep-awake: on (set_ret={0}。アイドルスリープ防止 / 蓋閉じは未検証・powercfg LIDACTION が確実)'
    'run.out'         = '出力先: {0}'
    'run.sample'      = '[{0,5}s] 残量 {1} | W {2} ({3}) | 累積 {4} Wh | {5}{6}'
    'run.charging'    = ' 充電中'
    'run.measuring'   = '計測中'
    'run.stop'        = '停止理由: {0}'
    'run.samples'     = 'サンプル数: {0} / 経過: {1} s'
    'run.level'       = '残量: {0}% → {1}% ({2} pt)'
    'run.cum'         = '累積: {0} Wh / 平均: {1} W / keep-awake clear_ret={2}'
    'run.wsrc'        = 'W取得経路: {0}'
    'run.close'       = 'Enter でウィンドウを閉じます'
  }
} else {
  @{
    'menu.title'      = 'wattlog: choose a measurement'
    'menu.disLevel'   = '  1) Discharge (on battery): auto-stops at {0}% remaining{1}'
    'menu.disTime'    = '  2) Discharge (on battery): stop after N minutes (ends early at {0}%){1}'
    'menu.chgLevel'   = '  3) Charge (plugged in): auto-stops at {0}% or when charging completes{1}'
    'menu.chgTime'    = '  4) Charge (plugged in): stop after N minutes (ends early at {0}% or charge complete){1}'
    'menu.pick'       = 'Number (1-4)'
    'menu.pickBad'    = 'Please enter 1-4. Starting with 1) Discharge (level stop)'
    'menu.note'       = 'Test conditions note (volume/WiFi/background). Power plan & brightness are captured automatically.'
    'menu.notePrompt' = 'Note (Enter to skip)'
    'menu.duration'   = 'Auto-stop after N minutes. Enter for no time limit (stops at the level threshold)'
    'menu.durationPrompt' = 'Minutes (Enter to skip)'
    'menu.durationBad' = 'Not a number of minutes: {0} (digits only; Enter alone = no time limit)'
    'err.duration'    = 'Minutes input was not a number 3 times ({0}). Aborted before measuring'
    'src.default'     = ' (default)'
    'src.conf'        = ' (config file)'
    'src.cli'         = ' (CLI)'
    'err.mode'        = '--Mode must be discharge|charge'
    'err.keepAwake'   = '-KeepAwake must be on|off'
    'err.confNoFile'  = 'Config file not found: {0}'
    'err.confDir'     = 'Config path is a directory: {0}'
    'conf.loaded'     = 'Config file: {0} (applied: {1})'
    'conf.syntax'     = 'Config line {0}: not a key=value pair, ignored ({1})'
    'conf.unknown'    = 'Config line {0}: unknown key ''{1}'', ignored'
    'conf.perRun'     = 'Config line {0}: {1} is a per-run condition and cannot be set here (you will be asked at startup)'
    'conf.badNumber'  = 'Config line {0}: {1} is not a number: {2}'
    'conf.badEnum'    = 'Config line {0}: {1} must be one of {2}: {3}'
    'conf.empty'      = 'Config line {0}: {1} is empty, ignored'
    'cond.plan'       = 'Power plan={0}'
    'cond.bright'     = 'Brightness={0}%'
    'cond.brightNa'   = 'Brightness=unavailable'
    'cond.na'         = 'unknown'
    'cond.none'       = '(no conditions recorded)'
    'stop.th_dis'     = 'Level {0}% reached the stop threshold {1}%'
    'stop.th_chg'     = 'Level {0}% reached the stop threshold {1}%'
    'stop.chg_done'   = 'Level {0}% / charge complete (charging flag off)'
    'stop.full_start' = 'Level {0}% / full from the start (no charging needed)'
    'stop.duration'   = 'Elapsed {0} reached the {1} min limit'
    'stop.running'    = 'Measuring'
    'stop.missing'    = '(no stop reason in this CSV = possibly killed)'
    'stop.unknown'    = 'Stop code {0}'
    'csv.noDev'       = '(no device info in this CSV)'
    'csv.regen'       = '/ rebuilt from CSV'
    'err.noCsv'       = 'CSV not found: {0}'
    'err.noRows'      = 'No data rows in CSV: {0}'
    'html.regen'      = 'HTML rebuilt: {0}'
    'sum.samples'     = 'Samples {0} / mode {1} / level {2}%->{3}% / {4} Wh'
    'dur.hm'          = '{0}h {1}m'
    'dur.ms'          = '{0}m {1}s'
    'dur.s'           = '{0}s'
    'dev.threads'     = '({0} cores, {1} threads)'
    'dev.display'     = 'Display {0}'
    'dev.npuNone'     = 'NPU none'
    'dev.cycles'      = 'Cycles {0}'
    'dev.unavail'     = '(device info unavailable)'
    'svg.empty'       = 'No data'
    'svg.sep'         = ' · '
    'card.model'      = 'Model'
    'card.device'     = 'Device'
    'card.cond'       = 'Conditions'
    'w.note'          = 'Moving median ~{0}s'
    'w.clip'          = '(peak clipped at the 99th percentile)'
    'chart.pct'       = 'Battery level'
    'chart.w'         = 'Instant power'
    'chart.wh'        = 'Cumulative energy'
    'page.h1'         = 'wattlog report'
    'page.sub'        = 'Whole-system power draw and battery level / generated {0}'
    'sum.loading'     = 'Summarizing…'
    'btn.copy'        = 'Copy summary'
    'btn.shot'        = 'Screenshot mode'
    'btn.shotTip'     = 'Unlocks the left column and hides the controls. Press Esc to exit'
    'btn.copyTbl'     = 'Copy table'
    'btn.copyTblHtml' = 'Copy HTML'
    'tile.avgw'       = 'Avg W'
    'tile.wh'         = 'Cumulative Wh'
    'tile.perpt'      = 'Per 1%'
    'meta.open'       = 'Measurement info (click to toggle)'
    'meta.mode'       = 'Mode'
    'meta.start'      = 'Start'
    'meta.end'        = 'End'
    'meta.samples'    = 'Samples'
    'meta.elapsed'    = 'Elapsed'
    'meta.interval'   = 'Interval'
    'meta.pctStart'   = 'Start level'
    'meta.pctEnd'     = 'End level'
    'meta.pctDelta'   = 'Level change'
    'meta.cumWh'      = 'Cumulative Wh'
    'meta.avgW'       = 'Avg W'
    'meta.stop'       = 'Stop reason'
    'meta.fullWh'     = 'Full-charge capacity'
    'meta.wsrc'       = 'W source'
    'tbl.title'       = 'Elapsed time and battery level'
    'tbl.unit'        = '(paste-ready table)'
    'tbl.step'        = 'Step:'
    'tbl.s15'         = '15 min'
    'tbl.s30'         = '30 min'
    'tbl.s1h'         = '1 hour'
    'tbl.loading'     = 'Rendering table…'
    'foot'            = 'wattlog / zero-install inline SVG. Open this single HTML file and take screenshots.'
    'wsrc.note'       = 'rate(direct)={0} / pct(computed)={1} / unavailable={2}'
    'run.start'       = 'wattlog start: mode={0} interval={1}s stop-at={2}%{3}'
    'run.keepawake'   = 'keep-awake: on (set_ret={0}; prevents idle sleep / lid-close untested - powercfg LIDACTION is reliable)'
    'run.out'         = 'Output dir: {0}'
    'run.sample'      = '[{0,5}s] level {1} | W {2} ({3}) | cum {4} Wh | {5}{6}'
    'run.charging'    = ' charging'
    'run.measuring'   = 'Measuring'
    'run.stop'        = 'Stop reason: {0}'
    'run.samples'     = 'Samples: {0} / elapsed: {1} s'
    'run.level'       = 'Level: {0}% -> {1}% ({2} pt)'
    'run.cum'         = 'Cumulative: {0} Wh / avg: {1} W / keep-awake clear_ret={2}'
    'run.wsrc'        = 'W source: {0}'
    'run.close'       = 'Press Enter to close the window'
  }
}
function T($key, $vals) { $f = $script:L[$key]; if ($null -eq $f) { return $key }; if ($vals) { return ($f -f $vals) } return $f }

# ---------- JS用UI文言（HTML内で var UI として注入） ----------
# $script:JSUI は単一引用ヒアストリング（補間不可）なので、言語テーブルをJSONで渡し、
# JS側は UI.key を参照する。tf() は {0}{1}… 置換ヘルパー。
$script:LJS = if ($script:Lang -eq 'ja') {
  @{
    'def'        = '始点クリック→終点クリックで区間統計（ドラッグでも可） / ホバー=値読取 / ダブルクリック=解除'
    'durHm'      = '{0}時間{1}分'
    'durH'       = '{0}時間'
    'durMs'      = '{0}分{1}秒'
    'durM'       = '{0}分'
    'durS'       = '{0}秒'
    'seg'        = '区間'
    'avg'        = '平均'
    'consume'    = '消費'
    'recover'    = '回復'
    'fullEst'    = '満充電→0%の推定'
    'chipCharge' = '充電'
    'chipDis'    = '放電'
    'copied'     = 'コピーしました'
    'copyFail'   = 'コピー失敗'
    'copySum'    = 'サマリをコピー'
    'sumHead'    = 'wattlog 計測サマリ'
    'lMode'      = 'モード'
    'lStart'     = '開始'
    'lEnd'       = '終了'
    'lElapsed'   = '経過'
    'lLevel'     = '残量'
    'lAvgW'      = '平均消費電力'
    'lCum'       = '累積'
    'lStop'      = '停止理由'
    'lDev'       = '端末'
    'lCond'      = '計測条件'
    'hover'      = '{0} | 残量 {1}% | {2} W | 累積 {3} Wh'
    'anchor'     = '始点 {0} を設定。終点をクリック（ダブルクリックで取消）'
    'stats'      = '区間 {0} | 平均 {1} W | Δ% {2} = {3} %/h | ΔWh {4} = {5} Wh/h | n={6}'
    'thStart'    = '開始'
    'thEnd'      = '終了'
    'thPct'      = '電池残量'
    'thPctChg'   = '残量表示'
    'thDiffDn'   = '減少差'
    'thDiffUp'   = '回復差'
    'btnTbl'     = '表をコピー'
    'btnTblHtml' = 'HTMLコピー'
    'toast'      = 'スクショ用モードです。撮影後 Esc で解除'
  }
} else {
  @{
    'def'        = 'Click the start then the end for segment stats (drag also works) / hover = read values / double-click = clear'
    'durHm'      = '{0}h {1}m'
    'durH'       = '{0}h'
    'durMs'      = '{0}m {1}s'
    'durM'       = '{0}m'
    'durS'       = '{0}s'
    'seg'        = 'Segment'
    'avg'        = 'avg'
    'consume'    = 'drain'
    'recover'    = 'gain'
    'fullEst'    = 'Estimated full->0%'
    'chipCharge' = 'Charging'
    'chipDis'    = 'Discharge'
    'copied'     = 'Copied'
    'copyFail'   = 'Copy failed'
    'copySum'    = 'Copy summary'
    'sumHead'    = 'wattlog summary'
    'lMode'      = 'Mode'
    'lStart'     = 'Start'
    'lEnd'       = 'End'
    'lElapsed'   = 'Elapsed'
    'lLevel'     = 'Level'
    'lAvgW'      = 'Avg power'
    'lCum'       = 'cum'
    'lStop'      = 'Stop reason'
    'lDev'       = 'Device'
    'lCond'      = 'Conditions'
    'hover'      = '{0} | level {1}% | {2} W | cum {3} Wh'
    'anchor'     = 'Start {0} set. Click the end point (double-click to cancel)'
    'stats'      = 'Segment {0} | avg {1} W | Δ% {2} = {3} %/h | ΔWh {4} = {5} Wh/h | n={6}'
    'thStart'    = 'Start'
    'thEnd'      = 'End'
    'thPct'      = 'Battery'
    'thPctChg'   = 'Level shown'
    'thDiffDn'   = 'Drop'
    'thDiffUp'   = 'Gain'
    'btnTbl'     = 'Copy table'
    'btnTblHtml' = 'Copy HTML'
    'toast'      = 'Screenshot mode. Press Esc when done'
  }
}

# ---------- 設定ファイルの結果を報告（ここで T が使える） ----------
if ($script:confFatal) { Write-Host (T $script:confFatal.key $script:confFatal.arg); exit 2 }
$confFatalIssue = $false
foreach ($it in $script:confIssues) {
  switch ($it.kind) {
    'syntax'    { Write-Host (T 'conf.syntax'    @(($it.line), ($it.key))) }
    'unknown'   { Write-Host (T 'conf.unknown'   @(($it.line), ($it.key))) }
    'perRun'    { Write-Host (T 'conf.perRun'    @(($it.line), ($it.key))) }
    'empty'     { Write-Host (T 'conf.empty'     @(($it.line), ($it.key))) }
    'badNumber' { Write-Host (T 'conf.badNumber' @(($it.line), ($it.key), ($it.val))); $confFatalIssue = $true }
    'badEnum'  { Write-Host (T 'conf.badEnum' @(($it.line), ($it.key), ($it.allow), ($it.val))); $confFatalIssue = $true }
  }
}
if ($confFatalIssue) { exit 2 }
if ($script:confKeys.Count -gt 0) {
  Write-Host (T 'conf.loaded' @(($script:confPath), ($script:confKeys -join ' ')))
}

# 各有効値の出所（CLI / conf / menu / default）# params: 行の source= に入る
$PN2K = @{ Interval = 'interval'; StopAt = 'stopat'; Duration = 'duration'; Out = 'out';
           Label = 'label'; KeepAwake = 'keepawake'; Lang = 'lang' }
$script:src = @{ mode = 'default' }
foreach ($k in $PN2K.Values) { $script:src[$k] = 'default' }
foreach ($pn in $PN2K.Keys) { if ($PSBoundParameters.ContainsKey($pn)) { $script:src[$PN2K[$pn]] = 'cli' } }
if ($PSBoundParameters.ContainsKey('Mode')) { $script:src['mode'] = 'cli' }
foreach ($k in $script:confKeys) { $script:src[$k] = 'conf' }

# ---------- 起動モード ----------
$showMenu = $false
# 設定ファイル/CLIで決まった項目はメニューで聞かない（Enterで既定、の入力負担を減らす）
$durationSet = ($PSBoundParameters.ContainsKey('Duration')) -or ($script:confKeys -contains 'duration')
if (-not $FromCsv) {
if (-not $Mode) {
  $showMenu = $true
  # 表示する閾値は実効値と同じ規則で先に出す（既定10/100、conf/CLI指定なら共用値）
  $stopTag = switch ($script:src['stopat']) { 'cli' { T 'src.cli' } 'conf' { T 'src.conf' } default { T 'src.default' } }
  $disShown = if ($StopAt -ge 0) { $StopAt } else { 10 }
  $chgShown = if ($StopAt -ge 0) { $StopAt } else { 100 }
  Write-Host (T 'menu.title')
  Write-Host (T 'menu.disLevel' @((Fmt $disShown 1), $stopTag))
  Write-Host (T 'menu.disTime'  @((Fmt $disShown 1), $stopTag))
  Write-Host (T 'menu.chgLevel' @((Fmt $chgShown 1), $stopTag))
  Write-Host (T 'menu.chgTime'  @((Fmt $chgShown 1), $stopTag))
  $k = (Read-Host (T 'menu.pick')).Trim()
  if (@('1', '2', '3', '4') -notcontains $k) { Write-Host (T 'menu.pickBad'); $k = '1' }
  $Mode = if ($k -eq '3' -or $k -eq '4') { 'charge' } else { 'discharge' }
  $script:src['mode'] = 'menu'
  # 時間入力を聞くのは 2)/4) を選んだときだけ（1)/3) は残量停止のみ）
  # 数字以外は無視して黙って走らせない（=「指定したはずの時間停止が効いていない」事故）。
  # Enter だけは「時間停止なし」の明示選択なので即確定。
  if (($k -eq '2' -or $k -eq '4') -and -not $durationSet) {
    Write-Host (T 'menu.duration')
    $bad = 0
    while ($true) {
      $ans = (Read-Host (T 'menu.durationPrompt')).Trim()
      if ($ans -eq '') { break }
      $dv = 0.0
      if ([double]::TryParse($ans, [System.Globalization.NumberStyles]::Float, $inv, [ref]$dv) -and $dv -gt 0) {
        $Duration = $dv
        $script:src['duration'] = 'menu'
        break
      }
      $bad++
      if ($bad -ge 3) { Write-Host (T 'err.duration' $ans); exit 2 }
      Write-Host (T 'menu.durationBad' $ans)
    }
  }
  if (-not $Note) {
    Write-Host (T 'menu.note')
    $Note = Read-Host (T 'menu.notePrompt')
  }
}
$Mode = $Mode.ToLower()
if ($Mode -ne 'discharge' -and $Mode -ne 'charge') { Write-Host (T 'err.mode'); exit 2 }
if ($Interval -le 0) { $Interval = 5 }
if ($StopAt -lt 0) { $StopAt = if ($Mode -eq 'discharge') { 10 } else { 100 } }
if ($KeepAwake -ne 'on' -and $KeepAwake -ne 'off') { Write-Host (T 'err.keepAwake'); exit 2 }
}

# ---------- バッテリー読み取り（プロセス内CIM・起動オーバーヘッドなし） ----------
function Read-Battery {
  $st = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue)
  $fu = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue)
  $w  = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
  $rem = 0.0; $full = 0.0; $ch = 0.0; $di = 0.0; $charging = $false; $online = $false
  foreach ($s in $st) {
    if ($s.RemainingCapacity) { $rem += [double]$s.RemainingCapacity }
    if ($s.ChargeRate) { $ch += [double]$s.ChargeRate }
    if ($s.DischargeRate) { $di += [double]$s.DischargeRate }
    if ($s.Charging) { $charging = $true }
    if ($s.PowerOnline) { $online = $true }
  }
  foreach ($s in $fu) { if ($s.FullChargedCapacity) { $full += [double]$s.FullChargedCapacity } }
  $est = $null
  foreach ($x in $w) { if ($x.EstimatedChargeRemaining -ne $null) { $est = [double]$x.EstimatedChargeRemaining; break } }
  return [pscustomobject]@{
    remaining_mwh = $rem; full_mwh = $full; charge_mw = $ch; discharge_mw = $di
    charging = $charging; power_online = $online; estimated_pct = $est
  }
}

# ---------- keep-awake（プロセス内で保持、終了時に解放） ----------
$esSet = 0; $esClear = 0
if (-not ('Wattlog.K32' -as [type])) {
  Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -Name 'K32' -Namespace 'Wattlog' | Out-Null
}
if ($KeepAwake -eq 'on' -and -not $FromCsv) {
  # 2147483649 = ES_CONTINUOUS|ES_SYSTEM_REQUIRED（16進リテラルはPSで溢れるため10進）
  $esSet = [Wattlog.K32]::SetThreadExecutionState([uint32]2147483649)
}
function Stop-KeepAwake {
  if ($KeepAwake -eq 'on') { $script:esClear = [Wattlog.K32]::SetThreadExecutionState([uint32]2147483648) }
}

# ---------- 計測条件（電源プラン・輝度を自動取得 / -Note を併記） ----------
function Get-Conditions {
  $plan = T 'cond.na'
  try {
    $s = (& powercfg /getactivescheme) -join ' '
    $m = [regex]::Matches($s, '\(([^)]+)\)')
    if ($m.Count -gt 0) { $plan = $m[$m.Count - 1].Groups[1].Value }
  } catch {}
  $bright = $null
  try {
    $b = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue)
    foreach ($x in $b) { if ($null -ne $x.CurrentBrightness) { $bright = [int]$x.CurrentBrightness; break } }
  } catch {}
  $parts = @((T 'cond.plan' $plan))
  $parts += if ($null -ne $bright) { (T 'cond.bright' $bright) } else { (T 'cond.brightNa') }
  $auto = $parts -join ', '
  if ($Note) { return "$auto / $Note" } else { return $auto }
}

# ---------- 端末情報（開始時に1回だけ取得・非管理者で読める範囲 / 読めない項目は黙って省略） ----------
function CleanName($s) { return (("$s") -replace '\(R\)|\(TM\)|\(C\)', '' -replace '\s+', ' ').Trim() }
function Get-DeviceInfo {
  $p = @()
  $name = $null
  try {
    $bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction SilentlyContinue
    # Lenovo等は SystemProductName が型番コード(例: 81HH)で、読みやすい機種名は SystemVersion/SystemFamily 側にある
    foreach ($k in @('SystemVersion', 'SystemFamily', 'SystemProductName')) {
      $v = CleanName $bios.$k
      if ($v -and $v -match '\s' -and -not $name) { $name = $v }
    }
    if (-not $name) { $name = CleanName $bios.SystemProductName }
  } catch {}
  if (-not $name) {
    try {
      $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
      $name = CleanName "$($cs.Manufacturer) $($cs.Model)"
    } catch {}
  }
  if ($name) { $p += $name }
  try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $p += ((CleanName ($os.Caption -replace '^Microsoft ', '')) + ' Build ' + $os.BuildNumber)
  } catch {}
  try {
    $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
    if ($cpu) { $p += ('CPU ' + (CleanName $cpu.Name) + ' ' + (T 'dev.threads' @($cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors))) }
  } catch {}
  try {
    $ram = [math]::Round(((Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object Capacity -Sum).Sum) / 1GB)
    if ($ram -gt 0) { $p += "RAM ${ram}GB" }
  } catch {}
  try {
    $g = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
    $gn = @($g | ForEach-Object { CleanName $_.Name } | Where-Object { $_ })
    if ($gn.Count -gt 0) { $p += ('GPU ' + ($gn -join ' + ')) }
    $res = @($g | Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
      ForEach-Object { "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)@$($_.CurrentRefreshRate)Hz" })
    if ($res.Count -gt 0) { $p += (T 'dev.display' ($res -join ' + ')) }
  } catch {}
  try {
    $pd = @(Get-PhysicalDisk -ErrorAction Stop)
    $ssd = @($pd | Where-Object { $_.MediaType -eq 'SSD' }).Count
    $hdd = @($pd | Where-Object { $_.MediaType -eq 'HDD' }).Count
    $dsk = @(); if ($ssd -gt 0) { $dsk += "SSD${ssd}" }; if ($hdd -gt 0) { $dsk += "HDD${hdd}" }
    if ($dsk.Count -gt 0) { $p += ('Disk ' + ($dsk -join '+')) }
  } catch {}
  try {
    $npu = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
      Where-Object { $_.Name -match '(?i)\bNPU\b|Hexagon|XDNA|AI Boost|Neural Processing' })
    if ($npu.Count -gt 0) {
      $p += ('NPU ' + (($npu | ForEach-Object { CleanName $_.Name } | Select-Object -Unique) -join ' + '))
    } else { $p += (T 'dev.npuNone') }
  } catch {}
  try {
    $cyc = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue)
    foreach ($c in $cyc) { if ($c.CycleCount -gt 0) { $p += (T 'dev.cycles' $c.CycleCount); break } }
  } catch {}
  if ($p.Count -eq 0) { return (T 'dev.unavail') }
  return $p -join ' / '
}

# ---------- SVG / HTML ----------
function New-SvgChart($Title, $Unit, $Points, $Color, $YFloor = $null, $YCap = $null, $Clip = $false, $Id = '', $Note = '') {
  $W = 920; $H = 280; $ml = 64; $mr = 20; $mt = 16; $mb = 38
  $iw = $W - $ml - $mr; $ih = $H - $mt - $mb
  $valid = @($Points | Where-Object { $null -ne $_.y })
  if ($valid.Count -eq 0) { return "<section><h2>$(Esc $Title)</h2><p class=`"empty`">$(T 'svg.empty')</p></section>" }
  $xMax = 1.0; foreach ($p in $Points) { if ($p.x -gt $xMax) { $xMax = [double]$p.x } }
  $dMin = [double]::MaxValue; $dMax = [double]::MinValue
  foreach ($p in $valid) { if ($p.y -lt $dMin) { $dMin = [double]$p.y }; if ($p.y -gt $dMax) { $dMax = [double]$p.y } }
  if ($dMax -eq $dMin) { $dMax = $dMin + 1 }
  $pad = ($dMax - $dMin) * 0.08
  # 明示的な下限/上限（残量=0..100%、電力=0..99パーセンタイル）があればそれを軸に。無ければデータ±8%
  if ($null -ne $YCap)   { $yMax = [double]$YCap } else { $yMax = $dMax + $pad }
  if ($null -ne $YFloor) { $yMin = [double]$YFloor } else { $yMin = $dMin - $pad }
  if ($yMax -le $yMin) { $yMax = $yMin + 1 }
  $clipDefs = ''
  if ($Clip) { $clipDefs = "<defs><clipPath id=`"clip-$Id`"><rect x=`"$ml`" y=`"$mt`" width=`"$iw`" height=`"$ih`"/></clipPath></defs>" }
  $clipAttr = if ($Clip) { " clip-path=`"url(#clip-$Id)`"" } else { '' }
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -le 5; $i++) {
    $yv = $yMin + ($yMax - $yMin) * $i / 5
    $yy = $mt + $ih - ($yv - $yMin) / ($yMax - $yMin) * $ih
    [void]$sb.Append("<line class=`"grid`" x1=`"$ml`" y1=`"$(Fmt $yy 1)`" x2=`"$($ml+$iw)`" y2=`"$(Fmt $yy 1)`"/>")
    [void]$sb.Append("<text class=`"tick`" x=`"$($ml-8)`" y=`"$(Fmt ($yy+4) 1)`" text-anchor=`"end`">$(Fmt $yv 1)</text>")
    $xv = $xMax * $i / 5
    $xx = $ml + $xv / $xMax * $iw
    $xanchor = if ($i -eq 0) { 'start' } elseif ($i -eq 5) { 'end' } else { 'middle' }
    [void]$sb.Append("<line class=`"grid`" x1=`"$(Fmt $xx 1)`" y1=`"$mt`" x2=`"$(Fmt $xx 1)`" y2=`"$($mt+$ih)`"/>")
    [void]$sb.Append("<text class=`"tick`" x=`"$(Fmt $xx 1)`" y=`"$($mt+$ih+18)`" text-anchor=`"$xanchor`">$(FmtDur $xv)</text>")
  }
  $poly = ''
  foreach ($p in $valid) {
    $px = $ml + [double]$p.x / $xMax * $iw
    $py = $mt + $ih - ([double]$p.y - $yMin) / ($yMax - $yMin) * $ih
    $poly += "$(Fmt $px 1),$(Fmt $py 1) "
  }
  $unitLabel = "($(Esc $Unit))"
  if ($Note) { $unitLabel = "($(Esc $Unit))$(T 'svg.sep')$(Esc $Note)" }
  return @"
<section>
  <h2>$(Esc $Title) <span class="unit">$unitLabel</span></h2>
  <svg viewBox="0 0 $W $H" width="100%" preserveAspectRatio="xMidYMid meet" role="img">
    $clipDefs
    $sb
    <line class="axis" x1="$ml" y1="$mt" x2="$ml" y2="$($mt+$ih)"/>
    <line class="axis" x1="$ml" y1="$($mt+$ih)" x2="$($ml+$iw)" y2="$($mt+$ih)"/>
    <polyline class="line" points="$poly" fill="none" stroke="$Color" stroke-width="2"$clipAttr/>
  </svg>
</section>
"@
}

# ---------- 事後分析UI（HTMLに仕込むインラインJS・計測中には動かない） ----------
$script:JSUI = @'
<script>
(function(){
  var ML=64,MR=20,MT=16,MB=38,W=920,H=280,IW=W-ML-MR,IH=H-MT-MB;
  var tMax=1; DATA.forEach(function(d){ if(d.t>tMax)tMax=d.t; });
  function sx(t){ return ML + t/tMax*IW; }
  var svgs=[].slice.call(document.querySelectorAll('svg'));
  var panel=document.getElementById('selpanel');
  var summary=document.getElementById('summary');
  var DEF=(typeof UI!=='undefined'&&UI.def)?UI.def:'';
  function tf(s){ var a=[].slice.call(arguments,1); return String(s).replace(/\{(\d)\}/g,function(m,i){return a[i];}); }
  function U(k){ return (typeof UI!=='undefined'&&UI[k])?UI[k]:k; }
  var sel=null, drag=null, anchor=null, moved=false, downX=0, shot=false, prevOpen=true;
  function fmt(v,d){ return (v===null||v===undefined||isNaN(v))?'-':v.toFixed(d); }
  function fmtDur(s){
    if(s===null||s===undefined||isNaN(s)) return '-';
    s=Math.max(0,Math.round(s));
    var h=Math.floor(s/3600), m=Math.floor((s%3600)/60), sec=s%60;
    if(h>0) return tf(U('durHm'),h,m);
    if(m>0) return tf(U('durMs'),m,sec);
    return tf(U('durS'),sec);
  }
  function paint(){
    svgs.forEach(function(sv){
      var r=sv.querySelector('.selrect');
      if(!r){ r=document.createElementNS('http://www.w3.org/2000/svg','rect'); r.setAttribute('class','selrect'); r.setAttribute('fill','rgba(15,118,110,.12)'); r.setAttribute('y',MT); r.setAttribute('height',IH); sv.appendChild(r); }
      var hl=sv.querySelector('.hovline');
      if(!hl){ hl=document.createElementNS('http://www.w3.org/2000/svg','line'); hl.setAttribute('class','hovline'); hl.setAttribute('stroke','#8a8a8a'); hl.setAttribute('stroke-dasharray','3 3'); hl.setAttribute('y1',MT); hl.setAttribute('y2',MT+IH); hl.setAttribute('visibility','hidden'); sv.appendChild(hl); }
      if(sel){ var x0=sx(sel[0]),x1=sx(sel[1]); r.setAttribute('x',x0); r.setAttribute('width',Math.max(0,x1-x0)); r.setAttribute('visibility','visible'); }
      else { r.setAttribute('visibility','hidden'); }
    });
  }
  function tOf(svg,ev){
    var b=svg.getBoundingClientRect();
    var x=(ev.clientX-b.left)/b.width*W;
    var t=(x-ML)/IW*tMax; return Math.max(0,Math.min(tMax,t));
  }
  function nearest(t){ var best=DATA[0],bd=1e18; DATA.forEach(function(d){ var dd=Math.abs(d.t-t); if(dd<bd){bd=dd;best=d;} }); return best; }
  function stats(){
    if(!sel){ panel.textContent=DEF; return; }
    var a=sel[0],b=sel[1],ws=[],ps=[],h0=null,h1=null;
    DATA.forEach(function(d){ if(d.t>=a&&d.t<=b){ if(d.w!==null&&d.w!==undefined)ws.push(d.w); if(d.p!==null&&d.p!==undefined)ps.push(d.p); if(h0===null){h0=d.h;} h1=d.h; } });
    var avg= ws.length? ws.reduce(function(x,y){return x+y;},0)/ws.length : null;
    var dp = ps.length>=2? ps[ps.length-1]-ps[0] : null;
    var dwh= (h0!==null&&h1!==null)? h1-h0 : null;
    var hrs=(b-a)/3600;
    var pph=(dp!==null&&hrs>0)? dp/hrs : null;
    var whh=(dwh!==null&&hrs>0)? dwh/hrs : null;
    panel.textContent=tf(U('stats'),fmtDur(b-a),fmt(avg,2),fmt(dp,2),fmt(pph,1),fmt(dwh,3),fmt(whh,2),ws.length);
  }
  function whole(){
    var f=DATA[0], l=DATA[DATA.length-1];
    var span=l.t-f.t, hrs=span/3600;
    var dp=(f.p!==null&&f.p!==undefined&&l.p!==null&&l.p!==undefined)? l.p-f.p : null;
    var pph=(dp!==null&&hrs>0)? dp/hrs : null;
    var ws=[]; DATA.forEach(function(d){ if(d.w!==null&&d.w!==undefined) ws.push(d.w); });
    var avgW=ws.length? ws.reduce(function(x,y){return x+y;},0)/ws.length : null;
    var dwh=(f.h!==null&&f.h!==undefined&&l.h!==null&&l.h!==undefined)? l.h-f.h : null;
    var whh=(dwh!==null&&hrs>0)? dwh/hrs : null;
    var dir=(dp!==null&&dp<0)?U('consume'):U('recover');
    var fullWh=(typeof FULLWH!=='undefined')?FULLWH:null;
    var remH=(avgW&&avgW>0&&dp!==null&&dp<0&&fullWh)? fullWh/avgW : null;
    return {span:span,hrs:hrs,dp:dp,pph:pph,avgW:avgW,dwh:dwh,whh:whh,dir:dir,remH:remH};
  }
  function setT(id,v){ var e=document.getElementById(id); if(e) e.textContent=v; }
  function summarize(){
    if(!summary) return;
    var w=whole();
    var txt=fmt(w.whh,2)+' Wh/h';
    if(w.remH!==null){ txt+=' | '+U('fullEst')+' '+fmtDur(w.remH*3600); }
    var chip=(MODE==='charge')?U('chipCharge'):(MODE==='discharge'?U('chipDis'):'');
    var sp=(typeof META!=='undefined'&&META.startPct!=null)?Math.round(META.startPct):null;
    var ep=(typeof META!=='undefined'&&META.endPct!=null)?Math.round(META.endPct):null;
    var hasRange=(sp!=null&&ep!=null);
    var chipHtml=(chip?'<span class="modechip">'+chip+'</span>':'')+'<span class="cap">'+U('seg')+'</span>'
      +(hasRange?'<span class="pctrange">'+sp+'% → '+ep+'%</span>':'');
    var head='<span class="bt-l">'+fmtDur(w.span)+'</span>';
    summary.innerHTML='<span class="chiprow">'+chipHtml+'</span><span class="bigtime">'+head+'</span><span class="sumline">'+txt+'</span>';
    setT('tile-pph', fmt(w.pph!==null?Math.abs(w.pph):null,1));
    setT('tile-pph-k', w.dir+' %/h');
    setT('tile-avgw', fmt(w.avgW,2));
    setT('tile-wh', fmt(w.dwh,3));
    var perPt=(w.dp&&w.span)?w.span/Math.abs(w.dp):null;
    var perPtTxt=(perPt==null)?'-':(perPt>=60?tf(U('durM'),(perPt/60).toFixed(1)):tf(U('durS'),Math.round(perPt)));
    setT('tile-perpt', perPtTxt);
  }
  function buildCopy(){
    var w=whole(), m=(typeof META!=='undefined')?META:{};
    var L=[];
    L.push(U('sumHead'));
    L.push(U('lMode')+': '+(m.mode||'-')+' / '+U('lStart')+' '+(m.start||'-')+' / '+U('lEnd')+' '+(m.end||'-')+' / '+U('lElapsed')+' '+fmtDur(w.span));
    L.push(U('lLevel')+': '+fmt(m.startPct,1)+'% → '+fmt(m.endPct,1)+'% (Δ '+fmt(w.dp,2)+' pt) / '+w.dir+' '+fmt(w.pph!==null?Math.abs(w.pph):null,1)+' %/h');
    L.push(U('lAvgW')+': '+fmt(w.avgW,2)+' W / '+fmt(w.whh,2)+' Wh/h / '+U('lCum')+' '+fmt(w.dwh,3)+' Wh');
    if(w.remH!==null){ L.push(U('fullEst')+': '+fmtDur(w.remH*3600)); }
    L.push(U('lStop')+': '+(m.stop||'-'));
    if(m.dev){ L.push(U('lDev')+': '+m.dev); }
    L.push(U('lCond')+': '+(m.cond||'-'));
    return L.join('\n');
  }
  function doCopy(){
    var btn=document.getElementById('copybtn'); if(!btn) return;
    var txt=buildCopy();
    function done(ok){ btn.textContent=ok?U('copied'):U('copyFail'); btn.classList.add('done'); setTimeout(function(){ btn.textContent=U('copySum'); btn.classList.remove('done'); },1600); }
    function fallback(){
      try{
        var ta=document.createElement('textarea'); ta.value=txt; ta.style.position='fixed'; ta.style.opacity='0';
        document.body.appendChild(ta); ta.focus(); ta.select();
        var ok=document.execCommand('copy'); document.body.removeChild(ta); done(ok);
      }catch(e){ done(false); }
    }
    if(navigator.clipboard&&navigator.clipboard.writeText){ navigator.clipboard.writeText(txt).then(function(){done(true);},function(){ fallback(); }); }
    else { fallback(); }
  }
  // ---------- 時間刻み表（WordPress貼り付け用） ----------
  var MODE = (typeof META!=='undefined' && META.mode) ? META.mode : '';
  var TSTEP = (MODE==='charge') ? 900 : 3600; // 既定: 放電=1時間 / 充電=15分（記事の実例に合わせる）
  var TBL_HTML='', TBL_TEXT='';
  function tLabel(s){
    s=Math.round(s); var h=Math.floor(s/3600), m=Math.round((s%3600)/60);
    if(h>0 && m>0) return tf(U('durHm'),h,m);
    if(h>0) return tf(U('durH'),h);
    return tf(U('durM'),m);
  }
  function pctAt(t){
    var best=DATA[0], bd=1e18;
    DATA.forEach(function(d){ var dd=Math.abs(d.t-t); if(dd<bd){bd=dd;best=d;} });
    return (best.p===null||best.p===undefined||isNaN(best.p)) ? null : Math.round(best.p);
  }
  function diffTxt(d){ if(d===null) return '-'; if(d<0) return '−'+(-d)+'%'; return d+'%'; }
  function buildTable(){
    var host=document.getElementById('battable'); if(!host || !DATA.length) return;
    var l=DATA[DATA.length-1], span=l.t;
    var rows=[{lb:U('thStart'), st:'s', p:pctAt(0)}];
    var k=1, fullRow=false;
    while(k*TSTEP < span){
      var p=pctAt(k*TSTEP);
      rows.push({lb:tLabel(k*TSTEP), p:p});
      if(MODE==='charge' && p!==null && p>=99){ fullRow=true; break; } // 充電は満タン到達行で打ち切り（以降の100%横ばいはノイズ）
      k++;
    }
    if(MODE!=='charge' || !fullRow) rows.push({lb:U('thEnd'), st:'e', p:pctAt(span)});
    var isCharge = MODE==='charge';
    var h='<table><tr><th></th><th>'+(isCharge?U('thPctChg'):U('thPct'))+'</th><th>'+(isCharge?U('thDiffUp'):U('thDiffDn'))+'</th></tr>';
    var t=U('lElapsed')+'\t'+(isCharge?U('thPctChg'):U('thPct'))+'\t'+(isCharge?U('thDiffUp'):U('thDiffDn'));
    var prev=null;
    rows.forEach(function(r){
      var d=(r.p===null||prev===null) ? null : r.p-prev;
      var dtxt=(r.st==='s') ? (r.p===null?'-':'0%') : diffTxt(d);
      var ptxt=(r.p===null) ? '-' : r.p+'%';
      h+='<tr><td>'+r.lb+'</td><td>'+ptxt+'</td><td>'+dtxt+'</td></tr>';
      t+='\n'+r.lb+'\t'+ptxt+'\t'+dtxt;
      if(r.p!==null) prev=r.p;
    });
    h+='</table>';
    TBL_TEXT=t;
    host.innerHTML=h;
    // コピー用に border 属性付きの素のマークアップ（WPのサニタイズでclass/styleが消えても表として貼れる）
    TBL_HTML=h.replace('<table>','<table border="1" cellspacing="0" cellpadding="6">');
  }
  function flash(btn,ok,orig){
    if(!btn) return;
    btn.textContent=ok?U('copied'):U('copyFail'); btn.classList.add('done');
    setTimeout(function(){ btn.textContent=orig; btn.classList.remove('done'); },1600);
  }
  function copyText(txt,btn,orig){
    function fb(){
      try{
        var ta=document.createElement('textarea'); ta.value=txt; ta.style.position='fixed'; ta.style.opacity='0';
        document.body.appendChild(ta); ta.focus(); ta.select();
        var ok=document.execCommand('copy'); document.body.removeChild(ta); flash(btn,ok,orig);
      }catch(e){ flash(btn,false,orig); }
    }
    if(navigator.clipboard&&navigator.clipboard.writeText){ navigator.clipboard.writeText(txt).then(function(){flash(btn,true,orig);},fb); }
    else { fb(); }
  }
  function copyTableRich(){
    var btn=document.getElementById('copytbl'); if(!btn) return;
    var host=document.getElementById('battable');
    function selFallback(){
      try{
        var r=document.createRange(); r.selectNodeContents(host);
        var s=window.getSelection(); s.removeAllRanges(); s.addRange(r);
        var ok=document.execCommand('copy'); s.removeAllRanges(); flash(btn,ok,U('btnTbl'));
      }catch(e){ flash(btn,false,U('btnTbl')); }
    }
    if(navigator.clipboard&&window.ClipboardItem){
      try{
        navigator.clipboard.write([new ClipboardItem({
          'text/html': new Blob([TBL_HTML],{type:'text/html'}),
          'text/plain': new Blob([TBL_TEXT],{type:'text/plain'})
        })]).then(function(){ flash(btn,true,U('btnTbl')); }, selFallback);
        return;
      }catch(e){}
    }
    selFallback();
  }
  function setStep(s){
    TSTEP=s; buildTable();
    [].slice.call(document.querySelectorAll('.chip')).forEach(function(c){
      c.classList.toggle('on', Number(c.getAttribute('data-step'))===s);
    });
  }
  svgs.forEach(function(sv){
    sv.addEventListener('mousemove',function(ev){
      if(shot) return;
      var t=tOf(sv,ev), d=nearest(t);
      svgs.forEach(function(s2){ var hl=s2.querySelector('.hovline'); hl.setAttribute('x1',sx(d.t)); hl.setAttribute('x2',sx(d.t)); hl.setAttribute('visibility','visible'); });
      if(drag!==null){
        if(Math.abs(ev.clientX-downX)>4){ moved=true; }
        if(moved){ anchor=null; sel=[Math.min(drag,t),Math.max(drag,t)]; paint(); stats(); return; }
      }
      if(anchor!==null){ sel=[Math.min(anchor,t),Math.max(anchor,t)]; paint(); stats(); return; }
      if(!sel){ panel.textContent=tf(U('hover'),fmtDur(d.t),fmt(d.p,1),fmt(d.w,2),fmt(d.h,3)); }
    });
    sv.addEventListener('mouseleave',function(){
      svgs.forEach(function(s2){ s2.querySelector('.hovline').setAttribute('visibility','hidden'); });
      if(drag===null&&anchor===null) stats();
    });
    sv.addEventListener('mousedown',function(ev){ if(shot) return; ev.preventDefault(); drag=tOf(sv,ev); downX=ev.clientX; moved=false; });
    sv.addEventListener('mouseup',function(ev){
      if(drag===null) return;
      var t=tOf(sv,ev);
      if(moved){ sel=[Math.min(drag,t),Math.max(drag,t)]; drag=null; moved=false; anchor=null; paint(); stats(); }
      else {
        drag=null; moved=false;
        if(anchor===null){ anchor=t; sel=null; paint(); panel.textContent=tf(U('anchor'),fmtDur(t)); }
        else { sel=[Math.min(anchor,t),Math.max(anchor,t)]; anchor=null; paint(); stats(); }
      }
    });
    sv.addEventListener('dblclick',function(){ sel=null; anchor=null; drag=null; moved=false; paint(); stats(); });
  });
  window.addEventListener('mouseup',function(){ drag=null; moved=false; });
  var cb=document.getElementById('copybtn'); if(cb){ cb.addEventListener('click',doCopy); }
  [].slice.call(document.querySelectorAll('.chip')).forEach(function(c){
    c.addEventListener('click',function(){ setStep(Number(c.getAttribute('data-step'))); });
  });
  var tb=document.getElementById('copytbl'); if(tb){ tb.addEventListener('click',copyTableRich); }
  var th=document.getElementById('copytblhtml'); if(th){ th.addEventListener('click',function(){ copyText(TBL_HTML,th,U('btnTblHtml')); }); }
  // ---------- スクショ用モード: 左カラムのクリップ解除＋操作UI非表示＋ホバー/選択クリア（Escで解除） ----------
  var det=document.querySelector('details.metadtl');
  function toast(msg){
    var t=document.getElementById('shottoast');
    if(!t){ t=document.createElement('div'); t.id='shottoast';
      t.style.cssText='position:fixed;left:50%;top:14px;transform:translateX(-50%);background:#1b1b1b;color:#fff;padding:8px 14px;border-radius:6px;font-size:13px;z-index:9;opacity:0;transition:opacity .5s';
      document.body.appendChild(t); }
    t.textContent=msg; t.style.opacity='1';
    clearTimeout(toast._h);
    toast._h=setTimeout(function(){ t.style.opacity='0'; },2200);
  }
  function setShot(on){
    if(shot===on) return;
    shot=on;
    document.body.classList.toggle('shot', on);
    if(on){
      sel=null; anchor=null; drag=null; moved=false;
      if(det){ prevOpen=det.open; det.open=true; }
      paint(); // sel=null で selrect は hidden になる
      svgs.forEach(function(s2){ var hl=s2.querySelector('.hovline'); if(hl) hl.setAttribute('visibility','hidden'); });
      if(panel) panel.textContent=DEF;
      toast(U('toast'));
    } else if(det){ det.open=prevOpen; }
  }
  var sb=document.getElementById('shotbtn'); if(sb){ sb.addEventListener('click',function(){ setShot(true); }); }
  document.addEventListener('keydown',function(ev){ if(ev.key==='Escape') setShot(false); });
  setStep(TSTEP);
  paint();
  summarize();
  stats();
})();
</script>
'@

function Build-Html($Rows, $Meta) {
  $pctPts = @($Rows | ForEach-Object { [pscustomobject]@{ x = $_.elapsed_s; y = $_.battery_pct } })
  $wPts   = @($Rows | ForEach-Object { [pscustomobject]@{ x = $_.elapsed_s; y = $_.watts } })
  $whPts  = @($Rows | ForEach-Object { [pscustomobject]@{ x = $_.elapsed_s; y = $_.cumulative_wh } })
  $dPct = ''
  if ($null -ne $Meta.startPct -and $null -ne $Meta.endPct) { $dPct = "$(Fmt ($Meta.endPct - $Meta.startPct) 1) pt" }
  # 事後分析UIへ渡すデータ配列（null は JS の null リテラルに）
  $dataJs = ($Rows | ForEach-Object {
    $p = if ($null -ne $_.battery_pct)    { Fmt $_.battery_pct 4 }    else { 'null' }
    $w = if ($null -ne $_.watts)          { Fmt $_.watts 4 }          else { 'null' }
    $h = if ($null -ne $_.cumulative_wh)  { Fmt $_.cumulative_wh 6 }  else { 'null' }
    "{t:$($_.elapsed_s),p:$p,w:$w,h:$h}"
  }) -join ','
  # 端末カード: device 行を「機種 / OS / CPU… / サイクル」に分解して縦並びの kv 表へ
  $devCard = ''
  $devStr = [string]$Meta.device
  if ($devStr -ne '' -and $devStr -notmatch '記録なし|取得不可' -and $devStr -notmatch 'unavailab|no device') {
    $parts = $devStr -split ' / '
    $model = ''; $os = ''; $kv = @()
    foreach ($p in $parts) {
      $t = ([string]$p).Trim()
      if ($t -eq '') { continue }
      if ($t -match '^(CPU|RAM|GPU|表示|Display|Disk|NPU|サイクル|Cycles)\s+(.*)$') { $kv += ,@($matches[1], $matches[2]) }
      elseif ($t -match '^(Windows|macOS)') { $os = $t }
      elseif ($model -eq '') { $model = $t }
      else { $kv += ,@('', $t) }
    }
    $rh = ''
    if ($model -ne '') { $rh += '<tr><th>' + (T 'card.model') + '</th><td>' + (Esc $model) + '</td></tr>' }
    if ($os -ne '')    { $rh += '<tr><th>OS</th><td>' + (Esc $os) + '</td></tr>' }
    foreach ($pair in $kv) { $rh += '<tr><th>' + (Esc $pair[0]) + '</th><td>' + (Esc $pair[1]) + '</td></tr>' }
    if ($rh -ne '') { $devCard = '<div class="card"><h3>' + (T 'card.device') + '</h3><table class="kv">' + $rh + '</table></div>' }
  }
  # 計測条件カード: 記録なし/なし/空 のときは出さない
  $condCard = ''
  $condStr = ([string]$Meta.conditions).Trim()
  if ($condStr -ne '' -and $condStr -notmatch '記録なし|なし' -and $condStr -notmatch 'no conditions') {
    $condCard = '<div class="card"><h3>' + (T 'card.cond') + '</h3><p class="condtxt">' + (Esc $condStr) + '</p></div>'
  }
  # 瞬時消費電力グラフ: 生値は数秒間隔のジッタ＋単発スパイクで橙の壁になるため、約1分窓の移動中央値で
  # トレンド線を出す（中央値は単発外れ値に強い）。残量/累積は元々滑らかなので非処理。
  # ホバー/区間統計は生の DATA を読むので詳細はそこで取れる。
  $wIvl = 0.0; [double]::TryParse([string]$Meta.interval, [ref]$wIvl) | Out-Null
  if ($wIvl -le 0) { $wIvl = 5 }
  $wK = [int][math]::Round(30 / $wIvl); if ($wK -lt 1) { $wK = 1 }
  $wSec = [int]($wK * $wIvl * 2)
  $wArr = @($wPts)
  $wSmooth = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $wArr.Count; $i++) {
    $y = $wArr[$i].y
    if ($null -eq $y) { $wSmooth.Add([pscustomobject]@{ x = $wArr[$i].x; y = $null }); continue }
    $lo = [math]::Max(0, $i - $wK); $hi = [math]::Min($wArr.Count - 1, $i + $wK)
    $win = New-Object System.Collections.Generic.List[double]
    for ($j = $lo; $j -le $hi; $j++) { $yj = $wArr[$j].y; if ($null -ne $yj) { $win.Add([double]$yj) } }
    if ($win.Count -gt 0) {
      $win.Sort()
      $mid = [int][math]::Floor($win.Count / 2)
      $med = if ($win.Count % 2 -eq 1) { $win[$mid] } else { ($win[$mid - 1] + $win[$mid]) / 2.0 }
    } else { $med = [double]$y }
    $wSmooth.Add([pscustomobject]@{ x = $wArr[$i].x; y = $med })
  }
  # クリップ上限は移動中央値の系列に対して99パーセンタイル（残った大きな実負荷ピークだけ抑える）
  $wCap = $null
  $wNums = @($wSmooth | ForEach-Object { $_.y } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
  if ($wNums.Count -ge 20) {
    $pi = [int][math]::Ceiling($wNums.Count * 0.99) - 1
    if ($pi -lt 0) { $pi = 0 }
    if ($pi -ge $wNums.Count) { $pi = $wNums.Count - 1 }
    $wCap = $wNums[$pi] * 1.05
    if ($wCap -le 0) { $wCap = $null }
  }
  $wClip = ($null -ne $wCap)
  $wNote = T 'w.note' $wSec
  if ($wClip) { $wNote += ' ' + (T 'w.clip') }
  $htmlLang = if ($script:Lang -eq 'ja') { 'ja' } else { 'en' }
  $tpl = @"
<!doctype html>
<html lang="$htmlLang"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>wattlog — $(Esc $Meta.startIso)</title>
<style>
  :root { --ink:#1b1b1b; --muted:#6b6b6b; --line:#d8d8d8; --bg:#ffffff; --accent:#0f766e; }
  * { box-sizing: border-box; }
  body { margin:0; padding:28px; background:#f4f4f2; color:var(--ink);
         font-family: "Segoe UI", "Hiragino Sans", "Meiryo", system-ui, sans-serif; }
  .wrap { max-width: 1480px; margin: 0 auto; background:var(--bg); border:1px solid var(--line);
          border-radius:10px; padding:18px 30px 26px; }
  /* 2カラム（≥1280px）: 左=計測情報+時間刻み表 / 右=区間統計+グラフ。狭幅は従来どおり1カラム縦積み */
  .cols { display:grid; grid-template-columns:minmax(0,1fr); }
  .colcharts { min-width:0; }
  @media (min-width:1280px) {
    .cols { grid-template-columns:380px minmax(0,1fr); gap:0 30px; align-items:start; }
    .colside { position:sticky; top:12px; max-height:calc(100vh - 24px); overflow:auto; }
    .colside table.meta { font-size:12px; }
    .colside table.meta th, .colside table.meta td { padding:5px 7px; }
    .colside #battable table { font-size:12px; }
    .colside #battable th, .colside #battable td { padding:5px 7px; }
  }
  /* スクショ用モード: 左カラムの内部スクロール解除＋操作専用UIを隠す（Escで解除） */
  body.shot { padding:12px; }
  body.shot .sub { display:none; }
  body.shot .colside { position:static; max-height:none; overflow:visible; }
  body.shot #selpanel, body.shot .tblbar, body.shot footer, body.shot .copybtn,
  body.shot details.metadtl > summary { display:none; }
  details.metadtl { margin:0 0 16px; }
  details.metadtl > summary { cursor:pointer; font-size:13px; color:#3a3a3a; padding:8px 12px;
    border:1px solid var(--line); border-radius:6px; background:#faf7f2; user-select:none; }
  details.metadtl > summary:hover { background:#f4efe7; }
  details.metadtl[open] > summary { border-radius:6px 6px 0 0; }
  details.metadtl[open] table.meta { margin-top:-1px; margin-bottom:0; }
  h1 { font-size: 20px; margin:0 0 4px; letter-spacing:.02em; }
  .sub { color:var(--muted); font-size:13px; margin:0 0 12px; }
  table.meta { width:100%; border-collapse:collapse; font-size:13px; margin-bottom:26px; }
  table.meta th, table.meta td { border:1px solid var(--line); padding:7px 10px; text-align:left; }
  table.meta th { background:#faf7f2; font-weight:600; color:#3a3a3a; width:1%; white-space:nowrap; }
  section { margin: 0 0 18px; }
  h2 { font-size:15px; margin:0 0 6px; font-weight:600; }
  h2 .unit { color:var(--muted); font-weight:400; font-size:13px; }
  svg { border:1px solid var(--line); border-radius:6px; background:#fff; cursor:crosshair; }
  .grid { stroke:#ececec; stroke-width:1; }
  .axis { stroke:#9a9a9a; stroke-width:1; }
  .tick { fill:var(--muted); font-size:11px; font-family:inherit; }
  .line { stroke-linejoin:round; stroke-linecap:round; }
  .empty { color:var(--muted); font-size:13px; }
  .panel { margin:0 0 22px; padding:10px 14px; border:1px solid var(--line); border-left:3px solid var(--accent);
           border-radius:6px; background:#faf7f2; color:#3a3a3a; font-size:13px; font-variant-numeric:tabular-nums; }
  .summary { border-left-color:#c2571a; font-weight:600; background:#fdf6f1; }
  .summary .bigtime { display:flex; flex-wrap:wrap; justify-content:flex-start; align-items:baseline; gap:0 10px;
                      font-size:26px; line-height:1.15; font-weight:700; letter-spacing:.02em; }
  .summary .bigtime .bt-l { white-space:nowrap; }
  .summary .pctrange { font-size:18px; font-weight:700; color:#c2571a; white-space:nowrap; }
  .summary .sumline { display:block; margin-top:2px; }
  .summaryrow { display:flex; gap:12px; align-items:flex-start; margin:0 0 22px; }
  .summaryrow .summary { flex:1; margin:0; }
  .sumbtns { flex:0 0 auto; display:flex; flex-direction:column; gap:8px; }
  .card { border:1px solid var(--line); border-radius:8px; padding:10px 12px; margin:0 0 14px; background:#fff; }
  .card h3 { font-size:12px; font-weight:600; color:var(--muted); margin:0 0 8px; letter-spacing:.04em; }
  table.kv { width:100%; border-collapse:collapse; font-size:13px; }
  table.kv th { text-align:left; font-weight:400; color:var(--muted); white-space:nowrap; width:1%; padding:2px 10px 2px 0; vertical-align:top; }
  table.kv td { padding:2px 0; }
  .condtxt { margin:0; font-size:13px; }
  .tiles { display:grid; grid-template-columns:1fr 1fr; gap:8px; margin:0 0 14px; }
  .tile { border:1px solid var(--line); border-radius:8px; background:#faf7f2; padding:8px 10px; }
  .tile .tv { display:block; font-size:18px; font-weight:700; font-variant-numeric:tabular-nums; }
  .tile .tk { display:block; font-size:11px; color:var(--muted); margin-top:2px; }
  .modechip { display:inline-block; font-size:11px; font-weight:600; padding:2px 9px; border-radius:999px;
              border:1px solid var(--accent); color:var(--accent); margin:0 0 6px; }
  .summary .chiprow { display:flex; align-items:baseline; gap:8px; margin:0 0 6px; }
  .summary .chiprow .modechip { margin:0; }
  .summary .chiprow .cap { font-size:12px; font-weight:400; color:var(--muted); letter-spacing:0; }
  .copybtn { flex:0 0 auto; padding:10px 16px; border:1px solid var(--line); border-radius:6px;
             background:#fff; color:#3a3a3a; font-size:13px; font-family:inherit; cursor:pointer; white-space:nowrap; }
  .copybtn:hover { background:#faf7f2; }
  .copybtn.done { border-color:var(--accent); color:var(--accent); }
  .tblbar { display:flex; gap:10px; align-items:center; margin:0 0 12px; flex-wrap:wrap; }
  .chips { color:var(--muted); font-size:13px; margin-right:auto; }
  .chip { margin-left:6px; padding:4px 10px; border:1px solid var(--line); border-radius:999px;
          background:#fff; font-size:12px; font-family:inherit; cursor:pointer; }
  .chip.on { border-color:var(--accent); color:var(--accent); background:#f0faf8; }
  #battable table { width:100%; border-collapse:collapse; font-size:13px; font-variant-numeric:tabular-nums; }
  #battable th, #battable td { border:1px solid var(--line); padding:7px 10px; text-align:left; }
  #battable th { background:#faf7f2; font-weight:600; }
  footer { color:var(--muted); font-size:12px; margin-top:8px; }
</style></head>
<body><div class="wrap">
  <h1>$(T 'page.h1')</h1>
  <p class="sub">$(T 'page.sub' (Esc $Meta.generatedIso))</p>
  <div class="cols">
    <div class="colside">
      <div class="summaryrow">
        <div class="panel summary" id="summary">$(T 'sum.loading')</div>
        <div class="sumbtns">
          <button type="button" id="copybtn" class="copybtn">$(T 'btn.copy')</button>
          <button type="button" id="shotbtn" class="copybtn" title="$(T 'btn.shotTip')">$(T 'btn.shot')</button>
        </div>
      </div>
      $devCard
      <div class="tiles">
        <div class="tile"><span class="tv" id="tile-pph">-</span><span class="tk" id="tile-pph-k">%/h</span></div>
        <div class="tile"><span class="tv" id="tile-avgw">-</span><span class="tk">$(T 'tile.avgw')</span></div>
        <div class="tile"><span class="tv" id="tile-wh">-</span><span class="tk">$(T 'tile.wh')</span></div>
        <div class="tile"><span class="tv" id="tile-perpt">-</span><span class="tk">$(T 'tile.perpt')</span></div>
      </div>
      $condCard
      <details class="metadtl">
        <summary>$(T 'meta.open')</summary>
        <table class="meta">
          <tr><th>$(T 'meta.mode')</th><td>$(Esc $Meta.mode)</td></tr>
          <tr><th>$(T 'meta.start')</th><td>$(Esc $Meta.startIso)</td></tr>
          <tr><th>$(T 'meta.end')</th><td>$(Esc $Meta.endIso)</td></tr>
          <tr><th>$(T 'meta.samples')</th><td>$($Rows.Count)</td></tr>
          <tr><th>$(T 'meta.elapsed')</th><td>$(FmtDur $Meta.elapsed_s)</td></tr>
          <tr><th>$(T 'meta.interval')</th><td>$(Fmt $Meta.interval 0) s</td></tr>
          <tr><th>$(T 'meta.pctStart')</th><td>$(Fmt $Meta.startPct 1) %</td></tr>
          <tr><th>$(T 'meta.pctEnd')</th><td>$(Fmt $Meta.endPct 1) %</td></tr>
          <tr><th>$(T 'meta.pctDelta')</th><td>$dPct</td></tr>
          <tr><th>$(T 'meta.cumWh')</th><td>$(Fmt $Meta.cumulative_wh 2) Wh</td></tr>
          <tr><th>$(T 'meta.avgW')</th><td>$(Fmt $Meta.avg_w 2) W</td></tr>
          <tr><th>$(T 'meta.stop')</th><td>$(Esc $Meta.stopReason)</td></tr>
          <tr><th>$(T 'meta.fullWh')</th><td>$(Fmt $Meta.full_wh 1) Wh</td></tr>
          <tr><th>$(T 'meta.wsrc')</th><td>$(Esc $Meta.wSourceNote)</td></tr>
        </table>
      </details>
      <section>
        <h2>$(T 'tbl.title') <span class="unit">$(T 'tbl.unit')</span></h2>
        <div class="tblbar">
          <span class="chips">$(T 'tbl.step')
            <button type="button" class="chip" data-step="900">$(T 'tbl.s15')</button>
            <button type="button" class="chip" data-step="1800">$(T 'tbl.s30')</button>
            <button type="button" class="chip" data-step="3600">$(T 'tbl.s1h')</button>
          </span>
          <button type="button" id="copytbl" class="copybtn">$(T 'btn.copyTbl')</button>
          <button type="button" id="copytblhtml" class="copybtn">$(T 'btn.copyTblHtml')</button>
        </div>
        <div id="battable"><p class="empty">$(T 'tbl.loading')</p></div>
      </section>
    </div>
    <div class="colcharts">
      <div class="panel" id="selpanel">$(Esc $script:LJS['def'])</div>
      $(New-SvgChart (T 'chart.pct') '%' $pctPts '#2563a8' 0 100 $false 'pct')
      $(New-SvgChart (T 'chart.w') 'W' $wSmooth '#c2571a' 0 $wCap $wClip 'watt' $wNote)
      $(New-SvgChart (T 'chart.wh') 'Wh' $whPts '#0f766e' 0 $null $false 'wh')
    </div>
  </div>
  <footer>$(T 'foot')</footer>
</div>
"@
  $fullWhJs = if ($null -ne $Meta.full_wh) { Fmt $Meta.full_wh 3 } else { 'null' }
  $uiJson = ($script:LJS | ConvertTo-Json -Compress)
  $metaJs = 'var META={mode:' + (JsStr $Meta.mode) + ',start:' + (JsStr $Meta.startIso) + ',end:' + (JsStr $Meta.endIso) +
            ',stop:' + (JsStr $Meta.stopReason) + ',cond:' + (JsStr $Meta.conditions) + ',dev:' + (JsStr $Meta.device) +
            ',startPct:' + $(if ($null -ne $Meta.startPct) { Fmt $Meta.startPct 2 } else { 'null' }) +
            ',endPct:' + $(if ($null -ne $Meta.endPct) { Fmt $Meta.endPct 2 } else { 'null' }) + '};'
  return $tpl + "<script>var DATA=[$dataJs];var FULLWH=$fullWhJs;var UI=$uiJson;$metaJs</script>" + $script:JSUI + "</body></html>"
}

# ---------- CSV から HTML 再生成（計測しない・UI変更後の確認用） ----------
if ($FromCsv) {
  if (-not (Test-Path $FromCsv)) { throw (T 'err.noCsv' $FromCsv) }
  $csvFull = (Resolve-Path $FromCsv).Path
  $lines = @(Get-Content -Path $csvFull)
  $condLine = $lines | Where-Object { $_ -match '^#\s*conditions:' } | Select-Object -First 1
  $conditions2 = if ($condLine) { ($condLine -replace '^#\s*conditions:\s*', '') } else { (T 'cond.none') }
  $devLine = $lines | Where-Object { $_ -match '^#\s*device:' } | Select-Object -First 1
  $device2 = if ($devLine) { ($devLine -replace '^#\s*device:\s*', '') } else { (T 'csv.noDev') }
  # 停止理由の復元: `# stop: <code> k=v` 行から言語ラベルを再組み立て（旧CSVは行が無いので missing 扱い）
  $stopLine2 = $lines | Where-Object { $_ -match '^#\s*stop:' } | Select-Object -First 1
  $stopParsed = if ($stopLine2) { Stop-Parse $stopLine2 } else { @('', $null) }
  $stopCode2 = [string]$stopParsed[0]
  $stopReason2 = if ($stopCode2) {
    Stop-Label $stopCode2 $stopParsed[1]
  } else {
    Stop-Label 'missing' $null
  }
  $dataLines = @($lines | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' })
  $raw = @($dataLines | ConvertFrom-Csv)
  if ($raw.Count -eq 0) { throw (T 'err.noRows' $FromCsv) }
  function Num($s) { if ($null -eq $s -or "$s".Trim() -eq '') { return $null }; return [double]::Parse($s, $inv) }
  $rows2 = New-Object System.Collections.Generic.List[object]
  foreach ($r in $raw) {
    $rows2.Add([pscustomobject]@{
      timestamp = $r.timestamp; elapsed_s = [int](Num $r.elapsed_s)
      battery_pct = Num $r.battery_pct; watts = Num $r.watts; w_source = $r.w_source
      charging = ($r.charging -eq '1'); power_online = ($r.power_online -eq '1')
      cumulative_wh = Num $r.cumulative_wh; wh_per_hour = Num $r.wh_per_hour
      remaining_mwh = [long](Num $r.remaining_mwh); full_mwh = [long](Num $r.full_mwh)
    })
  }
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($csvFull)
  $mode2 = if ($baseName -match 'wattlog-(discharge|charge)') { $Matches[1] }
           elseif (@($rows2 | Where-Object { $_.charging }).Count -gt 0) { 'charge' } else { 'discharge' }
  $wVals2 = @($rows2 | ForEach-Object { $_.watts } | Where-Object { $null -ne $_ })
  $avg2 = if ($wVals2.Count) { ($wVals2 | Measure-Object -Average).Average } else { $null }
  $ivl2 = if ($rows2.Count -ge 2) { $rows2[1].elapsed_s - $rows2[0].elapsed_s } else { 0 }
  $cnt2 = @{ rate = 0; pct = 0; none = 0 }
  foreach ($r in $rows2) { if ($cnt2.ContainsKey($r.w_source)) { $cnt2[$r.w_source] += 1 } }
  $lastFull = $rows2[$rows2.Count - 1].full_mwh
  $meta2 = [pscustomobject]@{
    mode = $mode2; interval = $ivl2
    startIso = $rows2[0].timestamp; endIso = $rows2[$rows2.Count - 1].timestamp
    generatedIso = IsoLocal (Get-Date); elapsed_s = $rows2[$rows2.Count - 1].elapsed_s
    startPct = $rows2[0].battery_pct; endPct = $rows2[$rows2.Count - 1].battery_pct
    cumulative_wh = $rows2[$rows2.Count - 1].cumulative_wh; avg_w = $avg2
    stopReason = if ($stopCode2) { "$stopReason2 $(T 'csv.regen')" } else { $stopReason2 }
    full_wh = if ($lastFull) { $lastFull / 1000 } else { $null }
    wSourceNote = (T 'wsrc.note' @($cnt2.rate, $cnt2.pct, $cnt2.none))
    conditions = $conditions2; device = $device2
  }
  # -Out が絶対パスならそのまま使う（Join-Path で「C:\...\C:\...」になるのを防ぐ）。相対ならカレントに連結
  $outDirR = if ($Out) { if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Resolve-Path .).Path $Out } }
              else { [System.IO.Path]::GetDirectoryName($csvFull) }
  if (-not (Test-Path -LiteralPath $outDirR)) { New-Item -ItemType Directory -Path $outDirR | Out-Null }
  $html2 = Join-Path $outDirR "$baseName.html"
  Build-Html $rows2 $meta2 | Set-Content -Path $html2 -Encoding UTF8
  Write-Host (T 'html.regen' $html2)
  Write-Host (T 'sum.samples' @($rows2.Count, $mode2, (Fmt $meta2.startPct 1), (Fmt $meta2.endPct 1), (Fmt $meta2.cumulative_wh 2)))
  return
}

# ---------- 本体 ----------
$outDir = Join-Path (Resolve-Path .).Path $Out
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$stamp = TsLabel (Get-Date)
$base = "wattlog-$Mode-$stamp"
if ($Label) { $base += "-$Label" }
$csvPath = Join-Path $outDir "$base.csv"
$htmlPath = Join-Path $outDir "$base.html"

$CSV_HEADER = 'timestamp,elapsed_s,battery_pct,watts,w_source,charging,power_online,cumulative_wh,wh_per_hour,remaining_mwh,full_mwh'
$conditions = Get-Conditions
$device = Get-DeviceInfo
$cfgLine = @(Config-Line | Where-Object { $_ })
Set-Content -Path $csvPath -Value (@("# device: $device", "# conditions: $conditions", (Params-Line)) + $cfgLine + @($CSV_HEADER)) -Encoding UTF8

$rows = New-Object System.Collections.Generic.List[object]
$start = Get-Date
$cum = 0.0
$prev = $null
$capacityWh = $null
$counts = @{ rate = 0; pct = 0; none = 0 }
$stopReason = ''
$stopCode = ''
$stopArg = $null
$everCharged = $false
$notChargingStreak = 0

Write-Host ((T 'run.start') -f $Mode, $Interval, $StopAt, $(if ($Duration -gt 0) { " duration=$Duration min" } else { '' }))
if ($KeepAwake -eq 'on') {
  Write-Host ((T 'run.keepawake') -f $esSet)
} else {
  Write-Host 'keep-awake: off'
}
Write-Host (T 'run.out' $outDir)
Write-Host ('-' * 72)

function Write-SampleHtml($Meta) {
  Build-Html $rows $Meta | Set-Content -Path $htmlPath -Encoding UTF8
}

while ($true) {
  # 絶対時刻ベースのドリフト補正: 第nサンプルは start + n*interval
  if ($rows.Count -gt 0) {
    $target = $start.AddSeconds($rows.Count * $Interval)
    $delayMs = ($target - (Get-Date)).TotalMilliseconds
    if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
  }
  $now = Get-Date
  $elapsed_s = [math]::Round(($now - $start).TotalSeconds)

  $d = Read-Battery
  $full_mwh = $d.full_mwh; $remaining_mwh = $d.remaining_mwh
  $pct = $null
  if ($remaining_mwh -gt 0 -and $full_mwh -gt 0) { $pct = $remaining_mwh / $full_mwh * 100 }
  elseif ($null -ne $d.estimated_pct) { $pct = $d.estimated_pct }
  if ($full_mwh -gt 0) { $capacityWh = $full_mwh / 1000 }

  $rateMw = $d.discharge_mw + $d.charge_mw
  $watts = $null; $wSource = 'none'
  if ($rateMw -gt 0) { $watts = $rateMw / 1000; $wSource = 'rate' }
  elseif ($prev -and $null -ne $prev.pct -and $null -ne $pct -and $capacityWh -gt 0) {
    $dtH = ($now - $prev.ms).TotalHours
    if ($dtH -gt 0) { $watts = (($prev.pct - $pct) / 100) * $capacityWh / $dtH; $wSource = 'pct' }
  }
  $counts[$wSource] += 1

  if ($prev -and $null -ne $prev.watts -and $null -ne $watts) {
    $dtH = ($now - $prev.ms).TotalHours
    $cum += [math]::Abs(($prev.watts + $watts) / 2) * $dtH
  }
  $wh_per_hour = if ($elapsed_s -gt 0) { $cum / ($elapsed_s / 3600) } else { $null }

  $row = [pscustomobject]@{
    timestamp = IsoLocal $now; elapsed_s = $elapsed_s; battery_pct = $pct; watts = $watts
    w_source = $wSource; charging = $d.charging; power_online = $d.power_online
    cumulative_wh = $cum; wh_per_hour = $wh_per_hour; remaining_mwh = $remaining_mwh; full_mwh = $full_mwh
  }
  $rows.Add($row)
  $csvLine = @(
    $row.timestamp, $row.elapsed_s, (Fmt $pct 2), (Fmt $watts 3), $wSource,
    $(if ($d.charging) { 1 } else { 0 }), $(if ($d.power_online) { 1 } else { 0 }),
    (Fmt $cum 4), (Fmt $wh_per_hour 3), $remaining_mwh, $full_mwh
  ) -join ','
  Add-Content -Path $csvPath -Value $csvLine -Encoding ASCII

  Write-Host ((T 'run.sample') -f `
    $elapsed_s,
    $(if ($null -ne $pct) { "$(Fmt $pct 1)%" } else { ' n/a' }),
    $(if ($null -ne $watts) { Fmt $watts 2 } else { '  n/a' }),
    $wSource,
    (Fmt $cum 2),
    $(if ($d.power_online) { 'AC' } else { 'BAT' }),
    $(if ($d.charging) { (T 'run.charging') } else { '' }))

  # サンプル毎にHTMLも更新（強制終了でも直前分まで残る）
  $wVals = @($rows | ForEach-Object { $_.watts } | Where-Object { $null -ne $_ })
  $avg = if ($wVals.Count) { ($wVals | Measure-Object -Average).Average } else { $null }
  $meta = [pscustomobject]@{
    mode = $Mode; interval = $Interval; startIso = IsoLocal $start; endIso = IsoLocal $now
    generatedIso = IsoLocal $now; elapsed_s = $elapsed_s
    startPct = $rows[0].battery_pct; endPct = $row.battery_pct
    cumulative_wh = $cum; avg_w = $avg; stopReason = if ($stopReason) { $stopReason } else { (T 'run.measuring') }
    full_wh = if ($full_mwh) { $full_mwh / 1000 } else { $null }
    wSourceNote = (T 'wsrc.note' @($counts.rate, $counts.pct, $counts.none))
    conditions = $conditions; device = $device
  }
  Write-SampleHtml $meta

  $prev = [pscustomobject]@{ ms = $now; pct = $pct; watts = $watts }

  # 充電完了の検出: AC接続で charging フラグが OFF（満充電宣言）→ 数サンプル連続で停止
  if ($Mode -eq 'charge') {
    if ($d.charging) { $everCharged = $true; $notChargingStreak = 0 }
    elseif ($d.power_online) { $notChargingStreak += 1 }
    if ($notChargingStreak -ge 3) {
      $stopCode = if ($everCharged) { 'charge_done' } else { 'full_from_start' }
      $stopArg = @{ pct = (Fmt $pct 1) }
      $stopReason = Stop-Label $stopCode $stopArg
      break
    }
  }

  if ($null -ne $pct) {
    if ($Mode -eq 'discharge' -and $pct -le $StopAt) {
      $stopCode = 'threshold_discharge'; $stopArg = @{ pct = (Fmt $pct 1); stopat = $StopAt }
      $stopReason = Stop-Label $stopCode $stopArg; break
    }
    if ($Mode -eq 'charge' -and $pct -ge $StopAt) {
      $stopCode = 'threshold_charge'; $stopArg = @{ pct = (Fmt $pct 1); stopat = $StopAt }
      $stopReason = Stop-Label $stopCode $stopArg; break
    }
  }
  if ($Duration -gt 0 -and $elapsed_s -ge $Duration * 60) {
    $stopCode = 'duration'; $stopArg = @{ elapsed_s = $elapsed_s; minutes = $Duration }
    $stopReason = Stop-Label $stopCode $stopArg; break
  }
}

# ---------- 終了処理 ----------
Stop-KeepAwake
# 停止理由を機械可読コードで CSV 末尾に追記（文言は焼かない。再生成時に言語を替えられる）
if ($stopCode) { Add-Content -Path $csvPath -Value (Stop-Line $stopCode $stopArg) -Encoding ASCII }
$end = Get-Date
$elapsed_s = [math]::Round(($end - $start).TotalSeconds)
$wVals = @($rows | ForEach-Object { $_.watts } | Where-Object { $null -ne $_ })
$avg = if ($wVals.Count) { ($wVals | Measure-Object -Average).Average } else { $null }
$meta = [pscustomobject]@{
  mode = $Mode; interval = $Interval; startIso = IsoLocal $start; endIso = IsoLocal $end
  generatedIso = IsoLocal $end; elapsed_s = $elapsed_s
  startPct = $rows[0].battery_pct; endPct = $rows[$rows.Count - 1].battery_pct
  cumulative_wh = $cum; avg_w = $avg; stopReason = $stopReason
  full_wh = if ($rows[$rows.Count - 1].full_mwh) { $rows[$rows.Count - 1].full_mwh / 1000 } else { $null }
  wSourceNote = (T 'wsrc.note' @($counts.rate, $counts.pct, $counts.none))
  conditions = $conditions; device = $device
}
Write-SampleHtml $meta

Write-Host ('-' * 72)
Write-Host (T 'run.stop' $stopReason)
Write-Host ((T 'run.samples') -f $rows.Count, $elapsed_s)
Write-Host ((T 'run.level') -f (Fmt $meta.startPct 1), (Fmt $meta.endPct 1), (Fmt ($meta.endPct - $meta.startPct) 1))
Write-Host ((T 'run.cum') -f (Fmt $cum 2), $(if ($null -ne $avg) { Fmt $avg 2 } else { '-' }), $esClear)
Write-Host (T 'run.wsrc' $meta.wSourceNote)
Write-Host "CSV : $csvPath"
Write-Host "HTML: $htmlPath"
if ($showMenu) { Read-Host (T 'run.close') | Out-Null }
