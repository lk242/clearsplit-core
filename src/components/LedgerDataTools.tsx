import { useCallback, useEffect, useState } from 'react'
import {
  exportPortableLedgerBackup,
  fetchLedgerReconciliation,
  type LedgerReconciliation,
} from '../lib/cloudLedger'
import type { CloudLedgerState } from '../types'
import {
  downloadLedgerFile,
  prepareLedgerCsv,
  prepareLedgerJson,
  shareLedgerFile,
  supportsLedgerFileShare,
  type LedgerExportFile,
} from '../utils/ledgerExport'
import { formatCurrency } from '../utils/format'
import { Icon } from './Icon'
import './LedgerDataTools.css'

type Props = {
  cloudLedger: CloudLedgerState
  canExport: boolean
}

export function LedgerDataTools({ cloudLedger, canExport }: Props) {
  const [report, setReport] = useState<LedgerReconciliation | null>(null)
  const [loading, setLoading] = useState(true)
  const [exporting, setExporting] = useState<'json' | 'csv' | null>(null)
  const [readyFile, setReadyFile] = useState<LedgerExportFile | null>(null)
  const [savingFile, setSavingFile] = useState(false)
  const [downloadNotice, setDownloadNotice] = useState('')
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    setLoading(true)
    try {
      setReport(await fetchLedgerReconciliation(cloudLedger.groupId))
      setError('')
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setLoading(false)
    }
  }, [cloudLedger.groupId])

  useEffect(() => { void refresh() }, [refresh])

  const download = async (format: 'json' | 'csv') => {
    setExporting(format)
    setReadyFile(null)
    setDownloadNotice('')
    setError('')
    try {
      const backup = await exportPortableLedgerBackup(cloudLedger.groupId)
      const file = format === 'json' ? prepareLedgerJson(backup) : prepareLedgerCsv(backup)
      setReadyFile(file)
      if (supportsLedgerFileShare(file)) {
        setDownloadNotice('檔案已產生，請點「分享／儲存檔案」，再選擇「儲存到檔案」。')
      } else {
        downloadLedgerFile(file)
        setDownloadNotice('下載已開始；若瀏覽器沒有反應，請點下方按鈕再次開啟檔案。')
      }
      setReport(backup.reconciliation)
    } catch (reason) {
      setError(toMessage(reason))
    } finally {
      setExporting(null)
    }
  }

  const saveReadyFile = async () => {
    if (!readyFile) return
    setSavingFile(true)
    setError('')
    try {
      const shared = await shareLedgerFile(readyFile)
      if (shared) {
        setDownloadNotice('已開啟系統分享面板；請選擇「儲存到檔案」或要傳送的 App。')
      } else {
        downloadLedgerFile(readyFile)
        setDownloadNotice('已開啟檔案；若顯示檔案內容，請使用瀏覽器分享選單儲存。')
      }
    } catch (reason) {
      if (isShareAbort(reason)) {
        setDownloadNotice('已取消分享，檔案仍保留在這裡，可再次點擊。')
      } else {
        try {
          downloadLedgerFile(readyFile)
          setDownloadNotice('無法開啟系統分享面板，已改用檔案下載。若仍無反應，請改用 Safari 開啟正式站。')
        } catch (fallbackReason) {
          setError(toMessage(fallbackReason))
        }
      }
    } finally {
      setSavingFile(false)
    }
  }

  return (
    <section className="ledger-data-tools">
      <header>
        <div><span>帳務資料</span><strong>核對、備份與匯出</strong></div>
        <button className="row-icon-button" type="button" aria-label="重新執行帳務核對" disabled={loading} onClick={() => void refresh()}><Icon name="refresh" size={16} /></button>
      </header>

      {report && (
        <div className={report.isHealthy ? 'reconciliation-state is-healthy' : 'reconciliation-state is-error'}>
          <Icon name={report.isHealthy ? 'check' : 'alert-circle'} size={19} />
          <div>
            <strong>{report.isHealthy ? '帳務守恆檢查通過' : '發現帳務完整性異常'}</strong>
            <span>私人分攤異常 {report.invalidPrivateShareCount} · 狀態異常 {report.invalidPrivateStatusCount} · 公費分錄異常 {report.invalidFundTransactionCount}</span>
          </div>
        </div>
      )}

      {report?.fundConfigured && (
        <div className="reconciliation-metrics">
          <div><span>公費總帳</span><strong>{formatCurrency(report.fundBalance)}</strong></div>
          <div><span>成員餘額合計</span><strong>{formatCurrency(report.fundAccountTotal)}</strong></div>
          <div><span>差異</span><strong className={report.fundBalanceDifference === 0 ? '' : 'is-danger'}>{formatCurrency(report.fundBalanceDifference)}</strong></div>
        </div>
      )}

      {loading && !report && <div className="data-tools-loading">正在執行後端帳務核對…</div>}
      {error && <div className="line-error" role="alert"><Icon name="alert-circle" size={16} />{error}</div>}

      {canExport && (
        <div className="data-export-actions">
          <button className="secondary-button" type="button" disabled={exporting !== null} onClick={() => void download('json')}><Icon name="cloud" size={16} />{exporting === 'json' ? '產生中…' : '下載 JSON 備份'}</button>
          <button className="secondary-button" type="button" disabled={exporting !== null} onClick={() => void download('csv')}><Icon name="receipt" size={16} />{exporting === 'csv' ? '產生中…' : '下載 CSV 對帳表'}</button>
        </div>
      )}
      {readyFile && (
        <div className="data-export-ready" role="status">
          <Icon name="check" size={18} />
          <div><strong>{readyFile.fileName}</strong><span>{downloadNotice}</span></div>
          <button className="secondary-button" type="button" disabled={savingFile || exporting !== null} onClick={() => void saveReadyFile()}>{savingFile ? '開啟中…' : '分享／儲存檔案'}</button>
        </div>
      )}
      <p>備份不含 LINE user ID、邀請憑證、登入帳號 ID 或原始群組訊息。為保留稽核軌跡，正式帳不提供覆寫式匯入。</p>
    </section>
  )
}

function toMessage(reason: unknown) {
  return reason instanceof Error ? reason.message : '無法處理帳務資料'
}

function isShareAbort(reason: unknown) {
  return reason instanceof DOMException && reason.name === 'AbortError'
}
