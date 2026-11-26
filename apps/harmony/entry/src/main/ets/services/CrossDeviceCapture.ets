import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { logWarn } from '../util/Log';
import { PickedImage, pickedImageFromFile } from './ImagePicker';

/**
 * 跨设备取图：华为「服务协同」（ServiceCollaborationKit）。
 *
 * 这是 WPS / 系统相机用的那条官方链路——菜单里列出附近同一账号的设备，
 * 选中后由对端（手机）拍照 / 扫描 / 选相册图，图片字节回传到本机。
 * 方向是「PC/平板向手机要图」，手机上不显示这个入口。
 *
 * 回传约定（实测）：
 *   1001202004  对端已启动（等用户操作）
 *   1001202006  回传文件名
 *   1001202005  全部回传完毕
 *   0           数据包（可能是完整一张，也可能是分片）
 *   1001202001 / 1001202003  对端取消 / 本端取消
 *   其他        失败码
 * 注意：接收组件必须真实渲染（1×1 即可），设成 0×0 时框架不会投递数据。
 */
export class CrossDeviceCapture {
  private static chunks: ArrayBuffer[] = [];
  private static busy: boolean = false;

  static reset(): void {
    CrossDeviceCapture.chunks = [];
    CrossDeviceCapture.busy = false;
  }

  /** 图片字节能否解码成一张图；能就返回尺寸。 */
  static probe(buffer: ArrayBuffer): image.ImageInfo | undefined {
    try {
      const source: image.ImageSource = image.createImageSource(buffer);
      const info: image.ImageInfo = source.getImageInfoSync();
      source.release();
      if (info.size.width > 0 && info.size.height > 0) {
        return info;
      }
      return undefined;
    } catch (error) {
      return undefined;
    }
  }

  /** 把一整张图写进沙箱，交给 ImagePicker 的压缩流程。 */
  static async writeAndLoad(buffer: ArrayBuffer, dir: string): Promise<PickedImage | undefined> {
    const path: string = dir + '/collab-' + Date.now() + '-' + Math.round(Math.random() * 1000) + '.img';
    try {
      const file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, buffer);
      } finally {
        fileIo.closeSync(file);
      }
      return await pickedImageFromFile(path);
    } catch (error) {
      logWarn('collab: 写入失败');
      return undefined;
    } finally {
      try {
        fileIo.unlinkSync(path);
      } catch (error) {
        // 删不掉留着也无妨
      }
    }
  }

  /**
   * 收到一包数据：能单独解码就是完整一张（多张会来多包）；
   * 解码不了就先攒着，拼起来再试（对端可能分片回传）。
   */
  static async accept(buffer: ArrayBuffer, dir: string): Promise<PickedImage | undefined> {
    const one: image.ImageInfo | undefined = CrossDeviceCapture.probe(buffer);
    if (one !== undefined) {
      CrossDeviceCapture.chunks = [];
      return await CrossDeviceCapture.writeAndLoad(buffer, dir);
    }
    CrossDeviceCapture.chunks.push(buffer);
    let total: number = 0;
    for (const chunk of CrossDeviceCapture.chunks) {
      total += chunk.byteLength;
    }
    const merged: ArrayBuffer = new ArrayBuffer(total);
    const view: Uint8Array = new Uint8Array(merged);
    let offset: number = 0;
    for (const chunk of CrossDeviceCapture.chunks) {
      view.set(new Uint8Array(chunk), offset);
      offset += chunk.byteLength;
    }
    if (CrossDeviceCapture.probe(merged) !== undefined) {
      CrossDeviceCapture.chunks = [];
      return await CrossDeviceCapture.writeAndLoad(merged, dir);
    }
    return undefined;
  }
}
