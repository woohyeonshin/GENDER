#Requires AutoHotkey v2
#SingleInstance Force

; ============================================================
;  CDP 크롬 종료
;  - 디버그 포트(9222)로 켠 크롬만 골라서 끔 (일반 크롬은 안 건드림)
;  - 먼저 창을 정상적으로 닫고(로그인 유지), 5초 안에 안 꺼지면 강제 종료
;  - 마지막에 포트가 닫혔는지 확인해서 알려 줌
; ============================================================

PORT := 9222
TITLE := "CDP 크롬 종료"

pids := DebugChromePids()
if !pids.Length {
    if PortOpen()
        MsgBox("포트는 열려 있는데 디버그 크롬을 못 찾았어요.`n작업 관리자에서 크롬을 확인해 주세요.", TITLE, "Icon!")
    else
        MsgBox("디버그 크롬이 이미 꺼져 있어요.", TITLE, "Iconi T3")
    ExitApp
}

; 1) 창을 정상적으로 닫기 (로그인 정보가 저장되게)
for pid in pids {
    for hwnd in WinGetList("ahk_pid " pid)
        try WinClose(hwnd)
}

; 2) 최대 5초 기다리기
deadline := A_TickCount + 5000
while (A_TickCount < deadline && AnyAlive(pids))
    Sleep(250)

; 3) 그래도 남아 있으면 강제 종료
forced := false
for pid in DebugChromePids() {
    try ProcessClose(pid)
    forced := true
}
Sleep(700)

; 4) 포트가 닫혔는지 확인
if PortOpen()
    MsgBox("아직 포트가 열려 있어요.`n작업 관리자에서 크롬을 모두 종료해 주세요.", TITLE, "Icon!")
else
    MsgBox("CDP 크롬을 완전히 껐어요." (forced ? "`n(안 꺼져서 강제로 종료했어요)" : ""), TITLE, "Iconi T3")
ExitApp

; 디버그 포트로 켠 크롬 본체 프로세스 번호들 (하위 프로세스는 본체가 꺼지면 같이 꺼짐)
DebugChromePids() {
    out := []
    try {
        wmi := ComObjGet("winmgmts:")
        for p in wmi.ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='chrome.exe'") {
            cl := ""
            try cl := p.CommandLine
            if (cl = "")
                continue
            if InStr(cl, "--remote-debugging-port") && !InStr(cl, "--type=")
                out.Push(p.ProcessId)
        }
    }
    return out
}

AnyAlive(pids) {
    for pid in pids
        if ProcessExist(pid)
            return true
    return false
}

; 디버그 포트가 아직 응답하는지 (프록시 안 거치고 바로 확인)
PortOpen() {
    global PORT
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(1000, 1000, 1000, 1000)
        req.Open("GET", "http://127.0.0.1:" PORT "/json/version", false)
        req.SetProxy(1)
        req.Send()
        return req.Status = 200
    }
    return false
}
