#NoEnv
#SingleInstance, Force
SetWorkingDir %A_ScriptDir%

; ==============================================================================
; 程式名稱：EVERY8D 簡訊發送工具
; 程式功能：發送簡訊、預約發送、管理範本、檢視本地發送紀錄、查詢送達狀態、
;           發送前確認、API 錯誤碼中文對照、過濾重複發送、攜帶式範本儲存、
;           多門號獨立存檔紀錄、帳密加密存檔、取消預約簡訊。
; ==============================================================================

Global RegPath := "HKCU\Software\Every8DSMSTool"
Global TmplFile := "templates.ini" 
Global LogFile := "sms_log.txt"
Global Templates := {}

; ==============================================================================
; 1. 初始化：載入範本、帳號認證與預約時間預設值
; ==============================================================================
InitAuth:
GoSub, LoadTemplates

; 讀取加密過的帳密
RegRead, SavedEncUID, %RegPath%, EncUID
RegRead, SavedEncPWD, %RegPath%, EncPWD
SavedUID := SimpleDecrypt(SavedEncUID)
SavedPWD := SimpleDecrypt(SavedEncPWD)

; 無痛遷移機制：如果發現舊版明碼帳密，自動升級成加密版並刪除舊機碼
if (SavedUID = "" || SavedPWD = "") {
    RegRead, OldUID, %RegPath%, UID
    RegRead, OldPWD, %RegPath%, PWD
    if (OldUID != "" && OldPWD != "") {
        SavedUID := Trim(OldUID)
        SavedPWD := Trim(OldPWD)
        RegDelete, %RegPath%, UID
        RegDelete, %RegPath%, PWD
        RegWrite, REG_SZ, %RegPath%, EncUID, % SimpleEncrypt(SavedUID)
        RegWrite, REG_SZ, %RegPath%, EncPWD, % SimpleEncrypt(SavedPWD)
    }
}

if (SavedUID = "" || SavedPWD = "") {
    InputBox, SavedUID, 初始帳號設定, 請輸入您的 EVERY8D 帳號 (UID):,, 280, 130
    if (ErrorLevel || SavedUID = "")
        ExitApp 
        
    InputBox, SavedPWD, 初始密碼設定, 請輸入您的 EVERY8D 密碼 (PWD):,, 280, 130, Hide
    if (ErrorLevel || SavedPWD = "")
        ExitApp 
    
    ; 寫入時進行加密
    RegWrite, REG_SZ, %RegPath%, EncUID, % SimpleEncrypt(SavedUID)
    RegWrite, REG_SZ, %RegPath%, EncPWD, % SimpleEncrypt(SavedPWD)
}

FutureTime := A_Now
EnvAdd, FutureTime, 30, Minutes 
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
Gui, 1:Add, Edit, x15 y115 w450 vDEST, 

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
IniRead, allTmpls, %TmplFile%, Templates
if (allTmpls != "" && allTmpls != "ERROR") {
    Loop, Parse, allTmpls, `n, `r
    {
        pos := InStr(A_LoopField, "=")
        if (pos) {
            tTitle := SubStr(A_LoopField, 1, pos-1)
            tContent := SubStr(A_LoopField, pos+1)
            tContent := StrReplace(tContent, "{NEWLINE}", "`n")
            Templates[tTitle] := tContent
        }
    }
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
Gui, 2:Add, Edit, x90 y232 w375 h60 vEditTmplContent gUpdateTmplCharCount, 

Gui, 2:Add, Text, x90 y295 w375 vTmplCharCountText c0x007ACC, 字數：0 字

Gui, 2:Add, Button, x15 y320 w215 h32 gSaveTmpl, 💾 新增 / 更新
Gui, 2:Add, Button, x250 y320 w215 h32 gDeleteTmpl, ❌ 刪除所選

GoSub, LoadTmplToLV
Gui, 2:Show, w480 h370, ⚙️ 簡訊範本管理
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
    GoSub, UpdateTmplCharCount
}
return

UpdateTmplCharCount:
Gui, 2:Submit, NoHide
len := StrLen(EditTmplContent)
GuiControl, 2:, TmplCharCountText, % "字數：" . len . " 字"
return

SaveTmpl:
Gui, 2:Submit, NoHide
if (EditTmplTitle = "" || EditTmplContent = "") {
    MsgBox, 48, 提示, 範本名稱與內容皆不可為空！
    return
}
if (InStr(EditTmplTitle, "=")) {
    MsgBox, 48, 提示, 範本名稱不可包含等號 (=)，請修改名稱！
    return
}

Templates[EditTmplTitle] := EditTmplContent
encodedContent := StrReplace(EditTmplContent, "`n", "{NEWLINE}")
encodedContent := StrReplace(encodedContent, "`r", "")
IniWrite, %encodedContent%, %TmplFile%, Templates, %EditTmplTitle%

GoSub, LoadTmplToLV  
GoSub, RefreshTmplDDL 

GuiControl, 2:, EditTmplTitle, 
GuiControl, 2:, EditTmplContent, 
GoSub, UpdateTmplCharCount

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
    IniDelete, %TmplFile%, Templates, %delTitle%
    
    GuiControl, 2:, EditTmplTitle,  
    GuiControl, 2:, EditTmplContent, 
    GoSub, UpdateTmplCharCount
    
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

ConfirmSendSMS:
Gui, 1:Submit, NoHide
if (DEST = "" || MSG = "") {
    MsgBox, 48, 提示, 請填寫手機號碼與簡訊內容！
    return
}

StringSplit, DestArr, DEST, `,
DestCount := 0
Loop, %DestArr0% {
    if (Trim(DestArr%A_Index%) != "")
        DestCount++
}

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

if (ResArr1 != "" && ResArr1 >= 0 && ResArr2 != "") {
    BatchID := (ResArr5 != "") ? ResArr5 : "N/A"
    Cost := (ResArr3 != "") ? ResArr3 : "0"
    StatusStr := UseSched ? "預約成功" : "發送成功"
    
    SuccessMsg := "簡訊發送請求處理完成！`n批次號碼：" . BatchID . "`n實際發送：" . ResArr2 . " 筆`n扣除點數：" . Cost . " 點`n剩餘點數：" . ResArr1 . " 點"
    
    FilteredList := ""
    if (FilterDuplicate && ResArr0 >= 6 && ResArr6 != "") {
        FilteredList := ResArr6
        SuccessMsg .= "`n`n⚠️ 以下門號因為 24 小時內已發送過相同內容，已被系統自動攔截過濾：`n" . ResArr6
    }
    
    MsgBox, 64, 處理結果, %SuccessMsg%
    
    PerMsgCost := (ResArr2 > 0) ? Round(Cost / ResArr2, 2) : 0
    StringSplit, DestArr, DEST, `,
    Loop, %DestArr0% {
        thisDest := Trim(DestArr%A_Index%)
        if (thisDest == "")
            continue
            
        thisStatus := StatusStr
        thisCost := PerMsgCost
        
        if (FilteredList != "" && InStr("/" . FilteredList . "/", "/" . thisDest . "/")) {
            thisStatus := "攔截(重複)"
            thisCost := 0
        }
        
        LogEntry := CurrentTime . "|" . thisStatus . "|" . BatchID . "|" . thisDest . "|" . CleanMSG . "|" . thisCost . "|-"
        FileAppend, %LogEntry%`n, %LogFile%, UTF-8
    }
    
    GuiControl, 1:, DEST, 
    GuiControl, 1:, MSG, 
    GuiControl, 1:Choose, TmplSelect, 1
    GoSub, UpdateCharCount
    
} else {
    errText := ""
    errCode := res
    if (ResArr0 >= 2) {
        errCode := ResArr1
        errText := "系統訊息：" . ResArr2 . "`n查表原因：" . TranslateErrorCode(errCode)
    } else {
        errText := TranslateErrorCode(errCode)
    }
    
    MsgBox, 16, 發送失敗, 錯誤代碼：%errCode%`n%errText%
    
    StringSplit, DestArr, DEST, `,
    Loop, %DestArr0% {
        thisDest := Trim(DestArr%A_Index%)
        if (thisDest == "")
            continue
        LogEntry := CurrentTime . "|發送失敗|N/A|" . thisDest . "|" . CleanMSG . "|0|" . errCode
        FileAppend, %LogEntry%`n, %LogFile%, UTF-8
    }
}

return

ResetAuth:
MsgBox, 52, 重置確認, 確定要清除儲存在加密登錄檔中的帳密嗎？`n清除後程式將自動重新啟動。
IfMsgBox, Yes
{
    RegDelete, %RegPath%, EncUID
    RegDelete, %RegPath%, EncPWD
    Reload 
}
return

; ==============================================================================
; 紀錄查詢子視窗 (GUI 3)
; ==============================================================================
ShowLogWindow:
Gui, 3:Destroy
Gui, 3:Default 
Gui, 3:Font, s10, Microsoft JhengHei

Gui, 3:Add, Text, x15 y15, 🔍 關鍵字搜尋：
Gui, 3:Add, Edit, x110 y12 w230 vFilterKeyword gFilterLogs, 
Gui, 3:Add, Button, x350 y10 w90 h30 gFilterLogs, 篩選紀錄
Gui, 3:Add, Button, x450 y10 w160 h30 gCheckDelivery, 📡 查詢電信送達狀態
Gui, 3:Add, Button, x620 y10 w160 h30 gCancelSchedule, 🚫 取消預約簡訊

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
        
        if (Field0 == 6) { 
            fBatchID := Trim(Field5)
            fDest := Trim(Field3)
            fMsg := Trim(Field4)
            fCost := "-"
            fReason := Trim(Field6)
        } else {           
            testField3 := Trim(Field3)
            if (RegExMatch(testField3, "^[\d\+]+$")) {
                fBatchID := Trim(Field5)
                fDest := Trim(Field3)
                fMsg := Trim(Field4)
                fCost := Trim(Field6)
                fReason := Trim(Field7)
            } else {
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
        
        if (fReason != "-" && fReason != "N/A" && fReason != "") {
            transReason := TranslateErrorCode(fReason)
            if (transReason != "未知錯誤碼")
                fReason := fReason . " (" . transReason . ")"
        }
        
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

CancelSchedule:
Gui, 3:Default
Row := LV_GetNext(0, "Focused") 
if (!Row) {
    MsgBox, 48, 提示, 請先點擊選擇一筆「預約成功」的紀錄！
    return
}
LV_GetText(selBatchID, Row, 3) 
LV_GetText(selStatus, Row, 2)

if (selBatchID = "N/A" || selBatchID = "") {
    MsgBox, 48, 提示, 該筆紀錄沒有批次號碼，無法取消！
    return
}
if (!InStr(selStatus, "預約")) {
    MsgBox, 48, 提示, 只能取消狀態為「預約成功」的簡訊！
    return
}

MsgBox, 52, 取消確認, 確定要取消批次號碼 [%selBatchID%] 的預約簡訊嗎？
IfMsgBox, Yes
{
    URL := "https://new.e8d.tw/API21/HTTP/EraseBooking.ashx"
    PostData := "UID=" . URIEncode(SavedUID) . "&PWD=" . URIEncode(SavedPWD) . "&BID=" . URIEncode(selBatchID)
    res := HTTPPost(URL, PostData)

    StringSplit, ResArr, res, `,
    if (ResArr1 != "" && ResArr1 >= 0) {
        MsgBox, 64, 取消成功, 成功取消預約！`n刪除筆數：%ResArr1%`n回補點數：%ResArr2%
        
        LV_Modify(Row, "Col2", "預約已取消") 
        
        tempFile := LogFile . ".tmp"
        FileDelete, %tempFile%
        Loop, Read, %LogFile%, %tempFile%
        {
            if (InStr(A_LoopReadLine, selBatchID) && InStr(A_LoopReadLine, "預約成功")) {
                newLine := StrReplace(A_LoopReadLine, "|預約成功|", "|預約已取消|")
                FileAppend, %newLine%`n
            } else {
                FileAppend, %A_LoopReadLine%`n
            }
        }
        FileMove, %tempFile%, %LogFile%, 1 
    } else {
        errText := TranslateErrorCode(ResArr1)
        if (ResArr2 != "")
            errText := ResArr2 . " (" . errText . ")"
        MsgBox, 16, 取消失敗, 錯誤代碼：%ResArr1%`n原因：%errText%
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
; 共用核心工具函式
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

SimpleEncrypt(str) {
    hexStr := ""
    Loop, Parse, str
    {
        charCode := Asc(A_LoopField) ^ 0x5AA5
        hexStr .= Format("{:04X}", charCode)
    }
    return hexStr
}

SimpleDecrypt(hexStr) {
    str := ""
    Loop, % StrLen(hexStr) / 4
    {
        hex := "0x" . SubStr(hexStr, A_Index * 4 - 3, 4)
        str .= Chr(hex ^ 0x5AA5)
    }
    return str
}

; ===== 完整對照官方規格表更新錯誤代碼 =====
TranslateErrorCode(code) {
    code := Trim(code)
    if (code == "-1")
        return "參數錯誤"
    else if (code == "-2")
        return "帳號或密碼錯誤"
    else if (code == "-3")
        return "手機號碼為互動黑名單"
    else if (code == "-4")
        return "預計發送時間逾期"
    else if (code == "-5")
        return "內容長度超過限制"
    else if (code == "-6")
        return "預約發送時間格式錯誤"
    else if (code == "-7")
        return "發送名單檔案過大"
    else if (code == "-8")
        return "手機號碼格式不符"
    else if (code == "-9")
        return "查無此批次發送紀錄"
    else if (code == "-10")
        return "手機系統不支援 MMS"
    else if (code == "-11")
        return "尚未開通 API 發送權限"
    else if (code == "-12")
        return "尚未開通國際簡訊權限"
    else if (code == "-13")
        return "尚未開通點數轉發權限"
    else if (code == "-14")
        return "尚未開通 MMS 發送權限"
    else if (code == "-15")
        return "主旨長度超過限制"
    else if (code == "-16")
        return "發送限制阻擋"
    else if (code == "-20")
        return "預約時間需大於現在時間 10 分鐘"
    else if (code == "-21")
        return "無效的簡訊批次號碼"
    else if (code == "-24")
        return "預約時間不可大於現在時間 6 個月"
    else if (code == "-99")
        return "伺服器發生不明錯誤"
    else if (code == "0")
        return "已送達電信端，等待手機收訊"
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
        return "內文含敏感關鍵字 (電信端阻擋)"
    else if (code == "106")
        return "內文含敏感關鍵字 (系統阻擋)"
    else if (code == "107")
        return "系統發送逾時"
    else if (code == "300")
        return "預約簡訊，系統尚未發送"
    else if (code == "301")
        return "無額度或額度不足無法發送"
    else if (code == "303")
        return "取消預約"
    else if (code == "500")
        return "國際門號未開通功能"
    else if (code == "700")
        return "已傳送"
    else if (code == "999")
        return "回覆簡訊"
    else if (code == "-666")
        return "未在官方規格內的例外錯誤"
    else
        return "未知錯誤碼"
}
