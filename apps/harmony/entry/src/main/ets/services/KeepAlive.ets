import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent, common } from '@kit.AbilityKit';
import { deviceInfo, BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { logInfo, logWarn } from '../util/Log';
import { LinkLog } from './LinkLog';

/** 胶囊轮播间隔：太密会被系统限流，4 秒左右看起来像「滚着走」。 */
const CAPSULE_INTERVAL_MS: number = 4200;

/**
 * 保活：连着主机时申请一个「长时任务（dataTransfer）」。
 *
 * 为什么需要：手机熄屏 / App 退到后台之后，系统会把进程冻结，JS 定时器和网络都没法继续跑。
 * 服务端 25 秒一跳心跳，冻结状态下回不了 pong，服务端 75 秒判死直接断开 ——
 * 这就是「放下手机再拿起来，连接老是断」的主要来源。
 *
 * 申请长时任务期间系统不会冻结本进程，心跳与直连 DataChannel 都能活着。
 * 只在「已连上主机」期间持有，断开后立刻释放（长时任务会显示在通知栏，别滥用）。
 *
 * 失败不影响主流程：没有权限 / 系统拒绝就退化成不保活，只记日志。
 */
export class KeepAlive {
  private static running: boolean = false;
  private static context: common.UIAbilityContext | undefined = undefined;
  private static pending: boolean = false;
  /** 长时任务通知 id：实况窗态（胶囊）用它来更新内容。0 表示没拿到。 */
  private static capsuleId: number = 0;
  private static capsuleTimer: number = -1;
  private static capsuleLines: string[] = [];
  private static capsuleIndex: number = 0;
  private static capsuleStartedAt: number = 0;
  private static capsuleProvider: (() => string[]) | undefined = undefined;
  private static capsuleOk: boolean = false;
  /** 上一次成功的那档实况窗参数（不同系统版本接受度不一样）。 */
  private static capsuleVariant: number = 0;

  /**
   * 鸿蒙手机上那个「灵动岛」= 长时任务通知的实况窗胶囊。
   * 只有手机支持（PC 的 2in1 不显示状态栏胶囊，也没必要占一个窗）；
   * 系统版本要到 API 21（HarmonyOS 6）才有连续任务子类型这组接口。
   */
  static capsuleSupported(): boolean {
    try {
      return deviceInfo.deviceType === 'phone' && deviceInfo.sdkApiVersion >= 21;
    } catch (error) {
      return false;
    }
  }

  static isCapsuleLive(): boolean {
    return KeepAlive.capsuleOk;
  }

  /** 由 AppRuntime 注入：返回「要轮播的几行字」，第一行进胶囊。 */
  static setCapsuleProvider(provider: () => string[]): void {
    KeepAlive.capsuleProvider = provider;
    KeepAlive.refreshCapsuleLines();
    if (KeepAlive.capsuleOk) {
      KeepAlive.publishCapsule();
    }
  }

  private static refreshCapsuleLines(): void {
    const provider: (() => string[]) | undefined = KeepAlive.capsuleProvider;
    if (provider === undefined) {
      return;
    }
    try {
      const lines: string[] = provider();
      if (lines.length > 0) {
        KeepAlive.capsuleLines = lines;
      }
    } catch (error) {
      logWarn('capsule lines failed');
    }
  }

  /** 开始轮播：每 4 秒换一行，胶囊和时间一起更新。 */
  private static startCapsuleTicker(): void {
    if (KeepAlive.capsuleTimer >= 0) {
      return;
    }
    KeepAlive.capsuleStartedAt = Date.now();
    KeepAlive.capsuleTimer = setInterval(() => {
      KeepAlive.capsuleIndex = KeepAlive.capsuleIndex + 1;
      KeepAlive.refreshCapsuleLines();
      KeepAlive.publishCapsule();
    }, CAPSULE_INTERVAL_MS);
    KeepAlive.publishCapsule();
  }

  private static stopCapsuleTicker(): void {
    if (KeepAlive.capsuleTimer >= 0) {
      clearInterval(KeepAlive.capsuleTimer);
      KeepAlive.capsuleTimer = -1;
    }
    KeepAlive.capsuleOk = false;
    KeepAlive.capsuleId = 0;
    KeepAlive.capsuleIndex = 0;
  }

  /**
   * 用长时任务通知 id 更新实况窗：typeCode 8 是上传下载那一类（第三方唯一开放的）。
   * 系统对实况窗参数挑得很细（少一个 template 就 401），这里按由丰富到保守的顺序试，
   * 第一次成功的那一档记下来，之后只用它，避免每 4 秒重试三遍。
   */
  private static publishCapsule(): void {
    const id: number = KeepAlive.capsuleId;
    if (id <= 0 || KeepAlive.capsuleLines.length === 0) {
      return;
    }
    const lines: string[] = KeepAlive.capsuleLines;
    const title: string = lines[KeepAlive.capsuleIndex % lines.length];
    const detail: string = lines.length > 1
      ? lines[(KeepAlive.capsuleIndex + 1) % lines.length] : title;
    KeepAlive.publishVariant(id, title, detail, KeepAlive.capsuleVariant).catch(() => undefined);
  }

  private static async publishVariant(id: number, title: string, detail: string,
    from: number): Promise<void> {
    for (let variant = from; variant < 4; variant++) {
      try {
        await notificationManager.publish(KeepAlive.capsuleRequest(id, title, detail, variant));
        if (KeepAlive.capsuleVariant !== variant) {
          KeepAlive.capsuleVariant = variant;
          LinkLog.write('life', '胶囊生效（档位 ' + variant + '）：' + title);
        }
        KeepAlive.capsuleOk = true;
        return;
      } catch (error) {
        const code: number = (error as BusinessError).code;
        if (variant === from) {
          LinkLog.write('life', '胶囊档位 ' + variant + ' 失败 code=' + code);
        }
      }
    }
    if (KeepAlive.capsuleOk) {
      KeepAlive.capsuleOk = false;
      LinkLog.write('life', '胶囊全部档位都失败，放弃更新');
    }
  }

  /**
   * 档位 0：官方文档那套（实况窗 + downloadTemplate）
   * 档位 1：档位 0 + 胶囊标题
   * 档位 2：档位 1 + 计时器
   * 档位 3：纯文本长时通知（兜底，至少通知栏能看到进度文案）
   */
  private static capsuleRequest(id: number, title: string, detail: string,
    variant: number): notificationManager.NotificationRequest {
    if (variant >= 3) {
      const fallback: notificationManager.NotificationRequest = {
        id: id,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'DSH 远程 · ' + title,
            text: detail
          }
        }
      };
      return fallback;
    }
    const live: notificationManager.NotificationSystemLiveViewContent = {
      typeCode: 8,
      title: title,
      text: detail
    };
    if (variant >= 1) {
      live.capsule = { title: title };
    }
    if (variant >= 2) {
      live.time = {
        initialTime: KeepAlive.capsuleStartedAt,
        isCountDown: false,
        isPaused: false,
        isInTitle: false
      };
    }
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: live
      },
      template: {
        name: 'downloadTemplate',
        data: {
          title: title,
          fileName: 'dsh-remote',
          progressValue: 0
        }
      }
    };
    return request;
  }

  /** EntryAbility 启动时绑定一次 UIAbilityContext。 */
  static bind(context: common.UIAbilityContext): void {
    KeepAlive.context = context;
  }

  static isRunning(): boolean {
    return KeepAlive.running;
  }

  /** 开始保活（幂等）。 */
  static async start(): Promise<void> {
    if (KeepAlive.running || KeepAlive.pending) {
      return;
    }
    const context: common.UIAbilityContext | undefined = KeepAlive.context;
    if (context === undefined) {
      logWarn('keepalive: 还没有 UIAbilityContext，跳过');
      return;
    }
    KeepAlive.pending = true;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 20261108,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      if (KeepAlive.capsuleSupported()) {
        // 手机：申请「实况窗通知」子类型的长时任务，拿到通知 id 后就能往胶囊里写字
        try {
          const request: backgroundTaskManager.ContinuousTaskRequest =
            new backgroundTaskManager.ContinuousTaskRequest();
          request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
          request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
          request.wantAgent = agent;
          request.combinedTaskNotification = false;
          const created: backgroundTaskManager.ContinuousTaskNotification =
            await backgroundTaskManager.startBackgroundRunning(context, request);
          KeepAlive.capsuleId = created.notificationId;
          LinkLog.write('life', '长时任务（实况窗）已申请 notificationId=' + created.notificationId);
        } catch (error) {
          const code: number = (error as BusinessError).code;
          LinkLog.write('life', '实况窗长时任务被拒 code=' + code + '，退回普通长时任务');
          await backgroundTaskManager.startBackgroundRunning(context,
            backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
          KeepAlive.capsuleId = 0;
        }
      } else {
        await backgroundTaskManager.startBackgroundRunning(context,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      }
      KeepAlive.running = true;
      logInfo('keepalive: 长时任务已启动（dataTransfer）');
      LinkLog.write('life', '保活开始（长时任务 dataTransfer）：熄屏/后台不再冻结');
      if (KeepAlive.capsuleId > 0) {
        KeepAlive.startCapsuleTicker();
      }
    } catch (error) {
      logWarn('keepalive start failed');
      LinkLog.write('life', '保活申请失败（连接仍可用，但后台可能被冻结）');
    } finally {
      KeepAlive.pending = false;
    }
  }

  /** 结束保活（幂等）。 */
  static async stop(): Promise<void> {
    if (!KeepAlive.running) {
      return;
    }
    const context: common.UIAbilityContext | undefined = KeepAlive.context;
    KeepAlive.running = false;
    KeepAlive.stopCapsuleTicker();
    LinkLog.write('life', '保活结束');
    if (context === undefined) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      logInfo('keepalive: 长时任务已停止');
    } catch (error) {
      logWarn('keepalive stop failed');
    }
  }
}
