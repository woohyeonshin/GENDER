# cdp_server.ps1 - resident helper for the Zendesk macro (Windows PowerShell 5.1, nothing to install)
# Started hidden by the macro (.ahk). Talks to Chrome through the debug port and to the macro through files:
#   request : <IpcDir>\in.txt   lines "key=value" (value escaped: \\ \n \t), first keys: id, cmd
#   response: <IpcDir>\out.txt  one line  id <TAB> OK|ERR <TAB> field1 <TAB> field2 ...  (fields escaped)
# Commands: ping, reset, tabs, window, pick, text, act (do = type|paste|selectall|copy|click|rclick|select)
# Never presses the submit button by itself: a click on data-test-id starting with "submit_button" is refused.
# This file must stay ASCII only (PowerShell 5.1 reads BOM-less files as ANSI).
param(
    [int]$Port = 9222,
    [Parameter(Mandatory = $true)][string]$IpcDir,
    [int]$ParentPid = 0
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$inFile = Join-Path $IpcDir 'in.txt'
$outFile = Join-Path $IpcDir 'out.txt'
$outTmp = Join-Path $IpcDir 'out.tmp'
$readyFile = Join-Path $IpcDir 'ready.txt'
$logFile = Join-Path $IpcDir 'server.log'

function Log([string]$m) {
    try { [IO.File]::AppendAllText($logFile, ((Get-Date).ToString('HH:mm:ss') + ' ' + $m + "`r`n"), $utf8) } catch { }
}

# ---- escaping shared with the macro (same rules as Enc/Dec in the .ahk) ----
function Enc([string]$s) {
    if ($null -eq $s) { return '' }
    return $s.Replace('\', '\\').Replace("`r", '').Replace("`n", '\n').Replace("`t", '\t')
}
function Dec([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -eq '\' -and $i -lt $s.Length - 1) {
            $d = $s[$i + 1]
            if ($d -eq 'n') { [void]$sb.Append("`n") }
            elseif ($d -eq 't') { [void]$sb.Append("`t") }
            else { [void]$sb.Append($d) }
            $i += 2
        } else { [void]$sb.Append($c); $i++ }
    }
    return $sb.ToString()
}
function Q([string]$s) { return ($s | ConvertTo-Json -Compress) }

# ---- Chrome tabs and websocket connections ----
$script:conns = @{}       # tab id -> @{ ws; seq }
$script:installed = @{}   # tab id -> $true (hover tracker installed)
$script:cur = $null       # tab id the macro is working in
$script:front = $null     # tab id last brought to front

function New-Token([int]$ms = 15000) { return (New-Object System.Threading.CancellationTokenSource($ms)).Token }

function Get-Tabs {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Proxy = $null
        $json = $wc.DownloadString("http://127.0.0.1:$Port/json")
    } catch { throw ('NO_CHROME (debug Chrome is not running on port ' + $Port + ')') }
    $all = $json | ConvertFrom-Json
    return @($all | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl -and $_.url -notlike 'devtools://*' -and $_.url -notlike 'chrome-extension://*' })
}

function Get-Conn($tab) {
    $c = $script:conns[$tab.id]
    if ($c -and $c.ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) { return $c }
    if ($c) { try { $c.ws.Dispose() } catch { } }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $null = $ws.ConnectAsync([Uri]$tab.webSocketDebuggerUrl, (New-Token)).GetAwaiter().GetResult()
    $c = @{ ws = $ws; seq = 0 }
    $script:conns[$tab.id] = $c
    $script:installed.Remove($tab.id)
    return $c
}

function Invoke-Cdp($c, [string]$method, $params = @{}) {
    $c.seq++
    $myId = $c.seq
    $json = @{ id = $myId; method = $method; params = $params } | ConvertTo-Json -Depth 20 -Compress
    $bytes = $utf8.GetBytes($json)
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $bytes)
    $null = $c.ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, (New-Token)).GetAwaiter().GetResult()
    $buf = New-Object byte[] 65536
    while ($true) {
        $ms = New-Object System.IO.MemoryStream
        do {
            $rseg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $buf)
            $r = $c.ws.ReceiveAsync($rseg, (New-Token)).GetAwaiter().GetResult()
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'CHROME_CLOSED_TAB' }
            $ms.Write($buf, 0, $r.Count)
        } until ($r.EndOfMessage)
        $obj = $utf8.GetString($ms.ToArray()) | ConvertFrom-Json
        if ($obj.id -eq $myId) { return $obj }
    }
}

function Eval-Js($c, [string]$expr) {
    $res = Invoke-Cdp $c 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true; awaitPromise = $true }
    if ($res.error) { throw ('CDP error: ' + $res.error.message) }
    if ($res.result.exceptionDetails) { throw ('JS error: ' + ($res.result.exceptionDetails | ConvertTo-Json -Depth 5 -Compress)) }
    return $res.result.result.value
}

# ---- page-side helpers (labels are found the same way as in cdp_act.ps1, which was verified on a Zendesk trial) ----
$pre = @'
const norm = s => (s || '').replace(/\s+/g, ' ').trim();
const vis = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
const labelOf = e => {
  if (e.labels && e.labels[0]) return e.labels[0].innerText;
  const lb = e.getAttribute('aria-labelledby');
  if (lb) { const t = document.getElementById(lb.split(' ')[0]); if (t) return t.innerText; }
  let p = e;
  for (let i = 0; i < 4 && p; i++) { p = p.parentElement; if (!p) break; const l = p.querySelector('label'); if (l) return l.innerText; }
  return '';
};
const CTL = 'input:not([type=file]):not([type=hidden]),textarea,select,[role=combobox],[role=textbox]';
const CLK = 'button,a,[role=button],[role=option],[role=tab],[role=menuitem],[role=link],[role=checkbox],[role=radio],summary,label';
const listLabel = label => {
  const wl = [...document.querySelectorAll(CTL)].filter(vis).map(e => [e, norm(labelOf(e))]).filter(x => x[1] !== '');
  let l = wl.filter(x => x[1] === label);
  if (!l.length) l = wl.filter(x => x[1].includes(label));
  return l.map(x => x[0]);
};
const listTestId = id => [...document.querySelectorAll('[data-test-id=' + JSON.stringify(id) + ']')].filter(vis);
const textOf = e => norm(e.innerText || e.getAttribute('aria-label'));
const listText = key => {
  const c = [...document.querySelectorAll(CLK)].filter(vis);
  let l = c.filter(e => textOf(e) === key);
  if (!l.length) l = [...document.querySelectorAll('*')].filter(e => e.children.length === 0 && vis(e) && norm(e.innerText) === key);
  const nd = t => t.replace(/[0-9]+/g, '#');   // counters like "알림: 0개" change: match with digits ignored
  if (!l.length && /[0-9]/.test(key)) l = c.filter(e => nd(textOf(e)) === nd(key));
  if (!l.length) l = c.filter(e => textOf(e).includes(key));
  return l;
};
const listAria = key => [...document.querySelectorAll(CTL)].filter(vis).filter(e => norm(e.getAttribute('aria-label')) === key);
const findBy = (by, key, n) => {
  let l = [];
  if (by === 'clabel' || by === 'label') l = listLabel(key);
  else if (by === 'caria') l = listAria(key);
  else if (by === 'ctestid') l = listTestId(key);
  else if (by === 'ctext') l = listText(key);
  else { l = listText(key); if (!l.length) l = listLabel(key); }
  return l.length >= n ? l[n - 1] : null;
};
const pointOf = el => {
  el.scrollIntoView({ block: 'center' });
  let p = el;
  // narrow inputs are clicked through their wrapper; buttons/links/options are clicked at their own center
  if (el.matches(CTL)) { while (p && p.getBoundingClientRect().width < 60 && p.parentElement) p = p.parentElement; }
  const r = p.getBoundingClientRect();
  return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };
};
'@

# remembers the element the mouse last moved over (so F-keys in the macro can ask "what is under the mouse?" without screen coordinates)
$pickJs = @'
(() => { if (window.__zdInst) return 1; window.__zdInst = true;
  const h = e => { window.__zdPick = e.target; window.__zdT = Date.now(); };
  document.addEventListener('mouseover', h, true); document.addEventListener('mousemove', h, true); return 1; })()
'@

function Run-Js($c, [string]$body) { return (Eval-Js $c ('(() => {' + $pre + $body + '})()')) | ConvertFrom-Json }

function Install-Pick($tab) {
    if ($script:installed.ContainsKey($tab.id)) { return }
    $c = Get-Conn $tab
    $null = Invoke-Cdp $c 'Page.addScriptToEvaluateOnNewDocument' @{ source = $pickJs }
    $null = Invoke-Cdp $c 'Runtime.evaluate' @{ expression = $pickJs; returnByValue = $true }
    $script:installed[$tab.id] = $true
}

function Sweep {
    try {
        $tabs = @(Get-Tabs)
        $ids = @{}
        foreach ($t in $tabs) {
            $ids[$t.id] = $true
            try { Install-Pick $t } catch { Log ('install failed: ' + $_.Exception.Message) }
        }
        foreach ($k in @($script:conns.Keys)) {
            if (-not $ids.ContainsKey($k)) {
                try { $script:conns[$k].ws.Dispose() } catch { }
                $script:conns.Remove($k)
                $script:installed.Remove($k)
            }
        }
    } catch { }
}

# the tab the user is looking at: has focus > is visible > looks like Zendesk
function Find-ActiveTab {
    $tabs = @(Get-Tabs)
    if (-not $tabs.Count) { throw 'NO_TAB' }
    $best = $null; $bestScore = -1
    foreach ($t in $tabs) {
        $score = 0
        try {
            $c = Get-Conn $t
            $st = (Eval-Js $c 'JSON.stringify([document.visibilityState, document.hasFocus()])') | ConvertFrom-Json
            if ($st[1]) { $score += 4 }
            if ($st[0] -eq 'visible') { $score += 2 }
        } catch { }
        if ("$($t.url)" -like '*zendesk*') { $score += 1 }
        if ($score -gt $bestScore) { $best = $t; $bestScore = $score }
    }
    return $best
}

function Resolve-Tab {
    $tabs = @(Get-Tabs)
    if (-not $tabs.Count) { throw 'NO_TAB' }
    if ($script:cur) {
        $t = $tabs | Where-Object { $_.id -eq $script:cur } | Select-Object -First 1
        if ($t) { return $t }
    }
    $t = Find-ActiveTab
    $script:cur = $t.id
    return $t
}

function Front($tab, $c) {
    if ($script:front -ne $tab.id) {
        $null = Invoke-Cdp $c 'Page.bringToFront'
        $script:front = $tab.id
    }
}

function Click-At($c, [double]$x, [double]$y, [string]$button = 'left') {
    $b = 1; if ($button -eq 'right') { $b = 2 }
    $null = Invoke-Cdp $c 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = $x; y = $y }
    $null = Invoke-Cdp $c 'Input.dispatchMouseEvent' @{ type = 'mousePressed'; x = $x; y = $y; button = $button; buttons = $b; clickCount = 1 }
    $null = Invoke-Cdp $c 'Input.dispatchMouseEvent' @{ type = 'mouseReleased'; x = $x; y = $y; button = $button; buttons = 0; clickCount = 1 }
}

function Press-Key($c, [string]$key, [int]$vk) {
    $null = Invoke-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = $key; code = $key; windowsVirtualKeyCode = $vk }
    $null = Invoke-Cdp $c 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = $key; code = $key; windowsVirtualKeyCode = $vk }
}

# ---- commands ----
function Do-Pick {
    $tabs = @(Get-Tabs)
    if (-not $tabs.Count) { throw 'NO_TAB' }
    $bestTab = $null; $bestT = 0
    foreach ($t in $tabs) {
        try {
            Install-Pick $t
            $c = Get-Conn $t
            $v = [double](Eval-Js $c '(window.__zdT || 0)')
            if ($v -gt $bestT) { $bestT = $v; $bestTab = $t }
        } catch { }
    }
    if (-not $bestTab) { throw 'NO_HOVER' }
    $c = Get-Conn $bestTab
    $r = Run-Js $c @'
const sel = window.__zdPick;
if (!sel || !document.contains(sel)) return JSON.stringify({ ok: false, err: 'NO_HOVER' });
let el = sel.closest(CTL);
if (!el && !sel.closest(CLK)) {
  let p = sel;
  for (let i = 0; i < 4 && p; i++, p = p.parentElement) {
    const cs = [...p.querySelectorAll(CTL)].filter(vis);
    if (cs.length === 1) { el = cs[0]; break; }
    if (cs.length > 1) break;
  }
}
const tagOf = e => e.tagName.toLowerCase() + (e.getAttribute('role') ? '/' + e.getAttribute('role') : '');
if (el) {
  const label = el.isContentEditable ? '' : norm(labelOf(el));   // rich editors (reply box): use data-test-id instead
  if (label) {
    const n = listLabel(label).indexOf(el) + 1;
    if (n > 0) return JSON.stringify({ ok: true, by: 'clabel', key: label, n: n, tag: tagOf(el) });
  }
  const tid = el.getAttribute('data-test-id');
  if (tid) {
    const n = listTestId(tid).indexOf(el) + 1;
    if (n > 0) return JSON.stringify({ ok: true, by: 'ctestid', key: tid, n: n, tag: tagOf(el) });
  }
}
if (el) {
  const ar = norm(el.getAttribute('aria-label'));
  if (ar) {
    const n = listAria(ar).indexOf(el) + 1;
    if (n > 0) return JSON.stringify({ ok: true, by: 'caria', key: ar, n: n, tag: tagOf(el) });
  }
}
const btn = sel.closest(CLK);
if (btn) {
  const t = textOf(btn);
  if (t && t.length <= 80) {
    const n = listText(t).indexOf(btn) + 1;
    if (n > 0) return JSON.stringify({ ok: true, by: 'ctext', key: t, n: n, tag: tagOf(btn) });
  }
  const tid = btn.getAttribute('data-test-id');
  if (tid) {
    const n = listTestId(tid).indexOf(btn) + 1;
    if (n > 0) return JSON.stringify({ ok: true, by: 'ctestid', key: tid, n: n, tag: tagOf(btn) });
  }
}
const holder = sel.closest('[data-test-id]');
if (holder) {
  const tid = holder.getAttribute('data-test-id');
  const n = listTestId(tid).indexOf(holder) + 1;
  if (n > 0) return JSON.stringify({ ok: true, by: 'ctestid', key: tid, n: n, tag: tagOf(holder) });
}
const t2 = norm(sel.innerText);
if (t2 && t2.length <= 80) {
  const n = listText(t2).indexOf(sel) + 1;
  if (n > 0) return JSON.stringify({ ok: true, by: 'ctext', key: t2, n: n, tag: tagOf(sel) });
}
if (!el && !btn) {
  // last resort: the visible input closest to the hovered spot (within 60px, small hovered element only)
  const r0 = sel.getBoundingClientRect(); const cx = r0.x + r0.width / 2, cy = r0.y + r0.height / 2;
  let best = null, bd = (r0.width < 300 && r0.height < 120) ? 60 : 0;
  for (const c of [...document.querySelectorAll(CTL)].filter(vis)) {
    const r = c.getBoundingClientRect();
    const dx = Math.max(r.left - cx, 0, cx - r.right), dy = Math.max(r.top - cy, 0, cy - r.bottom);
    const d = Math.hypot(dx, dy);
    if (d < bd) { bd = d; best = c; }
  }
  if (best) {
    const lb = best.isContentEditable ? '' : norm(labelOf(best));
    if (lb) { const n = listLabel(lb).indexOf(best) + 1; if (n > 0) return JSON.stringify({ ok: true, by: 'clabel', key: lb, n: n, tag: tagOf(best) }); }
    const ar = norm(best.getAttribute('aria-label'));
    if (ar) { const n = listAria(ar).indexOf(best) + 1; if (n > 0) return JSON.stringify({ ok: true, by: 'caria', key: ar, n: n, tag: tagOf(best) }); }
    const tid = best.getAttribute('data-test-id');
    if (tid) { const n = listTestId(tid).indexOf(best) + 1; if (n > 0) return JSON.stringify({ ok: true, by: 'ctestid', key: tid, n: n, tag: tagOf(best) }); }
  }
}
const chain = []; { let q = sel; for (let i = 0; i < 4 && q; i++, q = q.parentElement) chain.push(q.tagName.toLowerCase() + (q.id ? '#' + q.id : '') + (q.getAttribute('role') ? '[' + q.getAttribute('role') + ']' : '') + (q.getAttribute('data-test-id') ? '{' + q.getAttribute('data-test-id') + '}' : '')); }
return JSON.stringify({ ok: false, err: 'NO_TARGET ' + chain.join(' < ') + ' | ' + location.hostname });
'@
    if (-not $r.ok) { throw $r.err }
    $script:cur = $bestTab.id
    return @($r.by, $r.key, [string]$r.n, $r.tag)
}

function Do-Act($q) {
    $tab = Resolve-Tab
    $c = Get-Conn $tab
    Front $tab $c
    $by = [string]$q['by']; $key = [string]$q['key']
    $n = 1; $tmp = 0
    if ([int]::TryParse([string]$q['n'], [ref]$tmp) -and $tmp -ge 1) { $n = $tmp }
    $find = 'const el = findBy(' + (Q $by) + ',' + (Q $key) + ',' + $n + "); if (!el) return JSON.stringify({ok:false,err:'NOT_FOUND'});"
    $text = [string]$q['text']
    switch ($q['do']) {
        'type' {
            $clear = 'false'; if ($q['clear'] -eq '1') { $clear = 'true' }
            $r = Run-Js $c ($find +
                "if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {" +
                "el.scrollIntoView({block:'center'}); el.focus();" +
                "const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;" +
                "const nv = (" + $clear + " ? '' : el.value) + " + (Q $text) + ";" +
                "Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, nv);" +
                "el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true}));" +
                "return JSON.stringify({ok:true, mode:'input'}); }" +
                "const p = pointOf(el); return JSON.stringify({ok:true, mode:'rich', x:p.x, y:p.y});")
            if (-not $r.ok) { throw $r.err }
            if ($r.mode -eq 'rich') {
                Click-At $c $r.x $r.y
                Start-Sleep -Milliseconds 250
                if ($clear -eq 'true') { $null = Eval-Js $c "document.execCommand('selectAll')" }
                if ($text -ne '') { $null = Invoke-Cdp $c 'Input.insertText' @{ text = $text } }
            }
            return @('ok')
        }
        'paste' {
            $r = Run-Js $c ($find + "const p = pointOf(el); return JSON.stringify({ok:true,x:p.x,y:p.y,tag:el.tagName});")
            if (-not $r.ok) { throw $r.err }
            Click-At $c $r.x $r.y
            Start-Sleep -Milliseconds 150
            if ($text -ne '') {
                $null = Invoke-Cdp $c 'Input.insertText' @{ text = $text }
                if ($r.tag -eq 'INPUT' -or $r.tag -eq 'TEXTAREA') {
                    # insertText normally fires the page's input events; if the value did not change, fall back to the native setter
                    $probe = ($text -split "`r?`n")[0]
                    if ($probe.Length -gt 0) {
                        $chk = Run-Js $c ("const a = document.activeElement; if (!a || (a.tagName !== 'INPUT' && a.tagName !== 'TEXTAREA')) return JSON.stringify({ok:true,skip:true});" +
                            "if (a.value.includes(" + (Q $probe) + ")) return JSON.stringify({ok:true,has:true});" +
                            "const proto = a.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;" +
                            "Object.getOwnPropertyDescriptor(proto, 'value').set.call(a, a.value + " + (Q $text) + ");" +
                            "a.dispatchEvent(new Event('input', {bubbles:true})); a.dispatchEvent(new Event('change', {bubbles:true}));" +
                            "return JSON.stringify({ok:true,fallback:true});")
                    }
                }
            }
            return @('ok')
        }
        'selectall' {
            $r = Run-Js $c ($find + "const p = pointOf(el); return JSON.stringify({ok:true,x:p.x,y:p.y});")
            if (-not $r.ok) { throw $r.err }
            Click-At $c $r.x $r.y
            Start-Sleep -Milliseconds 150
            $null = Eval-Js $c "(() => { const a = document.activeElement; if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA')) a.select(); else document.execCommand('selectAll'); return 1; })()"
            return @('ok')
        }
        'copy' {
            $r = Run-Js $c ($find + "return JSON.stringify({ok:true, text: ((el.value !== undefined && el.value !== '') ? el.value : (el.innerText || el.textContent || '')).trim()});")
            if (-not $r.ok) { throw $r.err }
            if ([string]$r.text -eq '') { throw 'EMPTY' }
            return @([string]$r.text)
        }
        'click' {
            $r = Run-Js $c ($find + "const t = el.getAttribute('data-test-id') || ''; if (t.indexOf('submit_button') === 0) return JSON.stringify({ok:false,err:'BLOCKED_SUBMIT'}); const p = pointOf(el); return JSON.stringify({ok:true,x:p.x,y:p.y});")
            if (-not $r.ok) { throw $r.err }
            Click-At $c $r.x $r.y
            return @('ok')
        }
        'rclick' {
            $r = Run-Js $c ($find + "const p = pointOf(el); return JSON.stringify({ok:true,x:p.x,y:p.y});")
            if (-not $r.ok) { throw $r.err }
            Click-At $c $r.x $r.y 'right'
            return @('ok')
        }
        'select' {
            $opt = [string]$q['option']
            $qo = Q $opt
            $r = Run-Js $c ($find +
                "if (el.tagName === 'SELECT') { const o = [...el.options].find(x => norm(x.text) === " + $qo + ") || [...el.options].find(x => norm(x.text).includes(" + $qo + "));" +
                "if (!o) return JSON.stringify({ok:false,err:'NO_OPTION'}); el.value = o.value;" +
                "el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true}));" +
                "return JSON.stringify({ok:true,native:true,text:norm(o.text)}); }" +
                "const p = pointOf(el); return JSON.stringify({ok:true,x:p.x,y:p.y});")
            if (-not $r.ok) { throw $r.err }
            if ($r.native) { return @([string]$r.text) }
            Click-At $c $r.x $r.y
            $pt = $null
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Milliseconds 250
                $pt = Run-Js $c ("const L = [...document.querySelectorAll('[role=option]')].filter(vis);" +
                    "const o = L.find(x => norm(x.innerText) === " + $qo + ") || L.find(x => norm(x.innerText).includes(" + $qo + "));" +
                    "if (!o) return JSON.stringify({ok:false,n:L.length}); const p = pointOf(o); return JSON.stringify({ok:true,x:p.x,y:p.y,text:norm(o.innerText)});")
                if ($pt.ok) { break }
            }
            if (-not $pt.ok) { Press-Key $c 'Escape' 27; throw 'NO_OPTION' }
            Click-At $c $pt.x $pt.y
            Start-Sleep -Milliseconds 300
            return @([string]$pt.text)
        }
        default { throw ('UNKNOWN_ACT ' + $q['do']) }
    }
}

function Dispatch($q) {
    switch ($q['cmd']) {
        'ping' { $t = @(Get-Tabs); return @('pong', [string]$t.Count) }
        'reset' { $script:cur = $null; return @('ok') }
        'tabs' { return @(Get-Tabs | ForEach-Object { [string]$_.title }) }
        'window' {
            $kw = [string]$q['kw']
            $tabs = @(Get-Tabs)
            $t = $tabs | Where-Object { ([string]$_.title).IndexOf($kw, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
            if (-not $t) { $t = $tabs | Where-Object { ([string]$_.url).IndexOf($kw, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1 }
            if (-not $t) { throw 'NOT_FOUND' }
            $c = Get-Conn $t
            $null = Invoke-Cdp $c 'Page.bringToFront'
            $script:cur = $t.id
            $script:front = $t.id
            return @([string]$t.title)
        }
        'pick' { return @(Do-Pick) }
        'text' {
            $tab = Resolve-Tab
            $c = Get-Conn $tab
            $r = Run-Js $c "const parts = [document.body ? document.body.innerText : '']; for (const i of document.querySelectorAll('input,textarea')) { if (vis(i) && i.value) parts.push(i.value); } return JSON.stringify({text: parts.join('\n')});"
            return @([string]$r.text)
        }
        'act' { return @(Do-Act $q) }
        default { throw ('UNKNOWN_CMD ' + $q['cmd']) }
    }
}

function Handle([string]$raw) {
    $q = @{}
    foreach ($line in ($raw -split "`n")) {
        $line = $line.TrimEnd("`r")
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $q[$line.Substring(0, $i)] = Dec $line.Substring($i + 1) }
    }
    $id = [string]$q['id']
    try {
        $fields = @(Dispatch $q)
        $out = $id + "`tOK"
        foreach ($f in $fields) { $out += "`t" + (Enc ([string]$f)) }
        return $out
    } catch {
        $msg = $_.Exception.Message
        if ($msg -notmatch '^(NOT_FOUND|NO_OPTION|EMPTY|NO_HOVER|NO_TARGET|NO_CHROME|NO_TAB)') { Log ($q['cmd'] + ' ' + $q['do'] + ' failed: ' + $msg) }
        return $id + "`tERR`t" + (Enc $msg)
    }
}

# ---- main loop ----
if (-not (Test-Path -LiteralPath $IpcDir)) { New-Item -ItemType Directory -Path $IpcDir -Force | Out-Null }
Remove-Item -LiteralPath $inFile, $outFile, $outTmp, $readyFile -Force -ErrorAction SilentlyContinue
[IO.File]::WriteAllText($readyFile, [string]$PID, $utf8)
Log ('server started, pid ' + $PID + ', port ' + $Port)
$sw = [Diagnostics.Stopwatch]::StartNew()
$lastIdle = -5000
try {
    while ($true) {
        if (Test-Path -LiteralPath $inFile) {
            $raw = $null
            try { $raw = [IO.File]::ReadAllText($inFile, $utf8) } catch { Start-Sleep -Milliseconds 20; continue }
            try { Remove-Item -LiteralPath $inFile -Force } catch { }
            $res = Handle $raw
            [IO.File]::WriteAllText($outTmp, $res + "`r`n", $utf8)
            Move-Item -LiteralPath $outTmp -Destination $outFile -Force
        } else {
            if ($sw.ElapsedMilliseconds - $lastIdle -ge 2000) {
                $lastIdle = $sw.ElapsedMilliseconds
                if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
                Sweep
            }
            Start-Sleep -Milliseconds 25
        }
    }
} finally {
    Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue
    Log 'server stopped'
}
