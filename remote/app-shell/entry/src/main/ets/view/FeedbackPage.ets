import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { HdsNavDestination } from '@kit.UIDesignKit';
import { AppCtx } from '../common/AppCtx';
import { PageHeader, TopFade } from '../common/Chrome';
import {
  contactPref,
  detail,
  envLine,
  mine,
  NewTicket,
  notifyPref,
  setContactPref,
  setNotifyPref,
  submit,
  Ticket,
  upload,
  UPLOADS,
  UploadSpec
} from '../common/Feedback';
import { Haptics } from '../common/Haptics';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Notifier } from '../common/Notifier';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { FeedbackDetailView } from './feedback/FeedbackDetailView';
import { FeedbackEntryView } from './feedback/FeedbackEntryView';
import { FeedbackMineView } from './feedback/FeedbackMineView';
import { FeedbackSubmitView } from './feedback/FeedbackSubmitView';
import { PendingAttachment } from './feedback/FeedbackTypes';

/**
 * 反馈页薄壳协调器：
 * 管理 entry / submit / mine / detail 四屏状态切换、附件选取与工单请求，
 * 视觉层委托 view/feedback/* 子组件渲染。
 */
@Component
export struct FeedbackPage {
  onExit: () => void = () => {};

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('wideScreen') wideScreen: boolean = false;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('fbBack') @Watch('onFbBack') private fbBack: number = 0;

  @State @Watch('onStage') private stage: string = 'entry';
  @State private busy: boolean = false;
  @State private err: string = '';
  @State private note: string = '';

  // 提交表单状态
  @State private kind: string = 'bug';
  @State private text: string = '';
  @State private contact: string = '';
  @State private notifyOn: boolean = true;
  @State private pend: PendingAttachment[] = [];

  // 我的反馈列表状态
  @State private rows: Ticket[] = [];
  @State private loaded: boolean = false;

  // 工单详情状态
  @State private cur: Ticket | null = null;

  private fbStack: NavPathStack = new NavPathStack();
  private submitScroller: Scroller = new Scroller();

  private onStage(): void {
    AppStorage.setOrCreate('fbStage', this.stage);
  }

  private syncStageFromStack(): void {
    const names: string[] = this.fbStack.getAllPathName();
    const top: string = names.length > 0 ? names[names.length - 1] : 'entry';
    if (this.stage !== top) {
      this.stage = top;
    }
  }

  private onFbBack(): void {
    if (this.fbBack > 0) {
      this.back();
    }
  }

  aboutToAppear(): void {
    AppStorage.setOrCreate('fbStage', this.stage);
    this.notifyOn = notifyPref();
    this.contact = contactPref();
  }

  private pushStage(next: string): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (_e) {
    }
    this.fbStack.pushPathByName(next, null);
    this.syncStageFromStack();
  }

  private scrollToBottomSoon(): void {
    setTimeout(() => {
      try {
        this.submitScroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 忽略
      }
    }, 120);
  }

  private back(): void {
    Haptics.soft();
    if (this.fbStack.size() > 0) {
      this.err = '';
      this.fbStack.pop();
      this.syncStageFromStack();
      return;
    }
    this.onExit();
  }

  private async pickMedia(video: boolean): Promise<string[]> {
    const photoPicker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    const opt: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    opt.MIMEType = video ? photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE
      : photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opt.maxSelectNumber = video ? 1 : 3;
    const picked: photoAccessHelper.PhotoSelectResult = await photoPicker.select(opt);
    return picked.photoUris === undefined ? [] : picked.photoUris;
  }

  private async pickDoc(): Promise<string[]> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const vp: picker.DocumentViewPicker = new picker.DocumentViewPicker(AppCtx.ability());
    const uris: string[] = await vp.select(options);
    return uris === undefined || uris === null ? [] : uris;
  }

  private nameOf(uri: string): string {
    const cut: number = uri.lastIndexOf('/');
    const tail: string = cut >= 0 ? uri.slice(cut + 1) : uri;
    return tail.length > 80 ? tail.slice(tail.length - 80) : tail;
  }

  private countOf(targetKind: string): number {
    let n: number = 0;
    for (let i = 0; i < this.pend.length; i++) {
      if (this.pend[i].spec.kind === targetKind) {
        n++;
      }
    }
    return n;
  }

  private addPending(spec: UploadSpec, paths: string[]): void {
    const next: PendingAttachment[] = this.pend.slice();
    for (let i = 0; i < paths.length; i++) {
      if (this.countOf(spec.kind) + (next.length - this.pend.length) >= spec.count) {
        break;
      }
      next.push({ spec: spec, path: paths[i], name: this.nameOf(paths[i]), size: 0 });
    }
    this.pend = next;
  }

  private async addShot(): Promise<void> {
    if (this.countOf('screenshot') >= 3) {
      Toast.info('最多添加 3 张截图');
      return;
    }
    try {
      const uris: string[] = await this.pickMedia(false);
      if (uris.length > 0) {
        this.addPending(UPLOADS[0], uris);
      }
    } catch (e) {
      Toast.err('无法打开相册');
    }
  }

  private async addVideo(): Promise<void> {
    if (this.countOf('video') >= 1) {
      Toast.info('最多添加 1 段录屏');
      return;
    }
    try {
      const uris: string[] = await this.pickMedia(true);
      if (uris.length > 0) {
        this.addPending(UPLOADS[1], uris);
      }
    } catch (e) {
      Toast.err('无法打开相册');
    }
  }

  private async addLog(): Promise<void> {
    if (this.countOf('log') >= 1) {
      Toast.info('最多添加 1 个日志文件');
      return;
    }
    try {
      const uris: string[] = await this.pickDoc();
      if (uris.length > 0) {
        this.addPending(UPLOADS[2], uris);
      }
    } catch (e) {
      Toast.err('无法打开文件管理');
    }
  }

  private dropPending(i: number): void {
    if (i < 0 || i >= this.pend.length) {
      return;
    }
    const next: PendingAttachment[] = this.pend.slice();
    next.splice(i, 1);
    this.pend = next;
    Haptics.tap();
  }

  private async doSubmit(): Promise<void> {
    if (this.busy) {
      return;
    }
    const body: string = this.text.trim();
    if (body === '') {
      Toast.info('请先填写反馈内容再提交');
      return;
    }
    if (body.length > 10000) {
      this.err = '反馈正文不能超过 10000 字。';
      return;
    }
    this.busy = true;
    this.err = '';
    this.note = '';
    try {
      const t: NewTicket = {
        kind: this.kind,
        body: body,
        env: envLine(),
        contact: this.contact.trim(),
        notify: this.notifyOn
      };
      const id: string = await submit(t);
      setNotifyPref(this.notifyOn);
      setContactPref(this.contact.trim());
      let failed: string = '';
      for (let i = 0; i < this.pend.length; i++) {
        const one: PendingAttachment = this.pend[i];
        try {
          await upload(id, one.spec, one.path, one.name);
        } catch (e) {
          failed = one.spec.label + ' 上传未成功：' + (e as BusinessError).message;
        }
      }
      this.text = '';
      this.pend = [];
      this.rows = [];
      this.loaded = false;
      await this.loadMine();
      await this.openDetail(id);
      this.note = failed === '' ? '已提交，工单号 ' + id : '工单已建立，但' + failed;
      if (this.notifyOn) {
        await Notifier.ensure();
      }
    } catch (e) {
      this.err = (e as BusinessError).message;
      this.scrollToBottomSoon();
    } finally {
      this.busy = false;
    }
  }

  private async loadMine(): Promise<void> {
    this.busy = true;
    this.err = '';
    try {
      this.rows = await mine();
      this.loaded = true;
    } catch (e) {
      this.err = (e as BusinessError).message;
    } finally {
      this.busy = false;
    }
  }

  private async openDetail(id: string): Promise<void> {
    this.busy = true;
    this.err = '';
    try {
      this.cur = await detail(id);
      try {
        this.getUIContext().getFocusController().clearFocus();
      } catch (_e) {
      }
      const names: string[] = this.fbStack.getAllPathName();
      if (names.length > 0 && names[names.length - 1] === 'submit') {
        this.fbStack.pop(false);
        const remain: string[] = this.fbStack.getAllPathName();
        if (remain.length === 0 || remain[remain.length - 1] !== 'mine') {
          this.fbStack.pushPathByName('mine', null, false);
        }
      }
      this.fbStack.pushPathByName('detail', null, true);
      this.syncStageFromStack();
    } catch (e) {
      this.err = (e as BusinessError).message;
    } finally {
      this.busy = false;
    }
  }

  private titleOf(name: string): string {
    if (name === 'submit') {
      return '提交反馈';
    }
    if (name === 'mine') {
      return '我的反馈';
    }
    if (name === 'detail') {
      return '工单详情';
    }
    return '反馈与支持';
  }

  @Builder
  fbDest(name: string) {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        if (name === 'submit') {
          Scroll(this.submitScroller) {
            Column() {
              Column() {
                FeedbackSubmitView({
                  kind: $kind,
                  text: $text,
                  contact: $contact,
                  notifyOn: $notifyOn,
                  pend: this.pend,
                  busy: this.busy,
                  err: this.err,
                  onAddShot: (): void => {
                    void this.addShot();
                  },
                  onAddLog: (): void => {
                    void this.addLog();
                  },
                  onAddVideo: (): void => {
                    void this.addVideo();
                  },
                  onDropPending: (idx: number): void => {
                    this.dropPending(idx);
                  },
                  onBottomFieldFocus: (): void => {
                    this.scrollToBottomSoon();
                  },
                  onSubmit: (): void => {
                    void this.doSubmit();
                  }
                })
              }
              .width('100%')
              .constraintSize({ maxWidth: this.wideScreen ? 680 : 520 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({
              left: 16,
              right: 16,
              top: this.topInset + 64,
              bottom: this.bottomInset + 72
            })
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Top)
        } else if (name === 'mine') {
          Scroll() {
            Column() {
              Column() {
                FeedbackMineView({
                  rows: this.rows,
                  loaded: this.loaded,
                  busy: this.busy,
                  err: this.err,
                  onGoSubmit: (): void => {
                    this.err = '';
                    this.note = '';
                    this.pushStage('submit');
                  },
                  onOpenTicket: (id: string): void => {
                    this.note = '';
                    void this.openDetail(id);
                  },
                  onRetry: (): void => {
                    void this.loadMine();
                  }
                })
              }
              .width('100%')
              .constraintSize({ maxWidth: this.wideScreen ? 680 : 520 })
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
        } else {
          Scroll() {
            Column() {
              Column() {
                FeedbackDetailView({
                  cur: this.cur,
                  note: this.note,
                  err: this.err,
                  busy: this.busy,
                  onRefresh: (id: string): void => {
                    void this.openDetail(id);
                  }
                })
              }
              .width('100%')
              .constraintSize({ maxWidth: this.wideScreen ? 680 : 520 })
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
        }

        TopFade({ fadeHeight: this.topInset + 68 })
        Column() {
          PageHeader({
            title: this.titleOf(name),
            padTop: true,
            popIn: true,
            subPageDepth: 2,
            rightKind: name === 'mine' ? 'glyph' : 'none',
            onBack: () => {
              this.back();
            },
            onRight: () => {
              void this.loadMine();
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.themeBg)
    }
    .hideTitleBar(true)
    .hideBackButton(true)
    .backgroundColor(this.themeBg)
    .onShown(() => {
      this.syncStageFromStack();
    })
    .onHidden(() => {
      this.syncStageFromStack();
    })
    .onBackPressed(() => {
      this.back();
      return true;
    })
  }

  build() {
    Navigation(this.fbStack) {
      Stack({ alignContent: Alignment.Top }) {
        Scroll() {
          Column() {
            Column() {
              FeedbackEntryView({
                onGoSubmit: (): void => {
                  this.note = '';
                  this.err = '';
                  this.pushStage('submit');
                },
                onGoMine: (): void => {
                  this.note = '';
                  this.err = '';
                  this.pushStage('mine');
                  void this.loadMine();
                }
              })
            }
            .width('100%')
            .constraintSize({ maxWidth: this.wideScreen ? 680 : 520 })
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
        Column() {
          PageHeader({
            title: '反馈与支持',
            padTop: true,
            popIn: true,
            subPageDepth: 2,
            onBack: () => {
              this.back();
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.themeBg)
    }
    .hideTitleBar(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .navDestination(this.fbDest)
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
  }
}
