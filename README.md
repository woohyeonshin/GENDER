$c=@("$env:ProgramFiles\Google\Chrome\Application\chrome.exe","${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe","$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")|?{Test-Path $_}|select -First 1; $s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop')+'\CDP Chrome.lnk'); $s.TargetPath=$c; $s.Arguments='--remote-debugging-port=9222 --user-data-dir="'+$env:USERPROFILE+'\ChromeCDP"'; $s.Save(); "OK: $c"
localhost:9222/json/version



$ExecutionContext.SessionState.LanguageMode


Test-Path "$env:TEMP\zdcdp\ready.txt"


Get-Content "$env:TEMP\zdcdp\server.log" -Tail 20

$t=(Invoke-RestMethod http://127.0.0.1:9222/json)|?{$_.type -eq 'page'}|select -First 1; $t.title; $ws=New-Object System.Net.WebSockets.ClientWebSocket; $ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl,[Threading.CancellationToken]::None).Wait(); $ws.State



$tabs=(Invoke-RestMethod http://127.0.0.1:9222/json)|?{$_.type -eq 'page'}
foreach($t in $tabs){
  $out='?'
  try{
    $ws=New-Object System.Net.WebSockets.ClientWebSocket
    $null=$ws.ConnectAsync([Uri]$t.webSocketDebuggerUrl,[Threading.CancellationToken]::None).Wait(5000)
    $msg='{"id":1,"method":"Runtime.evaluate","params":{"expression":"JSON.stringify([!!window.__zdInst, window.__zdT||0])","returnByValue":true}}'
    $b=[Text.Encoding]::UTF8.GetBytes($msg)
    $null=$ws.SendAsync((New-Object 'ArraySegment[byte]' -ArgumentList (,$b)),'Text',$true,[Threading.CancellationToken]::None).Wait(5000)
    $buf=New-Object byte[] 65536
    $r=$ws.ReceiveAsync((New-Object 'ArraySegment[byte]' -ArgumentList (,$buf)),[Threading.CancellationToken]::None)
    if($r.Wait(5000)){$out=[Text.Encoding]::UTF8.GetString($buf,0,$r.Result.Count)}else{$out='TIMEOUT'}
    $ws.Dispose()
  }catch{$out='ERR '+$_.Exception.Message}
  $t.title+'  =>  '+$out
}
