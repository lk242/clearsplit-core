import { useEffect, type ReactNode } from 'react'
import { Icon } from './Icon'

type ModalProps = {
  open: boolean
  title: string
  description?: string
  children: ReactNode
  onClose: () => void
  compact?: boolean
}

export function Modal({ open, title, description, children, onClose, compact = false }: ModalProps) {
  useEffect(() => {
    if (!open) return

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    window.addEventListener('keydown', onKeyDown)

    return () => {
      document.body.style.overflow = previousOverflow
      window.removeEventListener('keydown', onKeyDown)
    }
  }, [onClose, open])

  if (!open) return null

  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className={compact ? 'modal-card modal-compact' : 'modal-card'} role="dialog" aria-modal="true" aria-labelledby="modal-title">
        <div className="modal-handle" aria-hidden="true" />
        <header className="modal-header">
          <div>
            <h2 id="modal-title">{title}</h2>
            {description && <p>{description}</p>}
          </div>
          <button className="icon-button quiet" type="button" aria-label="關閉" onClick={onClose}>
            <Icon name="x" size={20} />
          </button>
        </header>
        {children}
      </section>
    </div>
  )
}
