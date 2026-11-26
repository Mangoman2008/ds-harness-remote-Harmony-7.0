import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { getAppRuntime } from '../services/AppRuntime';
import { KeepAlive } from '../services/KeepAlive';
import { LinkLog } from '../services/LinkLog';

const DOMAIN = 0x0000;
const BG_DARK = '#070B16';
const BG_LIGHT = '#F2F5FA';
const CONTENT_DARK = '#F2F4FA';
const CONTENT_LIGHT = '#1B2437';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', '%{public}s', 'Failed to set colorMode');
    }
    const runtime = getAppRuntime();
    runtime.setSystemDark(this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    runtime.setSystemLandscape(this.context.config.direction === ConfigurationConstant.Direction.DIRECTION_HORIZONTAL);
    this.consumeAttentionWant(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  /**
   * 点「需要确认 / 需要回答」通知会把 App 拉起来：want 里带着会话 id，
   * 交给运行时在界面就绪后切过去（不在这里直接切，页面可能还没加载完）。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.consumeAttentionWant(want);
  }

  private consumeAttentionWant(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    // 从另一台设备流转过来：want 里带着主机 + 会话，交给运行时去连
    getAppRuntime().applyHandoff(params);
    const raw: Object | undefined = params['sessionId'];
    if (raw === undefined || raw === null) {
      return;
    }
    const sessionId: string = String(raw);
    if (sessionId.length === 0) {
      return;
    }
    getAppRuntime().requestOpenSession(sessionId);
  }

  /**
   * 源端：系统要流转走时被调用，把「正在哪台主机、哪条会话」塞进 want 参数。
   * 没有可交的东西就 REJECT，系统那边会显示「无法流转」。
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    const payload: Record<string, Object> | undefined = getAppRuntime().continuePayload();
    if (payload === undefined) {
      LinkLog.write('life', '流转：还没连上任何主机，拒绝');
      return AbilityConstant.OnContinueResult.REJECT;
    }
    const keys: string[] = Object.keys(payload);
    for (const key of keys) {
      wantParam[key] = payload[key];
    }
    LinkLog.write('life', '流转出去：session=' + String(payload['dshSession']).slice(0, 8));
    return AbilityConstant.OnContinueResult.AGREE;
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.setupWindowStage(windowStage);
  }

  /**
   * 从别的设备流转过来时，系统**不会**调 onWindowStageCreate，而是调这个。
   * 原来没实现，于是目标端窗口起来了却没有内容——表现就是「流转之后打不开」。
   */
  onWindowStageRestore(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageRestore');
    this.setupWindowStage(windowStage);
  }

  private setupWindowStage(windowStage: window.WindowStage): void {
    this.mainWindow = windowStage.getMainWindowSync();
    // 长时任务要用 UIAbilityContext：交给保活模块，连着主机时申请、断开时释放
    KeepAlive.bind(this.context as common.UIAbilityContext);
    this.applyWindowTheme();
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // Re-assert after content load: some devices drop the pre-load values.
      this.applyWindowTheme();
      this.markContinuable();
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  /** 告诉系统：这个应用可以被流转（任务中心/多设备中心里才会出现入口）。 */
  private markContinuable(): void {
    try {
      this.context.setMissionContinueState(AbilityConstant.ContinueState.ACTIVE)
        .catch((error: BusinessError) => {
          hilog.warn(DOMAIN, 'testTag', 'setMissionContinueState failed: %{public}s', JSON.stringify(error));
        });
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'continuation unsupported: %{public}s', JSON.stringify(err));
    }
  }

  /** Immersive layout plus window/bar colors matching the active theme. */
  private applyWindowTheme(): void {
    const win: window.Window | undefined = this.mainWindow;
    if (win === undefined) {
      return;
    }
    const dark: boolean = getAppRuntime().isDark();
    const bg: string = dark ? BG_DARK : BG_LIGHT;
    const content: string = dark ? CONTENT_DARK : CONTENT_LIGHT;
    try {
      win.setWindowBackgroundColor(bg);
      win.setWindowLayoutFullScreen(true);
      win.setWindowSystemBarProperties({
        statusBarColor: bg,
        statusBarContentColor: content,
        navigationBarColor: bg,
        navigationBarContentColor: content
      }).catch(() => {
        hilog.warn(DOMAIN, 'testTag', '%{public}s', 'setWindowSystemBarProperties rejected');
      });
    } catch (err) {
      hilog.warn(DOMAIN, 'testTag', 'immersive not supported: %{public}s', JSON.stringify(err));
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const runtime = getAppRuntime();
    runtime.setSystemDark(newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    runtime.setSystemLandscape(newConfig.direction === ConfigurationConstant.Direction.DIRECTION_HORIZONTAL);
    // 语言跟随系统时，系统切语言要重新算一次有效语言，并让界面重建。
    runtime.applyLanguage();
    runtime.notify();
    this.applyWindowTheme();
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // 安全存储要在设备解锁后可用：回前台时补一次身份读取
    getAppRuntime().retryBootstrap(this.context);
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
