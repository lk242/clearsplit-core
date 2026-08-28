export function formatCurrency(amount: number) {
  return `NT$ ${Math.round(amount).toLocaleString('zh-TW')}`
}

export function formatDate(date: string) {
  return new Intl.DateTimeFormat('zh-TW', { month: 'short', day: 'numeric' }).format(new Date(`${date}T12:00:00`))
}
