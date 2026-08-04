#NoEnv
#SingleInstance, Force  ; 確保只有一個執行實例
SetWorkingDir %A_ScriptDir%

; --- 設定檔與路徑 ---
IniFile := "config.ini"
TmplFile := "templates.ini"
LogFile := "sms_log.txt"

; --- 智慧帳密檢測與持久化 ---
if (!FileExist(IniFile)) {
    InputBox, SavedUID, 初始設定, 請輸入您的帳號 (UID):,, 200, 130
    if (ErrorLevel) ; 使用者取消
        ExitApp
    InputBox, SavedPWD, 初始設定, 請輸入您的密碼 (PWD):,, 200, 130, Hide
    if (ErrorLevel) ; 使用者取消
        ExitApp
    IniWrite, %SavedUID%, %IniFile%, Credentials, UID
    IniWrite, %SavedPWD%, %IniFile%, Credentials, PWD
    FileSetAttrib, +H, %IniFile%
} else {
    IniRead, SavedUID, %IniFile%, Credentials, UID, % ""
    IniRead, SavedPWD, %IniFile%, Credentials, PWD, % ""
}

; --- 初始化控制項位置參數 ---
Global MSG_Y := 144       ; MSG 編輯框起始 Y 軸
Global MSG_MinH := 100    ; 最低高度
Global MSG_MaxH := 220    ; 最高高度
Global Current_MSG_H := 100
Global HwndGui1           ; 主視窗 Hwnd

; --- 主視窗介面 (Gui 1) ---
Gui, 1:New, +HwndHwndGui1
Gui, 1:Default
Gui, 1:Font, s10, Microsoft JhengHei

Gui, 1:Add, Text, x20 y20 w320, 📱 手機號碼 (多組號碼以半形逗號隔開):
Gui, 1:Add, Edit, vDEST w320 h28, 0900000000

; 預約發送設定區 (精確對齊)
Gui, 1:Add, CheckBox, vUseSched gToggleSched x20 y+15 h20, 📅 啟用預約發送
Gui, 1:Add, DateTime, vSchedTime w180 h28 x160 yp-4 Disabled Choose%A_Now%, yyyy-MM-dd HH:mm:ss

Gui, 1:Add, Text, x20 y+15 w320, 💬 簡訊內容:
; 綁定 gCountChars 監聽字數與自動高度調整
Gui, 1:Add, Edit, vMSG x20 y144 w320 h100 gCountChars +Multi +WantReturn

; 以下為需要動態下移的控制項，皆加上 HWND 以便在代碼中控制位置
Gui, 1:Add, Text, x20 vCharCount cGreen w320 y252 hwndHwndCharCount, 字數: 0
Gui, 1:Add, Text, x20 y276 w320 hwndHwndTplLabel, 快速選取範本:
Gui, 1:Add, DropDownList, vTemplateList w210 gApplyTemplate x20 y299 hwndHwndTplList, % GetTemplates()
Gui, 1:Add, Button, gOpenTemplateManager w100 h28 x+10 yp-1 hwndHwndMgrBtn, ⚙ 管理範本

Gui, 1:Font, s11 Bold, Microsoft JhengHei
Gui, 1:Add, Button, gSendSMS w320 h50 x20 y339 hwndHwndSendBtn, ✉ 發送簡訊
Gui, 1:Font

Gui, 1:Font, s10, Microsoft JhengHei
Gui, 1:Add, Button, gCloseApp w320 h35 x20 y399 hwndHwndCloseBtn, ❌ 關閉視窗

Gui, 1:Show, w360, 發簡訊 v1
return

; --- 監聽「啟用預約發送」核取方塊 ---
ToggleSched:
    Gui, 1:Submit, NoHide
    if (UseSched)
        GuiControl, 1:Enable, SchedTime
    else
        GuiControl, 1:Disable, SchedTime
return

; --- 輔助函數：讀取純淨範本清單 ---
GetTemplates() {
    global TmplFile
    List := ""
    IniRead, Section, %TmplFile%, Templates
    if (Section != "ERROR" && Section != "") {
        Loop, Parse, Section, `n, `r  ; 解析 \n 並過濾掉 Windows 的 \r
        {
            if (A_LoopField = "")
                continue
            StringSplit, Pair, A_LoopField, =
            KeyName := Trim(Pair1)
            if (KeyName = "")
                continue
            List .= (List == "" ? "" : "|") . KeyName
        }
    }
    return List
}

; --- 分類錯誤 ---
GetErrorReason(code) {
    if (code = "-1")
        return "參數錯誤，該訊息傳送失敗"
    else if (code = "-2")
        return "API帳號或密碼錯誤，該訊息傳送失敗"
    else if (code = "-3")
        return "受話方手機號碼為互動黑名單，該訊息傳送失敗"
    else if (code = "-4")
        return "訊息預計發送時間已逾期 24小時以上，該訊息傳送失敗"
    else if (code = "-5")
        return "Short Message 內容長度超過限制，該訊息傳送失敗"
    else if (code = "-8")
        return "受話方手機號碼格式不符，該訊息傳送失敗"
    else if (code = "-10")
        return "受話方手機系統不支援 MMS，該訊息傳送失敗"
    else if (code = "301")
        return "無額度(或額度不足)無法發送"
    else if (code = "-99")
        return "發生不明錯誤"
    else
        return "其他或未知的錯誤代碼"
}

; --- 主視窗 ---
CountChars:
    Gui, 1:Submit, NoHide
    
    ; 1. 字數統計與變色提醒
    Len := StrLen(MSG)
    GuiControl, 1:, CharCount, 字數: %Len%
    if (Len > 70)
        GuiControl, 1:+cRed, CharCount
    else
        GuiControl, 1:+cGreen, CharCount
        
    ; 2. 計算行數以調整自適應高度
    StrReplace(MSG, "`n", "`n", LineCount)
    LineCount += 1
    
    ; 每行估計 20 像素，加上緩衝
    TargetH := LineCount * 20 + 20
    if (TargetH < MSG_MinH)
        TargetH := MSG_MinH
    if (TargetH > MSG_MaxH)
        TargetH := MSG_MaxH
        
    if (TargetH != Current_MSG_H) {
        Current_MSG_H := TargetH
        
        ; 調整 MSG 輸入框高度
        GuiControl, 1:Move, MSG, h%TargetH%
        
        ; 計算下方控制項的新 Y 座標 (絕對定位)
        NewY_CharCount := 144 + TargetH + 8
        NewY_TplLabel  := 144 + TargetH + 32
        NewY_TplList   := 144 + TargetH + 55
        NewY_MgrBtn    := 144 + TargetH + 55
        NewY_SendBtn   := 144 + TargetH + 95
        NewY_CloseBtn  := 144 + TargetH + 155
        
        GuiControl, 1:Move, %HwndCharCount%, y%NewY_CharCount%
        GuiControl, 1:Move, %HwndTplLabel%, y%NewY_TplLabel%
        GuiControl, 1:Move, %HwndTplList%, y%NewY_TplList%
        GuiControl, 1:Move, %HwndMgrBtn%, y%NewY_MgrBtn%
        GuiControl, 1:Move, %HwndSendBtn%, y%NewY_SendBtn%
        GuiControl, 1:Move, %HwndCloseBtn%, y%NewY_CloseBtn%
        
        ; 動態調整主視窗高度 (加上 AHK 邊框和標題列高度大約 45px)
        NewWinH := 144 + TargetH + 155 + 35 + 45
        WinMove, ahk_id %HwndGui1%,,,,, %NewWinH%
    }
return

; --- 主視窗：套用範本 ---
ApplyTemplate:
    Gui, 1:Submit, NoHide
    if (TemplateList != "") {
        IniRead, TmplContent, %TmplFile%, Templates, %TemplateList%, % ""
        if (TmplContent != "ERROR") {
            GuiControl, 1:, MSG, %TmplContent%
            Gosub, CountChars
        }
    }
return


; --- 子視窗：管理範本介面 ---
Global HwndGui2           ; 子視窗 Hwnd

OpenTemplateManager:
    Gui, 2:Destroy ; 重置防重複建立
    Gui, 2:New, +HwndHwndGui2
    Gui, 2:Default
    Gui, 2:Font, s10, Microsoft JhengHei
    
    Gui, 2:Add, Text, x20 y20 w260, 📁 現有範本列表 (點選載入修改):
    Gui, 2:Add, ListBox, vTmplListBox x20 y45 w260 r5 gLoadSelectedTmpl, % GetTemplates()
    
    Gui, 2:Add, Text, x20 y155 w260, 📝 範本名稱:
    Gui, 2:Add, Edit, vTmplName x20 y180 w260 h28
    
    Gui, 2:Add, Text, x20 y220 w260, 💬 範本內容:
    Gui, 2:Add, Edit, vTmplContent x20 y245 w260 h100 gCountTmplChars +Multi +WantReturn +VScroll
    
    Gui, 2:Add, Text, x20 vTmplCharCount cGreen w260 y355, 字數: 0
    Gui, 2:Add, Button, gSaveTmpl w120 h35 x20 y385, 💾 新增 / 儲存
    Gui, 2:Add, Button, gDeleteTmpl x160 y385 w120 h35, 🗑 刪除選擇
    
    Gui, 2:Show, w300 h440, 範本管理
return

; --- 子視窗：範本即時字數統計 ---
CountTmplChars:
    Gui, 2:Submit, NoHide
    
    ; 1. 字數統計與變色提醒
    Len := StrLen(TmplContent)
    GuiControl, 2:, TmplCharCount, 字數: %Len%
    if (Len > 70)
        GuiControl, 2:+cRed, TmplCharCount
    else
        GuiControl, 2:+cGreen, TmplCharCount
return

; --- 子視窗：從清單載入範本進行修改 ---
LoadSelectedTmpl:
    Gui, 2:Submit, NoHide
    if (TmplListBox != "") {
        IniRead, Content, %TmplFile%, Templates, %TmplListBox%, % ""
        if (Content != "ERROR") {
            GuiControl, 2:, TmplName, %TmplListBox%
            GuiControl, 2:, TmplContent, %Content%
            Gosub, CountTmplChars
        }
    }
return

; --- 子視窗：新增與修改儲存 ---
SaveTmpl:
    Gui, 2:Submit, NoHide
    if (TmplName = "") {
        MsgBox, 48, 提示, 請輸入有效的範本名稱！
        return
    }
    IniWrite, %TmplContent%, %TmplFile%, Templates, %TmplName%
    
    ; 同步更新主視窗與子視窗清單
    NewList := GetTemplates()
    GuiControl, 2:, TmplListBox, |%NewList%
    GuiControl, 1:, TemplateList, |%NewList%
    GuiControl, 1:Choose, TemplateList, 1  ; 強制重繪選單
    
    MsgBox, 64, 成功, 範本「%TmplName%」已儲存！
return

; --- 子視窗：刪除範本 ---
DeleteTmpl:
    Gui, 2:Submit, NoHide
    if (TmplName = "") {
        MsgBox, 48, 提示, 請選擇要刪除的範本！
        return
    }
    IniDelete, %TmplFile%, Templates, %TmplName%
    
    ; 清空子視窗編輯區
    GuiControl, 2:, TmplName, 
    GuiControl, 2:, TmplContent, 
    GuiControl, 2:, TmplCharCount, 字數: 0
    
    ; 同步更新列表
    NewList := GetTemplates()
    GuiControl, 2:, TmplListBox, |%NewList%
    GuiControl, 1:, TemplateList, |%NewList%
    GuiControl, 1:Choose, TemplateList, 1
    
    MsgBox, 64, 成功, 範本已成功刪除！
return

; --- 子視窗關閉事件：僅關閉銷毀 Gui 2，主程式正常運作 ---
2GuiClose:
    Gui, 2:Destroy
return

; --- 主視窗關閉與登出事件 ---
CloseApp:
1GuiClose:
GuiClose:
    ExitApp

; --- 簡訊發送與日誌記錄 ---
SendSMS:
    Gui, 1:Submit, NoHide
    
    if (DEST = "" || MSG = "") {
        MsgBox, 48, 提示, 請輸入手機號碼與簡訊內容！
        return
    }
    
    ; 處理預約時間參數 (ST)
    ST_Val := ""
    if (UseSched) {
        ST_Val := SchedTime  ; 若勾選預約，直接帶入選取的日期時間格式 (AHK原生回傳 yyyyMMddHHmmss)
    }
    
    ; 網址與內文 URL 編碼 (防止中文字與特殊字元截斷 API 參數)
    EncodedMSG := URIEncode(MSG)
    URL := "https://new.e8d.tw/API21/HTTP/SendSMS.ashx"
    PostData := "UID=" . SavedUID . "&PWD=" . SavedPWD . "&MSG=" . EncodedMSG . "&DEST=" . DEST . "&ST=" . ST_Val . "&RETRYTIME=1440"
    
    ; 發送 HTTP POST 請求
    whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
    whr.Open("POST", URL, true)
    whr.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded")
    
    IsNetworkSuccess := true
    try {
        whr.Send(PostData)
        whr.WaitForResponse()
        Result := whr.ResponseText
    } catch e {
        Result := "連線失敗"
        IsNetworkSuccess := false
    }
    
    ; --- 智慧解析與分類錯誤原因 ---
    FormatTime, CurrentTime,, yyyy-MM-dd HH:mm:ss
    Status := "失敗"
    ErrorReason := "無"
    
    if (!IsNetworkSuccess) {
        Status := "失敗"
        ErrorReason := "連線失敗，請檢查網路或 API 位址。"
    } else {
        ; 解析 API 回傳資料
        StringSplit, Res, Result, `,
        FirstField := Trim(Res1)
        
        ; 判斷是否為成功：首欄不以 "-" 開頭，且欄位數量 >= 5 (成功回傳：CREDIT,SENDED,COST,UNSEND,BATCHID)
        if (SubStr(FirstField, 1, 1) != "-" && Res0 >= 5) {
            Status := "成功"
            ErrorReason := (ST_Val != "") ? "預約發送設定成功" : "發送成功"
        } else {
            Status := "失敗"
            ErrorReason := GetErrorReason(FirstField)
            
            ; 若有 API 帶回的附帶說明，則加以顯示
            ApiMsg := (Res0 >= 2) ? Trim(Res2) : ""
            if (ApiMsg != "") {
                ErrorReason .= " - " . ApiMsg
            }
        }
    }
    
    ; --- 寫入 LOG 檔 (優化：多組號碼自動解析為多行獨立日誌) ---
    Loop, Parse, DEST, `,
    {
        TargetPhone := Trim(A_LoopField)
        if (TargetPhone = "")
            continue
            
        LogEntry := Format("[{1}] 電話: {2} | 內容: {3} | 狀態: {4} | 原因: {5} | 預約時間: {6} | 回應: {7}`n"
            , CurrentTime, TargetPhone, MSG, Status, ErrorReason, (ST_Val != "" ? ST_Val : "即時發送"), Result)
        FileAppend, %LogEntry%, %LogFile%
    }
    
    ; 發送結果提示與欄位重置
    if (Status = "成功") {
        if (ST_Val != "")
            MsgBox, 64, 成功, 簡訊預約成功！`n預約送出時間: %ST_Val%
        else
            MsgBox, 64, 成功, 簡訊發送成功！
        GuiControl, 1:, DEST,  ; 發送成功後僅自動清除手機號碼，保留內容
    } else {
        MsgBox, 48, 失敗, 簡訊發送失敗。`n`n狀態: %Status%`n失敗原因: %ErrorReason%`n回應內容: %Result%
    }
return

; --- 輔助函數：URL 編碼，相容 UTF-8 ---
URIEncode(str, encoding="UTF-8") {
    local Var, char, code, hex, i
    VarSetCapacity(Var, StrPut(str, encoding))
    StrPut(str, &Var, encoding)
    while code := NumGet(Var, A_Index - 1, "UChar") {
        if (code >= 0x30 && code <= 0x39  ; 0-9
            || code >= 0x41 && code <= 0x5A  ; A-Z
            || code >= 0x61 && code <= 0x7A  ; a-z
            || code == 0x2D || code == 0x2E  ; - .
            || code == 0x5F || code == 0x7E) ; _ ~
            char .= Chr(code)
        else {
            hex := Format("{:02X}", code)
            char .= "%" . hex
        }
    }
    return char
}