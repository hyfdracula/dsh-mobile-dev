/**
 * 全局悬浮「电脑立即接管提问」提示条（挂载于 `shell.overlay`）。
 * 当 Agent Mobile 处于手机回答模式且有提问正挂起等待手机确认时，
 * 坐在电脑前的用户可一键立即交还桌面端原生提问卡片，无需切进设置翻找开关。
 * @module agent-mobile-gateway/client/AskTakeoverOverlay
 */
import { useCallback, useEffect, useState, type ReactNode } from 'react'

interface PendingAskItem {
  callId: string
  sessionId: string
  questionCount: number
  firstHeader: string
  firstPrompt: string
  createdAt: number
}

interface PendingPairRequestItem {
  id: string
  verifyCode: string
  deviceName: string
  source: 'lan' | 'remote'
  createdAt: number
  expiresAt: number
}

interface AsksPollResponse {
  pending?: PendingAskItem[]
  pairRequests?: PendingPairRequestItem[]
  answerMode?: 'phone' | 'desktop'
  phoneOnline?: boolean
}

const ROUTE = '/api/dsh-mobile/panel'

function batchKeyOf(items: readonly PendingAskItem[]): string {
  if (items.length === 0) return ''
  return items.map((x) => x.callId).sort().join(',')
}

export function AskTakeoverOverlay(): ReactNode {
  const [pending, setPending] = useState<PendingAskItem[]>([])
  const [pairRequests, setPairRequests] = useState<PendingPairRequestItem[]>([])
  const [dismissedKey, setDismissedKey] = useState('')
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async (): Promise<void> => {
    try {
      const res = await fetch(`${ROUTE}/asks`, { credentials: 'same-origin', cache: 'no-store' })
      if (!res.ok) return
      const data = (await res.json()) as AsksPollResponse
      const next = Array.isArray(data.pending) ? data.pending : []
      const nextPairs = Array.isArray(data.pairRequests) ? data.pairRequests : []
      setPending(next)
      setPairRequests(nextPairs)
      if (next.length === 0) {
        setDismissedKey('')
      }
    } catch {
      // 网关尚未就绪或重启中时静默忽略
    }
  }, [])

  useEffect(() => {
    void refresh()
    const timer = setInterval(() => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      void refresh()
    }, 1000)
    const onWake = (): void => {
      if (typeof document === 'undefined' || document.visibilityState === 'visible') {
        void refresh()
      }
    }
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', onWake)
    }
    if (typeof window !== 'undefined') {
      window.addEventListener('focus', onWake)
    }
    return () => {
      clearInterval(timer)
      if (typeof document !== 'undefined') {
        document.removeEventListener('visibilitychange', onWake)
      }
      if (typeof window !== 'undefined') {
        window.removeEventListener('focus', onWake)
      }
    }
  }, [refresh])

  const takeover = useCallback(async (switchToDesktop: boolean): Promise<void> => {
    if (busy) return
    setBusy(true)
    try {
      const res = await fetch(`${ROUTE}/asks/takeover`, {
        method: 'POST',
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { 'content-type': 'application/json; charset=utf-8' },
        body: JSON.stringify(switchToDesktop ? { switchToDesktop: true } : {}),
      })
      if (res.ok) {
        const data = (await res.json()) as { pending?: PendingAskItem[] }
        const next = Array.isArray(data.pending) ? data.pending : []
        setPending(next)
        if (next.length === 0) setDismissedKey('')
      } else {
        await refresh()
      }
    } catch {
      // ignore transient network failure
    } finally {
      setBusy(false)
    }
  }, [busy, refresh])

  const decidePair = useCallback(async (id: string, approve: boolean): Promise<void> => {
    if (busy) return
    setBusy(true)
    try {
      const res = await fetch(`${ROUTE}/pair-requests/decide`, {
        method: 'POST',
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { 'content-type': 'application/json; charset=utf-8' },
        body: JSON.stringify({ id, approve }),
      })
      if (res.ok) {
        const data = (await res.json()) as { pairRequests?: PendingPairRequestItem[] }
        setPairRequests(Array.isArray(data.pairRequests) ? data.pairRequests : [])
      } else {
        await refresh()
      }
    } catch {
      // ignore transient network failure
    } finally {
      setBusy(false)
    }
  }, [busy, refresh])

  const firstPair = pairRequests[0]
  if (firstPair !== undefined) {
    return (
      <div
        role="status"
        aria-live="polite"
        style={{
          position: 'fixed',
          left: '50%',
          bottom: 92,
          transform: 'translateX(-50%)',
          zIndex: 62,
          pointerEvents: 'auto',
          width: 'min(540px, calc(100vw - 32px))',
          boxSizing: 'border-box',
          borderRadius: 16,
          border: '1px solid rgba(47, 107, 255, 0.42)',
          background: 'var(--dsw-alias-surface-card, rgba(22, 25, 32, 0.95))',
          backdropFilter: 'blur(16px)',
          boxShadow: '0 12px 32px rgba(0, 0, 0, 0.28)',
          padding: '12px 14px',
          display: 'flex',
          flexDirection: 'column',
          gap: 10,
          color: 'var(--dsw-alias-label-primary, #F5F7FA)',
        }}
      >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0, flexWrap: 'wrap' }}>
            <span
              style={{
                fontSize: 11,
                fontWeight: 600,
                color: '#2F6BFF',
                background: 'rgba(47, 107, 255, 0.14)',
                borderRadius: 999,
                padding: '2px 8px',
                whiteSpace: 'nowrap',
              }}
            >
              远程配对申请
            </span>
            <span style={{ fontSize: 13, fontWeight: 600 }}>
              {firstPair.deviceName}
            </span>
            <span style={{ fontSize: 11.5, color: 'var(--dsw-alias-label-secondary, #9AA4B2)' }}>
              {firstPair.source === 'remote' ? '经公网' : '局域网'}
            </span>
          </div>
          <span
            style={{
              fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
              fontSize: 17,
              fontWeight: 700,
              letterSpacing: 3,
              color: '#2F6BFF',
              background: 'rgba(47, 107, 255, 0.14)',
              borderRadius: 8,
              padding: '2px 9px',
            }}
          >
            {firstPair.verifyCode}
          </span>
        </div>
        <div style={{ fontSize: 12, color: 'var(--dsw-alias-label-secondary, #A7B0BE)' }}>
          请确认新手机显示的 4 位核对码与右上角一致，再点击批准配对。
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 8 }}>
          <button
            type="button"
            disabled={busy}
            onClick={() => { void decidePair(firstPair.id, false) }}
            style={{
              border: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.28))',
              background: 'var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.12))',
              color: 'var(--dsw-alias-label-primary, #E5E9F0)',
              borderRadius: 10,
              padding: '6px 12px',
              fontSize: 12,
              fontWeight: 500,
              fontFamily: 'inherit',
              cursor: busy ? 'default' : 'pointer',
            }}
          >
            拒绝
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={() => { void decidePair(firstPair.id, true) }}
            style={{
              border: '1px solid #2F6BFF',
              background: '#2F6BFF',
              color: '#FFFFFF',
              borderRadius: 10,
              padding: '6px 14px',
              fontSize: 12,
              fontWeight: 600,
              fontFamily: 'inherit',
              cursor: busy ? 'default' : 'pointer',
            }}
          >
            {busy ? '处理中…' : '批准配对'}
          </button>
        </div>
      </div>
    )
  }

  const currentKey = batchKeyOf(pending)
  if (pending.length === 0 || (dismissedKey !== '' && dismissedKey === currentKey)) {
    return null
  }

  const first = pending[0]
  const totalQuestions = pending.reduce((acc, item) => acc + Math.max(1, item.questionCount), 0)
  const preview = (first?.firstPrompt || first?.firstHeader || '点击立即在电脑当前会话窗口展示问题卡片').trim()

  return (
    <div
      role="status"
      aria-live="polite"
      style={{
        position: 'fixed',
        left: '50%',
        bottom: 92,
        transform: 'translateX(-50%)',
        zIndex: 60,
        pointerEvents: 'auto',
        width: 'min(540px, calc(100vw - 32px))',
        boxSizing: 'border-box',
        borderRadius: 16,
        border: '1px solid rgba(47, 107, 255, 0.38)',
        background: 'var(--dsw-alias-surface-card, rgba(22, 25, 32, 0.94))',
        backdropFilter: 'blur(16px)',
        boxShadow: '0 12px 32px rgba(0, 0, 0, 0.24)',
        padding: '12px 14px',
        display: 'flex',
        flexDirection: 'column',
        gap: 9,
        color: 'var(--dsw-alias-label-primary, #F5F7FA)',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0, flexWrap: 'wrap' }}>
          <span
            style={{
              fontSize: 11,
              fontWeight: 600,
              color: '#2F6BFF',
              background: 'rgba(47, 107, 255, 0.14)',
              borderRadius: 999,
              padding: '2px 8px',
              whiteSpace: 'nowrap',
            }}
          >
            Agent Mobile
          </span>
          <span style={{ fontSize: 13, fontWeight: 600, color: 'var(--dsw-alias-label-primary, #F5F7FA)' }}>
            {pending.length > 1
              ? `有 ${String(pending.length)} 组提问等待手机回答`
              : '提问正在手机端等待回答'}
          </span>
          {totalQuestions > 1
            ? (
              <span
                style={{
                  fontSize: 11,
                  color: 'var(--dsw-alias-label-secondary, #9AA4B2)',
                  background: 'var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.14))',
                  borderRadius: 999,
                  padding: '1px 7px',
                  whiteSpace: 'nowrap',
                }}
              >
                共 {String(totalQuestions)} 题
              </span>
            )
            : null}
        </div>
        <button
          type="button"
          aria-label="暂时收起接管提示"
          onClick={() => { setDismissedKey(currentKey) }}
          style={{
            border: 'none',
            background: 'transparent',
            color: 'var(--dsw-alias-label-tertiary, #9AA4B2)',
            fontSize: 16,
            lineHeight: 1,
            padding: '2px 5px',
            cursor: 'pointer',
            flexShrink: 0,
          }}
        >
          ×
        </button>
      </div>

      <div
        style={{
          fontSize: 12,
          color: 'var(--dsw-alias-label-secondary, #A7B0BE)',
          lineHeight: 1.45,
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          whiteSpace: 'nowrap',
        }}
        title={preview}
      >
        {preview}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 8, flexWrap: 'wrap' }}>
        <button
          type="button"
          disabled={busy}
          onClick={() => { void takeover(true) }}
          style={{
            border: '1px solid var(--dsw-alias-border-l2, rgba(127,127,127,0.28))',
            background: 'var(--dsw-alias-bg-layer-2, rgba(127,127,127,0.12))',
            color: 'var(--dsw-alias-label-primary, #E5E9F0)',
            borderRadius: 10,
            padding: '6px 11px',
            fontSize: 12,
            fontWeight: 500,
            fontFamily: 'inherit',
            cursor: busy ? 'default' : 'pointer',
            opacity: busy ? 0.55 : 1,
          }}
        >
          切为电脑优先
        </button>
        <button
          type="button"
          disabled={busy}
          onClick={() => { void takeover(false) }}
          style={{
            border: '1px solid #2F6BFF',
            background: 'var(--dsw-alias-state-business-primary, #2F6BFF)',
            color: '#FFFFFF',
            borderRadius: 10,
            padding: '6px 13px',
            fontSize: 12,
            fontWeight: 600,
            fontFamily: 'inherit',
            cursor: busy ? 'default' : 'pointer',
            opacity: busy ? 0.55 : 1,
          }}
        >
          {busy ? '正在交还…' : '在电脑上接管'}
        </button>
      </div>
    </div>
  )
}
