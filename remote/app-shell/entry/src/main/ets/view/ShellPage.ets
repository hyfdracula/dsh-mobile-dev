import uiMaterial from '@ohos.arkui.uiMaterial';
import { HdsBarWidthRangeOptions, HdsTabs, HdsTabsController, HdsTabsFloatingStyle, SystemMaterialParams, hdsMaterial } from '@kit.UIDesignKit';
import { Api } from '../common/Api';
import { AppCtx } from '../common/AppCtx';
import { Machines } from '../common/Machines';
import { Mat } from '../common/Mat';
import { Motion } from '../common/Motion';
import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { Notifier } from '../common/Notifier';
import { Marks } from '../common/Marks';
import { Unread } from '../common/Unread';
import { SessionList } from './SessionList';
import { SettingsPage } from './SettingsPage';

/** 连续单会话盯梢失败达到此次数后才放弃，避免偶发网络抖动误丢弃盯梢任务。 */
const MAX_WATCH_FAILS: number = 5;

/**
 * 两栏外壳：会话 / 设置。
 * 承载全局巡检、系统通知推送与未读红点/角标严格同步。
 */
@Component
export struct ShellPage {
  api: Api = new Api('', '');
  @Prop wanBase: string = '';
  @Prop token0: string = '';
  themeMode: string = 'auto';
  systemDark: boolean = true;
  @Prop netMode: string = 'auto';
  haptics: boolean = true;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  defaultLan: string = '';
  onReset: () => void = () => {};
  onSave: (b: string, t: string) => void = () => {};
  onSaveLan: (b: string, t: string, lan: string[], hostId?: string, e2eePub?: string, hostName?: string) => void = () => {};
  /** 当前电脑名（多电脑切换时显示在设置 -> 连接里） */
  @Prop machineName: string = '';
  onPickMachine: (id: string) => void = () => {};
  onRemoveMachine: (id: string) => void = () => {};
  onAddMachine: (wan: string, token: string, name: string) => void = () => {};
  onTheme: (m: string) => void = () => {};
  onNetMode: (m: string) => void = () => {};
  onHaptics: (v: boolean) => void = () => {};
  onHds: (v: boolean) => void = () => {};
  @State private idx: number = 0;
  @State private pressIdx: number = -1;
  // 列表页开了重命名弹窗时把底栏收掉，弹窗和蒙层才能盖全屏
  @StorageLink('sheetOpen') sheetOpen: boolean = false;
  /** 设置页二级页开着时底部浮岛隐藏：只存在于首页与设置页一级。 */
  @StorageLink('settingsSub') settingsSub: string = '';
  private tc: HdsTabsController = new HdsTabsController();
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  /** 通知巡检：回合 ID 记录、已提醒回合去重、运行态集合、6 秒冷却时间、待回答记录 */
  private lastTurnId: Map<string, string> = new Map<string, string>();
  private notifiedTurn: Map<string, string> = new Map<string, string>();
  private wasRunning: Set<string> = new Set<string>();
  private lastNote: Map<string, number> = new Map<string, number>();
  /** 记录已提醒过的待回答状态，避免同一提问反复弹通知 */
  private lastAsked: Map<string, boolean> = new Map<string, boolean>();
  /** 正在盯的会话（id -> 标题）：每 3 秒单独问一次 running，几秒的任务也不会漏 */
  private watching: Map<string, string> = new Map<string, string>();
  /** 每个盯梢会话的连续网络失败计数 */
  private watchFails: Map<string, number> = new Map<string, number>();
  private watchTimer: number = 0;
  private watchBusy: boolean = false;
  private watchCheckBusy: boolean = false;
  // 回前台立刻补扫一次：更新列表、未读与角标
  @StorageLink('fgProbe') @Watch('onForegroundProbe') fgProbe: number = 0;
  @StorageLink('machineEpoch') @Watch('onMachineEpoch') machineEpoch: number = 0;
  @StorageLink('pendingOpenSession') pendingOpenSession: string = '';

  private onMachineEpoch(): void {
    this.lastTurnId.clear();
    this.notifiedTurn.clear();
    this.wasRunning.clear();
    this.lastNote.clear();
    this.lastAsked.clear();
    this.watching.clear();
    this.watchFails.clear();
    this.watchBusy = false;
    this.watchCheckBusy = false;
    if (this.token0 !== '' && this.wanBase !== '') {
      void this.scanSessions(true, false);
    }
  }

  private onForegroundProbe(): void {
    const fromBg: boolean = AppStorage.get<boolean>('fgResumeFromBg') === true;
    if (fromBg) {
      AppStorage.setOrCreate('fgResumeFromBg', false);
    }
    void this.scanSessions(false, fromBg);
    void this.checkWatching(fromBg);
  }

  private tickN: number = 0;

  aboutToAppear(): void {
    // 换主题会重建本组件：把用户原来所在的 tab 找回来，别把他送回会话列表。
    const saved: number | undefined = AppStorage.get<number>('shellTab');
    if (saved !== undefined && saved > 0) {
      this.idx = saved;
      setTimeout(() => {
        try {
          this.tc.changeIndex(saved);
        } catch (e) {
          console.info('DSH_TAB restore skipped: ' + JSON.stringify(e));
        }
      }, 0);
    }
    try {
      const sup: boolean = uiMaterial.isImmersiveMaterialSupported();
      const lv: string = String(uiMaterial.getGlobalMaterialLevel());
      const st: string = String(uiMaterial.getMaterialInfo().state);
      console.info('DSH_MAT supported=' + sup + ' level=' + lv + ' state=' + st);
    } catch (e) {
      console.info('DSH_MAT probe failed: ' + JSON.stringify(e));
    }
    try {
      void Notifier.ensure(AppCtx.ability());
    } catch (e) {
      void Notifier.ensure();
    }
    // 触发未读状态初始化与桌面角标对齐
    Unread.count();
    if (this.token0 !== '' && this.wanBase !== '') {
      void this.scanSessions(true, false);
    }
    this.watchTimer = setInterval(() => {
      if (this.token0 === '' || this.wanBase === '') {
        return;
      }
      const isBg: boolean = AppStorage.get<boolean>('appFg') === false;
      if (isBg) {
        return;
      }
      this.tickN++;
      // 前台：局域网每 12 秒扫全表/3 秒盯梢；公网隧道适度降频为 18 秒扫全表/6 秒盯梢，减少弱网拥塞
      const wan: boolean = this.api.onWan();
      const scanMod: number = wan ? 6 : 4;
      if (this.tickN % scanMod === 0) {
        void this.scanSessions(false, false);
      }
      if (!wan || this.tickN % 2 === 0) {
        void this.checkWatching(false);
      }
    }, 3000);
  }

  /** 判断用户当前是否正在前台直视或正准备打开指定会话。后台/锁屏时一律为 false。 */
  private isActivelyViewing(sessionId: string): boolean {
    const fg: boolean = AppStorage.get<boolean>('appFg') !== false;
    if (!fg) {
      return false;
    }
    if (this.pendingOpenSession !== '' && this.pendingOpenSession === sessionId) {
      return true;
    }
    return this.openId() === sessionId;
  }

  /**
   * 扫一遍会话表并写入共享内存缓存供 SessionList 直接复用，
   * 仅基于真实运行结束或网关 lastTurnId 变更触发提醒，彻底消除重命名/元数据刷新误报；
   * 切回前台补扫只更新未读红点与状态，不再于眼前延迟弹横幅。
   */
  private async scanSessions(baseline: boolean, fromBg: boolean = false): Promise<void> {
    if (this.watchBusy || this.token0 === '' || this.wanBase === '') {
      return;
    }
    const epochAtStart: number = this.machineEpoch;
    const scopeId: string = Machines.activeId();
    this.watchBusy = true;
    try {
      const rows = await this.api.sessions();
      if (this.machineEpoch !== epochAtStart) {
        return;
      }
      this.api.cacheSessions(rows);
      const visibleIds: Set<string> = new Set<string>();
      let changedN: number = 0;

      for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        if (row.archived !== true) {
          visibleIds.add(row.id);
        }
        const title: string = row.title !== '' ? row.title : '未命名会话';
        const turnId: string = row.lastTurnId !== undefined ? row.lastTurnId : '';
        const prevTurnId: string | undefined = this.lastTurnId.get(row.id);
        const wasRunningBefore: boolean = this.wasRunning.has(row.id);

        if (row.running === true) {
          Marks.clear(row.id);
          this.watching.set(row.id, title);
          this.watchFails.delete(row.id);
          this.wasRunning.add(row.id);
        }

        // 检测「等你回答」新挂起提问
        const askingNow: boolean = row.asking === true;
        const wasAsking: boolean = this.lastAsked.get(row.id) === true;
        this.lastAsked.set(row.id, askingNow);
        if (askingNow && !wasAsking) {
          if (this.isActivelyViewing(row.id)) {
            Unread.markRead(row.id, scopeId);
          } else {
            Unread.markUnread(row.id, scopeId);
            if (!baseline && !fromBg) {
              this.notifyAsking(row.id, title);
            }
          }
        }

        const stoppedFromRunning: boolean = wasRunningBefore && row.running !== true;
        const turnChangedOnServer: boolean = prevTurnId !== undefined &&
          turnId !== '' &&
          turnId !== prevTurnId &&
          row.running !== true;
        const finishedKey: string = turnId !== '' ? turnId : String(row.updatedAt);

        if (row.running !== true) {
          this.wasRunning.delete(row.id);
        }
        if (turnId !== '') {
          this.lastTurnId.set(row.id, turnId);
        } else if (prevTurnId === undefined) {
          this.lastTurnId.set(row.id, '');
        }

        if (!baseline && (stoppedFromRunning || turnChangedOnServer)) {
          changedN++;
          this.watching.delete(row.id);
          this.watchFails.delete(row.id);
          if (this.notifiedTurn.get(row.id) !== finishedKey) {
            this.notifiedTurn.set(row.id, finishedKey);
            if (this.isActivelyViewing(row.id)) {
              Unread.markRead(row.id, scopeId);
            } else {
              if (row.lastTurnStatus !== undefined && row.lastTurnStatus !== '') {
                Marks.set(row.id, row.lastTurnStatus === 'completed' ? 'done' : 'interrupted');
              } else {
                void this.markOutcome(row.id);
              }
              Unread.markUnread(row.id, scopeId);
              if (!fromBg) {
                this.notifyDone(row.id, title);
              }
            }
          }
        }
      }

      // 彻底清理当前主机下已归档或已删除会话的幽灵未读红点与通知
      Unread.pruneToVisible(visibleIds, scopeId);
      console.info('DSH_NOTIFY scan rows=' + rows.length + ' changed=' + changedN +
        ' watching=' + this.watching.size + ' unread=' + String(Unread.count()));
    } catch (e) {
      // 后台巡检失败不打扰用户
    } finally {
      this.watchBusy = false;
    }
  }

  /** 被盯住的会话：问到 running 变 false 即推送通知、标未读并放开；单次网络抖动不丢弃。 */
  private async checkWatching(fromBg: boolean = false): Promise<void> {
    if (this.watchCheckBusy || this.watching.size === 0 || this.token0 === '' || this.wanBase === '') {
      return;
    }
    const epochAtStart: number = this.machineEpoch;
    const scopeId: string = Machines.activeId();
    this.watchCheckBusy = true;
    try {
      const ids: string[] = [];
      this.watching.forEach((v: string, k: string) => {
        ids.push(k);
      });
      for (let i = 0; i < ids.length; i++) {
        if (this.machineEpoch !== epochAtStart) {
          return;
        }
        const id: string = ids[i];
        const titleRaw: string | undefined = this.watching.get(id);
        const title: string = titleRaw !== undefined && titleRaw !== '' ? titleRaw : '会话';
        try {
          const r = await this.api.messages(id, 1, true);
          if (this.machineEpoch !== epochAtStart) {
            return;
          }
          this.watchFails.delete(id);
          console.info('DSH_NOTIFY watch id=' + id + ' running=' + String(r.running));

          const hasAsk: boolean = r.questions !== undefined &&
            r.questions.active !== undefined &&
            r.questions.active.length > 0;
          if (hasAsk && this.lastAsked.get(id) !== true) {
            this.lastAsked.set(id, true);
            if (!this.isActivelyViewing(id)) {
              Unread.markUnread(id, scopeId);
              if (!fromBg) {
                this.notifyAsking(id, title);
              }
            }
          }

          if (r.running === false) {
            this.watching.delete(id);
            this.wasRunning.delete(id);
            const tailSeq: number = r.messages.length > 0 ? r.messages[r.messages.length - 1].seq : r.total;
            const kind: string = r.lastTurn !== undefined && r.lastTurn !== '' ? r.lastTurn : 'completed';
            const turnKey: string = kind + ':' + String(tailSeq);
            if (this.notifiedTurn.get(id) !== turnKey) {
              this.notifiedTurn.set(id, turnKey);
              if (this.isActivelyViewing(id)) {
                Unread.markRead(id, scopeId);
              } else {
                void this.markOutcome(id);
                Unread.markUnread(id, scopeId);
                if (!fromBg) {
                  this.notifyDone(id, title);
                }
              }
            }
          }
        } catch (e) {
          if (this.machineEpoch !== epochAtStart) {
            return;
          }
          const fails: number = (this.watchFails.get(id) ?? 0) + 1;
          this.watchFails.set(id, fails);
          console.info('DSH_NOTIFY watch fail id=' + id + ' count=' + String(fails));
          if (fails >= MAX_WATCH_FAILS) {
            this.watching.delete(id);
            this.watchFails.delete(id);
          }
        }
      }
    } finally {
      this.watchCheckBusy = false;
    }
  }

  /** 判断这一轮是「完成」还是「中断」，记到 Marks 里给列表卡片上色。 */
  private async markOutcome(id: string): Promise<void> {
    try {
      const r = await this.api.messages(id, 1, true);
      const kind: string = r.lastTurn === undefined ? '' : r.lastTurn;
      if (kind === '') {
        return;
      }
      const s: string = kind === 'completed' ? 'done' : 'interrupted';
      Marks.set(id, s);
      console.info('DSH_MARK session=' + id + ' turn=' + kind + ' -> ' + s);
    } catch (e) {
      console.info('DSH_MARK failed session=' + id);
    }
  }

  private openId(): string {
    const o = AppStorage.get<string>('openSession');
    return o !== undefined ? o : '';
  }

  private shouldDeliverNotification(dedupeKey: string, sessionId: string): boolean {
    const on: boolean | undefined = AppStorage.get<boolean>('notifyDone');
    if (on === false) {
      return false;
    }
    if (this.isActivelyViewing(sessionId)) {
      return false;
    }
    const bgOnly: boolean | undefined = AppStorage.get<boolean>('notifyBgOnly');
    const fg: boolean | undefined = AppStorage.get<boolean>('appFg');
    if ((bgOnly === undefined || bgOnly) && fg === true) {
      return false;
    }
    const now: number = Date.now();
    const n = this.lastNote.get(dedupeKey);
    const noted: number = n !== undefined ? n : 0;
    if (now - noted <= 6000) {
      return false;
    }
    this.lastNote.set(dedupeKey, now);
    return true;
  }

  /** 同一会话 6 秒内只发一条：扫描与盯梢两条路可能同时命中同一次完成。 */
  private notifyDone(id: string, title: string): void {
    if (!this.shouldDeliverNotification(id, id)) {
      return;
    }
    console.info('DSH_NOTIFY turn finished session=' + id);
    const showTitle: boolean = AppStorage.get<boolean>('notifyShowTitle') !== false;
    const body: string = showTitle ? ('「' + title + '」已经回复，点开看看') : '有一条智能体回复已完成，点开查看';
    void Notifier.done('任务完成', body, id);
  }

  /** 待回答提问通知。 */
  private notifyAsking(id: string, title: string): void {
    if (!this.shouldDeliverNotification('ask:' + id, id)) {
      return;
    }
    console.info('DSH_NOTIFY waiting answer session=' + id);
    const showTitle: boolean = AppStorage.get<boolean>('notifyShowTitle') !== false;
    const body: string = showTitle ? ('「' + title + '」有一个问题需要你确认') : '智能体有一个问题需要你确认，点开查看';
    void Notifier.done('等你回答', body, id);
  }

  aboutToDisappear(): void {
    if (this.watchTimer !== 0) {
      clearInterval(this.watchTimer);
      this.watchTimer = 0;
    }
  }

  private tint(i: number): string {
    return this.idx === i ? Tokens.accent : Tokens.dim2;
  }

  /** 会话图标：对话气泡 */
  @Builder
  iconChat() {
    Image($r('app.media.ic_chat'))
      .width(23)
      .height(23)
      .fillColor(this.tint(0))
      .objectFit(ImageFit.Contain)
  }

  /** 设置图标：齿轮 */
  @Builder
  iconSettings() {
    Image($r('app.media.ic_gear'))
      .width(23)
      .height(23)
      .fillColor(this.tint(1))
      .objectFit(ImageFit.Contain)
  }

  /** 底部浮岛样式：中小大屏自适应宽度，受全局沉浸光感开关控制。 */
  private floatStyle(): HdsTabsFloatingStyle {
    const w: HdsBarWidthRangeOptions = { smallWidth: 264, mediumWidth: 300, largeWidth: 340 };
    const style: HdsTabsFloatingStyle = { barWidth: w, barBottomMargin: 18 };
    if (this.hdsOn && Mat.isImmersiveReady()) {
      const mat: SystemMaterialParams = {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      };
      style.systemMaterialEffect = mat;
    }
    return style;
  }

  @Builder
  tabPill(i: number, label: string) {
    Stack() {
      Column() {
        if (i === 0) {
          this.iconChat()
        } else {
          this.iconSettings()
        }
        Text(label)
          .fontSize(11)
          .fontWeight(this.idx === i ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.tint(i))
          .margin({ top: 4 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .scale({
        x: this.pressIdx === i ? 0.82 : 1,
        y: this.pressIdx === i ? 0.82 : 1
      })
      .animation(Motion.flagshipSnappy())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 6, right: 6, top: 6, bottom: 6 })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.pressIdx = i;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.pressIdx = -1;
      }
    })
    .onClick(() => {
      Haptics.tap();
      this.idx = i;
      this.tc.changeIndex(i);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      HdsTabs({ controller: this.tc }) {
        TabContent() {
          SessionList({ api: this.api, machineName: this.machineName, onPickMachine: this.onPickMachine })
        }
        .tabBar(this.tabPill(0, '会话'))

        TabContent() {
          SettingsPage({
            api: this.api,
            wanBase: this.wanBase,
            token0: this.token0,
            themeMode: this.themeMode,
            systemDark: this.systemDark,
            netMode: this.netMode,
            haptics: this.haptics,
            hdsOn: this.hdsOn,
            defaultLan: this.defaultLan,
            onReset: () => {
              this.onReset();
            },
            onSave: (b: string, t: string) => {
              this.onSave(b, t);
            },
            machineName: this.machineName,
            onPickMachine: (id: string) => {
              this.onPickMachine(id);
            },
            onRemoveMachine: (id: string) => {
              this.onRemoveMachine(id);
            },
            onAddMachine: (wan: string, token: string, name: string) => {
              this.onAddMachine(wan, token, name);
            },
            onSaveLan: (b: string, t: string, lan: string[], hostId?: string, e2eePub?: string, hostName?: string) => {
              this.onSaveLan(b, t, lan, hostId, e2eePub, hostName);
            },
            onTheme: (m: string) => {
              this.onTheme(m);
            },
            onNetMode: (m: string) => {
              this.onNetMode(m);
            },
            onHaptics: (v: boolean) => {
              this.onHaptics(v);
            },
            onHds: (v: boolean) => {
              this.onHds(v);
            }
          })
        }
        .tabBar(this.tabPill(1, '设置'))
      }
      .barHeight(this.sheetOpen || this.settingsSub !== '' ? 0 : 64)
      .barFloatingStyle(this.floatStyle())
      .barMode(BarMode.Fixed)
      .barPosition(BarPosition.End)
      .vertical(false)
      .barOverlap(true)
      .barBackgroundColor(this.hdsOn ? (Mat.isImmersiveReady() ? Color.Transparent : Tokens.glassBar) : Tokens.surface)
      .barBackgroundBlurStyle(this.hdsOn ? (Mat.isImmersiveReady() ? BlurStyle.NONE : BlurStyle.COMPONENT_THICK) : BlurStyle.NONE)
      .scrollable(false)
      .animationDuration(0)
      .onChange((i: number) => {
        this.idx = i;
        AppStorage.setOrCreate('shellTab', i);
        if (i === 0) {
          AppStorage.setOrCreate('listDirty', Date.now());
        }
        if (i !== 1) {
          AppStorage.setOrCreate('settingsBack', Date.now());
          AppStorage.setOrCreate('settingsSub', '');
        }
      })
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
  }
}
