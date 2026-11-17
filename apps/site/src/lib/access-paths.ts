/** Same-origin contract shared by the email gate and its server. */
export const accessPaths = {
  welcome: '/api/access/welcome',
  unlock: '/api/access/unlock',
  session: '/api/access/session',
  doc: (id: string) => `/api/access/docs/${encodeURIComponent(id)}`,
  privatePrefix: '/__private/',
} as const
