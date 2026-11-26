import { Api } from '../common/Api';
import { AppCtx } from '../common/AppCtx';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Machines } from '../common/Machines';
import { Mat } from '../common/Mat';
import { Pairing } from '../common/Pairing';
import { SegmentOption, SlidingSegment } from '../common/SlidingSegment';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { HintLabel, SheetHeader } from '../common/Widgets';
import { AgentSetupCard } from './AgentSetupCard';
import { ConnectForm } from './ConnectForm';
import { DeviceCard } from './DeviceCard';
import { MachineList } from './MachineList';

const NET_MODE_OPTIONS: SegmentOption[] = [
  { id: 'auto', label: '自动' },
  { id: 'lan', label: '仅局域网' },
  { id: 'wan', label: '仅公网' }
];

/**
 * 「连接」面板（精简聚焦版）：
 * 多电脑切换、网络策略、手动地址表单、外网 Cloudflare 隧道半屏向导与当前设备信息。
 */
@Component
export struct ConnectPanel {
  api: Api = new Api('', '');
  @Link editBase: string;
  @Link editToken: string;
  @Prop saved: string = '';
  @Prop saveErr: string = '';
  @Prop saving: boolean = false;
  @Prop saveStage: number = 0;
  @Prop saveDetail: string = '';
  @Prop saveElapsed: number = 0;
  @Prop netMode: string = 'auto';
  @Prop machineName: string = '';
  @Prop currentBase: string = '';
  @Prop pluginVersion: string = '';
  @Prop sessionsCount: number = -1;
  @Prop connected: boolean = false;
  @Prop linkLoading: boolean = false;
  @Prop isLanLink: boolean = false;

  onSave: () => void = () => {};
  onNetMode: (mode: string) => void = () => {};
  onPickMachine: (id: string) => void = () => {};
  onRemoveMachine: (id: string) => void = () => {};
  onAddMachine: (wan: string, token: string, name: string) => void = () => {};
  onOpenPair: (entry: string) => void = () => {};
  onReconnect: () => void = () => {};
  onRemoveCurrent: () => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('linkEncrypted') linkEncrypted: boolean = false;

  @State private addOn: boolean = false;
  @State private addBase: string = '';
  @State private addToken: string = '';
  @State private addName: string = '';
  @State private addErr: string = '';

  @State private renameOn: boolean = false;
  @State private renameId: string = '';
  @State private renameName: string = '';
  @State private renameErr: string = '';

  @State private tunnelSheet: boolean = false;
  @State private copiedAll: boolean = false;

  private confirmRemoveMachine(id: string): void {
    Haptics.tap();
    AppCtx.confirm(
      '忘记这台电脑',
      '会从这台手机上删掉它的地址与令牌；电脑端不受影响。',
      '忘记',
      () => {
        this.onRemoveMachine(id);
      },
      true
    );
  }

  private submitAddMachine(): void {
    const rawBase: string = this.addBase.trim();
    const rawToken: string = this.addToken.trim();
    if (rawBase === '') {
      this.addErr = '请填写这台电脑的连接地址。';
      return;
    }
    if (rawBase.indexOf('://') >= 0 && !/^https?:\/\//i.test(rawBase)) {
      this.addErr = '连接地址仅支持 http:// 或 https:// 协议。';
      return;
    }
    const norm: string = Pairing.normalizeBase(rawBase);
    if (!/^https?:\/\/[^\s/]+/i.test(norm)) {
      this.addErr = '连接地址格式不正确，请检查域名或 IP 端口。';
      return;
    }
    if (rawToken === '') {
      this.addErr = '请填写访问令牌。';
      return;
    }
    Haptics.tap();
    this.addErr = '';
    this.addOn = false;
    this.onAddMachine(norm, rawToken, this.addName.trim());
    Toast.ok('已添加并切换');
  }

  private submitRenameMachine(): void {
    const name: string = this.renameName.trim();
    if (name === '') {
      this.renameErr = '电脑名称不能为空。';
      return;
    }
    Haptics.tap();
    Machines.rename(this.renameId, name);
    this.renameErr = '';
    this.renameOn = false;
    Toast.ok('已重命名');
  }

  @Builder
  sectionTitle(text: string, topMargin: number = 18) {
    Text(text)
      .fontSize(Tokens.fsCaption)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.4)
      .margin({ left: 6, top: topMargin, bottom: 8 })
  }

  @Builder
  netChip(label: string, mode: string) {
    Text(label)
      .fontSize(Tokens.fsFoot)
      .fontColor(this.netMode === mode ? Tokens.accentInk : Tokens.dim)
      .backgroundColor(this.netMode === mode ? Tokens.accent : Tokens.surface2)
      .borderRadius(Tokens.rPill)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        if (this.netMode === mode) {
          return;
        }
        Haptics.tap();
        this.onNetMode(mode);
      })
  }

  @Builder
  addMachineChip(label: string, entry: string) {
    Text(label)
      .fontSize(Tokens.fsBody)
      .fontColor(Tokens.accent)
      .backgroundColor(Tokens.accentSoft)
      .borderRadius(Tokens.rPill)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .margin({ right: 8 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        Haptics.tap();
        if (entry === 'manual') {
          this.addBase = '';
          this.addToken = '';
          this.addName = '';
          this.addErr = '';
          this.addOn = true;
          return;
        }
        this.onOpenPair(entry);
      })
  }

  @Builder
  addMachineSheet() {
    Scroll() {
      Column() {
        Row() {
          Text('添加电脑')
            .fontSize(Tokens.fsTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
          HintLabel({
            title: '',
            tipText: '填入另一台电脑的地址与访问令牌即可切换；同一台电脑无需重复添加。'
          })
          .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 14 })

        TextInput({ text: this.addName, placeholder: '备注名称（可留空）' })
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .margin({ bottom: 10 })
          .onChange((v: string) => {
            this.addName = v;
          })

        TextInput({ text: this.addBase, placeholder: 'https://dsh.example.com 或 192.168.1.3:8901' })
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .margin({ bottom: 10 })
          .onChange((v: string) => {
            this.addBase = v;
            if (this.addErr !== '') {
              this.addErr = '';
            }
          })

        TextInput({ text: this.addToken, placeholder: '访问令牌' })
          .type(InputType.Password)
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .onChange((v: string) => {
            this.addToken = v;
            if (this.addErr !== '') {
              this.addErr = '';
            }
          })

        if (this.addErr !== '') {
          Text(this.addErr)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .lineHeight(18)
            .width('100%')
            .padding(10)
            .margin({ top: 10 })
            .backgroundColor(Tokens.intrBg)
            .borderRadius(Tokens.rSm)
        }

        Row() {
          Text('取消')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.surface2)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              this.addOn = false;
            })
          Text('添加并切换')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.accent)
            .margin({ left: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              this.submitAddMachine();
            })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: this.bottomInset + 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  renameMachineSheet() {
    Scroll() {
      Column() {
        Text('重命名这台电脑')
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
          .margin({ bottom: 14 })

        TextInput({ text: this.renameName, placeholder: '给这台电脑起个名字' })
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .onChange((v: string) => {
            this.renameName = v;
            if (this.renameErr !== '') {
              this.renameErr = '';
            }
          })

        if (this.renameErr !== '') {
          Text(this.renameErr)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .lineHeight(18)
            .width('100%')
            .padding(10)
            .margin({ top: 10 })
            .backgroundColor(Tokens.intrBg)
            .borderRadius(Tokens.rSm)
        }

        Row() {
          Text('取消')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.surface2)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              this.renameOn = false;
            })
          Text('保存')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.accent)
            .margin({ left: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              this.submitRenameMachine();
            })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: this.bottomInset + 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
  }

  private linkSummaryText(): string {
    if (this.linkLoading) {
      return '正在检测连接…';
    }
    if (!this.connected) {
      return '未连接 · 请检查网络或重新配对';
    }
    const route: string = this.isLanLink ? '已连接 · 局域网直连' : '已连接 · 公网入口';
    return this.linkEncrypted ? route + ' · 端到端加密' : route;
  }

  @Builder
  linkStatusCard() {
    Column() {
      Row() {
        Row()
          .width(8)
          .height(8)
          .borderRadius(Tokens.rPill)
          .backgroundColor(this.linkLoading ? Tokens.dim2 : (this.connected ? Tokens.ok : Tokens.err))
        Text(this.linkSummaryText())
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.linkLoading ? Tokens.dim2 : (this.connected ? Tokens.fg : Tokens.err))
          .margin({ left: 8 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.linkLoading && this.connected && this.linkEncrypted) {
          Text('端到端加密')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.doneInk)
            .backgroundColor(Tokens.doneBg)
            .borderRadius(Tokens.rPill)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .margin({ left: 6 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.currentBase !== '') {
        Text(this.currentBase)
          .fontSize(Tokens.fsCaption)
          .fontFamily('monospace')
          .fontColor(Tokens.dim2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .borderRadius(Tokens.rGroup)
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 6, bottom: 6 })
  }

  private tunnelScript(): string {
    return 'winget install --id Cloudflare.cloudflared\n' +
      'cloudflared --version\n' +
      'cloudflared tunnel login\n' +
      'cloudflared tunnel create agent-mobile\n' +
      'cloudflared tunnel list\n' +
      'cloudflared tunnel route dns agent-mobile am.你的域名.com\n' +
      '# 下面这段写进 %USERPROFILE%\\.cloudflared\\config.yml，<UUID> 换成第 3 步的隧道 ID\n' +
      'tunnel: <UUID>\n' +
      'credentials-file: C:\\Users\\你\\.cloudflared\\<UUID>.json\n' +
      'ingress:\n' +
      '  - hostname: am.你的域名.com\n' +
      '    service: http://127.0.0.1:8901\n' +
      '  - service: http_status:404\n' +
      'cloudflared tunnel run agent-mobile\n' +
      'cloudflared service install\n' +
      'sc query cloudflared';
  }

  private async copyTunnelAll(): Promise<void> {
    const ok: boolean = await copyText(this.tunnelScript(), '已复制全部命令');
    if (ok) {
      this.copiedAll = true;
      setTimeout(() => {
        this.copiedAll = false;
      }, 1800);
    }
  }

  @Builder
  guideStep(n: string, title: string, cmd: string) {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          Text(n)
            .fontSize(Tokens.fsCaption)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.accentInk)
        }
        .width(18)
        .height(18)
        .borderRadius(Tokens.rPill)
        .backgroundColor(Tokens.accent)

        Text(title)
          .fontSize(Tokens.fsFoot)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Column() {
          ForEach(cmd.split('\n'), (line: string, idx: number) => {
            Text(line)
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim)
              .fontFamily('monospace')
              .lineHeight(16)
              .width('100%')
          }, (line: string, idx: number) => String(idx) + '-' + line)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Row() {
          Image($r('app.media.ic_copy'))
            .width(13)
            .height(13)
            .fillColor(Tokens.accent)
            .objectFit(ImageFit.Contain)
        }
        .width(26)
        .height(26)
        .borderRadius(Tokens.rSm)
        .backgroundColor(Tokens.surface3)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 6 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          void copyText(cmd, '已复制命令');
        })
      }
      .width('100%')
      .padding(10)
      .margin({ top: 6 })
      .backgroundColor(Tokens.surface2)
      .borderRadius(Tokens.rSm)
      .alignItems(VerticalAlign.Top)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 12 })
  }

  @Builder
  tunnelGuideSheet() {
    Scroll() {
      Column() {
        SheetHeader({
          title: 'Cloudflare 外网隧道指南',
          subtitle: '配置后手机在 4G / 5G 下也能加密访问电脑',
          onClose: () => {
            this.tunnelSheet = false;
          }
        })

        Row() {
          Text('支持一键复制完整命令到电脑执行')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .layoutWeight(1)
          Text(this.copiedAll ? '已复制' : '复制全部')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              void this.copyTunnelAll();
            })
        }
        .width('100%')
        .margin({ top: 12 })

        this.guideStep('1', '安装 cloudflared（Windows 管理员 PowerShell）',
          'winget install --id Cloudflare.cloudflared\ncloudflared --version')
        this.guideStep('2', '登录 Cloudflare（浏览器选域名授权）', 'cloudflared tunnel login')
        this.guideStep('3', '创建隧道并记录 UUID', 'cloudflared tunnel create agent-mobile\ncloudflared tunnel list')
        this.guideStep('4', '绑定域名路由', 'cloudflared tunnel route dns agent-mobile am.你的域名.com')
        this.guideStep('5', '写入配置文件 %USERPROFILE%\\.cloudflared\\config.yml',
          'tunnel: <第 3 步 UUID>\ncredentials-file: C:\\Users\\你\\.cloudflared\\<第 3 步 UUID>.json\ningress:\n  - hostname: am.你的域名.com\n    service: http://127.0.0.1:8901\n  - service: http_status:404')
        this.guideStep('6', '手动运行验证连通', 'cloudflared tunnel run agent-mobile')
        this.guideStep('7', '安装为系统服务开机自启', 'cloudflared service install\nsc query cloudflared')

        Column() {
          Text('回到 App 填入公网地址')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
          Text('将 https://am.你的域名.com 填入电脑端「Agent Mobile」面板并同步到此处，在家直连局域网、出门自动切换隧道。')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .lineHeight(17)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(12)
        .backgroundColor(Tokens.accentSoft)
        .borderRadius(Tokens.rMd)
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: this.bottomInset + 22 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      // 0. 当前连接与加密态
      this.linkStatusCard()

      // 1. 多电脑管理
      this.sectionTitle('电脑', 10)
      Column() {
        MachineList({
          onPick: (id: string) => {
            this.onPickMachine(id);
            Toast.ok('已切换电脑');
          },
          onRemove: (id: string) => {
            this.confirmRemoveMachine(id);
          },
          onRename: (id: string, name: string) => {
            this.renameId = id;
            this.renameName = name;
            this.renameErr = '';
            this.renameOn = true;
          }
        })
      }
      .width('100%')
      .bindSheet($$this.renameOn, this.renameMachineSheet(),
        Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
          this.renameOn = false;
        }, true, true))

      Row() {
        this.addMachineChip('扫码配对', 'scan')
        this.addMachineChip('新手引导', 'guide')
        this.addMachineChip('手动添加', 'manual')
      }
      .width('100%')
      .margin({ top: 2, bottom: 4 })
      .bindSheet($$this.addOn, this.addMachineSheet(),
        Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
          this.addOn = false;
        }, true, true))

      // 2. 网络策略
      this.sectionTitle('网络策略', 16)
      Column() {
        Row() {
          Text('连接优先策略')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
          HintLabel({
            title: '',
            tipText: '自动：同一 Wi-Fi 下优先走局域网直连，出门自动走公网隧道；仅局域网：不回退隧道；仅公网：强制走隧道入口。'
          })
          .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          SlidingSegment({
            options: NET_MODE_OPTIONS,
            selected: this.netMode,
            onSelect: (mode: string) => {
              this.onNetMode(mode);
            }
          })
        }
        .width('100%')
        .margin({ top: 10 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)

      // 3. 连接地址与外网向导
      this.sectionTitle('连接地址与外网', 18)
      ConnectForm({
        base: $editBase,
        token: $editToken,
        saved: this.saved,
        errMsg: this.saveErr,
        saving: this.saving,
        stageIdx: this.saveStage,
        stageDetail: this.saveDetail,
        elapsedSec: this.saveElapsed,
        onSave: (): void => {
          this.onSave();
        },
        onRePair: (): void => {
          this.onOpenPair('scan');
        }
      })

      AgentSetupCard()

      Row() {
        Text('外网访问配置向导（Cloudflare 隧道）')
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text('查看指南')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .margin({ right: 6 })
        Text('›')
          .fontSize(17)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .margin({ top: 10 })
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        Haptics.tap();
        this.tunnelSheet = true;
      })
      .bindSheet($$this.tunnelSheet, this.tunnelGuideSheet(),
        Mat.sheetOpts(this.hdsOn, SheetSize.LARGE, () => {
          this.tunnelSheet = false;
        }))

      // 4. 当前设备概况与断开/移除
      DeviceCard({
        name: this.machineName,
        base: this.currentBase,
        pluginVersion: this.pluginVersion,
        sessions: this.sessionsCount,
        onReconnect: (): void => {
          this.onReconnect();
        },
        onRemove: (): void => {
          this.onRemoveCurrent();
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
