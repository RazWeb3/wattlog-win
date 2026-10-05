# wattlog 第1段 — ゼロインストール バッテリー電力ロガー（PowerShell ネイティブ）
# 起動: wattlog.cmd をダブルクリック（メニューが出る）または
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
  [string]$Note = ''
)
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

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
  if ($h -gt 0) { return "${h}時間${m}分" }
  if ($m -gt 0) { return "${m}分${ss}秒" }
  return "${ss}秒"
}
function Esc($s) {
  return ([string]$s).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}
function JsStr($s) {
  $t = [string]$s
  $t = $t.Replace('\', '\\').Replace('"', '\"').Replace("`r", ' ').Replace("`n", ' ')
  return '"' + $t + '"'
}
function TsLabel($d) { return $d.ToString('yyyyMMdd-HHmmss', $inv) }
function IsoLocal($d) { return $d.ToString('yyyy-MM-ddTHH:mm:ss', $inv) }

# ---------- 起動モード ----------
$showMenu = $false
if (-not $FromCsv) {
if (-not $Mode) {
  $showMenu = $true
  Write-Host 'wattlog: モードを選択してください'
  Write-Host '  1) 放電計測（バッテリー駆動。残量閾値で自動停止）'
  Write-Host '  2) 充電計測（電源接続。残量閾値または時間で自動停止）'
  $k = Read-Host '番号'
  $Mode = if ($k -eq '2') { 'charge' } else { 'discharge' }
  if (-not $Note) {
    Write-Host '計測条件のメモ（音量/WiFi/バックグラウンド等。電源プラン・輝度は自動取得）'
    $Note = Read-Host 'メモ（Enter でスキップ）'
  }
}
$Mode = $Mode.ToLower()
if ($Mode -ne 'discharge' -and $Mode -ne 'charge') { Write-Host '--Mode は discharge|charge'; exit 2 }
if ($Interval -le 0) { $Interval = 5 }
if ($StopAt -lt 0) { $StopAt = if ($Mode -eq 'discharge') { 10 } else { 100 } }
if ($KeepAwake -ne 'on' -and $KeepAwake -ne 'off') { Write-Host '-KeepAwake は on|off'; exit 2 }
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
  $plan = '不明'
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
  $parts = @("電源プラン=$plan")
  $parts += if ($null -ne $bright) { "輝度=$bright%" } else { '輝度=取得不可' }
  $auto = $parts -join ', '
  if ($Note) { return "$auto / メモ: $Note" } else { return $auto }
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
    if ($cpu) { $p += "CPU $(CleanName $cpu.Name) ($($cpu.NumberOfCores)コア$($cpu.NumberOfLogicalProcessors)スレッド)" }
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
    if ($res.Count -gt 0) { $p += ('表示 ' + ($res -join ' + ')) }
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
    } else { $p += 'NPU なし' }
  } catch {}
  try {
    $cyc = @(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue)
    foreach ($c in $cyc) { if ($c.CycleCount -gt 0) { $p += "サイクル $($c.CycleCount)回"; break } }
  } catch {}
  if ($p.Count -eq 0) { return '（端末情報 取得不可）' }
  return $p -join ' / '
}

# ---------- SVG / HTML ----------
function New-SvgChart($Title, $Unit, $Points, $Color, $YFloor = $null, $YCap = $null, $Clip = $false, $Id = '', $Note = '') {
  $W = 920; $H = 280; $ml = 64; $mr = 20; $mt = 16; $mb = 38
  $iw = $W - $ml - $mr; $ih = $H - $mt - $mb
  $valid = @($Points | Where-Object { $null -ne $_.y })
  if ($valid.Count -eq 0) { return "<section><h2>$(Esc $Title)</h2><p class=`"empty`">データなし</p></section>" }
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
  if ($Note) { $unitLabel = "($(Esc $Unit)) ・ $(Esc $Note)" }
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
  var DEF='始点クリック→終点クリックで区間統計（ドラッグでも可） / ホバー=値読取 / ダブルクリック=解除';
  var sel=null, drag=null, anchor=null, moved=false, downX=0, shot=false, prevOpen=true;
  function fmt(v,d){ return (v===null||v===undefined||isNaN(v))?'-':v.toFixed(d); }
  function fmtDur(s){
    if(s===null||s===undefined||isNaN(s)) return '-';
    s=Math.max(0,Math.round(s));
    var h=Math.floor(s/3600), m=Math.floor((s%3600)/60), sec=s%60;
    if(h>0) return h+'時間'+m+'分';
    if(m>0) return m+'分'+sec+'秒';
    return sec+'秒';
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
    panel.textContent='区間 '+fmtDur(b-a)+' | 平均 '+fmt(avg,2)+' W | Δ% '+fmt(dp,2)+' = '+fmt(pph,1)+' %/h | ΔWh '+fmt(dwh,3)+' = '+fmt(whh,2)+' Wh/h | n='+ws.length;
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
    var dir=(dp!==null&&dp<0)?'消費':'回復';
    var fullWh=(typeof FULLWH!=='undefined')?FULLWH:null;
    var remH=(avgW&&avgW>0&&dp!==null&&dp<0&&fullWh)? fullWh/avgW : null;
    return {span:span,hrs:hrs,dp:dp,pph:pph,avgW:avgW,dwh:dwh,whh:whh,dir:dir,remH:remH};
  }
  function setT(id,v){ var e=document.getElementById(id); if(e) e.textContent=v; }
  function summarize(){
    if(!summary) return;
    var w=whole();
    var txt=fmt(w.whh,2)+' Wh/h';
    if(w.remH!==null){ txt+=' | 満充電→0%の推定 '+fmtDur(w.remH*3600); }
    var chip=(MODE==='charge')?'充電':(MODE==='discharge'?'放電':'');
    var sp=(typeof META!=='undefined'&&META.startPct!=null)?Math.round(META.startPct):null;
    var ep=(typeof META!=='undefined'&&META.endPct!=null)?Math.round(META.endPct):null;
    var hasRange=(sp!=null&&ep!=null);
    var chipHtml=(chip?'<span class="modechip">'+chip+'</span>':'')+'<span class="cap">区間</span>'
      +(hasRange?'<span class="pctrange">'+sp+'% → '+ep+'%</span>':'');
    var head='<span class="bt-l">'+fmtDur(w.span)+'</span>';
    summary.innerHTML='<span class="chiprow">'+chipHtml+'</span><span class="bigtime">'+head+'</span><span class="sumline">'+txt+'</span>';
    setT('tile-pph', fmt(w.pph!==null?Math.abs(w.pph):null,1));
    setT('tile-pph-k', w.dir+' %/h');
    setT('tile-avgw', fmt(w.avgW,2));
    setT('tile-wh', fmt(w.dwh,3));
    var perPt=(w.dp&&w.span)?w.span/Math.abs(w.dp):null;
    var perPtTxt=(perPt==null)?'-':(perPt>=60?(perPt/60).toFixed(1)+'分':Math.round(perPt)+'秒');
    setT('tile-perpt', perPtTxt);
  }
  function buildCopy(){
    var w=whole(), m=(typeof META!=='undefined')?META:{};
    var L=[];
    L.push('wattlog 計測サマリ');
    L.push('モード: '+(m.mode||'-')+' / 開始 '+(m.start||'-')+' / 終了 '+(m.end||'-')+' / 経過 '+fmtDur(w.span));
    L.push('残量: '+fmt(m.startPct,1)+'% → '+fmt(m.endPct,1)+'% (Δ '+fmt(w.dp,2)+' pt) / '+w.dir+' '+fmt(w.pph!==null?Math.abs(w.pph):null,1)+' %/h');
    L.push('平均消費電力: '+fmt(w.avgW,2)+' W / '+fmt(w.whh,2)+' Wh/h / 累積 '+fmt(w.dwh,3)+' Wh');
    if(w.remH!==null){ L.push('満充電→0%の推定: '+fmtDur(w.remH*3600)); }
    L.push('停止理由: '+(m.stop||'-'));
    if(m.dev){ L.push('端末: '+m.dev); }
    L.push('計測条件: '+(m.cond||'-'));
    return L.join('\n');
  }
  function doCopy(){
    var btn=document.getElementById('copybtn'); if(!btn) return;
    var txt=buildCopy();
    function done(ok){ btn.textContent=ok?'コピーしました':'コピー失敗'; btn.classList.add('done'); setTimeout(function(){ btn.textContent='サマリをコピー'; btn.classList.remove('done'); },1600); }
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
    if(h>0 && m>0) return h+'時間'+m+'分';
    if(h>0) return h+'時間';
    return m+'分';
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
    var rows=[{lb:'開始', p:pctAt(0)}];
    var k=1, fullRow=false;
    while(k*TSTEP < span){
      var p=pctAt(k*TSTEP);
      rows.push({lb:tLabel(k*TSTEP), p:p});
      if(MODE==='charge' && p!==null && p>=99){ fullRow=true; break; } // 充電は満タン到達行で打ち切り（以降の100%横ばいはノイズ）
      k++;
    }
    if(MODE!=='charge' || !fullRow) rows.push({lb:'終了', p:pctAt(span)});
    var isCharge = MODE==='charge';
    var h='<table><tr><th></th><th>'+(isCharge?'残量表示':'電池残量')+'</th><th>'+(isCharge?'回復差':'減少差')+'</th></tr>';
    var t='経過\t'+(isCharge?'残量表示':'電池残量')+'\t'+(isCharge?'回復差':'減少差');
    var prev=null;
    rows.forEach(function(r){
      var d=(r.p===null||prev===null) ? null : r.p-prev;
      var dtxt=(r.lb==='開始') ? (r.p===null?'-':'0%') : diffTxt(d);
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
    btn.textContent=ok?'コピーしました':'コピー失敗'; btn.classList.add('done');
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
        var ok=document.execCommand('copy'); s.removeAllRanges(); flash(btn,ok,'表をコピー');
      }catch(e){ flash(btn,false,'表をコピー'); }
    }
    if(navigator.clipboard&&window.ClipboardItem){
      try{
        navigator.clipboard.write([new ClipboardItem({
          'text/html': new Blob([TBL_HTML],{type:'text/html'}),
          'text/plain': new Blob([TBL_TEXT],{type:'text/plain'})
        })]).then(function(){ flash(btn,true,'表をコピー'); }, selFallback);
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
      if(!sel){ panel.textContent=fmtDur(d.t)+' | 残量 '+fmt(d.p,1)+'% | '+fmt(d.w,2)+' W | 累積 '+fmt(d.h,3)+' Wh'; }
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
        if(anchor===null){ anchor=t; sel=null; paint(); panel.textContent='始点 '+fmtDur(t)+' を設定。終点をクリック（ダブルクリックで取消）'; }
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
  var th=document.getElementById('copytblhtml'); if(th){ th.addEventListener('click',function(){ copyText(TBL_HTML,th,'HTMLコピー'); }); }
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
      toast('スクショ用モードです。撮影後 Esc で解除');
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
  if ($devStr -ne '' -and $devStr -notmatch '記録なし') {
    $parts = $devStr -split ' / '
    $model = ''; $os = ''; $kv = @()
    foreach ($p in $parts) {
      $t = ([string]$p).Trim()
      if ($t -eq '') { continue }
      if ($t -match '^(CPU|RAM|GPU|表示|Disk|NPU|サイクル)\s+(.*)$') { $kv += ,@($matches[1], $matches[2]) }
      elseif ($t -match '^(Windows|macOS)') { $os = $t }
      elseif ($model -eq '') { $model = $t }
      else { $kv += ,@('', $t) }
    }
    $rh = ''
    if ($model -ne '') { $rh += '<tr><th>機種</th><td>' + (Esc $model) + '</td></tr>' }
    if ($os -ne '')    { $rh += '<tr><th>OS</th><td>' + (Esc $os) + '</td></tr>' }
    foreach ($pair in $kv) { $rh += '<tr><th>' + (Esc $pair[0]) + '</th><td>' + (Esc $pair[1]) + '</td></tr>' }
    if ($rh -ne '') { $devCard = '<div class="card"><h3>端末情報</h3><table class="kv">' + $rh + '</table></div>' }
  }
  # 計測条件カード: 記録なし/なし/空 のときは出さない
  $condCard = ''
  $condStr = ([string]$Meta.conditions).Trim()
  if ($condStr -ne '' -and $condStr -notmatch '記録なし' -and $condStr -ne 'なし') {
    $condCard = '<div class="card"><h3>計測条件</h3><p class="condtxt">' + (Esc $condStr) + '</p></div>'
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
  $wNote = '移動中央値 約' + $wSec + '秒'
  if ($wClip) { $wNote += '（上限は99パーセンタイルでクリップ）' }
  $tpl = @"
<!doctype html>
<html lang="ja"><head><meta charset="utf-8">
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
  <h1>wattlog 計測結果</h1>
  <p class="sub">システム全体の消費電力と残量の推移 / 生成 $(Esc $Meta.generatedIso)</p>
  <div class="cols">
    <div class="colside">
      <div class="summaryrow">
        <div class="panel summary" id="summary">区間を集計中…</div>
        <div class="sumbtns">
          <button type="button" id="copybtn" class="copybtn">サマリをコピー</button>
          <button type="button" id="shotbtn" class="copybtn" title="左カラムのスクロールを解除し操作UIを隠します。Escで戻ります">スクショ用</button>
        </div>
      </div>
      $devCard
      <div class="tiles">
        <div class="tile"><span class="tv" id="tile-pph">-</span><span class="tk" id="tile-pph-k">%/h</span></div>
        <div class="tile"><span class="tv" id="tile-avgw">-</span><span class="tk">平均 W</span></div>
        <div class="tile"><span class="tv" id="tile-wh">-</span><span class="tk">累積 Wh</span></div>
        <div class="tile"><span class="tv" id="tile-perpt">-</span><span class="tk">1%あたり</span></div>
      </div>
      $condCard
      <details class="metadtl">
        <summary>計測情報（クリックで開閉）</summary>
        <table class="meta">
          <tr><th>モード</th><td>$(Esc $Meta.mode)</td></tr>
          <tr><th>開始</th><td>$(Esc $Meta.startIso)</td></tr>
          <tr><th>終了</th><td>$(Esc $Meta.endIso)</td></tr>
          <tr><th>サンプル数</th><td>$($Rows.Count)</td></tr>
          <tr><th>経過</th><td>$(FmtDur $Meta.elapsed_s)</td></tr>
          <tr><th>間隔</th><td>$(Fmt $Meta.interval 0) s</td></tr>
          <tr><th>開始残量</th><td>$(Fmt $Meta.startPct 1) %</td></tr>
          <tr><th>終了残量</th><td>$(Fmt $Meta.endPct 1) %</td></tr>
          <tr><th>残量変化</th><td>$dPct</td></tr>
          <tr><th>累積Wh</th><td>$(Fmt $Meta.cumulative_wh 2) Wh</td></tr>
          <tr><th>平均W</th><td>$(Fmt $Meta.avg_w 2) W</td></tr>
          <tr><th>停止理由</th><td>$(Esc $Meta.stopReason)</td></tr>
          <tr><th>満充電容量</th><td>$(Fmt $Meta.full_wh 1) Wh</td></tr>
          <tr><th>W取得経路</th><td>$(Esc $Meta.wSourceNote)</td></tr>
        </table>
      </details>
      <section>
        <h2>経過時間と電池残量 <span class="unit">(記事貼り付け用の表)</span></h2>
        <div class="tblbar">
          <span class="chips">間隔:
            <button type="button" class="chip" data-step="900">15分</button>
            <button type="button" class="chip" data-step="1800">30分</button>
            <button type="button" class="chip" data-step="3600">1時間</button>
          </span>
          <button type="button" id="copytbl" class="copybtn">表をコピー</button>
          <button type="button" id="copytblhtml" class="copybtn">HTMLコピー</button>
        </div>
        <div id="battable"><p class="empty">表を描画中…</p></div>
      </section>
    </div>
    <div class="colcharts">
      <div class="panel" id="selpanel">始点クリック→終点クリックで区間統計（ドラッグでも可） / ホバー=値読取 / ダブルクリック=解除</div>
      $(New-SvgChart '残量' '%' $pctPts '#2563a8' 0 100 $false 'pct')
      $(New-SvgChart '瞬時消費電力' 'W' $wSmooth '#c2571a' 0 $wCap $wClip 'watt' $wNote)
      $(New-SvgChart '累積消費電力量' 'Wh' $whPts '#0f766e' 0 $null $false 'wh')
    </div>
  </div>
  <footer>wattlog 第1段 / ゼロインストール・インラインSVG。この HTML 単体で開いてスクリーンショット可能。</footer>
</div>
"@
  $fullWhJs = if ($null -ne $Meta.full_wh) { Fmt $Meta.full_wh 3 } else { 'null' }
  $metaJs = 'var META={mode:' + (JsStr $Meta.mode) + ',start:' + (JsStr $Meta.startIso) + ',end:' + (JsStr $Meta.endIso) +
            ',stop:' + (JsStr $Meta.stopReason) + ',cond:' + (JsStr $Meta.conditions) + ',dev:' + (JsStr $Meta.device) +
            ',startPct:' + $(if ($null -ne $Meta.startPct) { Fmt $Meta.startPct 2 } else { 'null' }) +
            ',endPct:' + $(if ($null -ne $Meta.endPct) { Fmt $Meta.endPct 2 } else { 'null' }) + '};'
  return $tpl + "<script>var DATA=[$dataJs];var FULLWH=$fullWhJs;$metaJs</script>" + $script:JSUI + "</body></html>"
}

# ---------- CSV から HTML 再生成（計測しない・UI変更後の確認用） ----------
if ($FromCsv) {
  if (-not (Test-Path $FromCsv)) { throw "CSV が見つかりません: $FromCsv" }
  $csvFull = (Resolve-Path $FromCsv).Path
  $lines = @(Get-Content -Path $csvFull)
  $condLine = $lines | Where-Object { $_ -match '^#\s*conditions:' } | Select-Object -First 1
  $conditions2 = if ($condLine) { ($condLine -replace '^#\s*conditions:\s*', '') } else { '（このCSVに条件記録なし）' }
  $devLine = $lines | Where-Object { $_ -match '^#\s*device:' } | Select-Object -First 1
  $device2 = if ($devLine) { ($devLine -replace '^#\s*device:\s*', '') } else { '（このCSVに端末情報記録なし）' }
  $dataLines = @($lines | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' })
  $raw = @($dataLines | ConvertFrom-Csv)
  if ($raw.Count -eq 0) { throw "CSV にデータ行がありません: $FromCsv" }
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
    stopReason = 'CSV から再生成（計測していない）'
    full_wh = if ($lastFull) { $lastFull / 1000 } else { $null }
    wSourceNote = "rate(直接)=$($cnt2.rate) / pct(算出)=$($cnt2.pct) / 取得不可=$($cnt2.none)"
    conditions = $conditions2; device = $device2
  }
  # -Out が絶対パスならそのまま使う（Join-Path で「C:\...\C:\...」になるのを防ぐ）。相対ならカレントに連結
  $outDirR = if ($Out) { if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path (Resolve-Path .).Path $Out } }
              else { [System.IO.Path]::GetDirectoryName($csvFull) }
  if (-not (Test-Path -LiteralPath $outDirR)) { New-Item -ItemType Directory -Path $outDirR | Out-Null }
  $html2 = Join-Path $outDirR "$baseName.html"
  Build-Html $rows2 $meta2 | Set-Content -Path $html2 -Encoding UTF8
  Write-Host "HTML 再生成: $html2"
  Write-Host ("サンプル数 {0} / モード {1} / 残量 {2}%→{3}% / 累積 {4} Wh" -f `
    $rows2.Count, $mode2, (Fmt $meta2.startPct 1), (Fmt $meta2.endPct 1), (Fmt $meta2.cumulative_wh 2))
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
Set-Content -Path $csvPath -Value @("# device: $device", "# conditions: $conditions", $CSV_HEADER) -Encoding UTF8

$rows = New-Object System.Collections.Generic.List[object]
$start = Get-Date
$cum = 0.0
$prev = $null
$capacityWh = $null
$counts = @{ rate = 0; pct = 0; none = 0 }
$stopReason = ''
$everCharged = $false
$notChargingStreak = 0

Write-Host ("wattlog 開始: mode={0} interval={1}s stop-at={2}%{3}" -f $Mode, $Interval, $StopAt, $(if ($Duration -gt 0) { " duration=$Duration min" } else { '' }))
if ($KeepAwake -eq 'on') {
  Write-Host ("keep-awake: on (set_ret={0}。アイドルスリープ防止 / 蓋閉じは未検証・powercfg LIDACTION が確実)" -f $esSet)
} else {
  Write-Host 'keep-awake: off'
}
Write-Host "出力先: $outDir"
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

  Write-Host ("[{0,5}s] 残量 {1} | W {2} ({3}) | 累積 {4} Wh | {5}{6}" -f `
    $elapsed_s,
    $(if ($null -ne $pct) { "$(Fmt $pct 1)%" } else { ' n/a' }),
    $(if ($null -ne $watts) { Fmt $watts 2 } else { '  n/a' }),
    $wSource,
    (Fmt $cum 2),
    $(if ($d.power_online) { 'AC' } else { 'BAT' }),
    $(if ($d.charging) { ' 充電中' } else { '' }))

  # サンプル毎にHTMLも更新（強制終了でも直前分まで残る）
  $wVals = @($rows | ForEach-Object { $_.watts } | Where-Object { $null -ne $_ })
  $avg = if ($wVals.Count) { ($wVals | Measure-Object -Average).Average } else { $null }
  $meta = [pscustomobject]@{
    mode = $Mode; interval = $Interval; startIso = IsoLocal $start; endIso = IsoLocal $now
    generatedIso = IsoLocal $now; elapsed_s = $elapsed_s
    startPct = $rows[0].battery_pct; endPct = $row.battery_pct
    cumulative_wh = $cum; avg_w = $avg; stopReason = if ($stopReason) { $stopReason } else { '計測中' }
    full_wh = if ($full_mwh) { $full_mwh / 1000 } else { $null }
    wSourceNote = "rate(直接)=$($counts.rate) / pct(算出)=$($counts.pct) / 取得不可=$($counts.none)"
    conditions = $conditions; device = $device
  }
  Write-SampleHtml $meta

  $prev = [pscustomobject]@{ ms = $now; pct = $pct; watts = $watts }

  # 充電完了の検出: AC接続で charging フラグが OFF（満充電宣言）→ 数サンプル連続で停止
  if ($Mode -eq 'charge') {
    if ($d.charging) { $everCharged = $true; $notChargingStreak = 0 }
    elseif ($d.power_online) { $notChargingStreak += 1 }
    if ($notChargingStreak -ge 3) {
      $why = if ($everCharged) { '充電完了（充電フラグOFF）' } else { '満充電（充電不要・開始時から）' }
      $stopReason = "残量 $(Fmt $pct 1)% / $why"
      break
    }
  }

  if ($null -ne $pct) {
    if ($Mode -eq 'discharge' -and $pct -le $StopAt) { $stopReason = "残量 $(Fmt $pct 1)% が停止閾値 $StopAt% 以下"; break }
    if ($Mode -eq 'charge' -and $pct -ge $StopAt) { $stopReason = "残量 $(Fmt $pct 1)% が停止閾値 $StopAt% 以上"; break }
  }
  if ($Duration -gt 0 -and $elapsed_s -ge $Duration * 60) { $stopReason = "経過 $elapsed_s s が指定時間 $Duration 分に到達"; break }
}

# ---------- 終了処理 ----------
Stop-KeepAwake
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
  wSourceNote = "rate(直接)=$($counts.rate) / pct(算出)=$($counts.pct) / 取得不可=$($counts.none)"
  conditions = $conditions; device = $device
}
Write-SampleHtml $meta

Write-Host ('-' * 72)
Write-Host "停止理由: $stopReason"
Write-Host "サンプル数: $($rows.Count) / 経過: $elapsed_s s"
Write-Host ("残量: {0}% → {1}% ({2} pt)" -f (Fmt $meta.startPct 1), (Fmt $meta.endPct 1), (Fmt ($meta.endPct - $meta.startPct) 1))
Write-Host ("累積: {0} Wh / 平均: {1} W / keep-awake clear_ret={2}" -f (Fmt $cum 2), $(if ($null -ne $avg) { Fmt $avg 2 } else { '-' }), $esClear)
Write-Host ("W取得経路: {0}" -f $meta.wSourceNote)
Write-Host "CSV : $csvPath"
Write-Host "HTML: $htmlPath"
if ($showMenu) { Read-Host 'Enter でウィンドウを閉じます' | Out-Null }
