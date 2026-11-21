/**
 * 本地桌宠素材包加载（dsh-go 的 whale-girl 包格式）。
 *
 * 说明：鲸娘/Deepy 的美术素材**不在** dsh-go 的 AGPL 授权范围内（版权归 DSH-TUI，保留所有权利），
 * 所以这些 PNG 不随本仓库分发 —— `resources/rawfile/pets/` 已被 .gitignore 排除，只在本人机器上
 * 存在时才生效；素材缺失时界面自动退回原来的 emoji 桌宠。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
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
/** 用户自备素材放这里（应用沙箱内）：files/pets/user/pack.json + 同目录的图片。 */
const USER_PACK_DIR = 'pets/user';
/** 只解码实际用到的几段动画，避免把 20 多张图全塞进内存。 */
const WANTED: string[] = ['idle', 'typing', 'thinking', 'happy', 'sleeping'];

class PetPackStore {
  private anims: Map<string, PetAnim> = new Map<string, PetAnim>();
  private loaded: boolean = false;
  private usable: boolean = false;
  /** 当前素材来源：'内置' | '自定义' | ''（没有素材）。 */
  private source: string = '';
  /** 用户素材目录的绝对路径，设置页要给用户看。 */
  private userDir: string = '';

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
    this.userDir = context.filesDir + '/' + USER_PACK_DIR;
    // 用户自备素材优先（同一个 pack.json 格式），没有就回落到内置鲸娘
    if (await this.loadFromFiles(context)) {
      return;
    }
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
      this.source = this.usable ? '内置' : '';
      LinkLog.write('pet', 'pack loaded anims=' + this.anims.size + ' names=' + Array.from(this.anims.keys()).join(','));
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : String(error);
      logWarn('pet pack unavailable: ' + detail);
      LinkLog.write('pet', 'pack unavailable: ' + detail);
      this.usable = false;
    }
  }

  /** 已加载的动画名（设置页一行说明里给用户看）。 */
  animNames(): string {
    if (this.anims.size === 0) {
      return '';
    }
    return Array.from(this.anims.keys()).join('/');
  }

  /** 素材来源（'内置' / '自定义' / ''）。 */
  packSource(): string {
    return this.source;
  }

  /** 用户素材目录（给设置页显示，方便用 hdc 推文件进去）。 */
  userPackPath(): string {
    return this.userDir;
  }

  /** 重新加载：改了素材不用重启 App。 */
  async reload(context: common.Context): Promise<void> {
    this.anims.clear();
    this.usable = false;
    this.source = '';
    this.loaded = false;
    await this.load(context);
  }

  /** 从应用沙箱读用户素材；没有或格式不对返回 false（回落内置）。 */
  private async loadFromFiles(context: common.Context): Promise<boolean> {
    const manifest: string = context.filesDir + '/' + USER_PACK_DIR + '/pack.json';
    try {
      if (!fileIo.accessSync(manifest)) {
        return false;
      }
      const file: fileIo.File = fileIo.openSync(manifest, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
      const root: Record<string, Object> | undefined = asRecord(JSON.parse(text) as Object);
      if (root === undefined) {
        return false;
      }
      const animations: Record<string, Object> | undefined = asRecord(root['animations']);
      if (animations === undefined) {
        return false;
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
        const decoded: image.PixelMap | undefined = await this.decodeFile(
          context.filesDir + '/' + USER_PACK_DIR + '/' + anim.sheet);
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
      this.source = this.usable ? '自定义' : '';
      LinkLog.write('pet', 'user pack loaded anims=' + this.anims.size + ' from ' + this.userDir);
      return this.usable;
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : String(error);
      LinkLog.write('pet', 'user pack failed: ' + detail);
      return false;
    }
  }

  private async decodeFile(path: string): Promise<image.PixelMap | undefined> {
    try {
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const source: image.ImageSource = image.createImageSource(buffer);
      return await source.createPixelMap();
    } catch (error) {
      logWarn('pet user sheet decode failed: ' + path);
      return undefined;
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
