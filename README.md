$c=@("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")|?{Test-Path $_}|select -First 1; $s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\CDP Chrome.lnk'); $s.TargetPath=$c; $s.Arguments='--remote-debugging-port=9222 --user-data-dir="'+$env:USERPROFILE+'\ChromeCDP"'; $s.Save(); "OK: $c"
localhost:9222/json/version



$ExecutionContext.SessionState.LanguageMode


Test-Path "$env:TEMP\zdcdp\ready.txt"


Get-Content "$env:TEMP\zdcdp\server.log" -Tail 20

$t=(Invoke-RestMethod http://127.0.0.1:9222/json)|?{$_.type -eq 'page'}|select -First 1; $t.title; $ws=New-Object System.Net.WebSockets.ClientWebSocket; $ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl,[Threading.CancellationToken]::None).Wait(); $ws.State
