#NoEnv
#SingleInstance, Force  ; 確保只有一個執行實例
SetWorkingDir %A_ScriptDir%

; --- 系統設定檔路徑 ---
IniFile := "config.ini"
TmplFile := "templates.ini"
LogFile := "sms_log.txt"

; --- 初始化：帳戶驗證與加密儲存 ---
InitAuth:
if (!FileExist(IniFile)) {
    ; 首次執行，要求輸入帳密
    InputBox, SavedUID, 初始設定, 請輸入您的帳號 (UID):,, 200, 130
    if (ErrorLevel || SavedUID="")
        ExitApp
    InputBox, SavedPWD, 初始設定, 請輸入您的密碼 (PWD):,, 200, 130, Hide
    if (ErrorLevel || SavedPWD="")
        ExitApp
        
    ; 將明文帳密加密後寫入設定檔，並設為隱藏屬性
    EncUID := Encrypt(SavedUID)
    EncPWD := Encrypt(SavedPWD)
    
    IniWrite, %EncUID%, %IniFile%, Credentials, UID
    IniWrite, %EncPWD%, %IniFile%, Credentials, PWD
    FileSetAttrib, +H, %IniFile% 
} else {
    ; 讀取加密的帳密資料
    IniRead, EncUID, %IniFile%, Credentials, UID, % ""
    IniRead, EncPWD, %IniFile%, Credentials, PWD, % ""
    
    ; 解密為明文供 API 呼叫使用
    SavedUID := Decrypt(EncUID)
    SavedPWD := Decrypt(EncPWD)
    
    ; 防錯/防篡改機制：若解密失敗 (回傳空值)，則刪除損毀的設定檔並要求重設
    if (SavedUID = "" || SavedPWD = "") {
        MsgBox, 48, 錯誤, 本地密碼檔解密失敗或已損毀，將為您重置設定。
        FileSetAttrib, -H, %IniFile%
        FileDelete, %IniFile%
        Goto, InitAuth
    }
}

; --- UI 佈局全域變數 ---
Global MSG_Y := 144       ; 簡訊內容框起始 Y 軸
Global MSG_MinH := 100    ; 簡訊內容框最低高度
Global MSG_MaxH := 220    ; 簡訊內容框最高高度
Global Current_MSG_H := 100
Global HwndGui1           ; 主視窗控制代碼 (Hwnd)

; --- 建立主視窗 (Gui 1) ---
Gui, 1:New, +HwndHwndGui1
Gui, 1:Default
Gui, 1:Font, s10, Microsoft JhengHei

; 頂部：手機號碼標題與查詢餘額按鈕
Gui, 1:Add, Text, x20 y20 w210, 📱 手機號碼 (多組請以逗號隔開):
Gui, 1:Add, Button, gCheckCredit x240 y16 w100 h24, 💰 查詢餘額
Gui, 1:Add, Edit, vDEST x20 y45 w320 h28, 0900000000

; 預約發送設定區
Gui, 1:Add, CheckBox, vUseSched gToggleSched x20 y+15 h20, 📅 啟用預約發送
Gui, 1:Add, DateTime, vSchedTime w180 h28 x160 yp-4 Disabled Choose%A_Now%, yyyy-MM-dd HH:mm:ss

Gui, 1:Add, Text, x20 y+15 w320, 💬 簡訊內容:
; 綁定 gCountChars 進行字數統計與高度自適應
Gui, 1:Add, Edit, vMSG x20 y144 w320 h100 gCountChars +Multi +WantReturn

; 下方控制項 (綁定 HWND 供動態排版使用)
Gui, 1:Add, Text, x20 vCharCount cGreen w320 y252 hwndHwndCharCount, 字數: 0
Gui, 1:Add, Text, x20 y276 w320 hwndHwndTplLabel, 快速選取範本:
Gui, 1:Add, DropDownList, vTemplateList w210 gApplyTemplate x20 y299 hwndHwndTplList, % GetTemplates()
Gui, 1:Add, Button, gOpenTemplateManager w100 h28 x+10 yp-1 hwndHwndMgrBtn, ⚙ 管理範本

Gui, 1:Font, s11 Bold, Microsoft JhengHei
Gui, 1:Add, Button, gSendSMS w320 h50 x20 y339 hwndHwndSendBtn, ✉ 發送簡訊
Gui, 1:Font

; 底部按鈕區 (恢復滿版關閉按鈕)
Gui, 1:Font, s10, Microsoft JhengHei
Gui, 1:Add, Button, gCloseApp w320 h35 x20 y399 hwndHwndCloseBtn, ❌ 關閉視窗

; 隱蔽的重置帳密功能 (位於右下角的灰色小字體)
Gui, 1:Font, s8, Microsoft JhengHei
Gui, 1:Add, Text, gResetAuth x290 y439 cGray hwndHwndResetBtn, [重置帳密]

Gui, 1:Show, w360, 發簡訊 v1 (安全儲存版)
return

; --- UI 事件：查詢 API 點數餘額 ---
CheckCredit:
    URL := "https://new.e8d.tw/API21/HTTP/GetCredit.ashx"
    PostData := "UID=" . SavedUID . "&PWD=" . SavedPWD
    
    whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
    whr.Open("POST", URL, true)
    whr.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded")
    
    try {
        whr.Send(PostData)
        whr.WaitForResponse()
        Result := Trim(whr.ResponseText)
        
        ; 判斷是否為負數錯誤碼
        if (SubStr(Result, 1, 1) = "-") {
            Reason := GetErrorReason(Result)
            MsgBox, 48, 餘額查詢失敗, 查詢失敗！`n`n錯誤碼：%Result%`n原因：%Reason%
            
            ; 若因帳密錯誤導致查詢失敗，一樣主動提示重置
            if (Result = "-2") {
                MsgBox, 52, 帳密錯誤, 系統偵測到您的 API 帳號或密碼發生錯誤。`n請問是否要清除記錄並重新設定？
                IfMsgBox, Yes
                {
                    FileSetAttrib, -H, %IniFile%
                    FileDelete, %IniFile%
                    Reload
                }
            }
        } else {
            MsgBox, 64, 帳戶餘額, 🟢 您目前的帳戶餘額為：`n`n%Result% 點
        }
    } catch e {
        MsgBox, 16, 錯誤, 連線至 API 失敗，請檢查網路連線。
    }
return

; --- UI 事件：切換預約發送 ---
ToggleSched:
    Gui, 1:Submit, NoHide
    if (UseSched)
        GuiControl, 1:Enable, SchedTime
    else
        GuiControl, 1:Disable, SchedTime
return

; --- 核心邏輯：讀取範本清單 ---
GetTemplates() {
    global TmplFile
    List := ""
    IniRead, Section, %TmplFile%, Templates
    if (Section != "ERROR" && Section != "") {
        Loop, Parse, Section, `n, `r  ; 處理換行與過濾 \r
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

; --- 核心邏輯：API 錯誤碼對應 ---
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

; --- UI 事件：簡訊內容字數統計與高度自適應 ---
CountChars:
    Gui, 1:Submit, NoHide
    
    ; 1. 更新字數統計 (超過 70 字顯示紅色警告)
    Len := StrLen(MSG)
    GuiControl, 1:, CharCount, 字數: %Len%
    if (Len > 70)
        GuiControl, 1:+cRed, CharCount
    else
        GuiControl, 1:+cGreen, CharCount
        
    ; 2. 計算行數
    StrReplace(MSG, "`n", "`n", LineCount)
    LineCount += 1
    
    ; 3. 根據行數動態計算目標高度
    TargetH := LineCount * 20 + 20
    if (TargetH < MSG_MinH)
        TargetH := MSG_MinH
    if (TargetH > MSG_MaxH)
        TargetH := MSG_MaxH
        
    ; 4. 執行版面重排
    if (TargetH != Current_MSG_H) {
        Current_MSG_H := TargetH
        
        GuiControl, 1:Move, MSG, h%TargetH%
        
        ; 重新計算並移動下方所有控制項的 Y 軸位置
        NewY_CharCount := 144 + TargetH + 8
        NewY_TplLabel  := 144 + TargetH + 32
        NewY_TplList   := 144 + TargetH + 55
        NewY_MgrBtn    := 144 + TargetH + 55
        NewY_SendBtn   := 144 + TargetH + 95
        NewY_CloseBtn  := 144 + TargetH + 155
        NewY_ResetBtn  := 144 + TargetH + 195  ; 隱蔽按鈕的 Y 軸 (緊隨關閉按鈕下)
        
        GuiControl, 1:Move, %HwndCharCount%, y%NewY_CharCount%
        GuiControl, 1:Move, %HwndTplLabel%, y%NewY_TplLabel%
        GuiControl, 1:Move, %HwndTplList%, y%NewY_TplList%
        GuiControl, 1:Move, %HwndMgrBtn%, y%NewY_MgrBtn%
        GuiControl, 1:Move, %HwndSendBtn%, y%NewY_SendBtn%
        GuiControl, 1:Move, %HwndCloseBtn%, y%NewY_CloseBtn%
        GuiControl, 1:Move, %HwndResetBtn%, y%NewY_ResetBtn%
        
        ; 調整主視窗總高度 (多預留一點空間給底部的文字)
        NewWinH := 144 + TargetH + 195 + 25 + 45
        WinMove, ahk_id %HwndGui1%,,,,, %NewWinH%
    }
return

; --- UI 事件：套用選擇的範本 ---
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


; --- 建立子視窗：範本管理模組 (Gui 2) ---
Global HwndGui2           ; 子視窗控制代碼

OpenTemplateManager:
    Gui, 2:Destroy ; 防止重複建立視窗
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

; --- 範本管理事件：即時字數統計 ---
CountTmplChars:
    Gui, 2:Submit, NoHide
    Len := StrLen(TmplContent)
    GuiControl, 2:, TmplCharCount, 字數: %Len%
    if (Len > 70)
        GuiControl, 2:+cRed, TmplCharCount
    else
        GuiControl, 2:+cGreen, TmplCharCount
return

; --- 範本管理事件：載入所選範本 ---
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

; --- 範本管理事件：儲存範本 ---
SaveTmpl:
    Gui, 2:Submit, NoHide
    if (TmplName = "") {
        MsgBox, 48, 提示, 請輸入有效的範本名稱！
        return
    }
    IniWrite, %TmplContent%, %TmplFile%, Templates, %TmplName%
    
    ; 同步更新主視窗與子視窗的範本下拉清單/列表
    NewList := GetTemplates()
    GuiControl, 2:, TmplListBox, |%NewList%
    GuiControl, 1:, TemplateList, |%NewList%
    GuiControl, 1:Choose, TemplateList, 1  ; 重置選取狀態
    
    MsgBox, 64, 成功, 範本「%TmplName%」已儲存！
return

; --- 範本管理事件：刪除範本 ---
DeleteTmpl:
    Gui, 2:Submit, NoHide
    if (TmplName = "") {
        MsgBox, 48, 提示, 請選擇要刪除的範本！
        return
    }
    IniDelete, %TmplFile%, Templates, %TmplName%
    
    ; 清空編輯區
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

; --- 關閉與重置事件處理 ---
2GuiClose:
    Gui, 2:Destroy ; 僅銷毀子視窗
return

ResetAuth:
    MsgBox, 52, 重置確認, 確定要清除已儲存的帳號密碼嗎？`n清除後程式將會重新啟動。
    IfMsgBox, Yes
    {
        FileSetAttrib, -H, %IniFile%
        FileDelete, %IniFile%
        Reload
    }
return

CloseApp:
1GuiClose:
GuiClose:
    ExitApp

; --- 核心邏輯：發送簡訊 API 請求 ---
SendSMS:
    Gui, 1:Submit, NoHide
    
    if (DEST = "" || MSG = "") {
        MsgBox, 48, 提示, 請輸入手機號碼與簡訊內容！
        return
    }
    
    ; 決定是否帶入預約時間
    ST_Val := ""
    if (UseSched) {
        ST_Val := SchedTime  ; AHK 原生格式: yyyyMMddHHmmss
    }
    
    ; 確保內文及特殊字元正確傳遞 (避免 URL 截斷)
    EncodedMSG := URIEncode(MSG)
    URL := "https://new.e8d.tw/API21/HTTP/SendSMS.ashx"
    PostData := "UID=" . SavedUID . "&PWD=" . SavedPWD . "&MSG=" . EncodedMSG . "&DEST=" . DEST . "&ST=" . ST_Val . "&RETRYTIME=1440"
    
    ; 執行 HTTP POST
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
    
    ; --- API 回傳結果解析 ---
    FormatTime, CurrentTime,, yyyy-MM-dd HH:mm:ss
    Status := "失敗"
    ErrorReason := "無"
    
    if (!IsNetworkSuccess) {
        Status := "失敗"
        ErrorReason := "連線失敗，請檢查網路或 API 位址。"
    } else {
        StringSplit, Res, Result, `,
        FirstField := Trim(Res1)
        
        ; 成功條件：首欄非負號，且回傳欄位數量大於等於 5 (標準規格)
        if (SubStr(FirstField, 1, 1) != "-" && Res0 >= 5) {
            Status := "成功"
            ErrorReason := (ST_Val != "") ? "預約發送設定成功" : "發送成功"
        } else {
            Status := "失敗"
            ErrorReason := GetErrorReason(FirstField)
            
            ; 若 API 提供額外的錯誤訊息，一併附上
            ApiMsg := (Res0 >= 2) ? Trim(Res2) : ""
            if (ApiMsg != "") {
                ErrorReason .= " - " . ApiMsg
            }
        }
    }
    
    ; --- 紀錄 Log 檔 (支援多組號碼分列紀錄) ---
    Loop, Parse, DEST, `,
    {
        TargetPhone := Trim(A_LoopField)
        if (TargetPhone = "")
            continue
            
        LogEntry := Format("[{1}] 電話: {2} | 內容: {3} | 狀態: {4} | 原因: {5} | 預約時間: {6} | 回應: {7}`n"
            , CurrentTime, TargetPhone, MSG, Status, ErrorReason, (ST_Val != "" ? ST_Val : "即時發送"), Result)
        FileAppend, %LogEntry%, %LogFile%
    }
    
    ; --- 處理發送後 UI 狀態 ---
    if (Status = "成功") {
        if (ST_Val != "")
            MsgBox, 64, 成功, 簡訊預約成功！`n預約送出時間: %ST_Val%
        else
            MsgBox, 64, 成功, 簡訊發送成功！
        GuiControl, 1:, DEST,  ; 成功後清空號碼欄位以防誤傳，保留內文
    } else {
        MsgBox, 48, 失敗, 簡訊發送失敗。`n`n狀態: %Status%`n失敗原因: %ErrorReason%`n回應內容: %Result%
        
        ; --- 主動偵測帳密錯誤並提示重置 ---
        if (FirstField = "-2") {
            MsgBox, 52, 帳密錯誤, 系統偵測到您的 API 帳號或密碼發生錯誤。`n請問是否要清除記錄並重新設定？
            IfMsgBox, Yes
            {
                FileSetAttrib, -H, %IniFile%
                FileDelete, %IniFile%
                Reload
            }
        }
    }
return

; --- 核心工具：UTF-8 URL 編碼 (支援中文與特殊符號) ---
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

; ==========================================
; --- 核心工具：帳號密碼 XOR 安全加解密模組 ---
; ==========================================

; 將字串進行 XOR 混淆，並轉換為 Hex (十六進位) 格式儲存
Encrypt(str, key:="E8DSecureKey2026") {
    hexStr := ""
    keyLen := StrLen(key)
    Loop, Parse, str
    {
        charAsc := Asc(A_LoopField)
        keyCharAsc := Asc(SubStr(key, Mod(A_Index-1, keyLen)+1, 1))
        xorVal := charAsc ^ keyCharAsc
        hexVal := Format("{:02X}", xorVal)
        hexStr .= hexVal
    }
    return hexStr
}

; 讀取 Hex (十六進位) 字串，轉為十進位後進行 XOR 解密還原
Decrypt(hexStr, key:="E8DSecureKey2026") {
    str := ""
    keyLen := StrLen(key)
    len := StrLen(hexStr)
    i := 1
    charIndex := 1
    while (i < len) {
        hexPair := SubStr(hexStr, i, 2)
        
        ; 將 Hex 字串轉換為數值，並確保 AHK 正確識別數值型態以進行 XOR 運算
        xorVal := "0x" . hexPair
        xorVal += 0 
        
        keyCharAsc := Asc(SubStr(key, Mod(charIndex-1, keyLen)+1, 1))
        charAsc := xorVal ^ keyCharAsc
        str .= Chr(charAsc)
        
        i += 2
        charIndex++
    }
    return str
}