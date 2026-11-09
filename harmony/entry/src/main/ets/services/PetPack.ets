/**
 * 本地桌宠素材包加载（dsh-go 的 whale-girl 包格式）。
 *
 * 说明：鲸娘/Deepy 的美术素材**不在** dsh-go 的 AGPL 授权范围内（版权归 DSH-TUI，保留所有权利），
 * 所以这些 PNG 不随本仓库分发 —— `resources/rawfile/pets/` 已被 .gitignore 排除，只在本人机器上
 * 存在时才生效；素材缺失时界面自动退回原来的 emoji 桌宠。
 */
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { asArray, asRecord, jsonNum, jsonStr } from '../protocol/Types';
import { logWarn } from '../util/Log';
import { LinkLog } from './LinkLog';

/** 一帧：在精灵图里的列序号 + 停留毫秒。 */
export class PetFrame {
  index: number = 0;
  ms: number = 120;
}

/** 一段动画：一张横向精灵图 + 逐帧时长。 */
export class PetAnim {
  name: string = '';
  sheet: string = '';
  frameW: number = 0;
  frameH: number = 0;
  frames: PetFrame[] = [];
  /** 解码后的整张精灵图（只解一次）。 */
  pixel: image.PixelMap | undefined = undefined;
  /** 精灵图像素尺寸（显示时按 PET_SCALE 放大）。 */
  sheetW: number = 0;
  sheetH: number = 0;
}

const PACK_DIR = 'pets/whale-girl';
/** 只解码实际用到的几段动画，避免把 20 多张图全塞进内存。 */
const WANTED: string[] = ['idle', 'typing', 'thinking', 'happy'];

class PetPackStore {
  private anims: Map<string, PetAnim> = new Map<string, PetAnim>();
  private loaded: boolean = false;
  private usable: boolean = false;

  /** 素材是否可用（没有素材时界面继续用 emoji）。 */
  ready(): boolean {
    return this.usable;
  }

  /** 读 pack.json 并解码需要的精灵图；失败不影响主流程。 */
  async load(context: common.Context): Promise<void> {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(PACK_DIR + '/pack.json');
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      const root: Record<string, Object> | undefined = asRecord(JSON.parse(text) as Object);
      if (root === undefined) {
        return;
      }
      const animations: Record<string, Object> | undefined = asRecord(root['animations']);
      if (animations === undefined) {
        return;
      }
      for (const name of WANTED) {
        const record: Record<string, Object> | undefined = asRecord(animations[name]);
        if (record === undefined) {
          continue;
        }
        const anim: PetAnim = new PetAnim();
        anim.name = name;
        anim.sheet = jsonStr(record, 'sheet', '');
        anim.frameW = jsonNum(record, 'frameW', 0);
        anim.frameH = jsonNum(record, 'frameH', 0);
        if (anim.sheet.length === 0 || anim.frameW <= 0 || anim.frameH <= 0) {
          continue;
        }
        const frames: Object[] | undefined = asArray(record['frames']);
        if (frames === undefined) {
          continue;
        }
        for (const frameRecord of frames) {
          const frameObj: Record<string, Object> | undefined = asRecord(frameRecord);
          if (frameObj === undefined) {
            continue;
          }
          const frame: PetFrame = new PetFrame();
          frame.index = jsonNum(frameObj, 'i', 0);
          frame.ms = jsonNum(frameObj, 'ms', 120);
          anim.frames.push(frame);
        }
        if (anim.frames.length === 0) {
          continue;
        }
        const decoded: image.PixelMap | undefined = await this.decode(context, PACK_DIR + '/' + anim.sheet);
        if (decoded === undefined) {
          continue;
        }
        anim.pixel = decoded;
        const info: image.ImageInfo = await decoded.getImageInfo();
        anim.sheetW = info.size.width;
        anim.sheetH = info.size.height;
        this.anims.set(name, anim);
      }
      this.usable = this.anims.size > 0;
      LinkLog.write('pet', 'pack loaded anims=' + this.anims.size + ' names=' + Array.from(this.anims.keys()).join(','));
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : String(error);
      logWarn('pet pack unavailable: ' + detail);
      LinkLog.write('pet', 'pack unavailable: ' + detail);
      this.usable = false;
    }
  }

  private async decode(context: common.Context, path: string): Promise<image.PixelMap | undefined> {
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(path);
      const source: image.ImageSource = image.createImageSource(bytes.buffer as ArrayBuffer);
      return await source.createPixelMap();
    } catch (error) {
      logWarn('pet sheet decode failed: ' + path);
      return undefined;
    }
  }

  /** 当前状态该放哪段动画；素材缺哪段就退回 idle。 */
  animNameFor(state: string): string {
    const preferred: string = state === 'working' ? 'typing'
      : (state === 'waiting' ? 'thinking' : (state === 'done' ? 'happy' : 'idle'));
    if (this.anims.has(preferred)) {
      return preferred;
    }
    return this.anims.has('idle') ? 'idle' : '';
  }

  anim(name: string): PetAnim | undefined {
    return this.anims.get(name);
  }
}

export const PetPack: PetPackStore = new PetPackStore();
