#NoEnv
#SingleInstance, Force
SetWorkingDir %A_ScriptDir%

; ==============================================================================
; 程式名稱：EVERY8D 簡訊發送工具
; 程式功能：透過 EVERY8D API 發送簡訊、預約發送、管理簡訊範本、檢視本地發送紀錄。
; 儲存機制：採用 Windows 登錄檔 (HKCU) 儲存帳密與範本，利用 Windows 原生使用者帳戶
;           隔離機制確保安全性，達到「零外部設定檔」的極簡化。
; ==============================================================================

; --- 定義系統全域變數 ---
; RegPath: 儲存 EVERY8D 帳號密碼的登錄檔主機碼路徑
Global RegPath := "HKCU\Software\Every8DSMSTool"
; TmplRegPath: 儲存所有自訂簡訊範本的子機碼路徑
Global TmplRegPath := "HKCU\Software\Every8DSMSTool\Templates"
; LogFile: 本地發送紀錄檔名稱 (與主程式放在同一個資料夾)
Global LogFile := "sms_log.txt"
; Templates: 程式執行期間，存放在記憶體中的範本關聯陣列 (Dictionary)
Global Templates := {}

; ==============================================================================
; 1. 初始化：載入範本、帳號認證與預約時間預設值
; ==============================================================================
InitAuth:
; --- 載入登錄檔中的範本 ---
; 透過 GoSub 跳轉執行 LoadTemplates 標籤區塊，將登錄檔範本讀入 Templates 陣列
GoSub, LoadTemplates

; --- 讀取登錄檔帳密 ---
RegRead, SavedUID, %RegPath%, UID
RegRead, SavedPWD, %RegPath%, PWD

; 清除可能存在的頭尾空白字元
SavedUID := Trim(SavedUID)
SavedPWD := Trim(SavedPWD)

; 若登錄檔中找不到紀錄 (首次執行或已被重置)，則跳出輸入框要求使用者設定
if (SavedUID = "" || SavedPWD = "") {
    InputBox, SavedUID, 初始帳號設定, 請輸入您的 EVERY8D 帳號 (UID):,, 280, 130
    if (ErrorLevel || SavedUID = "")
        ExitApp ; 使用者按取消或未輸入則直接結束程式
        
    InputBox, SavedPWD, 初始密碼設定, 請輸入您的 EVERY8D 密碼 (PWD):,, 280, 130, Hide
    if (ErrorLevel || SavedPWD = "")
        ExitApp ; 使用者按取消或未輸入則直接結束程式
    
    ; 將輸入的帳密寫入登錄檔保存，供下次啟動直接讀取
    RegWrite, REG_SZ, %RegPath%, UID, %SavedUID%
    RegWrite, REG_SZ, %RegPath%, PWD, %SavedPWD%
}

; --- 計算預設預約時間 (預設為：開啟軟體當下的 10 分鐘後) ---
FutureTime := A_Now
EnvAdd, FutureTime, 10, Minutes ; 增加 10 分鐘
FormatTime, DefDate, %FutureTime%, yyyyMMdd ; 格式化為 20231231
FormatTime, DefHour, %FutureTime%, HH       ; 格式化為 24 小時制的時
FormatTime, DefMin, %FutureTime%, mm        ; 格式化為分

; 動態產生下拉選單的時間選項 (利用迴圈產生 00~23 時 / 00~59 分)
HourOptions := ""
Loop, 24 {
    h := Format("{:02d}", A_Index - 1)
    ; 若符合預設時間，加上 "||" 讓其成為下拉選單的預設選項
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
Gui, 1:Font, s10, Microsoft JhengHei ; 設定預設字型為微軟正黑體，大小 10

; --- 帳戶狀態區 ---
Gui, 1:Add, GroupBox, x15 y10 w450 h70, 帳號登入狀態
Gui, 1:Add, Text, x30 y38, 當前帳號：
Gui, 1:Add, Text, x100 y38 w130 vUIDDisplay c0x0055AA, %SavedUID% ; 藍字顯示帳號
Gui, 1:Add, Button, x240 y32 w95 h30 gCheckCredit, 💰 查詢餘額
Gui, 1:Add, Button, x345 y32 w110 h30 gResetAuth, 🔑 重置帳密

; --- 發送對象設定區 ---
Gui, 1:Add, Text, x15 y95, 📱 手機號碼 (多筆請用半形逗號隔開)：
Gui, 1:Add, Edit, x15 y115 w450 vDEST, 0900000000

; --- 預約發送設定區 ---
; Checkbox 綁定 gToggleSched，勾選狀態改變時動態啟用/停用右側時間元件
Gui, 1:Add, Checkbox, x15 y152 w135 vUseSched gToggleSched, ⏰ 啟用預約發送
Gui, 1:Add, DateTime, x150 y149 w120 vSchedDate Disabled Choose%DefDate%, yyyy/MM/dd
Gui, 1:Add, DropDownList, x290 y149 w45 vSchedHour Disabled, %HourOptions%
Gui, 1:Add, Text, x340 y152, 時
Gui, 1:Add, DropDownList, x365 y149 w45 vSchedMin Disabled, %MinOptions%
Gui, 1:Add, Text, x415 y152, 分

; --- 簡訊範本選擇區 ---
Gui, 1:Add, Text, x15 y185, 📋 選擇簡訊範本：
TmplOptions := "|-- 請選擇內建範本 --||"
for title, content in Templates {
    TmplOptions .= title . "|" ; 組合範本名稱進入下拉選單
}
Gui, 1:Add, DropDownList, x15 y205 w320 vTmplSelect gOnTmplSelect, %TmplOptions%
Gui, 1:Add, Button, x345 y203 w120 h28 gOpenTmplMgr, ⚙️ 範本管理

; --- 簡訊內容編輯與字數統計區 ---
Gui, 1:Add, Text, x15 y240, 💬 簡訊內容：
Gui, 1:Add, Edit, x15 y265 w450 h110 vMSG gUpdateCharCount, 
Gui, 1:Add, Text, x15 y380 w450 vCharCountText c0x007ACC, 字數：0 字 (共 0 封簡訊)

; --- 核心控制按鈕 ---
Gui, 1:Add, Button, x15 y415 w215 h40 gSendSMS Default, 🚀 發送簡訊
Gui, 1:Add, Button, x250 y415 w215 h40 gShowLogWindow, 📜 檢視紀錄

; 顯示主視窗
Gui, 1:Show, w480 h470, EVERY8D簡訊發送
GoSub, UpdateCharCount ; 啟動時先算一次字數 (預設為 0)
return

; ==============================================================================
; 範本讀取與介面更新邏輯
; ==============================================================================
LoadTemplates:
Templates := {} ; 清空當前陣列
; 透過 Loop, Reg 遍歷登錄檔中的所有範本 (鍵名=標題, 鍵值=內容)
Loop, Reg, %TmplRegPath%, V
{
    RegRead, tmplContent
    if (!ErrorLevel)
        Templates[A_LoopRegName] := tmplContent
}
return

RefreshTmplDDL:
; 用於管理介面新增/刪除範本後，同步更新主視窗的下拉選單
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
; 確保選中的不是預設提示字元，並自動將對應的內容帶入文字框
if (TmplSelect != "" && TmplSelect != "-- 請選擇內建範本 --" && Templates.HasKey(TmplSelect)) {
    GuiControl, 1:, MSG, % Templates[TmplSelect]
    GoSub, UpdateCharCount ; 帶入後自動重算字數
}
return

UpdateCharCount:
Gui, 1:Submit, NoHide
len := StrLen(MSG) ; 計算字元長度 (AHK 預設以 UTF-16 處理，中文英文皆算 1 個長度)
if (len == 0) {
    GuiControl, 1:+c007ACC, CharCountText ; 恢復預設藍色
    GuiControl, 1:, CharCountText, % "字數：0 字 (共 0 封簡訊)"
} else if (len <= 70) {
    ; 單則簡訊標準限制為 70 個字 (含標點符號與空白)
    GuiControl, 1:+c007ACC, CharCountText
    GuiControl, 1:, CharCountText, % "字數：" . len . " 字 (共 1 封簡訊)"
} else {
    ; 超過 70 字後，電信商的「長簡訊」計費標準通常為每 67 字拆分為一封計費 (預留 3 字作為標頭串接碼)
    parts := Ceil(len / 67)
    GuiControl, 1:+cRed, CharCountText ; 超出 70 字變為紅色警告
    GuiControl, 1:, CharCountText, % "字數：" . len . " 字 (超過 70 字，將拆分為 " . parts . " 封簡訊計費)"
}
return

ToggleSched:
Gui, 1:Submit, NoHide
; 依據 Checkbox 是否打勾，啟用或禁用時間選擇器
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
Gui, 2:Destroy ; 先銷毀可能存在的舊視窗，確保資料與介面為最新
Gui, 2:Default
Gui, 2:Font, s10, Microsoft JhengHei

Gui, 2:Add, Text, x15 y15, 📋 現有範本清單：
; AltSubmit 參數允許捕捉到滑鼠點擊項目的事件 (A_GuiEvent)
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
LV_Delete() ; 清空 ListView
for title, content in Templates {
    LV_Add("", title, content) ; 將記憶體中的陣列逐一加入表格
}
return

OnTmplLVSelect:
; 當使用者使用滑鼠(I)點擊某個項目(S=Select)時，將資料自動帶入下方的編輯框
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
; 同步更新記憶體與實體登錄檔
Templates[EditTmplTitle] := EditTmplContent
RegWrite, REG_SZ, %TmplRegPath%, %EditTmplTitle%, %EditTmplContent%

GoSub, LoadTmplToLV  ; 更新清單
GoSub, RefreshTmplDDL ; 同步更新主視窗下拉選單
MsgBox, 64, 成功, 範本已成功儲存！
return

DeleteTmpl:
Gui, 2:Default
Row := LV_GetNext(0, "Focused") ; 取得當前選中的行數
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
    GuiControl, 2:, EditTmplTitle,  ; 清空編輯框
    GuiControl, 2:, EditTmplContent, 
    GoSub, LoadTmplToLV
    GoSub, RefreshTmplDDL
    MsgBox, 64, 完成, 已成功刪除該範本！
}
return

2GuiClose:
Gui, 2:Destroy ; 關閉範本視窗時僅銷毀子視窗，不影響主程式
return

; ==============================================================================
; API 核心事件：查詢點數與發送簡訊
; ==============================================================================
CheckCredit:
; 呼叫 GetCredit.ashx 取得剩餘點數
URL := "https://new.e8d.tw/API21/HTTP/GetCredit.ashx"
PostData := "UID=" . URIEncode(SavedUID) . "&PWD=" . URIEncode(SavedPWD)
res := HTTPPost(URL, PostData)

; 判斷回傳值是否為數字 (包含小數點與負數)
if (RegExMatch(res, "^-?\d+(\.\d+)?$")) {
    if (res >= 0)
        MsgBox, 64, 餘額查詢成功, 您的 EVERY8D 簡訊剩餘點數為：%res% 點
    else
        MsgBox, 16, 查詢失敗, 錯誤代碼：%res%（請檢查帳號密碼是否正確）
} else {
    MsgBox, 48, 系統回應, 回應內容：%res%
}
return

SendSMS:
Gui, 1:Submit, NoHide
if (DEST = "" || MSG = "") {
    MsgBox, 48, 提示, 請填寫手機號碼與簡訊內容！
    return
}

URL := "https://new.e8d.tw/API21/HTTP/SendSMS.ashx"
; 將所有參數轉換為 URL 安全編碼 (UTF-8 格式) 以防中文變亂碼
PostData := "UID=" . URIEncode(SavedUID) . "&PWD=" . URIEncode(SavedPWD) . "&DEST=" . URIEncode(DEST) . "&MSG=" . URIEncode(MSG)

; 處理預約時間參數 (ST)
if (UseSched) {
    FormatTime, SDate, %SchedDate%, yyyyMMdd
    STime := SDate . SchedHour . SchedMin . "00" ; 格式需求為：YYYYMMDDHHMMSS
    PostData .= "&ST=" . STime
}

res := HTTPPost(URL, PostData)

; 剖析 EVERY8D SendSMS 回應字串 (格式：credit,sended,cost,unsend,batch_id)
StringSplit, ResArr, res, `,

FormatTime, CurrentTime,, yyyy-MM-dd HH:mm:ss
; 寫入 Log 前先清除簡訊內容中的換行，防止破壞 txt 的單行欄位格式
CleanMSG := StrReplace(MSG, "`n", " ")
CleanMSG := StrReplace(CleanMSG, "`r", "")

; 成功判定條件：ResArr1(點數餘額)為數字且 >= 0，且 ResArr2(發送數) > 0
if (ResArr1 != "" && ResArr1 >= 0 && ResArr2 > 0) {
    BatchID := (ResArr5 != "") ? ResArr5 : "N/A"
    Cost := (ResArr3 != "") ? ResArr3 : "0"
    StatusStr := UseSched ? "預約成功" : "發送成功"
    
    MsgBox, 64, 發送成功, 簡訊已成功送出！`n批次號碼 (BatchID)：%BatchID%`n扣除點數：%Cost% 點`n剩餘點數：%ResArr1% 點
    
    ; 寫入日誌 (7 欄位格式)
    LogEntry := CurrentTime . " | " . StatusStr . " | " . DEST . " | " . CleanMSG . " | " . BatchID . " | " . Cost . " | -"
} else {
    MsgBox, 16, 發送失敗, API 回傳訊息：%res%
    ; 失敗紀錄 (填入 0 點數與 API 回傳的錯誤原因)
    LogEntry := CurrentTime . " | 發送失敗 | " . DEST . " | " . CleanMSG . " | N/A | 0 | " . res
}

FileAppend, %LogEntry%`n, %LogFile%, UTF-8
return

ResetAuth:
MsgBox, 52, 重置確認, 確定要清除儲存在登錄檔中的帳密嗎？`n清除後程式將自動重新啟動。
IfMsgBox, Yes
{
    RegDelete, %RegPath%, UID
    RegDelete, %RegPath%, PWD
    Reload ; 自動重啟程式重新觸發初始化設定
}
return

; ==============================================================================
; 紀錄查詢子視窗 (GUI 3) - 包含搜尋與舊版 Log 相容處理
; ==============================================================================
ShowLogWindow:
Gui, 3:Destroy
Gui, 3:Default ; ★重要：宣告接下來的操作對象為 GUI 3，確保 ListView 欄位寬度設定生效
Gui, 3:Font, s10, Microsoft JhengHei
Gui, 3:Add, Text, x15 y15, 🔍 關鍵字搜尋：
Gui, 3:Add, Edit, x110 y12 w350 vFilterKeyword gFilterLogs, 
Gui, 3:Add, Button, x470 y10 w120 h30 gFilterLogs, 篩選紀錄

; 表格定義與顯示順序對調 (將狀態放第二欄，手機號碼放第三欄)
Gui, 3:Add, ListView, x15 y50 w770 h380 vLogLV Grid, 時間|狀態|手機號碼|簡訊內容|批次號碼|扣除點數|失敗原因
LV_ModifyCol(1, 120) ; 時間
LV_ModifyCol(2, 70)  ; 狀態
LV_ModifyCol(3, 100) ; 手機號碼
LV_ModifyCol(4, 220) ; 簡訊內容 (主要閱讀區間拉最大)
LV_ModifyCol(5, 90)  ; 批次號碼
LV_ModifyCol(6, 60)  ; 扣除點數
LV_ModifyCol(7, 80)  ; 失敗原因

GoSub, LoadLogsToLV
Gui, 3:Show, w800 h450, 📜 發送紀錄查詢
return

LoadLogsToLV:
Gui, 3:Default
LV_Delete() ; 重繪前先清空當前列表
if (FileExist(LogFile)) {
    Loop, Read, %LogFile%
    {
        if (A_LoopReadLine = "")
            continue
        ; 以 "|" 符號切割每一行的內容
        StringSplit, Field, A_LoopReadLine, |
        
        ; 【向下相容處理】
        ; 因舊版程式只記錄了 6 個欄位，新版加入了「扣除點數」變成 7 個欄位。
        ; 透過判斷 Field0 (切割後的總陣列數) 來決定如何賦值，確保舊紀錄依然可正常讀取。
        fTime := Trim(Field1)
        fStatus := Trim(Field2)
        fDest := Trim(Field3)
        
        if (Field0 == 6) { ; 舊版相容邏輯
            fMsg := Trim(Field4)
            fBatchID := Trim(Field5)
            fCost := "-"
            fReason := Trim(Field6)
        } else {           ; 新版 7 欄位邏輯 (依據寫入順序剖析)
            fMsg := Trim(Field4)
            fBatchID := Trim(Field5)
            fCost := Trim(Field6)
            fReason := Trim(Field7)
        }

        ; 若有搜尋條件，比對電話、內容與批次碼，不符合者直接略過不加入表格
        if (FilterKeyword != "") {
            if (!InStr(fDest, FilterKeyword) && !InStr(fMsg, FilterKeyword) && !InStr(fBatchID, FilterKeyword))
                continue
        }

        LV_Add("", fTime, fStatus, fDest, fMsg, fBatchID, fCost, fReason)
    }
}
return

FilterLogs:
Gui, 3:Submit, NoHide
GoSub, LoadLogsToLV
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

; HTTPPost: 用於向伺服器發送 POST 請求
HTTPPost(url, postData) {
    whr := ComObjCreate("WinHttp.WinHttpRequest.5.1")
    whr.Open("POST", url, false) ; false 代表同步請求，等待伺服器回應
    whr.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
    whr.Send(postData)
    return whr.ResponseText
}

; URIEncode: 確保傳送的中文與特殊符號 (如 + # &) 能被伺服器正確解析
; 原理：將非英數字元轉換成 UTF-8 Hex Code (如 "%E6%B8%AC" 代表 "測")
URIEncode(str) {
    VarSetCapacity(Var, StrPut(str, "UTF-8"))
    StrPut(str, &Var, "UTF-8")
    while code := NumGet(Var, A_Index - 1, "UChar") {
        ; 保留標準的英文、數字、連字號、底線等不需編碼的字元
        if (code >= 0x30 && code <= 0x39 || code >= 0x41 && code <= 0x5A || code >= 0x61 && code <= 0x7A || code == 0x2D || code == 0x2E || code == 0x5F || code == 0x7E)
            char .= Chr(code)
        else {
            hex := Format("{:02X}", code)
            char .= "%" . hex
        }
    }
    return char
}