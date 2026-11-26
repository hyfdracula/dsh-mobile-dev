import { BackendCapabilities, SlashCommandRow, defaultBackendCapabilities } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

interface MergedCmdItem {
  name: string;
  label: string;
  desc: string;
  danger: boolean;
  builtin: boolean;
}

const RESERVED_ADD_NAMES: string[] = ['file', 'goal', 'plan', 'feedback'];

function isBuiltinCmd(name: string): boolean {
  return name === 'compact' || name === 'permission' || name === 'model' || name === 'export';
}

function cmdTitleOf(cmd: SlashCommandRow): string {
  const n: string = cmd.name;
  if (n === 'restart') return '空闲重启网关';
  if (n === 'restart-force') return '立即强制重启';
  if (n === 'web') return '打开网页控制台';
  return '/' + n;
}

/**
 * 双分组输入框「+」与「/」指令菜单（F09）：
 * - 分组一「添加」：依据当前智能体能力动态展示图片/文件/长期目标/计划模式/反馈入口；
 * - 分组二「指令」：依据能力裁剪内置指令及电脑端动态扩展指令。
 */
@Component
export struct ComposerPlusMenu {
  @Prop planActive: boolean = false;
  @Prop hasGoal: boolean = false;
  @Prop hostCommands: SlashCommandRow[] = [];
  @Prop filterPrefix: string = '';
  @Prop cmdBusyText: string = '';
  @Prop backendId: string = 'dsh';
  @Prop caps: BackendCapabilities = defaultBackendCapabilities('dsh');
  @Prop showFeedback: boolean = false;
  onPhotos: () => void = () => {};
  onCamera: () => void = () => {};
  onFiles: () => void = () => {};
  onGoal: () => void = () => {};
  onTogglePlan: () => void = () => {};
  onFeedback: () => void = () => {};
  onSelectCommand: (cmd: SlashCommandRow) => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  private mergedCommands(): MergedCmdItem[] {
    const out: MergedCmdItem[] = [];
    const seen: Set<string> = new Set<string>();
    if (this.caps.compact) {
      seen.add('compact');
      out.push({
        name: 'compact',
        label: '压缩上下文',
        desc: '整理早期历史以释放上下文窗口',
        danger: false,
        builtin: true
      });
    }
    if (this.backendId === 'dsh') {
      seen.add('permission');
      out.push({
        name: 'permission',
        label: '权限档位',
        desc: '快速切换当前会话的执行权限',
        danger: false,
        builtin: true
      });
    }
    if (this.caps.modelSwitch) {
      seen.add('model');
      out.push({
        name: 'model',
        label: '切换模型',
        desc: '更换当前会话模型与推理强度',
        danger: false,
        builtin: true
      });
    }
    seen.add('export');
    out.push({
      name: 'export',
      label: '下载会话日志',
      desc: this.backendId === 'dsh' ? '导出 Markdown (.md) 或完整包 (.zip)' : '导出 Markdown (.md)',
      danger: false,
      builtin: true
    });
    for (let i = 0; i < this.hostCommands.length; i++) {
      const c: SlashCommandRow = this.hostCommands[i];
      const n: string = c.name.trim().toLowerCase();
      if (n === '' || seen.has(n) || RESERVED_ADD_NAMES.indexOf(n) >= 0) {
        continue;
      }
      seen.add(n);
      out.push({
        name: c.name,
        label: cmdTitleOf(c),
        desc: c.description !== '' ? c.description : ('在电脑端执行 /' + c.name),
        danger: n === 'restart-force',
        builtin: isBuiltinCmd(n)
      });
    }
    const q: string = this.filterPrefix.trim().toLowerCase();
    if (q === '') {
      return out;
    }
    const filtered: MergedCmdItem[] = [];
    for (let i = 0; i < out.length; i++) {
      const it: MergedCmdItem = out[i];
      if (it.name.toLowerCase().indexOf(q) >= 0 || it.label.toLowerCase().indexOf(q) >= 0) {
        filtered.push(it);
      }
    }
    return filtered;
  }

  private hasAnyAddAction(): boolean {
    return this.caps.images || this.caps.files || this.caps.goalMode || this.caps.planMode || this.showFeedback;
  }

  private showAddGroup(): boolean {
    return this.filterPrefix.trim() === '' && this.hasAnyAddAction();
  }

  @Builder
  private addTile(title: string, sub: string, active: boolean, act: () => void) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(Tokens.fsBody)
        .fontWeight(FontWeight.Medium)
        .fontColor(active ? Tokens.accent : Tokens.fg)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(sub)
        .fontSize(10.5)
        .fontColor(active ? Tokens.accent : Tokens.dim2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .height(50)
    .padding({ left: 8, right: 8 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(Tokens.rMd)
    .backgroundColor(active ? Tokens.accentSoft : Mat.subCardBg(this.hdsOn))
    .border({ width: 0.5, color: active ? Tokens.accentGlass : Mat.subCardBorderColor(this.hdsOn) })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
    .onClick(() => {
      Haptics.tap();
      act();
    })
  }

  build() {
    Column() {
      if (this.cmdBusyText !== '') {
        Row({ space: 8 }) {
          LoadingProgress().width(14).height(14).color(Tokens.accent)
          Text(this.cmdBusyText)
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.accent)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .margin({ bottom: 8 })
        .borderRadius(Tokens.rSm)
        .backgroundColor(Tokens.accentSoft)
      }

      if (this.showAddGroup()) {
        Text('添加')
          .fontSize(Tokens.fsCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.dim2)
          .letterSpacing(0.6)
          .width('100%')
          .padding({ left: 4, bottom: 6 })

        Column({ space: 6 }) {
          if (this.caps.images || this.caps.files) {
            Row({ space: 6 }) {
              if (this.caps.images) {
                this.addTile('相册图片', '选择照片', false, (): void => { this.onPhotos(); })
                this.addTile('拍照', '即时拍摄', false, (): void => { this.onCamera(); })
              }
              if (this.caps.files) {
                this.addTile('本地文件', '/file', false, (): void => { this.onFiles(); })
              }
            }
            .width('100%')
          }

          if (this.caps.goalMode || this.caps.planMode || this.showFeedback) {
            Row({ space: 6 }) {
              if (this.caps.goalMode) {
                this.addTile('长期目标', this.hasGoal ? '已设定' : '/goal', this.hasGoal, (): void => { this.onGoal(); })
              }
              if (this.caps.planMode) {
                this.addTile('计划模式', this.planActive ? '已开启' : '未开启', this.planActive, (): void => { this.onTogglePlan(); })
              }
              if (this.showFeedback) {
                this.addTile('会话反馈', '/feedback', false, (): void => { this.onFeedback(); })
              }
            }
            .width('100%')
          }
        }
        .width('100%')
        .margin({ bottom: 10 })
      }

      Row() {
        Text('指令')
          .fontSize(Tokens.fsCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.dim2)
          .letterSpacing(0.6)
        if (this.filterPrefix.trim() !== '') {
          Text(' · /' + this.filterPrefix.trim())
            .fontSize(Tokens.fsCaption)
            .fontFamily('monospace')
            .fontColor(Tokens.accent)
        }
      }
      .width('100%')
      .padding({ left: 4, bottom: 6 })

      Scroll() {
        Column() {
          if (this.mergedCommands().length === 0) {
            Text('没有匹配的斜杠指令')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .padding({ left: 8, top: 8, bottom: 8 })
          } else {
            ForEach(this.mergedCommands(), (item: MergedCmdItem, idx: number) => {
              Column() {
                if (idx > 0) {
                  Divider().color(Tokens.lineSoft).margin({ left: 10, right: 10 })
                }
                Row({ space: 8 }) {
                  Column({ space: 1 }) {
                    Text(item.label)
                      .fontSize(Tokens.fsBody)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(item.danger ? Tokens.err : Tokens.fg)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(item.desc)
                      .fontSize(11)
                      .fontColor(Tokens.dim2)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Text('/' + item.name)
                    .fontSize(11)
                    .fontFamily('monospace')
                    .fontColor(item.danger ? Tokens.err : Tokens.dim2)
                    .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                    .borderRadius(Tokens.rPill)
                    .backgroundColor(Tokens.surface3)
                }
                .width('100%')
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .alignItems(VerticalAlign.Center)
                .borderRadius(Tokens.rSm)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
                .onClick(() => {
                  Haptics.tap();
                  const row: SlashCommandRow = {
                    name: item.name,
                    description: item.desc,
                    section: item.builtin ? 'builtin' : 'plugin'
                  };
                  this.onSelectCommand(row);
                })
              }
              .width('100%')
            }, (item: MergedCmdItem) => item.name + '_' + item.label)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 204 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .backgroundColor(Mat.subCardBg(this.hdsOn))
      .borderRadius(Tokens.rMd)
      .border(Mat.subCardBorder(this.hdsOn))
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
    .transition(Motion.panelTransition(this.motionMode))
  }
}
