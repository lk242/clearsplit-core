import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import type { LedgerHandoffReceipt, Participant, Theme } from '../types'
import './HandoffCompleteView.css'

type HandoffCompleteViewProps = {
  receipt: LedgerHandoffReceipt
  participants: Participant[]
  theme: Theme
  onToggleTheme: () => void
  onFinish: () => void
}

export function HandoffCompleteView({ receipt, participants, theme, onToggleTheme, onFinish }: HandoffCompleteViewProps) {
  return (
    <div className="app-shell handoff-shell">
      <header className="topbar">
        <div className="brand"><span className="brand-mark"><Icon name="wallet" size={18} /></span><span>ClearSplit</span></div>
        <button className="icon-button" type="button" aria-label={theme === 'light' ? '切換為深色模式' : '切換為淺色模式'} onClick={onToggleTheme}>
          <Icon name={theme === 'light' ? 'moon' : 'sun'} size={20} />
        </button>
      </header>

      <main className="handoff-page">
        <section className="handoff-hero">
          <span className="handoff-check"><Icon name="check" size={30} /></span>
          <p>開帳流程完成</p>
          <h1>帳務權限已安全交接</h1>
          <span>帳本沒有被刪除；這個頁面原本持有的一次性開帳權限已失效。</span>
        </section>

        <section className="handoff-card">
          <div><span>帳本</span><strong>{receipt.groupName}</strong></div>
          <div><span>帳務負責人</span><strong>{receipt.responsibleMemberName}</strong></div>
          <div><span>成員</span><strong>{participants.length} 位</strong></div>
        </section>

        <section className="handoff-members" aria-label="交接時成員名單">
          {participants.map((participant) => (
            <article key={participant.id}>
              <Avatar participant={participant} size="medium" />
              <div><strong>{participant.name}</strong><span>{participant.id === receipt.responsibleMemberId ? '帳務負責人' : '參與成員'}</span></div>
              {participant.id === receipt.responsibleMemberId && <Icon name="check" size={18} />}
            </article>
          ))}
        </section>

        <div className="handoff-guidance">
          <Icon name="alert-circle" size={19} />
          <span>請回到剛才完成 LINE 加入的頁面並重新整理；該 LINE 身分現在是唯一可管理帳本的人。</span>
        </div>

        <button className="secondary-button full-width" type="button" onClick={onFinish}>完成並清除此裝置的開帳暫存</button>
      </main>
    </div>
  )
}
