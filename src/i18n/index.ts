import { fr } from './fr';

export type MessageKey = keyof typeof fr;

const catalogs: Record<string, Record<MessageKey, string>> = { fr };
let current = catalogs.fr;

export function setLocale(locale: string): void {
  current = catalogs[locale] ?? catalogs.fr;
}

export function t(key: MessageKey, params?: Record<string, string | number>): string {
  let s: string = current[key] ?? key;
  if (params) for (const [k, v] of Object.entries(params)) s = s.replace(`{${k}}`, String(v));
  return s;
}
