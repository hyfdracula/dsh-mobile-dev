import { FEEDBACK_KINDS, UploadSpec } from '../../common/Feedback';
import { Tokens } from '../../common/Tokens';

/** 用户交流群号（QQ 群，一键复制进群）。 */
export const QQ_GROUP: string = '1131519744';

/** 一条待上传的反馈附件。 */
export interface PendingAttachment {
  spec: UploadSpec;
  path: string;
  name: string;
  size: number;
}

/** 反馈分类中文名。 */
export function feedbackKindName(kind: string): string {
  for (let i = 0; i < FEEDBACK_KINDS.length; i++) {
    if (FEEDBACK_KINDS[i].id === kind) {
      return FEEDBACK_KINDS[i].name;
    }
  }
  return kind;
}

/** 工单状态文字色令牌。 */
export function ticketStatusInk(status: string): string {
  if (status === 'done') {
    return Tokens.doneInk;
  }
  if (status === 'wontfix') {
    return Tokens.dim2;
  }
  if (status === 'doing') {
    return Tokens.runInk;
  }
  return Tokens.askInk;
}

/** 工单状态胶囊底色令牌。 */
export function ticketStatusBg(status: string): string {
  if (status === 'done') {
    return Tokens.doneBg;
  }
  if (status === 'wontfix') {
    return Tokens.surface2;
  }
  if (status === 'doing') {
    return Tokens.runBg;
  }
  return Tokens.askBg;
}
