/**
 * Agent Mobile 浏览器侧入口：注册设置面板「Agent Mobile」配对与权限控制页。
 * @module agent-mobile-gateway/client
 */
import { MobileSection } from './MobileSection.tsx'
import { FeedbackSection } from './FeedbackSection.tsx'
import { AskTakeoverOverlay } from './AskTakeoverOverlay.tsx'

export const inject = ['slots']

const FEEDBACK_STATE = '/api/dsh-mobile/panel/feedback/state'

export function apply(ctx: any): void {
  ctx.slots.inject('settings.section', () => ctx.slots.register({
    name: 'settings.section',
    id: 'dsh-mobile',
    order: 36,
    label: () => 'Agent Mobile',
  }, MobileSection as never))

  ctx.slots.inject('shell.overlay', () => ctx.slots.register({
    name: 'shell.overlay',
    id: 'dsh-mobile-ask-takeover',
  }, AskTakeoverOverlay as never))

  const registerFeedback = (): void => {
    ctx.slots.inject('settings.section', () => ctx.slots.register({
      name: 'settings.section',
      id: 'dsh-mobile-feedback',
      order: 37,
      label: () => '用户反馈',
    }, FeedbackSection as never))
  }

  void fetch(FEEDBACK_STATE, { credentials: 'same-origin', cache: 'no-store' })
    .then(async (res) => {
      if (!res.ok) return null
      return (await res.json()) as { configured?: boolean }
    })
    .then((state) => {
      if (state?.configured === true) registerFeedback()
    })
    .catch(() => undefined)
}
