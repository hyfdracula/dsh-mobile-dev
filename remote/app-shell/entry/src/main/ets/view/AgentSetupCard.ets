import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Tokens } from '../common/Tokens';

/** 给用户复制给 AI 的一段配置说明：目标是让 agent 在电脑上把外网访问配好。 */
const AI_SETUP_PROMPT: string[] = [
  '我在电脑上安装了 Agent Mobile 网关，手机客户端需要在外网连到它。请在我的电脑上完成下面几步，最后只输出两行结果。',
  '',
  '1. 安装并启用 agent-mobile-gateway 插件（默认监听 127.0.0.1:8901），确认 curl http://127.0.0.1:8901/health 返回 ok。',
  '2. 安装 cloudflared（Windows: winget install Cloudflare.cloudflared；macOS: brew install cloudflared）。',
  '3. 用我的 Cloudflare 账号登录并创建命名隧道：cloudflared tunnel login，然后 cloudflared tunnel create agent-mobile。',
  '4. 给隧道加 DNS 路由：cloudflared tunnel route dns agent-mobile am.<我的域名>。',
  '5. 安装成服务并启动：cloudflared service install <隧道 token>。',
  '6. 用公网地址访问 /health，确认返回 ok。',
  '',
  '网关访问令牌可从电脑端「Agent Mobile」设置面板读取。',
  '最后只输出两行，不要别的解释：',
  '地址: https://am.<我的域名>',
  '令牌: <这个 token>'
];

function tunnelFullScript(): string {
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

/**
 * 「让 AI 帮你配」阅读浮卡正文：
 * 承接在统一的景深雾面悬浮阅读卡中，点击一键复制即可交给 Codex / Claude / 任意 agent 执行。
 */
@Component
export struct AiSetupGuideBody {
  @State private copied: boolean = false;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private async copyPrompt(): Promise<void> {
    const ok: boolean = await copyText(AI_SETUP_PROMPT.join('\n'), '已复制，粘贴给你的 AI');
    if (ok) {
      this.copied = true;
      setTimeout(() => {
        this.copied = false;
      }, 1800);
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('把下面这段完整指令复制给你的 AI（Codex / Claude Code / 任意智能体），它会直接在电脑上完成网关检查与 Cloudflare 隧道配置，最后返回公网地址与访问令牌。')
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.dim)
        .lineHeight(20)
        .width('100%')

      Column() {
        Text(AI_SETUP_PROMPT.join('\n'))
          .fontSize(Tokens.fsFoot)
          .lineHeight(19)
          .fontColor(Tokens.fg)
          .fontFamily('monospace')
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Mat.subCardBg(this.hdsOn))
      .border(Mat.subCardBorder(this.hdsOn))
      .borderRadius(Tokens.rCard)

      Row() {
        Text(this.copied ? '已复制完整指令' : '一键复制给 AI')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(Tokens.accent)
          .borderRadius(Tokens.rInput)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
          .onClick(() => {
            void this.copyPrompt();
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 「外网访问配置向导（Cloudflare 隧道）」阅读浮卡正文：
 * 与「让 AI 帮你配」共享同一套悬浮景深阅读卡片与 hdsOn 液态玻璃适配。
 */
@Component
export struct TunnelSetupGuideBody {
  @State private copiedAll: boolean = false;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private async copyTunnelAll(): Promise<void> {
    const ok: boolean = await copyText(tunnelFullScript(), '已复制全部命令');
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
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .border(Mat.subCardBorder(this.hdsOn))
        .justifyContent(FlexAlign.Center)
        .margin({ left: 6 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          Haptics.tap();
          void copyText(cmd, '已复制命令');
        })
      }
      .width('100%')
      .padding(10)
      .margin({ top: 6 })
      .backgroundColor(Mat.subCardBg(this.hdsOn))
      .border(Mat.subCardBorder(this.hdsOn))
      .borderRadius(Tokens.rSm)
      .alignItems(VerticalAlign.Top)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 12 })
  }

  build() {
    Column() {
      Row() {
        Text('按步骤手动执行，或一键复制全部命令到电脑')
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
      .margin({ top: 14 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
