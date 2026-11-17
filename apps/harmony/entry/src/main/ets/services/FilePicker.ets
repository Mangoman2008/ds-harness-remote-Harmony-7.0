/**
 * 从系统文件选择器取任意文件，读成 base64 交给 `fileUploads/upload`。
 *
 * 远端协议只接受「先上传拿到 receiptId，再在 prompt 里放 `{type:'file', receiptId}`」，
 * 所以这里不做压缩、不改内容：字节原样送上去，主机负责暂存与会话内引用。
 * 单条消息上限 4 MiB（Noise 分片 48 KiB/片），base64 会膨胀约 1/3，
 * 因此原始文件控制在 2.5 MiB 以内，超了直接挡下来并说明原因。
 */

import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { logWarn } from '../util/Log';

/** 一条待发送的文件。base64 是标准字母表（协议要求 canonical base64）。 */
export class PickedFile {
  name: string = '';
  base64: string = '';
  bytes: number = 0;
}

/** 原始字节上限：base64 后约 3.3 MiB，留在单条 4 MiB 之内。 */
export const MAX_FILE_BYTES: number = 2500000;

/** 打开系统文件选择器；用户取消、或文件读不出来时返回空数组。 */
export async function pickFiles(maxCount: number): Promise<PickedFile[]> {
  const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
  options.maxSelectNumber = maxCount > 0 ? maxCount : 1;
  options.fileSuffixFilters = [];
  const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
  const uris: string[] = await documentPicker.select(options);
  const out: PickedFile[] = [];
  for (const uri of uris) {
    const picked: PickedFile | undefined = readPickedFile(uri);
    if (picked !== undefined) {
      out.push(picked);
    }
  }
  return out;
}

/** 按 URI 读字节并转 base64；读不到或超限返回 undefined（调用方负责提示）。 */
function readPickedFile(uri: string): PickedFile | undefined {
  let file: fs.File | undefined = undefined;
  try {
    file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    const stat: fs.Stat = fs.statSync(file.fd);
    if (stat.size > MAX_FILE_BYTES) {
      logWarn('file picker: 文件过大，已跳过');
      return undefined;
    }
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
    const read: number = fs.readSync(file.fd, buffer);
    if (read <= 0) {
      return undefined;
    }
    const bytes: Uint8Array = new Uint8Array(buffer, 0, read);
    const helper: util.Base64Helper = new util.Base64Helper();
    const picked: PickedFile = new PickedFile();
    picked.name = displayName(uri);
    picked.bytes = read;
    picked.base64 = helper.encodeToStringSync(bytes);
    return picked;
  } catch (error) {
    logWarn('file picker: 读取失败');
    return undefined;
  } finally {
    if (file !== undefined) {
      try {
        fs.closeSync(file);
      } catch (error) {
        // 关不上就算了，不要因为清理失败打断发送
      }
    }
  }
}

/** URI 最后一段当显示名，去掉 query。 */
function displayName(uri: string): string {
  const plain: string = uri.split('?')[0];
  const parts: string[] = plain.split('/');
  const last: string = parts.length > 0 ? parts[parts.length - 1] : '';
  return last.length > 0 ? decodeURIComponent(last) : 'file';
}
