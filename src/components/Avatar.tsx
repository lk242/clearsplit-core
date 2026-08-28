import type { Participant } from '../types'

export function Avatar({ participant, size = 'medium' }: { participant: Participant; size?: 'small' | 'medium' | 'large' }) {
  if (participant.avatarUrl) {
    return <img className={`avatar avatar-${size}`} src={participant.avatarUrl} alt={`${participant.name} 的頭像`} referrerPolicy="no-referrer" />
  }
  return (
    <span
      className={`avatar avatar-${size}`}
      style={{ color: participant.color, backgroundColor: `${participant.color}1f` }}
      aria-hidden="true"
    >
      {participant.name.trim().slice(0, 1).toUpperCase()}
    </span>
  )
}
