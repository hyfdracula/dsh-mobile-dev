import pasteboard from '@ohos.pasteboard';
import { Haptics } from './Haptics';
import { Toast } from './Toast';

/**
 * 统一剪贴板复制入口：写入系统剪贴板 + 轻触振动 + 轻提示。
 * okToast 传空串时不弹成功提示（适合外层已有自绘状态行的场景）。
 */
export async function copyText(text: string, okToast: string = '已复制'): Promise<boolean> {
  try {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    await pasteboard.getSystemPasteboard().setData(data);
    Haptics.success();
    if (okToast !== '') {
      Toast.ok(okToast);
    }
    return true;
  } catch (e) {
    Toast.err('复制失败');
    return false;
  }
}

export class Clipboard {
  static async copy(text: string, okToast: string = '已复制'): Promise<boolean> {
    return await copyText(text, okToast);
  }
}
