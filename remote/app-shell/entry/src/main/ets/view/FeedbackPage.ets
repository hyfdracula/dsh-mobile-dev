import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
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
  @State private depth1Tab: string = 'submit';
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

  private entryScroller: Scroller = new Scroller();
  private midScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();

  private onStage(): void {
    AppStorage.setOrCreate('fbStage', this.stage);
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

  private stageDepth(s: string): number {
    if (s === 'detail') {
      return 2;
    }
    if (s === 'submit' || s === 'mine') {
      return 1;
    }
    return 0;
  }

  private switchStage(next: string): void {
    if (this.stage === next) {
      return;
    }
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (_e) {
    }
    if (next === 'submit' || next === 'mine') {
      this.depth1Tab = next;
    } else if (next === 'detail') {
      this.depth1Tab = 'mine';
    }
    try {
      const targetScroller: Scroller = next === 'entry'
        ? this.entryScroller
        : (next === 'detail' ? this.detailScroller : this.midScroller);
      targetScroller.scrollEdge(Edge.Top);
    } catch (e) {
      // 滚动容器未就绪时忽略
    }
    this.getUIContext().animateTo(Motion.stepPaneAnim(this.motionMode), () => {
      this.stage = next;
    });
  }

  private scrollToBottomSoon(): void {
    setTimeout(() => {
      try {
        this.midScroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 忽略
      }
    }, 120);
  }

  private back(): void {
    Haptics.soft();
    if (this.stage === 'submit' || this.stage === 'mine') {
      this.err = '';
      this.note = '';
      this.switchStage('entry');
      return;
    }
    if (this.stage === 'detail') {
      this.err = '';
      this.switchStage('mine');
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
      this.switchStage('detail');
    } catch (e) {
      this.err = (e as BusinessError).message;
    } finally {
      this.busy = false;
    }
  }

  private titleOf(): string {
    if (this.stage === 'submit') {
      return '提交反馈';
    }
    if (this.stage === 'mine') {
      return '我的反馈';
    }
    if (this.stage === 'detail') {
      return '工单详情';
    }
    return '反馈与支持';
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Stack({ alignContent: Alignment.TopStart }) {
        // 深度 0：反馈入口
        Scroll(this.entryScroller) {
          Column() {
            Column() {
              FeedbackEntryView({
                onGoSubmit: (): void => {
                  this.note = '';
                  this.err = '';
                  this.switchStage('submit');
                },
                onGoMine: (): void => {
                  this.note = '';
                  this.err = '';
                  this.switchStage('mine');
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
        .backgroundColor(this.themeBg)
        .translate({ x: String((0 - this.stageDepth(this.stage)) * 100) + '%' })
        .hitTestBehavior(this.stage === 'entry' ? HitTestMode.Default : HitTestMode.None)
        .enabled(this.stage === 'entry')

        // 深度 1：提交反馈 / 我的反馈
        Scroll(this.midScroller) {
          Column() {
            Column() {
              if (this.depth1Tab === 'submit') {
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
              } else {
                FeedbackMineView({
                  rows: this.rows,
                  loaded: this.loaded,
                  busy: this.busy,
                  err: this.err,
                  onGoSubmit: (): void => {
                    this.err = '';
                    this.note = '';
                    this.switchStage('submit');
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
            bottom: this.bottomInset + (this.depth1Tab === 'submit' ? 72 : 40)
          })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
        .backgroundColor(this.themeBg)
        .translate({ x: String((1 - this.stageDepth(this.stage)) * 100) + '%' })
        .hitTestBehavior(this.stage === 'submit' || this.stage === 'mine' ? HitTestMode.Default : HitTestMode.None)
        .enabled(this.stage === 'submit' || this.stage === 'mine')

        // 深度 2：工单详情
        Scroll(this.detailScroller) {
          Column() {
            Column() {
              if (this.cur !== null || this.stage === 'detail') {
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
        .backgroundColor(this.themeBg)
        .translate({ x: String((2 - this.stageDepth(this.stage)) * 100) + '%' })
        .hitTestBehavior(this.stage === 'detail' ? HitTestMode.Default : HitTestMode.None)
        .enabled(this.stage === 'detail')
      }
      .width('100%')
      .height('100%')
      .clip(true)

      TopFade({ fadeHeight: this.topInset + 68 })
      Column() {
        PageHeader({
          title: this.titleOf(),
          padTop: true,
          rightKind: this.stage === 'mine' ? 'glyph' : 'none',
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
}
