# LINE 成員與記帳 Bot

## 已上線流程

LINE 在系統中有兩個明確分工：

1. LIFF 邀請連結只負責成員本人登入、帶入 LINE 顯示名稱與頭像，並加入指定帳本。已加入者再次開啟同一連結會直接回到正式站，不會重複建立成員。
2. `ClearSplit 記帳助手` 官方帳號只負責群組綁定、成員身分連結與接收明確的 `#記帳` 指令。普通聊天內容一律忽略，Bot 不會讀取或匯入未加標記的款項。

LIFF 與正式頁共用同一個穩定帳務登入。直接開啟正式站時，程式會先讀取並向 Supabase 驗證這台裝置已保存的帳務工作階段；有效時直接載入帳本及自己的 LINE 顯示名稱，不再要求 LIFF 重登。只有工作階段不存在或已失效時，才嘗試目前的 LINE 登入或顯示「用 LINE 登入同步」。第一次登入但尚未加入任何帳本，也會先建立穩定帳號，讓使用者建立自己的第一本帳本。LINE access token 只送到 Edge Function 驗證，不儲存在帳本或前端長期資料中。通過驗證後，後端才簽發同一個 Supabase 帳務身分。

LINE 顯示名稱與頭像由 Edge Function 向 LINE 驗證後寫入私有 `line_identities`。瀏覽器只能透過 `get_my_line_profile()` 讀取自己帳號的顯示名稱與頭像，不能讀取 LINE user ID，也不能讀取其他使用者的個人資料。首頁歡迎詞只把這個純文字名稱交給 React 顯示，不作為帳務權限或金額判斷依據。

Safari 與 iPhone／iPad 加入主畫面的 Web App 不會共享 localStorage。從主畫面 App 按 LINE 登入時，App 先在自己的儲存空間產生 256-bit 隨機交接碼；Safari 完成 LINE 驗證後，Edge Function 只把交接碼的 SHA-256 雜湊、穩定帳號與 10 分鐘期限寫入資料庫。使用者回到主畫面 App 後，以原始交接碼兌換一次新的 Supabase 工作階段，成功後立即移除裝置端交接碼；資料庫使用原子刪除防止重放。Supabase access token 與 refresh token 不會放入回呼網址或交接資料表。

若超過 10 分鐘才回到 App、清除網站資料、移除 App 資料或工作階段被撤銷，基於安全仍須重新登入。Safari 登入完成頁會提示使用者回到主畫面的 ClearSplit；成功交接一次後，後續重開由 App 自己的 localStorage 恢復登入。

受邀加入不會消耗使用者的建立帳本額度。帳本上限與角色邊界請以 `README.md` 的「權限與配額」為準。

帳本負責人在成員頁按 `Bots` 並選擇 LINE 後：

1. 將 `ClearSplit 記帳助手` 加為好友。
2. 邀請官方帳號進入 LINE 群組。
3. 將頁面產生的 `#綁定 32位綁定碼` 貼到該群組。
4. 替每位帳本成員產生個人連結碼，讓本人在群組貼上 `#連結 32位連結碼`。群組綁定與個人身分是兩個不同步驟。
5. 收到連結成功回覆後，使用 `#記帳 項目 金額` 建立「公帳支出」草稿。發話者的 LINE user ID 只用於找到已連結的帳本成員與稽核誰回報，不會被當成私人代墊付款人。

例如：

```text
#記帳 晚餐 400
```

這代表建立「公費支付晚餐 400 元」的公帳草稿。Bot 不接受付款人、參與者或私人分帳語法；私人代墊一律回網站逐筆建立。若發話者尚未加入帳本或尚未完成個人連結，Bot 會拒絕建立草稿，不會猜測身分。

Bot 只會建立待確認草稿，不會直接寫入正式帳目。負責人必須回到 ClearSplit 公費頁核對日期、金額、代墊需求與重複警示後再確認入帳。LINE webhook event ID、LINE message ID，以及同一期／同日／同金額檢查共同防止重送或跨來源重複入帳；暫時性處理失敗會回傳失敗狀態，讓 LINE redelivery 重試。

## 成員邀請設計：邀請連結 + 本人確認

由帳本管理者建立一組有期限、可撤銷的邀請連結，例如：

```text
https://countapp.example/join/{invite-token}
```

管理者在網頁按「分享到 LINE」，把連結送到既有群組。每位成員開啟連結後，以 LINE Login 登入、預覽自己的顯示名稱與頭像，最後按「加入帳本」。加入是本人明確操作，且帳本內用不可變的使用者 ID 辨識身分，不用可能重複或隨時改名的 display name。

這個流程的理由：

- 成員加入不依賴 Official Account；只有需要群組記帳的帳本才邀請 Bot。
- 每位成員明確同意加入，可在加入前顯示會保存的資料。
- 網頁、iPhone 與 Android 都能使用同一條連結；沒有 LINE 的人仍可提供手動加入備援。
- LINE Login 可讓網頁取得已授權使用者的 ID、顯示名稱和頭像，減少輸入成本。

## 後續可增加：LIFF 分享目標選擇器

若要讓「分享到 LINE」更順，可建立 LIFF App，使用 `liff.shareTargetPicker()` 讓建立者直接挑好友或群組分享邀請訊息。分享動作仍由使用者發起，且不代表應用程式能讀取被選群組的完整名單。

## 不直接抓取群組全員

Messaging API 的確有群組成員 ID API，但它要求 LINE Official Account 已在該群組中，而且「列出全部成員」只開放 verified 或 premium Official Account。部分未提供個人資料同意的使用者也不會出現在結果內。因此它不適合作為一般私人群組的主要匯入途徑；即使未來導入 bot，仍應讓每位成員確認帳本身分。

## 安全與資料規則

- 邀請 token 儲存雜湊，不把原始 token 寫入資料庫；預設 7 天失效。
- token 可設定最大使用次數，帳本管理者可立即撤銷。
- LINE user ID 只用來綁定帳本使用者，不在前端或分享訊息中公開。
- 跨瀏覽器恢復帳本時，Edge Function 會重新向 LINE 驗證 access token 的有效期、channel audience 與 `profile` scope；非帳本成員無法只靠登入 LINE 取得帳本。
- 主畫面 App 的登入交接碼使用 256-bit 隨機值、10 分鐘失效、資料庫只保存雜湊且原子單次兌換；匿名與一般 authenticated 角色都不能直接讀取交接資料或執行存取函式。
- display name 與頭像是可變的展示資料，帳務關聯一律使用內部 member ID。
- 在登入按鈕旁明確說明這台裝置會保留帳務工作階段；使用者清除網站資料即可移除裝置端登入狀態。
- 加入後保留 audit event：誰、何時、透過哪一個 invite 加入。
- 提供手動新增與稍後綁定 LINE 的備援，避免登入問題阻斷記帳。

## 官方依據

- [LINE Login overview](https://developers.line.biz/en/docs/line-login/overview/)
- [Managing LINE Login users](https://developers.line.biz/en/docs/line-login/managing-users/)
- [LIFF share target picker](https://developers.line.biz/en/reference/liff/#share-target-picker)
- [Getting group member user IDs](https://developers.line.biz/en/docs/messaging-api/getting-user-ids/)
- [Consent on getting user profile information](https://developers.line.biz/en/docs/messaging-api/user-consent)
