import { HdsNavDestination, HdsNavigationTitleBarOptions } from '@kit.UIDesignKit';
import { Api, PermRow, PresetRow } from '../common/Api';
import { PageHeader, TopFade, buildTransparentHdsTitle } from '../common/Chrome';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Motion } from '../common/Motion';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { EmptyState } from '../common/Widgets';

/**
 * 会话级 Agent 预设与权限策略页：
 * 支持安全区适配、加载态与空态区分，以及配置损坏预设（broken）的醒目告警与原因复制。
 */
@Component
export struct PresetsPage {
  @Consume('stack') stack: NavPathStack;
  api: Api = new Api('', '');
  param: ChatParam = { id: '', title: '' };

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private presets: PresetRow[] = [];
  @State private currentPreset: string = '';
  @State private permPresets: PermRow[] = [];
  @State private currentPerm: string = '';
  @State private loading: boolean = true;
  @State private saving: boolean = false;
  @State private err: string = '';
  @State private note: string = '';

  aboutToAppear(): void {
    void this.load();
  }

  private isBroken(p: PresetRow): boolean {
    return p.broken !== undefined && p.broken !== '' && p.broken !== 'false';
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.err = '';
    try {
      const p = await this.api.presets();
      this.presets = p.presets;
      this.currentPreset = p.current;
      const q = await this.api.permissions(this.param.id);
      this.permPresets = q.presets;
      this.currentPerm = q.current;
      if (p.unavailable && q.unavailable) {
        this.note = '当前宿主未暴露预设与权限服务';
      } else if (p.unavailable) {
        this.note = 'Agent 预设目录不可用，权限仍可切换';
      } else if (q.unavailable) {
        this.note = '权限预设目录不可用，Agent 预设仍可切换';
      } else {
        this.note = '';
      }
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private async choosePreset(p: PresetRow): Promise<void> {
    if (this.saving || this.loading) {
      return;
    }
    Haptics.tap();
    this.saving = true;
    this.err = '';
    try {
      const scope: string = await this.api.selectPreset(this.param.id, p.id);
      this.currentPreset = p.id;
      this.note = scope === 'global'
        ? ('当前会话已开始对话，已将「' + p.name + '」设为后续新会话默认预设')
        : ('已切换至预设「' + p.name + '」');
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.saving = false;
    }
  }

  private async choosePerm(p: PermRow): Promise<void> {
    if (this.saving || this.loading) {
      return;
    }
    Haptics.tap();
    this.saving = true;
    this.err = '';
    try {
      const now: string = await this.api.setPermission(this.param.id, p.value);
      this.currentPerm = now;
      this.note = '权限策略已切换为「' + p.name + '」';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.saving = false;
    }
  }

  @Builder
  radioDot(active: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (active) {
        Circle()
          .width(20)
          .height(20)
          .fill(Tokens.ok)
        Text('√')
          .fontSize(Tokens.fsFoot)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.accentInk)
      } else {
        Circle()
          .width(20)
          .height(20)
          .fill(Color.Transparent)
          .stroke(Tokens.line)
          .strokeWidth(1.5)
      }
    }
    .width(20)
    .height(20)
    .margin({ right: 12 })
  }

  @Builder
  presetCard(p: PresetRow) {
    Column() {
      Row() {
        this.radioDot(p.id === this.currentPreset)

        Column() {
          Row() {
            Text(p.name)
              .fontSize(Tokens.fsBodyLg)
              .fontWeight(p.id === this.currentPreset ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(p.id === this.currentPreset ? Tokens.accent : Tokens.fg)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (p.isDefault) {
              Text('默认')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim)
                .backgroundColor(Tokens.surface2)
                .borderRadius(Tokens.rPill)
                .padding({ left: 7, right: 7, top: 2, bottom: 2 })
                .margin({ left: 6 })
            }

            if (this.isBroken(p)) {
              Text('配置异常')
                .fontSize(Tokens.fsCaption)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.err)
                .backgroundColor(Tokens.intrBg)
                .border({ width: 1, color: Tokens.err })
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .margin({ left: 6 })
            }

            if (p.id === this.currentPreset) {
              Text('当前')
                .fontSize(Tokens.fsCaption)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.accentInk)
                .backgroundColor(Tokens.accentStrong)
                .borderRadius(Tokens.rPill)
                .padding({ left: 9, right: 9, top: 2, bottom: 2 })
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (p.description !== '') {
            Text(p.description)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .lineHeight(17)
              .margin({ top: 4 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.isBroken(p)) {
        Row() {
          Text('异常原因：' + p.broken)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .lineHeight(17)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('复制')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.err)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(Tokens.rPill)
            .border({ width: 1, color: Tokens.err })
            .margin({ left: 8 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              void copyText(p.broken, '已复制异常原因');
            })
        }
        .width('100%')
        .padding(10)
        .margin({ top: 10 })
        .backgroundColor(Tokens.intrBg)
        .borderRadius(Tokens.rSm)
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(Tokens.rMd)
    .backgroundColor(p.id === this.currentPreset ? Tokens.accentSoft : Tokens.surface)
    .border({
      width: p.id === this.currentPreset ? 1.5 : 1,
      color: this.isBroken(p) ? Tokens.err : (p.id === this.currentPreset ? Tokens.accent : Tokens.lineSoft)
    })
    .margin({ bottom: 8 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      void this.choosePreset(p);
    })
  }

  @Builder
  permCard(p: PermRow) {
    Row() {
      this.radioDot(p.value === this.currentPerm)

      Column() {
        Text(p.name)
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(p.value === this.currentPerm ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(p.value === this.currentPerm ? Tokens.accent : Tokens.fg)
        if (p.description !== '') {
          Text(p.description)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(17)
            .margin({ top: 3 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (p.value === this.currentPerm) {
        Text('当前')
          .fontSize(Tokens.fsCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .backgroundColor(Tokens.accentStrong)
          .borderRadius(Tokens.rPill)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(Tokens.rMd)
    .backgroundColor(p.value === this.currentPerm ? Tokens.accentSoft : Tokens.surface)
    .border({
      width: p.value === this.currentPerm ? 1.5 : 1,
      color: p.value === this.currentPerm ? Tokens.accent : Tokens.lineSoft
    })
    .margin({ bottom: 8 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      void this.choosePerm(p);
    })
  }

  @Builder
  private headerBar() {
    Column() {
      PageHeader({
        title: '预设与权限',
        subtitle: this.param.title !== '' ? this.param.title : '当前会话',
        padTop: true,
        immersive: true,
        subPageDepth: 2,
        rightKind: 'label',
        rightLabel: '刷新',
        onBack: () => {
          this.stack.pop();
        },
        onRight: () => {
          void this.load();
        }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  private hdsTitle(): HdsNavigationTitleBarOptions {
    const stack: CustomBuilder = (): void => { this.headerBar(); };
    return buildTransparentHdsTitle(stack);
  }

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column() {
            Column() {
              if (this.err !== '') {
                Row() {
                  Text(this.err)
                    .fontSize(Tokens.fsFoot)
                    .fontColor(Tokens.err)
                    .lineHeight(18)
                    .maxLines(4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('复制')
                    .fontSize(Tokens.fsCaption)
                    .fontColor(Tokens.err)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .borderRadius(Tokens.rPill)
                    .border({ width: 1, color: Tokens.err })
                    .margin({ left: 8 })
                    .onClick(() => {
                      void copyText(this.err, '已复制错误信息');
                    })
                }
                .width('100%')
                .padding(12)
                .margin({ bottom: 12 })
                .backgroundColor(Tokens.intrBg)
                .border({ width: 1, color: Tokens.err })
                .borderRadius(Tokens.rMd)
                .alignItems(VerticalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
              }

              if (this.note !== '') {
                Row() {
                  Text('√ ' + this.note)
                    .fontSize(Tokens.fsFoot)
                    .fontColor(Tokens.ok)
                    .lineHeight(18)
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .margin({ bottom: 12 })
                .backgroundColor(Tokens.doneBg)
                .borderRadius(Tokens.rMd)
                .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
              }

              if (this.loading) {
                Column() {
                  LoadingProgress()
                    .width(28)
                    .height(28)
                    .color(Tokens.accent)
                  Text('正在读取预设与权限…')
                    .fontSize(Tokens.fsBody)
                    .fontColor(Tokens.dim2)
                    .margin({ top: 10 })
                }
                .width('100%')
                .padding({ top: 72, bottom: 48 })
                .alignItems(HorizontalAlign.Center)
              } else {
                Text('Agent 预设')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
                  .letterSpacing(1.4)
                  .width('100%')
                  .margin({ left: 6, top: 4, bottom: 8 })

                if (this.presets.length === 0) {
                  EmptyState({
                    icon: $r('app.media.ic_gear'),
                    title: '暂无可用 Agent 预设',
                    hint: '当前电脑端宿主未提供预设目录',
                    action: '重新加载',
                    onAction: () => {
                      void this.load();
                    }
                  })
                } else {
                  ForEach(this.presets, (p: PresetRow) => {
                    this.presetCard(p)
                  }, (p: PresetRow) => 'p-' + p.id + '-' + (p.id === this.currentPreset ? '1' : '0') + '-' + p.broken)
                }

                Text('权限策略')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
                  .letterSpacing(1.4)
                  .width('100%')
                  .margin({ left: 6, top: 18, bottom: 8 })

                if (this.permPresets.length === 0) {
                  EmptyState({
                    icon: $r('app.media.ic_pc'),
                    title: '暂无可用权限策略',
                    hint: '当前电脑端宿主未提供权限目录',
                    action: '重新加载',
                    onAction: () => {
                      void this.load();
                    }
                  })
                } else {
                  ForEach(this.permPresets, (p: PermRow) => {
                    this.permCard(p)
                  }, (p: PermRow) => 'q-' + p.value + '-' + (p.value === this.currentPerm ? '1' : '0'))
                }
              }
            }
            .width('100%')
            .constraintSize({ maxWidth: 520 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({
            left: 16,
            right: 16,
            top: this.topInset + 64,
            bottom: this.bottomInset + 40
          })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)

        TopFade({ fadeHeight: this.topInset + 68 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.themeBg)
    }
    .hideTitleBar(false)
    .titleBar(this.hdsTitle())
    .hideBackButton(true)
    .backgroundColor(this.themeBg)
  }
}
