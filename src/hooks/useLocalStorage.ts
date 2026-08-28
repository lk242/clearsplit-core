import { useEffect, useState } from 'react'

type Validator<T> = (value: unknown) => value is T

export function useLocalStorage<T>(key: string, initialValue: T | (() => T), validator?: Validator<T>) {
  const [value, setValue] = useState<T>(() => {
    const storedValue = window.localStorage.getItem(key)
    if (storedValue !== null) {
      try {
        const parsed: unknown = JSON.parse(storedValue)
        if (!validator) return parsed as T
        if (validator(parsed)) return parsed
        preserveRecoveryCopy(key, storedValue)
      } catch {
        preserveRecoveryCopy(key, storedValue)
      }
    }

    return initialValue instanceof Function ? initialValue() : initialValue
  })

  useEffect(() => {
    try {
      window.localStorage.setItem(key, JSON.stringify(value))
    } catch {
      // The app stays usable when private browsing blocks local storage.
    }
  }, [key, value])

  return [value, setValue] as const
}

function preserveRecoveryCopy(key: string, rawValue: string) {
  try {
    window.localStorage.setItem(`${key}-recovery`, rawValue)
  } catch {
    // A blocked storage API cannot retain a recovery copy.
  }
}
