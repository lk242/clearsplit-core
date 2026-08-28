import type { ReactNode } from 'react'

export type IconName =
  | 'alert-circle' | 'arrow-down' | 'arrow-right' | 'arrow-up' | 'car' | 'check'
  | 'chevron-down' | 'chevron-right' | 'dots' | 'home' | 'moon' | 'pencil' | 'plus'
  | 'receipt' | 'shopping-bag' | 'sparkles' | 'sun' | 'trash'
  | 'cloud' | 'refresh' | 'share' | 'user-plus' | 'users' | 'utensils' | 'wallet' | 'x'

const paths: Record<IconName, ReactNode> = {
  home: <><path d="m3 10.5 9-7.5 9 7.5"/><path d="M5 9.5V21h14V9.5M9 21v-7h6v7"/></>,
  receipt: <><path d="M6 3h12v19l-3-2-3 2-3-2-3 2Z"/><path d="M9 8h6M9 12h6M9 16h4"/></>,
  users: <><path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></>,
  wallet: <><path d="M20 7V5a2 2 0 0 0-2-2H5a3 3 0 0 0 0 6h15v12H5a3 3 0 0 1-3-3V6"/><path d="M16 13h4"/></>,
  sun: <><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.66 6.34l1.41-1.41"/></>,
  plus: <path d="M12 5v14M5 12h14"/>,
  'arrow-up': <><path d="m18 15-6-6-6 6"/><path d="M12 9v12"/></>,
  'arrow-down': <><path d="m6 9 6 6 6-6"/><path d="M12 3v12"/></>,
  'arrow-right': <><path d="M5 12h14M13 6l6 6-6 6"/></>,
  'chevron-right': <path d="m9 18 6-6-6-6"/>,
  'chevron-down': <path d="m6 9 6 6 6-6"/>,
  sparkles: <><path d="m12 3-1 3.1a4 4 0 0 1-2.6 2.6L5 10l3.4 1.3a4 4 0 0 1 2.6 2.6l1 3.1 1-3.1a4 4 0 0 1 2.6-2.6L19 10l-3.4-1.3A4 4 0 0 1 13 6.1Z"/><path d="m5 3-.4 1.2A2 2 0 0 1 3.3 5L2 5.5 3.3 6a2 2 0 0 1 1.3.8L5 8l.4-1.2A2 2 0 0 1 6.7 6L8 5.5 6.7 5a2 2 0 0 1-1.3-.8Z"/></>,
  moon: <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/>,
  pencil: <><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L8 18l-4 1 1-4Z"/></>,
  trash: <><path d="M3 6h18M8 6V4h8v2M19 6l-1 15H6L5 6M10 11v6M14 11v6"/></>,
  x: <><path d="m18 6-12 12M6 6l12 12"/></>,
  check: <path d="m5 12 4 4L19 6"/>,
  'user-plus': <><path d="M15 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="8" cy="7" r="4"/><path d="M19 8v6M16 11h6"/></>,
  utensils: <><path d="M3 2v7a3 3 0 0 0 6 0V2M6 2v20M15 2v8h5M18 2v20"/></>,
  car: <><path d="m5 17-2-2V9l2-5h14l2 5v6l-2 2Z"/><path d="M5 17v3M19 17v3M3 10h18M7 14h.01M17 14h.01"/></>,
  'shopping-bag': <><path d="M6 2 3 6v16h18V6l-3-4Z"/><path d="M3 6h18M8 10a4 4 0 0 0 8 0"/></>,
  dots: <><circle cx="5" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1" fill="currentColor" stroke="none"/></>,
  'alert-circle': <><circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 17h.01"/></>,
  cloud: <path d="M17.5 19H6a4 4 0 0 1-.4-8 6.5 6.5 0 0 1 12.5-1.5A4.8 4.8 0 0 1 17.5 19Z"/>,
  refresh: <><path d="M20 6v5h-5"/><path d="M4 18v-5h5"/><path d="M18.5 9A7 7 0 0 0 6 6.5L4 9M5.5 15A7 7 0 0 0 18 17.5l2-2.5"/></>,
  share: <><circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="m8.6 10.5 6.8-4M8.6 13.5l6.8 4"/></>,
}

export function Icon({ name, size = 24 }: { name: IconName; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {paths[name]}
    </svg>
  )
}
