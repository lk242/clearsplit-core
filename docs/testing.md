# Testing

## Local frontend gate

```powershell
corepack pnpm test
corepack pnpm lint
corepack pnpm build
```

金額分攤、私人逐筆義務、三種通訊服務的共用指令／防重送流程、i18n、資料格式與 CSV 匯出皆有單元測試。production build 同時執行 TypeScript strict check。

## Fresh database integration test

先用全新本機資料庫從頭套用所有 migration，再執行：

```text
supabase/tests/financial_invariants.sql
supabase/tests/fund_advance_offsets.sql
supabase/tests/fund_closeout_netting.sql
supabase/tests/fund_input_attribution.sql
supabase/tests/ledger_deletion.sql
supabase/tests/line_auth_handoff.sql
supabase/tests/line_webhook_permissions.sql
supabase/tests/messaging_provider_contracts.sql
supabase/tests/multi_ledger_accounts.sql
```

這些 assertion transactions 最後一律 `rollback`。除了 schema 與帳務守恆，刪除測試會建立包含公費代墊、進行中收款和 LINE 草稿的完整臨時帳本，執行整本刪除並驗證相依資料清除與刪除收據後再回滾。多帳本測試另驗證配額、建立者／負責人／加入者邊界、封存唯讀，以及 LINE 個人資料只能由本人讀取且不洩漏 LINE user ID。登入交接測試驗證角色隔離、期限、單次兌換、重放拒絕及不同帳號不可覆寫同一交接碼。

## Mobile smoke test

至少使用 390×844 viewport 測試：LIFF 首次加入、LIFF 已加入自動導回、主畫面 App 啟動 LINE 登入、Safari 完成後回到 App 自動接回、完全關閉再開仍保持登入、重新整理、深淺模式、語言切換、公費支出／代墊、公費雙向確認、私人付款／收款雙向確認、LINE／Discord／Telegram 草稿覆核、重複警示與整本刪除前備份確認。
