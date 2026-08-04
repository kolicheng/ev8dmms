#NoEnv
#SingleInstance, Force
SetWorkingDir %A_ScriptDir%

; ==============================================================================
; 程式名稱：EVERY8D 簡訊發送工具
; 程式功能：發送簡訊、預約發送、管理範本、檢視本地發送紀錄、查詢送達狀態、
;           發送前確認、API 錯誤碼中文對照、過濾 24 小時內重複發送。
; ==============================================================================

Global RegPath := "HKCU\Software\Every8DSMSTool"
Global TmplRegPath := "HKCU\Software\Every8DSMSTool\Templates"
Global LogFile := "sms_log.txt"
Global Templates := {}

; ==============================================================================
; 1. 初始化：載入範本、帳號認證與預約時間預設值
; ==============================================================================
InitAuth:
GoSub, LoadTemplates

RegRead, SavedUID, %RegPath%, UID
RegRead, SavedPWD, %RegPath%, PWD
SavedUID := Trim(SavedUID)
SavedPWD := Trim(SavedPWD)

if (SavedUID = "" || SavedPWD = "") {
    InputBox, SavedUID, 初始帳號設定, 請輸入您的 EVERY8D 帳號 (UID):,, 280, 130
    if (ErrorLevel || SavedUID = "")
        ExitApp 
        
    InputBox, SavedPWD, 初始密碼設定, 請輸入您的 EVERY8D 密碼 (PWD):,, 280, 130, Hide
    if (ErrorLevel || SavedPWD = "")
        ExitApp 
    
    RegWrite, REG_SZ, %RegPath%, UID, %SavedUID%
    RegWrite, REG_SZ, %RegPath%, PWD, %SavedPWD%
}

FutureTime := A_Now
EnvAdd, FutureTime, 10, Minutes
FormatTime, DefDate, %FutureTime%, yyyyMMdd
FormatTime, DefHour, %FutureTime%, HH 
FormatTime, DefMin, %FutureTime%, mm  

HourOptions := ""
Loop, 24 {
    h := Format("{:02d}", A_Index - 1)
    HourOptions .= h . (h == DefHour ? "||" : "|")
}
MinOptions := ""
Loop, 60 {
    m := Format("{:02d}", A_Index - 1)
    MinOptions .= m . (m == DefMin ? "||" : "|")
}

; ==============================================================================
; 主介面 (GUI 1) 建構與排版
; ==============================================================================
Gui, 1:Default
Gui, 1:Font, s10, Microsoft JhengHei 

Gui, 1:Add, GroupBox, x15 y10 w450 h70, 帳號登入狀態
Gui, 1:Add, Text, x30 y38, 當前帳號：
Gui, 1:Add, Text, x100 y38 w130 vUIDDisplay c0x0055AA, %SavedUID%
Gui, 1:Add, Button, x240 y32 w95 h30 gCheckCredit, 💰 查詢餘額
Gui, 1:Add, Button, x345 y32 w110 h30 gResetAuth, 🔑 重置帳密

Gui, 1:Add, Text, x15 y95, 📱 手機號碼 (多筆請用半形逗號隔開)：
Gui, 1:Add, Edit, x15 y115 w450 vDEST, 0900000000

Gui, 1:Add, Checkbox, x15 y152 w135 vUseSched gToggleSched, ⏰ 啟用預約發送
Gui, 1:Add, DateTime, x150 y149 w120 vSchedDate Disabled Choose%DefDate%, yyyy/MM/dd
Gui, 1:Add, DropDownList, x290 y149 w45 vSchedHour Disabled, %HourOptions%
Gui, 1:Add, Text, x340 y152, 時
Gui, 1:Add, DropDownList, x365 y149 w45 vSchedMin Disabled, %MinOptions%
Gui, 1:Add, Text, x415 y152, 分

Gui, 1:Add, Text, x15 y185, 📋 選擇簡訊範本：
TmplOptions := "|-- 請選擇內建範本 --||"
for title, content in Templates {
    TmplOptions .= title . "|"
}
Gui, 1:Add, DropDownList, x15 y205 w320 vTmplSelect gOnTmplSelect, %TmplOptions%
Gui, 1:Add, Button, x345 y203 w120 h28 gOpenTmplMgr, ⚙️ 範本管理

Gui, 1:Add, Text, x15 y240, 🏷️ 簡訊主旨 (選填，僅供註記不發送給客戶)：
Gui, 1:Add, Edit, x15 y260 w450 vSB, 

Gui, 1:Add, Text, x15 y295, 💬 簡訊內容：
Gui, 1:Add, Edit, x15 y315 w450 h110 vMSG gUpdateCharCount, 
Gui, 1:Add, Text, x15 y435 w450 vCharCountText c0x007ACC, 字數：0 字 (共 0 封簡訊)

; C 功能：過濾重複發送選項
Gui, 1:Add, Checkbox, x15 y460 w300 vFilterDuplicate Checked, 🛡️ 過濾 24 小時內相同門號重複發送的訊息

Gui, 1:Add, Button, x15 y490 w215 h40 vSendBtn Default gConfirmSendSMS, 🚀 發送簡訊
Gui, 1:Add, Button, x250 y490 w215 h40 gShowLogWindow, 📜 檢視紀錄

Gui, 1:Show, w480 h550, EVERY8D簡訊發送工具
GoSub, UpdateCharCount 
return

; ==============================================================================
; 範本讀取與介面更新邏輯
; ==============================================================================
LoadTemplates:
Templates := {} 
Loop, Reg, %TmplRegPath%, V
{
    RegRead, tmplContent
    if (!ErrorLevel)
        Templates[A_LoopRegName] := tmplContent
}
return

RefreshTmplDDL:
TmplOptions := "|-- 請選擇內建範本 --||"
for title, content in Templates {
    TmplOptions .= title . "|"
}
GuiControl, 1:, TmplSelect, %TmplOptions%
return

; ==============================================================================
; 觸發事件處理：範本選擇、字數精準計算、預約狀態切換
; ==============================================================================
OnTmplSelect:
Gui, 1:Submit, NoHide
if (TmplSelect != "" && TmplSelect != "-- 請選擇內建範本 --" && Templates.HasKey(TmplSelect)) {
    GuiControl, 1:, MSG, % Templates[TmplSelect]
    GoSub, UpdateCharCount 
}
return

UpdateCharCount:
Gui, 1:Submit, NoHide
len := StrLen(MSG)
if (len == 0) {
    GuiControl, 1:+c007ACC, CharCountText 
    GuiControl, 1:, CharCountText, % "字數：0 字 (共 0 封簡訊)"
    GuiControl, 1:Enable, SendBtn
} else if (len <= 70) {
    GuiControl, 1:+c007ACC, CharCountText
    GuiControl, 1:, CharCountText, % "字數：" . len . " 字 (共 1 封簡訊)"
    GuiControl, 1:Enable, SendBtn
} else if (len <= 333) {
    parts := Ceil(len / 67)
    GuiControl, 1:+cRed, CharCountText 
    GuiControl, 1:, CharCountText, % "字數：" . len . " 字 (超過 70 字，將拆分為 " . parts . " 封簡訊計費)"
    GuiControl, 1:Enable, SendBtn
} else {
    GuiControl, 1:+cRed, CharCountText 
    GuiControl, 1:, CharCountText, % "字數：" . len . " 字 (已超過系統上限 333 字，無法發送！)"
    GuiControl, 1:Disable, SendBtn
}
return

ToggleSched:
Gui, 1:Submit, NoHide
if (UseSched) {
    GuiControl, 1:Enable, SchedDate
    GuiControl, 1:Enable, SchedHour
    GuiControl, 1:Enable, SchedMin
} else {
    GuiControl, 1:Disable, SchedDate
    GuiControl, 1:Disable, SchedHour
    GuiControl, 1:Disable, SchedMin
}
return

; ==============================================================================
; 範本管理子視窗 (GUI 2) 邏輯
; ==============================================================================
OpenTmplMgr:
Gui, 2:Destroy 
Gui, 2:Default
Gui, 2:Font, s10, Microsoft JhengHei

Gui, 2:Add, Text, x15 y15, 📋 現有範本清單：
Gui, 2:Add, ListView, x15 y35 w450 h150 vTmplLV gOnTmplLVSelect Grid AltSubmit, 範本名稱|範本內容
LV_ModifyCol(1, 130)
LV_ModifyCol(2, 300)

Gui, 2:Add, Text, x15 y200, 範本名稱：
Gui, 2:Add, Edit, x90 y198 w375 vEditTmplTitle, 

Gui, 2:Add, Text, x15 y235, 範本內容：
Gui, 2:Add, Edit, x90 y232 w375 h60 vEditTmplContent, 

Gui, 2:Add, Button, x15 y305 w215 h32 gSaveTmpl, 💾 新增 / 更新
Gui, 2:Add, Button, x250 y305 w215 h32 gDeleteTmpl, ❌ 刪除所選

GoSub, LoadTmplToLV
Gui, 2:Show, w480 h355, ⚙️ 簡訊範本管理
return

LoadTmplToLV:
Gui, 2:Default
LV_Delete() 
for title, content in Templates {
    LV_Add("", title, content) 
}
return

OnTmplLVSelect:
if (A_GuiEvent = "I" && InStr(ErrorLevel, "S", true)) {
    LV_GetText(selTitle, A_EventInfo, 1)
    LV_GetText(selContent, A_EventInfo, 2)
    GuiControl, 2:, EditTmplTitle, %selTitle%
    GuiControl, 2:, EditTmplContent, %selContent%
}
return

SaveTmpl:
Gui, 2:Submit, NoHide
if (EditTmplTitle = "" || EditTmplContent = "") {
    MsgBox, 48, 提示, 範本名稱與內容皆不可為空！
    return
}
Templates[EditTmplTitle] := EditTmplContent
RegWrite, REG_SZ, %TmplRegPath%, %EditTmplTitle%, %EditTmplContent%
GoSub, LoadTmplToLV  
GoSub, RefreshTmplDDL 
MsgBox, 64, 成功, 範本已成功儲存！
return

DeleteTmpl:
Gui, 2:Default
Row := LV_GetNext(0, "Focused") 
if (!Row) {
    MsgBox, 48, 提示, 請先點擊選擇要刪除的範本！
    return
}
LV_GetText(delTitle, Row, 1)
MsgBox, 52, 刪除確認, 確定要刪除範本「%delTitle%」嗎？
IfMsgBox, Yes
{
    Templates.Delete(delTitle)
    RegDelete, %TmplRegPath%, %delTitle%
    GuiControl, 2:, EditTmplTitle,  
    GuiControl, 2:, EditTmplContent, 
    GoSub, LoadTmplToLV
    GoSub, RefreshTmplDDL
    MsgBox, 64, 完成, 已成功刪除該範本！
}
return

2GuiClose:
Gui, 2:Destroy 
return

; ==============================================================================
; API 核心事件：查詢點數與發送簡訊
; ==============================================================================
CheckCredit:
URL := "https://new.e8d.tw/API21/HTTP/GetCredit.ashx"
PostData := "UID=" . URIEncode(SavedUID) . "&PWD=" . URIEncode(SavedPWD)
res := HTTPPost(URL, PostData)

if (RegExMatch(res, "^-?\d+(\.\d+)?$")) {
    if (res >= 0)
        MsgBox, 64, 餘額查詢成功, 您的 EVERY8D 簡訊剩餘點數為：%res% 點
    else {
        errText := TranslateErrorCode(res)
        MsgBox, 16, 查詢失敗, 錯誤代碼：%res%`n錯誤原因：%errText%
    }
} else {
    StringSplit, ErrArr, res, `,
    if (ErrArr0 >= 2) {
        errText := TranslateErrorCode(ErrArr1)
        MsgBox, 16, 查詢失敗, 錯誤代碼：%ErrArr1%`n系統訊息：%ErrArr2%`n查表原因：%errText%
    } else {
        MsgBox, 48, 系統回應, 回應內容：%res%
    }
}
return

; 發送前確認邏輯
ConfirmSendSMS:
Gui, 1:Submit, NoHide
if (DEST = "" || MSG = "") {
    MsgBox, 48, 提示, 請填寫手機號碼與簡訊內容！
    return
}

; 計算預計發送對象數量
StringSplit, DestArr, DEST, `,
DestCount := 0
Loop, %DestArr0% {
    if (Trim(DestArr%A_Index%) != "")
        DestCount++
}

; 計算每則簡訊預計點數 (簡單估算，實際以電信商回傳為主)
len := StrLen(MSG)
costPerMsg := (len <= 70) ? 1 : Ceil(len / 67)
totalCost := DestCount * costPerMsg

ConfirmMsg := "確定要發送這則簡訊嗎？`n`n發送對象：" . DestCount . " 組門號`n預估扣除：" . totalCost . " 點"
if (FilterDuplicate)
    ConfirmMsg .= "`n`n⚠️ 已啟用「過濾 24 小時內重複訊息」功能"
    
MsgBox, 52, 發送前確認, %ConfirmMsg%
IfMsgBox, Yes
{
    GoSub, SendSMS
}
return

SendSMS:
; 根據是否勾選過濾重複，決定使用的 API 端點
if (FilterDuplicate)
    URL := "https://new.e8d.tw/API21/HTTP/SendSMS4FilterMessage.ashx"
else
    URL := "https://new.e8d.tw/API21/HTTP/SendSMS.ashx"
    
PostData := "UID=" . URIEncode(SavedUID) . "&PWD=" . URIEncode(SavedPWD) . "&SB=" . URIEncode(SB) . "&DEST=" . URIEncode(DEST) . "&MSG=" . URIEncode(MSG)

if (UseSched) {
    FormatTime, SDate, %SchedDate%, yyyyMMdd
    STime := SDate . SchedHour . SchedMin . "00" 
    PostData .= "&ST=" . STime
}

res := HTTPPost(URL, PostData)
StringSplit, ResArr, res, `,
FormatTime, CurrentTime,, yyyy/MM/dd HH:mm:ss
CleanMSG := StrReplace(MSG, "`n", " ")
CleanMSG := StrReplace(CleanMSG, "`r", "")

; 解析回傳值 (成功：credit,sended,cost,unsend,batch_id,重複發送門號,重複批次碼)
if (ResArr1 != "" && ResArr1 >= 0 && ResArr2 != "") {
    BatchID := (ResArr5 != "") ? ResArr5 : "N/A"
    Cost := (ResArr3 != "") ? ResArr3 : "0"
    StatusStr := UseSched ? "預約成功" : "發送成功"
    
    SuccessMsg := "簡訊發送請求處理完成！`n批次號碼：" . BatchID . "`n實際發送：" . ResArr2 . " 筆`n扣除點數：" . Cost . " 點`n剩餘點數：" . ResArr1 . " 點"
    
    ; 如果啟用了過濾，且有被過濾掉的門號，提示使用者
    if (FilterDuplicate && ResArr0 >= 6 && ResArr6 != "") {
        SuccessMsg .= "`n`n⚠️ 以下門號因為 24 小時內已發送過相同內容，已被系統自動攔截過濾：`n" . ResArr6
        StatusStr .= " (含攔截)"
    }
    
    MsgBox, 64, 處理結果, %SuccessMsg%
    LogEntry := CurrentTime . "|" . StatusStr . "|" . BatchID . "|" . DEST . "|" . CleanMSG . "|" . Cost . "|-"
} else {
    ; 處理失敗狀況
    errText := ""
    errCode := res
    if (ResArr0 >= 2) {
        errCode := ResArr1
        errText := "系統訊息：" . ResArr2 . "`n查表原因：" . TranslateErrorCode(errCode)
    } else {
        errText := TranslateErrorCode(errCode)
    }
    
    MsgBox, 16, 發送失敗, 錯誤代碼：%errCode%`n%errText%
    LogEntry := CurrentTime . "|發送失敗|N/A|" . DEST . "|" . CleanMSG . "|0|" . errCode
}

FileAppend, %LogEntry%`n, %LogFile%, UTF-8
return

ResetAuth:
MsgBox, 52, 重置確認, 確定要清除儲存在登錄檔中的帳密嗎？`n清除後程式將自動重新啟動。
IfMsgBox, Yes
{
    RegDelete, %RegPath%, UID
    RegDelete, %RegPath%, PWD
    Reload 
}
return

; ==============================================================================
; 紀錄查詢子視窗 (GUI 3) - 欄位重構並相容舊版紀錄
; ==============================================================================
ShowLogWindow:
Gui, 3:Destroy
Gui, 3:Default 
Gui, 3:Font, s10, Microsoft JhengHei

Gui, 3:Add, Text, x15 y15, 🔍 關鍵字搜尋：
Gui, 3:Add, Edit, x110 y12 w350 vFilterKeyword gFilterLogs, 
Gui, 3:Add, Button, x470 y10 w120 h30 gFilterLogs, 篩選紀錄
Gui, 3:Add, Button, x600 y10 w180 h30 gCheckDelivery, 📡 查詢電信送達狀態

; 根據指定順序建構表頭
Gui, 3:Add, ListView, x15 y50 w770 h380 vLogLV Grid, 日期時間|狀態|批次|手機號碼|簡訊內容|扣點數|失敗原因
LV_ModifyCol(1, 140) 
LV_ModifyCol(2, 90)  
LV_ModifyCol(3, 100) 
LV_ModifyCol(4, 100) 
LV_ModifyCol(5, 200) 
LV_ModifyCol(6, 60)  
LV_ModifyCol(7, 80)  

GoSub, LoadLogsToLV
Gui, 3:Show, w800 h450, 📜 發送紀錄查詢
return

LoadLogsToLV:
Gui, 3:Default
LV_Delete() 
if (FileExist(LogFile)) {
    Loop, Read, %LogFile%
    {
        if (A_LoopReadLine = "")
            continue
        StringSplit, Field, A_LoopReadLine, |
        
        fTime := Trim(Field1)
        fStatus := Trim(Field2)
        
        ; 為了讓以前存的紀錄不會因為欄位對調而亂掉，自動判斷是舊版還是新版
        if (Field0 == 6) { 
            ; 最早期的 6 欄版本 (時間|狀態|號碼|內容|批次|原因)
            fBatchID := Trim(Field5)
            fDest := Trim(Field3)
            fMsg := Trim(Field4)
            fCost := "-"
            fReason := Trim(Field6)
        } else {           
            ; 判斷第 3 欄位是不是純數字或+號開頭(代表是舊版的手機號碼)
            testField3 := Trim(Field3)
            if (RegExMatch(testField3, "^[\d\+]+$")) {
                ; 舊版 7 欄位 (時間|狀態|號碼|內容|批次|點數|原因)
                fBatchID := Trim(Field5)
                fDest := Trim(Field3)
                fMsg := Trim(Field4)
                fCost := Trim(Field6)
                fReason := Trim(Field7)
            } else {
                ; 全新重構 7 欄位 (時間|狀態|批次|號碼|內容|點數|原因)
                fBatchID := Trim(Field3)
                fDest := Trim(Field4)
                fMsg := Trim(Field5)
                fCost := Trim(Field6)
                fReason := Trim(Field7)
            }
        }

        if (FilterKeyword != "") {
            if (!InStr(fDest, FilterKeyword) && !InStr(fMsg, FilterKeyword) && !InStr(fBatchID, FilterKeyword))
                continue
        }
        
        ; 如果有錯誤碼，把它翻譯出來顯示
        if (fReason != "-" && fReason != "N/A" && fReason != "") {
            transReason := TranslateErrorCode(fReason)
            if (transReason != "未知錯誤碼")
                fReason := fReason . " (" . transReason . ")"
        }
        
        ; 按照新的指定順序加入 ListView
        LV_Add("", fTime, fStatus, fBatchID, fDest, fMsg, fCost, fReason)
    }
}
return

FilterLogs:
Gui, 3:Submit, NoHide
GoSub, LoadLogsToLV
return

CheckDelivery:
Gui, 3:Default
Row := LV_GetNext(0, "Focused") 
if (!Row) {
    MsgBox, 48, 提示, 請先點擊選擇一筆紀錄！
    return
}
; 批次碼現在是第 3 欄，手機號碼是第 4 欄
LV_GetText(selBatchID, Row, 3) 
LV_GetText(selDest, Row, 4)    
if (selBatchID = "N/A" || selBatchID = "") {
    MsgBox, 48, 提示, 該筆紀錄發送失敗，沒有批次號碼無法查詢！
    return
}

URL := "https://new.e8d.tw/API21/HTTP/GetDeliveryStatus.ashx"
PostData := "UID=" . URIEncode(SavedUID) . "&PWD=" . URIEncode(SavedPWD) . "&BID=" . URIEncode(selBatchID) . "&PNO=1&RESPFORMAT=0"
res := HTTPPost(URL, PostData)

StringSplit, Lines, res, `n, `r
if (Lines1 == "0" || Lines0 < 2) {
    MsgBox, 48, 查詢結果, 電信端尚未產生狀態報告，或查無此批次資料。
} else {
    StringSplit, Cols, Lines2, %A_Tab%, %A_Space%
    if (Cols0 >= 5) {
        StatusCode := Trim(Cols5)
        StatusText := TranslateErrorCode(StatusCode)
        MsgBox, 64, 電信端送達狀態, 發送門號：%selDest%`n目前狀態：(%StatusCode%) %StatusText%
    } else {
        MsgBox, 64, 狀態查詢 (原始回傳), %res%
    }
}
return

3GuiClose:
Gui, 3:Destroy
return

1GuiClose:
GuiClose:
ExitApp

; ==============================================================================
; 共用核心工具函式：HTTP 請求與網址安全編碼
; ==============================================================================
HTTPPost(url, postData) {
    whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
    whr.Open("POST", url, false) 
    whr.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
    whr.Send(postData)
    return whr.ResponseText
}

URIEncode(str) {
    VarSetCapacity(Var, StrPut(str, "UTF-8"))
    StrPut(str, &Var, "UTF-8")
    while code := NumGet(Var, A_Index - 1, "UChar") {
        if (code >= 0x30 && code <= 0x39 || code >= 0x41 && code <= 0x5A || code >= 0x61 && code <= 0x7A || code == 0x2D || code == 0x2E || code == 0x5F || code == 0x7E)
            char .= Chr(code)
        else {
            hex := Format("{:02X}", code)
            char .= "%" . hex
        }
    }
    return char
}

; ==============================================================================
; 錯誤碼翻譯函式 (依據 API 2.1 規格書附件一)
; ==============================================================================
TranslateErrorCode(code) {
    code := Trim(code)
    if (code == "-10")
        return "受話方手機系統不支援 MMS"
    else if (code == "-8")
        return "受話方手機號碼格式不符"
    else if (code == "-5")
        return "內容長度超過限制"
    else if (code == "-4")
        return "預計發送時間已逾期 24 小時以上"
    else if (code == "-3")
        return "受話方手機號碼為互動黑名單"
    else if (code == "-2")
        return "API 帳號或密碼錯誤"
    else if (code == "-1")
        return "參數錯誤"
    else if (code == "0")
        return "訊息已成功送達電信端，等待手機收訊中"
    else if (code == "100")
        return "已成功送達手機"
    else if (code == "101")
        return "收訊失敗 (手機關機、訊號不良或容量不足)"
    else if (code == "102")
        return "電信端網路系統、設備出現異常"
    else if (code == "103")
        return "收訊失敗 (門號錯誤、空號或停用中)"
    else if (code == "104")
        return "門號為電信端之黑名單"
    else if (code == "105")
        return "因訊息內文含有敏感關鍵字進行阻擋 (電信端回覆)"
    else if (code == "106")
        return "因訊息內文含有敏感關鍵字進行阻擋 (系統判斷)"
    else if (code == "300")
        return "預約簡訊，系統尚未發送"
    else if (code == "301")
        return "無額度或額度不足無法發送"
    else if (code == "303")
        return "取消預約"
    else if (code == "500")
        return "該門號為國際門號，請至帳號設定開啟國際簡訊發送功能"
    else if (code == "700")
        return "已傳送"
    else if (code == "999")
        return "回覆簡訊"
    else
        return "未知錯誤碼"
}
