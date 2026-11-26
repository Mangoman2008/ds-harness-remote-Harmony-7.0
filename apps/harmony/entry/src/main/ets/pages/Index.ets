import { KeyboardAvoidMode, UIContext, display, window, promptAction } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { KeyCode } from '@ohos.multimodalInput.keyCode';
import { pdfService, pdfViewManager, PdfView } from '@kit.PDFKit';
import { common, Want } from '@kit.AbilityKit';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { AppRuntime, ChatItem, ChatQuestion, DEFAULT_SERVER_URL, DEFAULT_ACCOUNT, PHASE_BOOT, PHASE_CHAT,
  PHASE_CONNECTING, PHASE_DEVICES, PHASE_SETUP, ModelOption, SlashCommand,
  getAppRuntime, errorMessage, maskSecrets } from '../services/AppRuntime';
import { RemoteHostDevice } from '../model/Types';
import { DirectoryEntry, HarnessWorkspace } from '../net/HarnessClient';
import { HostPluginBundle, HostPluginRow } from '../net/PluginInventory';
import { WorkspaceGitDiff, WorkspaceGitFile, WorkspaceGitStatus } from '../net/HarnessClient';
import { PluginSettingField, PluginSettingsForm } from '../net/PluginSettings';
import { BotCatalogRow } from '../net/BotCatalog';
import { HarnessRemoteSession, HarnessSchedule, HarnessScheduleDelivery } from '../net/HarnessClient';
import { applyTint, darkPalette, lightPalette, Palette } from '../services/Theme';
import { OAuthProvider, clientVersion as appVersion } from '../net/ServerApi';
import { t, english, LANG_SYSTEM, LANG_ZH, LANG_EN } from '../services/I18n';
import { logWarn } from '../util/Log';
import { PetAnim, PetPack } from '../services/PetPack';
import { LinkLog } from '../services/LinkLog';
import {
  Breakpoint, FoldState, breakpointOf, contentColumnWidth, deviceColumns, foldStateOf,
  isCompactWidth, isExpandedWidth, mascotVisible
} from '../services/Adaptive';
import { PickedImage, captureImage, compressPixelMap, pickImages, pickedImageFromBase64 }
  from '../services/ImagePicker';
import { CrossDevice } from '../services/CrossDevice';
import { CrossDeviceCapture } from '../services/CrossDeviceCapture';
import { CollaborationServiceFilter, createCollaborationServiceMenuItems, CollaborationServiceStateDialog }
  from '@kit.ServiceCollaborationKit';
import { MAX_FILE_BYTES, PickedFile, pickFiles } from '../services/FilePicker';
import { SavedProfile } from '../services/SecureStore';
import { PromptFilePart, PromptImagePart } from '../net/HarnessClient';
import { RtcBridge } from '../services/RtcBridge';
import { heartbeatBodyOf } from '../services/Heartbeat';
import { image } from '@kit.ImageKit';
import { vibrator } from '@kit.SensorServiceKit';
import { util } from '@kit.ArkTS';
import BuildProfile from 'BuildProfile';


/** 这台设备是手机吗（决定回车是发送还是换行、要不要申请后台胶囊）。 */
function isPhoneDevice(): boolean {
  try {
    return deviceInfo.deviceType === 'phone';
  } catch (error) {
    return false;
  }
}

/** 桌宠精灵图放大倍数（像素风，整数倍最清晰）。 */
const PET_SCALE: number = 1.2;

@Entry
@Component
struct Index {
  private runtime: AppRuntime = getAppRuntime();
  /** ArkWeb/WebRTC 桥：目前只跑能力自检，数据面仍走 relay。 */
  private rtc: RtcBridge = new RtcBridge();
  private images: MarkdownImageCache = new MarkdownImageCache();
  @State imageVersion: number = 0;
  /** 设置项镜像：直接读 runtime 字段不会触发重建，第一次点选会「看起来没反应」。 */
  @State uiShowInspector: boolean = false;
  @State uiPetEnabled: boolean = true;
  @State uiHomeMascot: boolean = true;
  @State uiThemeTint: number = 0;
  @State uiCompactHistory: boolean = false;
  @State uiSecretMask: boolean = false;
  @State uiNotifications: boolean = true;
  @State uiSplitWidth: number = 0;
  /** 会话壁纸（压缩后的 JPEG base64）。 */
  @State wallpaper: string = '';
  /** 壁纸压暗强度：0 淡 / 1 中 / 2 浓。 */
  @State uiWallpaperDim: number = 1;
  /** 桌宠冒出来的俏皮话（2.6 秒后自动消失）。 */
  @State petQuip: string = '';
  /** 双击桌宠时的「炸屏」缩放倍数。 */
  /** 炸屏专用全屏层：单独一层，保证真的铺满整屏（不再靠小挂件自己放大）。 */
  @State petBoomVisible: boolean = false;
  @State petBoomScale: number = 1;
  /** 炸屏层的透明度：层常驻挂载，动画才有组件可作用（反复挂载会让 animateTo 失效）。 */
  @State petBoomOpacity: number = 0;
  private petQuipTimer: number = -1;
  private petLastTap: number = 0;
  private petTapTimer: number = -1;
  /** 会话空闲起点（毫秒）；待命超过 3 分钟就让桌宠睡着。 */
  private petIdleSince: number = 0;
  private petSleepTimer: number = -1;
  private petBooming: boolean = false;
  /** 输入坞实际高度（输入框长高时桌宠跟着上移）。 */
  @State dockHeight: number = 60;
  /** 设置面板的重绘版本号：@Builder 参数不会自己重算，改一次值就重建整块。 */
  @State settingsRev: number = 0;
  /** 桌宠精灵图当前帧 / 当前动画名（素材缺省时为空，界面回到 emoji）。 */
  @State petFrame: number = 0;
  @State petAnim: string = '';
  private petFrameCursor: number = 0;
  private petTimer: number = -1;
  private scroller: Scroller = new Scroller();
  private fieldsPrefilled: boolean = false;
  private mainWindow: window.Window | undefined = undefined;

  @State phase: string = PHASE_BOOT;
  @State busy: boolean = false;
  @State busyAction: string = '';
  @State errorMsg: string = '';
  @State infoMsg: string = '';
  /** 自动重连提示（含倒计时与第几次），原来是死数据只给状态点染色用。 */
  @State reconnectNotice: string = '';
  @State networkOnline: boolean = true;
  /** 会话页里正在等重连（短抖动不踢回设备列表）。 */
  @State reconnecting: boolean = false;
  /** 连接诊断面板。 */
  @State diagnosticsOpen: boolean = false;
  /** 连接详情（点顶栏传输徽标打开）：传输路径 / 握手耗时 / 延迟 / 回落原因。 */
  @State linkDetailOpen: boolean = false;
  /** 已手动「看原文」的气泡（打码的敏感内容点一下就能展开）。 */
  @State revealedSecrets: string[] = [];
  /** 主题色选择面板。 */
  @State tintPickerOpen: boolean = false;
  /** 当前滚动位置对应的轮次（1 起），轮次导航胶囊显示用。 */
  @State turnPosition: number = 1;
  /** 定时任务面板。 */
  @State schedulesOpen: boolean = false;
  @State devices: RemoteHostDevice[] = [];
  @State sessions: HarnessRemoteSession[] = [];
  @State sessionsLoadFailed: boolean = false;
  @State messages: ChatItem[] = [];
  @State generating: boolean = false;
  @State currentSessionId: string = '';
  @State currentSessionTitle: string = '';
  @State connectedHostName: string = '';
  @State connectedDeviceId: string = '';
  @State deviceAliases: Record<string, string> = {};
  @State renamingDeviceId: string = '';
  @State renameInput: string = '';
  /** 会话重命名编辑态。 */
  @State renamingSession: boolean = false;
  @State sessionTitleInput: string = '';
  /** 会话搜索。 */
  @State sessionSearchInput: string = '';
  @State sessionSearchResults: HarnessRemoteSession[] = [];
  @State sessionSearchActive: boolean = false;
  /** 上下文占用百分比，0 表示未知。 */
  @State contextPercent: number = 0;
  /** 这条连接的数据面：'' | 'lan' | 'p2p' | 'turn' | 'relay'。 */
  @State connectedTransport: string = '';
  /** 已选好、还没发出去的图片。 */
  @State pendingImages: PickedImage[] = [];
  /** 已上传到主机、等着随这条消息发出去的文件（receiptId 已经拿到）。 */
  @State pendingFiles: PromptFilePart[] = [];
  @State pickingFile: boolean = false;
  /** 正在取图/压缩。 */
  @State pickingImages: boolean = false;
  @State connectStage: string = '';
  /** 诊断用：设备型号（读不到就给 unknown）。 */
  private deviceModelLabel(): string {
    try {
      const model: string = deviceInfo.productModel;
      return model.length > 0 ? model : 'unknown';
    } catch (error) {
      return 'unknown';
    }
  }

  /** 连接已经跑了多少秒：卡在哪里一眼能看出来。 */
  @State connectElapsedSec: number = 0;
  private connectStartAt: number = 0;
  private connectTickTimer: number = -1;
  /** 斜杠命令候选。 */
  @State slashCommands: SlashCommand[] = [];
  /** 模型选择器。 */
  @State showModelPicker: boolean = false;
  /** 顶栏齿轮打开的面板。 */
  @State showSessionPanel: boolean = false;
  @State modelOptions: ModelOption[] = [];
  @State currentModelLabel: string = '';
  @State currentModelProvider: string = '';
  @State currentModelEffort: string = '';
  @State permissionPreset: string = '';
  /** 按住说话：波形条高度、计时、是否处于「上滑取消」区。 */
  /** 文字大小档位与倍数（0 小 / 1 标准 / 2 大 / 3 特大）。 */
  @State textScaleMode: number = 1;
  @State profilesList: SavedProfile[] = [];
  /** 「更多」面板（替代系统菜单，自己控制对比度）。 */
  @State showMoreMenu: boolean = false;
  /** 服务器切换面板。 */
  @State showServerSwitch: boolean = false;
  /** 通用设置的点选面板。 */
  @State choiceOpen: boolean = false;
  @State choiceKind: string = '';
  /** 单台设备的操作面板（卡片 ⋯）。 */
  @State deviceMenuId: string = '';
  /** 按下中的服务器行 key，用来做明显的按压反馈。 */
  @State pressedChoiceKey: string = '';
  /** 官方服务器固定地址，切换时直接可选，不用手输。 */
  private static readonly OFFICIAL_SERVER: string = 'https://dsh.r2049.cn';
  @State textScaleValue: number = 1;
  /** 窗口尺寸（vp），PC 上放大窗口时据此调整布局。 */
  @State windowWidthVp: number = 0;
  @State windowHeightVp: number = 0;
  /** 1 vp 等于多少 px（手势给的是 px，translate 收的是 vp）。 */
  private pxPerVp: number = 1;
  /** 当前窗口宽度落在哪个断点（xs/sm/md/lg/xl），布局判断统一走它。 */
  @State breakpoint: Breakpoint = 'sm';
  /** 折叠形态（展开 / 半折 / 折叠）；双折轴三折叠也归一到这三态。 */
  @State foldState: FoldState = 'expanded';
  /** 键盘是否弹起：弹起时收起语境胶囊、收窄列表底部留白。 */
  @State keyboardVisible: boolean = false;
  /** 切换服务器中（与 runtime 同步），用于设备页的即时提示与防重复点击。 */
  @State switchingServer: boolean = false;
  @State switchingTo: string = '';
  /** 提示词面板（本地提示词库）。 */
  @State promptPanelOpen: boolean = false;
  /** 执行轨迹面板：把本次会话里的工具调用按顺序列成时间线。 */
  @State trajectoryOpen: boolean = false;
  /** 新建工作区面板。 */
  @State workspaceCreateOpen: boolean = false;
  /** 文本文件预览面板。 */
  @State filePreviewOpen: boolean = false;
  /** 预览的是不是 PDF（走系统 PDF Kit 渲染）。 */
  @State previewIsPdf: boolean = false;
  /** PDF 全屏连续阅读（0.6.8 对齐）：预览面板铺满整屏。 */
  @State pdfFullscreen: boolean = false;
  @State pdfError: string = '';
  private pdfController: pdfViewManager.PdfController = new pdfViewManager.PdfController();
  /** 消息操作面板（自绘，替代系统 ActionSheet）。 */
  @State messageActionsOpen: boolean = false;
  @State messageActionText: string = '';
  @State messageActionKind: string = '';
  @State messageActionSeq: number = 0;
  /** 被长按那条消息自带的图片（base64），可直接拿来当待发送。 */
  @State messageActionImages: string[] = [];
  @State messageActionTime: number = 0;
  /** 该消息里所有代码块拼起来的内容，空串表示没有代码。 */
  @State messageActionCode: string = '';
  /** 设备详情面板（点 ⋯ 菜单里的「查看详情」打开）。 */
  @State deviceDetailId: string = '';
  /** 会话列表只看收藏。 */
  @State favoriteOnly: boolean = false;
  /** 展开看原文的心跳消息 id（默认折叠成可读正文）。 */
  @State heartbeatExpanded: string[] = [];
  /** 全屏编辑面板（长文写作时用，对齐 Android 的 composer expand）。 */
  @State composerExpanded: boolean = false;
  /** 登录页：密码登录默认收起（有扫码/授权方式时），对齐上游 #335。 */
  @State passwordLoginOpen: boolean = false;
  /** 发送方式面板（长按发送键）。 */
  @State sendModeOpen: boolean = false;
  /** 写作辅助面板（点 ✦）：提示词库 / 全屏编辑。 */
  @State writingMenuOpen: boolean = false;
  /** 归档 / 置顶集合的本地镜像（运行时对象不是可观察的，直接读不会触发重渲染）。 */
  @State archivedIds: string[] = [];
  @State pinnedIds: string[] = [];
  /** 当前会话还有更早历史可翻（同上，运行时字段要镜像）。 */
  @State historyHasMore: boolean = false;
  @State loadingOlderHistory: boolean = false;
  /** 会话抽屉里是否把已归档的会话也列出来。 */
  @State showArchived: boolean = false;
  /** 按工作区过滤会话（存完整 cwd；空 = 全部）。 */
  @State workspaceFilter: string = '';
  /** 会话内搜索（只在当前会话里找）。 */
  @State inSessionSearchOpen: boolean = false;
  @State inSessionQuery: string = '';
  /** 被手工展开的长消息（item.id）。 */
  @State expandedMessages: string[] = [];
  @State workspacePathInput: string = '';
  @State workspaceNameDraft: string = '';
  @State promptDraftInput: string = '';
  /** 上一次同步到的会话 id，用来判断「切了会话」并搬运草稿。 */
  private lastSyncedSessionId: string = '';
  private draftSaveTimer: number = -1;
  /** 每个会话自己的「是否跟随底部」：切走再回来不强行把你拽到底部。 */
  private stickBySession: Record<string, boolean> = {};
  /** 每个会话最后停在的那一行（item.id），切回来据此定位。 */
  private scrollAnchors: Record<string, string> = {};
  private anchorSaveTimer: number = -1;
  @State permissionOptionsList: string[] = [];
  /** 工作区选择。 */
  @State workspaces: HarnessWorkspace[] = [];
  @State selectedWorkspaceId: string = '';
  /** 待选推理等级的模型（null 表示未进入等级选择）。 */
  @State pendingModel: ModelOption | undefined = undefined;
  /** 文件浏览面板。 */
  @State showBrowser: boolean = false;
  @State browsePath: string = '';
  @State directoryEntries: DirectoryEntry[] = [];
  /** 工作区改名。 */
  @State editingWorkspaceId: string = '';
  @State workspaceTitleInput: string = '';

  @State serverInput: string = '';
  @State emailInput: string = '';
  @State passwordInput: string = '';
  /** 两步验证：服务端下发的一次性挑战（非空表示现在要输验证码/恢复码）。 */
  @State passwordChallenge: string = '';
  @State twoFactorCode: string = '';
  private passwordChallengeServer: string = '';
  @State promptInput: string = '';
  @State qrUrl: string = '';
  @State providers: OAuthProvider[] = [];
  @State providerId: string = '';
  private providersRequested: boolean = false;
  @State showSessions: boolean = false;
  /** PC：鼠标悬停在哪一行（会话行/主机卡），用来做 hover 高亮。 */
  @State hoverRowId: string = '';
  /** PC：鼠标停在哪个消息上（气泡旁出快捷操作）。 */
  @State hoverMessageId: string = '';
  /** 分栏分隔条拖动中 / 悬停中。 */
  @State splitDragging: boolean = false;
  @State splitHover: boolean = false;
  private splitDragBase: number = 0;
  /** 竖屏会话抽屉的跟手进度：0 全收起，1 全展开（手势拖动直接改这个值）。 */
  @State drawerOpen: number = 0;
  private drawerCloseTimer: number = -1;
  /** 本次拖动的起点进度，以及它是不是从聊天页发起的（两个地方各有一把手势）。 */
  private drawerDragBase: number = 0;
  private drawerDragFromChat: boolean = false;
  @State topInset: number = 0;
  @State bottomInset: number = 0;
  @State isLandscape: boolean = false;
  @State accountEmail: string = '';
  @State accountServer: string = '';
  @State namePreviewId: string = '';
  @State headerNamePopup: boolean = false;
  /** 顶栏主机名的切换面板。 */
  @State hostSwitcherOpen: boolean = false;
  /** Git 审查面板：改动清单 + 单个文件 diff + 勾选回传。 */
  @State gitOpen: boolean = false;
  /** 输入框是否聚焦：决定那条柔光亮不亮。 */
  @State inputFocused: boolean = false;
  /** 桌宠拖动：长按后可拖到任意位置，松手弹回坞上方。 */
  @State petDragX: number = 0;
  @State petDragY: number = 0;
  @State petDragging: boolean = false;
  /** 长按已授权拖动（松手后清掉，下一轮要重新长按）。 */
  @State petArmed: boolean = false;
  @State gitLoading: boolean = false;
  @State gitError: string = '';
  @State gitBranch: string = '';
  @State gitSummary: string = '';
  @State gitDiffPath: string = '';
  @State gitDiffText: string = '';
  @State gitDiffError: string = '';
  private gitFiles: WorkspaceGitFile[] = [];
  private gitSelected: string[] = [];
  @State themeMode: number = 0;
  @State languageMode: number = 0;
  @State isDarkUi: boolean = false;
  @State showSettings: boolean = false;
  /** 是否跟随最新消息；用户往上翻时置 false，避免流式输出把列表一直拽到底。 */
  @State stickToBottom: boolean = true;
  private searchDebounceTimer: number = -1;
  /** 上一次强制贴底的会话 id，用于区分「刚切进来」还是「流式更新」。 */
  private lastScrolledSessionId: string = '';
  /** chatRows 缓存：流式输出时每帧全量重算太贵。 */
  private chatRowsKey: string = '';
  private chatRowsCache: ChatItem[] = [];
  /** 图片全屏预览：src、缩放与平移。 */
  @State previewSrc: string = '';
  @State previewActive: boolean = false;
  @State previewScale: number = 1;
  @State previewOffsetX: number = 0;
  @State previewOffsetY: number = 0;
  /** 双指缩放/拖动的手势起点：不记起点就会按「累计位移」反复叠加，图片直接飘出屏幕。 */
  private previewScaleStart: number = 1;
  private previewPanStartX: number = 0;
  private previewPanStartY: number = 0;
  /** 输入坞上跟随手指/鼠标的光斑位置与强度。 */
  @State dockLightX: number = 0;
  @State dockLightY: number = 0;
  @State dockLightOpacity: number = 0;
  /** 列表下方陪伴小人的呼吸状态（由定时器来回切）。 */
  @State maidBob: boolean = false;
  private maidTimer: number = -1;
  /** 有待确认交互时每 15 秒跳一次，用来刷新卡片上的「已等待 N 分钟」。 */
  private waitTimer: number = -1;
  @State private waitTick: number = 0;
  /** 一键自检的结果行（空表示还没跑过）。 */
  @State private selfCheckLines: string[] = [];
  private dockLightHideTimer: number = -1;
  /** 录音已停止、等主机转写。 */
  /** 被手动展开的连续工具调用段（键是段首工具的 id）。 */
  @State expandedRuns: string[] = [];
  /** 哪些消息的「思考」被展开（默认折叠成两行）。 */
  @State expandedReasoning: string[] = [];
  /** 列表里被折叠的工作区分组（存组标题）。 */
  @State collapsedWorkspaces: string[] = [];
  /** 「最近」入口是否展开（默认收起，不再常驻占一行）。 */
  @State recentOpen: boolean = false;
  /** 终端浮层：输出缓冲 + 可否输入 + 运行状态。 */
  @State terminalOpen: boolean = false;
  @State terminalText: string = '';
  @State terminalWritable: boolean = false;
  @State terminalRunning: boolean = false;
  @State terminalBusy: boolean = false;
  @State terminalTitle: string = '';
  @State terminalInput: string = '';
  /** xterm 视图是否就绪；就绪前的输出先攒着。 */
  private terminalReady: boolean = false;
  private terminalPending: string[] = [];
  private terminalController: webview.WebviewController = new webview.WebviewController();
  /** 应用内 Web 控制台：直接开宿主机上的 dsh web（网页版），地址填一次记住。 */
  /** 图片键的小菜单：相册 / 拍照（挤在一起就别再加按钮了）。 */
  @State imageMenuOpen: boolean = false;
  /** 附近在线设备名：有才显示「用附近设备拍照」那一行。 */
  @State nearbyDevices: string[] = [];
  /** 跨设备取图（服务协同）的进度文案。 */
  @State collabMsg: string = '';
  @State webConsoleOpen: boolean = false;
  @State webConsoleSrc: string = '';
  @State webConsoleInput: string = '';
  @State webConsoleLoading: boolean = false;
  @State webConsoleError: string = '';
  private webConsoleController: webview.WebviewController = new webview.WebviewController();
  private terminalBridge: TerminalBridge = new TerminalBridge();
  /** 主机插件清单浮层。 */
  @State pluginsOpen: boolean = false;
  @State pluginsLoading: boolean = false;
  @State pluginsError: string = '';
  @State pluginsRev: number = 0;
  private hostPlugins: HostPluginBundle[] = [];
  /** 正在编辑的插件设置表单。 */
  @State pluginFormOpen: boolean = false;
  @State pluginFormTitle: string = '';
  @State pluginFormFields: PluginSettingField[] = [];
  @State pluginFormEditing: string = '';
  @State pluginFormDraft: string = '';
  private pluginFormNamespace: string = '';
  private pluginFormRevision: number = 0;
  /** DS-Bot 目录（机器人 + 群组）。 */
  @State botsOpen: boolean = false;
  @State botsLoading: boolean = false;
  @State botsError: string = '';
  private bots: BotCatalogRow[] = [];
  private windowChromeDark: boolean = false;
  private chromeApplied: boolean = false;

  aboutToAppear(): void {
    this.runtime.onUiUpdate = () => {
      this.syncFromRuntime();
    };
    // 把隐藏 Web 里的 WebRTC 桥交给运行时：连接时若它已就绪就走 LAN 直连，否则走中继
    this.runtime.attachRtcBridge(this.rtc);
    this.watchFoldStatus();
    // 键盘避让用 resize：pan 会把整个页面往上推，顶栏整条被顶出屏幕
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.runtime.bootstrap(getContext(this));
    // 陪伴小人：每 2 秒翻身一次，配合 .animation 就是来回呼吸
    this.maidTimer = setInterval(() => {
      this.maidBob = !this.maidBob;
    }, 2000);
    // 桌宠精灵图：素材（dsh-go 的 whale-girl 包）只在本机存在，缺省时自动回退到 emoji
    this.petSleepTimer = setInterval(() => {
      if (this.runtime.petState() === 'idle' && this.petIdleSince > 0
        && Date.now() - this.petIdleSince > 180000) {
        this.restartPetAnimation();
      }
    }, 30000);
    PetPack.load(getContext(this)).then(() => {
      this.restartPetAnimation();
    }).catch(() => undefined);
  }

  aboutToDisappear(): void {
    if (this.waitTimer >= 0) {
      clearInterval(this.waitTimer);
      this.waitTimer = -1;
    }
    if (this.petSleepTimer >= 0) {
      clearInterval(this.petSleepTimer);
      this.petSleepTimer = -1;
    }
    this.stopPetAnimation();
    if (this.maidTimer >= 0) {
      clearInterval(this.maidTimer);
      this.maidTimer = -1;
    }
    if (this.mainWindow !== undefined) {
      this.mainWindow.off('avoidAreaChange');
      this.mainWindow.off('windowSizeChange');
    }
  }

  /**
   * 折叠屏适配：监听折叠状态。
   * 折叠屏展开/折叠时窗口尺寸本来就会变化，断点会跟着更新；这里额外订阅状态，
   * 一是为了在状态切换的瞬间就把断点刷新，二是留一个展开态标记给后续布局用。
   */
  private watchFoldStatus(): void {
    try {
      this.foldState = foldStateOf(display.getFoldStatus());
      display.on('foldStatusChange', (status: display.FoldStatus) => {
        this.foldState = foldStateOf(status);
        this.breakpoint = breakpointOf(this.windowWidthVp);
      });
      // 主屏/副屏/协同显示切换会换一套窗口尺寸，断点也要重算
      display.on('foldDisplayModeChange', (mode: display.FoldDisplayMode) => {
        this.breakpoint = breakpointOf(this.windowWidthVp);
      });
    } catch (error) {
      // 非折叠设备没有该能力，按完全展开处理
      this.foldState = 'expanded';
    }
  }

  /**
   * 系统返回（左右边缘内滑 / 返回键）。
   * 顺序：先关浮层 → 会话页回到主机列表（连接保留）→ 连接中取消 → 其余交给系统。
   * 返回 true 表示已处理，不会退出应用。
   */
  onBackPress(): boolean {
    if (this.imageMenuOpen) {
      this.imageMenuOpen = false;
      return true;
    }
    if (this.previewActive) {
      this.previewActive = false;
      return true;
    }
    if (this.messageActionsOpen) {
      this.messageActionsOpen = false;
      return true;
    }
    if (this.promptPanelOpen) {
      this.promptPanelOpen = false;
      return true;
    }
    if (this.trajectoryOpen) {
      this.trajectoryOpen = false;
      return true;
    }
    if (this.filePreviewOpen) {
      this.filePreviewOpen = false;
      return true;
    }
    if (this.writingMenuOpen) {
      this.writingMenuOpen = false;
      return true;
    }
    if (this.sendModeOpen) {
      this.sendModeOpen = false;
      return true;
    }
    if (this.schedulesOpen) {
      this.schedulesOpen = false;
      return true;
    }
    if (this.tintPickerOpen) {
      this.tintPickerOpen = false;
      return true;
    }
    if (this.linkDetailOpen) {
      this.linkDetailOpen = false;
      return true;
    }
    if (this.diagnosticsOpen) {
      this.diagnosticsOpen = false;
      return true;
    }
    if (this.composerExpanded) {
      this.composerExpanded = false;
      return true;
    }
    if (this.workspaceCreateOpen) {
      this.workspaceCreateOpen = false;
      return true;
    }
    if (this.choiceOpen) {
      this.choiceOpen = false;
      return true;
    }
    if (this.showServerSwitch || this.showMoreMenu || this.showModelPicker
      || this.showSessionPanel || this.showBrowser || this.showSettings) {
      this.showServerSwitch = false;
      this.showMoreMenu = false;
      this.showModelPicker = false;
      this.showSessionPanel = false;
      this.showBrowser = false;
      this.showSettings = false;
      return true;
    }
    if (this.showSessions) {
      this.closeDrawer();
      return true;
    }
    if (this.phase === PHASE_CHAT) {
      // 会话页 → 主机列表，连接保持不断（和左上角箭头同一个行为）
      this.runtime.keepAliveToDevices();
      return true;
    }
    if (this.phase === PHASE_CONNECTING) {
      this.runtime.cancelConnect();
      return true;
    }
    return false;
  }

  onPageShow(): void {
    // 回前台：补查网络状态并做一次链路体检（后台待久了 socket 往往是半开的）。
    // 原来这里只把 appBackground 置回 false，连接死没死全靠用户发消息才知道。
    LinkLog.write('life', '页面回到前台');
    this.runtime.onAppForeground();
    this.runtime.appBackground = false;
  }

  onPageHide(): void {
    // 留痕：窗口被收起/切走时记一条，排查「点了什么就没了」有据可查
    LinkLog.write('life', '页面转到后台');
    this.runtime.appBackground = true;
    this.runtime.refreshCapsule();
  }

  private measureInsets(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.mainWindow = win;
      // 2in1/PC：设个最小窗口尺寸（官方建议自由窗口应用给出可用下限，别让人拖成一条缝）
      win.setWindowLimits({ minWidth: 480, minHeight: 520 }).catch(() => undefined);
      // 沉浸式布局：页面铺到状态栏/导航条下面，避让交给 applyInsets 的 padding。
      // 不开这个，expandSafeArea 不会真的延伸到系统栏区域，底部就会多出一条导航条留白。
      win.setWindowLayoutFullScreen(true).catch(() => {
      });
      this.applyInsets(win);
      win.on('avoidAreaChange', () => {
        this.applyInsets(win);
      });
      win.on('windowSizeChange', (size: window.Size) => {
        this.applyWindowSize(size);
      });
      win.on('keyboardHeightChange', (height: number) => {
        const shown: boolean = height > 0;
        if (shown === this.keyboardVisible) {
          return;
        }
        this.keyboardVisible = shown;
        // 键盘把可视区压矮后，列表要跟着滚到底，内容整体上移，而不是被输入坞压住
        if (this.stickToBottom) {
          setTimeout(() => {
            this.scrollChatToBottom();
          }, 80);
        }
      });
    }).catch(() => {
      this.topInset = 0;
      this.bottomInset = 0;
    });
  }

  private applyInsets(win: window.Window): void {
    const ui: UIContext = this.getUIContext();
    // 2in1 全屏时系统状态栏高度是 0，但窗口自己那条标题栏还在，内容会顶到它下面被挡住，
    // 所以取「系统栏高度」和「窗口装饰高度」里大的那个当顶部安全区。
    let decorPx: number = 0;
    try {
      decorPx = win.getWindowDecorHeight();
    } catch (error) {
      decorPx = 0;
    }
    const systemTopPx: number = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
    const topPx: number = Math.max(systemTopPx, decorPx > 0 ? decorPx + 24 : 0);
    const bottomPx: number = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
    this.topInset = ui.px2vp(topPx);
    this.bottomInset = ui.px2vp(bottomPx);
    const rect: window.Rect = win.getWindowProperties().windowRect;
    this.isLandscape = rect.width > rect.height;
    this.windowWidthVp = ui.px2vp(rect.width);
    this.windowHeightVp = ui.px2vp(rect.height);
    this.pxPerVp = this.windowWidthVp > 0 ? rect.width / this.windowWidthVp : 1;
    this.breakpoint = breakpointOf(this.windowWidthVp);
  }

  private applyWindowSize(size: window.Size): void {
    const ui: UIContext = this.getUIContext();
    this.windowWidthVp = ui.px2vp(size.width);
    this.windowHeightVp = ui.px2vp(size.height);
    this.isLandscape = size.width > size.height;
    this.breakpoint = breakpointOf(this.windowWidthVp);
  }

  /** Build identity shown in the UI, so an installed APK can be matched to a source revision. */
  private buildTag(): string {
    return `v${BuildProfile.VERSION_NAME} (${BuildProfile.VERSION_CODE}) · ${BuildProfile.BUILD_MODE_NAME}`;
  }

  /** Copy the authorization link, so a long URL never has to be read off the screen. */
  private copyAuthorizeLink(): void {
    const url: string = this.qrUrl;
    if (url.length === 0) {
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: this.tr('授权链接已复制') });
    }).catch(() => {
      promptAction.showToast({ message: this.tr('复制失败，可长按链接手动复制') });
    });
  }

  /** Open the authorization link in the system browser (the page that is already signed in). */
  private openAuthorizeLink(): void {
    const url: string = this.qrUrl;
    if (url.length === 0) {
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    context.openLink(url).catch(() => {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      context.startAbility(want).catch(() => {
      });
    });
  }

  /** 用系统浏览器打开一个地址（Web 控制台兜底用）。 */
  private openInBrowser(url: string): void {
    if (url.length === 0) {
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    context.openLink(url).catch(() => {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      context.startAbility(want).catch(() => {
        promptAction.showToast({ message: this.tr('没有可用的浏览器') });
      });
    });
  }

  /** 只有存在待确认交互时才需要每 15 秒刷新一次等待时长，平时不空转。 */
  private syncWaitTimer(): void {
    const pending: number = this.runtime.pendingInteractionCount();
    if (pending > 0 && this.waitTimer < 0) {
      this.waitTimer = setInterval(() => {
        this.waitTick += 1;
      }, 15000);
    } else if (pending === 0 && this.waitTimer >= 0) {
      clearInterval(this.waitTimer);
      this.waitTimer = -1;
      // 收尾时再跳一次，让最后一张卡回到「无待确认」的样子
      this.waitTick += 1;
    }
  }

  private syncFromRuntime(): void {
    this.syncWaitTimer();
    // 从通知点进来的话，运行时里存着要打开的会话；等界面同步完再切，避免和 follow 抢
    const wanted: string = this.runtime.consumePendingOpenSession();
    if (wanted.length > 0 && wanted !== this.currentSessionId) {
      this.runtime.openSession(wanted).catch(() => undefined);
    }
    this.uiShowInspector = this.runtime.showInspector;
    this.uiPetEnabled = this.runtime.petEnabled;
    this.uiHomeMascot = this.runtime.homeMascotEnabled;
    this.uiThemeTint = this.runtime.themeTint;
    this.uiCompactHistory = this.runtime.compactHistory;
    this.uiSecretMask = this.runtime.secretMask;
    this.uiNotifications = this.runtime.notificationsEnabled;
    this.uiSplitWidth = this.runtime.splitWidth;
    this.wallpaper = this.runtime.wallpaper;
    this.uiWallpaperDim = this.runtime.wallpaperDim;
    if (this.runtime.petState() === 'idle') {
      if (this.petIdleSince === 0) {
        this.petIdleSince = Date.now();
      }
    } else {
      this.petIdleSince = 0;
    }
    this.restartPetAnimation();
    this.phase = this.runtime.phase;
    this.busy = this.runtime.busy;
    this.busyAction = this.runtime.busyAction;
    this.errorMsg = this.runtime.errorMsg;
    this.devices = this.runtime.devices.slice();
    this.sessions = this.runtime.sessions.slice();
    this.sessionsLoadFailed = this.runtime.sessionsLoadFailed;
    this.archivedIds = this.runtime.archivedSessionIds.slice();
    this.pinnedIds = this.runtime.pinnedSessionIds.slice();
    this.historyHasMore = this.runtime.historyHasMore;
    this.loadingOlderHistory = this.runtime.loadingOlderHistory;
    this.messages = this.runtime.messages.slice();
    this.generating = this.runtime.generating;
    this.currentSessionId = this.runtime.currentSessionId;
    this.currentSessionTitle = this.runtime.currentSessionTitle;
    this.infoMsg = '';
    this.contextPercent = this.runtime.contextPercent;
    this.connectedTransport = this.runtime.transportLabel;
    this.connectStage = this.runtime.connectStage;
    // 重连文案原来只用于给状态点染色，用户看不到「几秒后重连第几次」。
    this.reconnectNotice = this.runtime.reconnectStatus;
    this.reconnecting = this.runtime.reconnecting;
    this.networkOnline = this.runtime.networkOnline;
    if (this.phase === PHASE_CONNECTING) {
      if (this.connectStartAt === 0) {
        this.connectStartAt = Date.now();
        this.connectElapsedSec = 0;
        this.connectTickTimer = setInterval(() => {
          this.connectElapsedSec = Math.max(0, Math.round((Date.now() - this.connectStartAt) / 1000));
        }, 1000);
      }
    } else if (this.connectStartAt !== 0) {
      this.connectStartAt = 0;
      if (this.connectTickTimer >= 0) {
        clearInterval(this.connectTickTimer);
        this.connectTickTimer = -1;
      }
    }
    this.slashCommands = this.runtime.slashCommands;
    this.modelOptions = this.runtime.modelOptions;
    this.currentModelLabel = this.runtime.currentModelLabel;
    this.currentModelProvider = this.runtime.currentModelProvider;
    this.currentModelEffort = this.runtime.currentModelEffort;
    this.textScaleMode = this.runtime.textScaleMode;
    this.profilesList = this.runtime.profiles.slice();
    this.textScaleValue = this.runtime.textScale();
    this.permissionPreset = this.runtime.permissionPreset;
    this.permissionOptionsList = this.runtime.permissionOptions.slice();
    this.workspaces = this.runtime.workspaces;
    this.selectedWorkspaceId = this.runtime.selectedWorkspaceId;
    this.browsePath = this.runtime.browsePath;
    this.directoryEntries = this.runtime.directoryEntries;
    if (this.sessionSearchActive) {
      const found: HarnessRemoteSession[] | undefined = this.runtime.searchResults;
      this.sessionSearchResults = found !== undefined ? found : [];
    }
    // 切了会话：先把上一段草稿存回去，再把新会话的草稿捞出来
    if (this.lastSyncedSessionId !== this.currentSessionId) {
      if (this.lastSyncedSessionId.length > 0) {
        this.runtime.saveDraft(this.lastSyncedSessionId, this.promptInput);
        this.stickBySession[this.lastSyncedSessionId] = this.stickToBottom;
      }
      this.lastSyncedSessionId = this.currentSessionId;
      this.promptInput = this.runtime.draftOf(this.currentSessionId);
      const restored: boolean | undefined = this.stickBySession[this.currentSessionId];
      this.stickToBottom = restored === undefined ? true : restored;
      if (!this.stickToBottom) {
        const anchorId: string | undefined = this.scrollAnchors[this.currentSessionId];
        if (anchorId !== undefined) {
          // 消息还没渲染完，稍等一下再定位，必要时补一次
          setTimeout(() => {
            this.scrollToMessage(anchorId);
          }, 260);
          setTimeout(() => {
            if (!this.stickToBottom) {
              this.scrollToMessage(anchorId);
            }
          }, 700);
        }
      }
    }
    this.switchingServer = this.runtime.switchingServer;
    this.switchingTo = this.runtime.switchingTo;
    this.connectedHostName = this.runtime.connectedHostName;
    this.connectedDeviceId = this.runtime.connectedDeviceId;
    this.deviceAliases = this.runtime.deviceAliases;
    this.accountEmail = this.runtime.email;
    this.accountServer = this.runtime.serverUrl;
    this.themeMode = this.runtime.themeMode;
    this.languageMode = this.runtime.languageMode;
    this.isDarkUi = this.runtime.isDark();
    this.isLandscape = this.runtime.systemLandscape;
    this.syncWindowChrome();
    this.qrUrl = this.runtime.qrUrl;
    this.providers = this.runtime.providers.slice();
    this.providerId = this.runtime.providerId;
    if (this.phase === PHASE_SETUP && !this.providersRequested) {
      this.providersRequested = true;
      this.runtime.loadProviders(this.serverInput);
    }
    if (!this.fieldsPrefilled) {
      // Prefill the official public Server so a fresh install never dials an empty or dead address.
      this.serverInput = this.runtime.serverUrl.length > 0 ? this.runtime.serverUrl : DEFAULT_SERVER_URL;
      this.emailInput = this.runtime.email.length > 0 ? this.runtime.email : DEFAULT_ACCOUNT;
      this.fieldsPrefilled = true;
    }
    if (this.phase === PHASE_CHAT) {
      // 切换/首次进入会话时强制贴底一次：否则 stickToBottom 在首帧测量里可能被判成 false，
      // 列表会停在历史中间，看不到最新消息。
      if (this.currentSessionId !== this.lastScrolledSessionId) {
        this.lastScrolledSessionId = this.currentSessionId;
        this.stickToBottom = true;
        setTimeout(() => {
          this.scrollChatToBottom();
          setTimeout(() => {
            this.scrollChatToBottom();
          }, 300);
        }, 120);
      } else {
        setTimeout(() => {
          this.scrollChatToBottom();
        }, 100);
      }
    }
  }

  private scrollChatToBottom(): void {
    if (this.messages.length === 0 || !this.stickToBottom) {
      return;
    }
    // scrollEdge 比 scrollToIndex 稳：列表项高度不定时 scrollToIndex 偶尔不动
    try {
      this.scroller.scrollEdge(Edge.Bottom);
    } catch (error) {
      this.scroller.scrollToIndex(this.messages.length - 1, false);
    }
  }

  /** 优先走系统分享面板；不可用就复制到剪贴板。 */
  private shareText(text: string): void {
    if (text.trim().length === 0) {
      return;
    }
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const data = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content: text
      });
      const controller = new systemShare.ShareController(data);
      controller.show(context, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      }).catch(() => {
        this.copyToClipboard(text);
      });
      return;
    } catch (error) {
      this.copyToClipboard(text);
    }
  }

  private copyToClipboard(text: string): void {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: this.tr('分享内容已复制') });
    }).catch(() => undefined);
  }

  /** 列表里第一个消息项的下标（上面可能还有一个「加载更早」的行）。 */
  private chatItemOffset(): number {
    return this.historyHasMore || this.loadingOlderHistory ? 1 : 0;
  }

  /** 跳到上/下一个用户消息（轮次）；没有更多就提示。 */
  private jumpTurn(delta: number): void {
    const turns: number[] = this.runtime.userTurnIndexes();
    if (turns.length === 0) {
      return;
    }
    const current: number = this.runtime.currentTurnPosition(Math.max(0, this.turnPosition - 1));
    let target: number = Math.min(turns.length, Math.max(1, (current === 0 ? turns.length : current) + delta));
    this.turnPosition = target;
    try {
      this.scroller.scrollToIndex(this.chatItemOffset() + turns[target - 1], true);
    } catch (error) {
      this.scroller.scrollEdge(Edge.Top);
    }
  }

  /** 轮次导航胶囊上的文字：`3/9 · 12 步 · 1m20s`。 */
  private turnPillText(): string {
    const turns: number[] = this.runtime.userTurnIndexes();
    if (turns.length === 0) {
      return '';
    }
    const position: number = Math.min(turns.length, Math.max(1, this.turnPosition));
    const summary: string = this.runtime.lastTurnSummary;
    return position + '/' + turns.length + (summary.length > 0 ? ' · ' + summary : '');
  }

  /** 选文件 → 上传拿回执 → 挂到待发列表（失败要说清楚，不能静默丢掉）。 */
  private attachFile(): Promise<void> {
    if (this.pickingFile) {
      return Promise.resolve();
    }
    this.pickingFile = true;
    return pickFiles(1).then((files: PickedFile[]) => {
      this.pickingFile = false;
      if (files.length === 0) {
        return;
      }
      const file: PickedFile = files[0];
      if (file.bytes > MAX_FILE_BYTES) {
        promptAction.showToast({ message: this.tr('文件超过 2.6MB，暂时发不了') });
        return;
      }
      this.runtime.uploadFile(file).then((part: PromptFilePart) => {
        this.pendingFiles = this.pendingFiles.concat([part]);
      }).catch((error: Error) => {
        this.errorMsg = this.tr('文件上传失败：') + error.message;
        promptAction.showToast({ message: this.tr('文件上传失败') });
      });
    }).catch(() => {
      this.pickingFile = false;
    });
  }

  /** 待发文件总大小（只算上传成功的，0 表示未知）。 */
  private pendingFilesTotalBytes(): number {
    let total: number = 0;
    for (const file of this.pendingFiles) {
      total += file.bytes;
    }
    return total;
  }

  private removePendingFile(index: number): void {
    const next: PromptFilePart[] = this.pendingFiles.slice();
    next.splice(index, 1);
    this.pendingFiles = next;
  }

  /**
   * 回车键上有没有按 Ctrl / ⌘。
   * getModifierKeyState 在部分 2in1 版本会抛异常，绝不能让它把异常扔回 ArkUI 的事件分发，
   * 所以这里单独包一层；取不到就当作没按修饰键（退化成普通换行，不会误发消息）。
   */
  private modifierPressed(event: KeyEvent, name: string): boolean {
    try {
      const probe: ((keys: Array<string>) => boolean) | undefined = event.getModifierKeyState;
      return probe === undefined ? false : probe([name]);
    } catch (error) {
      LinkLog.write('key', '修饰键读取失败：' + errorMessage(error));
      return false;
    }
  }

  private ctrlEnterPressed(event: KeyEvent): boolean {
    return this.modifierPressed(event, 'Ctrl') || this.modifierPressed(event, 'Meta');
  }

  /**
   * 回车是不是「发送」：
   * - 手机：回车就是换行（屏幕小，误发代价高），发送靠右下角那颗键；
   * - PC/2in1：回车上屏（Enter 发送、Shift+Enter 换行），这是桌面聊天软件的通用约定。
   *   原来绑的 Ctrl+Enter 在鸿蒙 PC 上会被输入法吃掉，实测根本收不到。
   */
  private enterSends(): boolean {
    return !isPhoneDevice();
  }

  private sendTap(): void {
    if (this.reconnecting) {
      promptAction.showToast({ message: this.tr('正在重连，连上后再发') });
      return;
    }
    const text: string = this.promptInput;
    const picked: PickedImage[] = this.pendingImages;
    const files: PromptFilePart[] = this.pendingFiles;
    if (text.trim().length === 0 && picked.length === 0 && files.length === 0) {
      return;
    }
    this.promptInput = '';
    this.pendingImages = [];
    this.pendingFiles = [];
    const parts: PromptImagePart[] = [];
    for (const image of picked) {
      const part: PromptImagePart = new PromptImagePart();
      part.mediaType = image.mediaType;
      part.base64 = image.base64;
      part.name = image.name;
      parts.push(part);
    }
    // 发出去就把草稿清掉：onChange 不会因为代码里清空而触发，不清的话切回来还是这段文字
    this.runtime.saveDraft(this.currentSessionId, '');
    const fileNames: string[] = [];
    for (const file of files) {
      fileNames.push(file.name);
    }
    this.runtime.sendPrompt(text, parts, files, fileNames);
    // 发送后输入框会从多行缩回单行、坞跟着变矮。必须等这一帧布局落定再滚，
    // 否则滚动是按旧高度算的，收回去之后新消息就矮到坞后面去了。
    this.stickToBottom = true;
    setTimeout(() => {
      this.scrollChatToBottom();
    }, 80);
    setTimeout(() => {
      if (this.stickToBottom) {
        this.scrollChatToBottom();
      }
    }, 240);
  }

  /** 从剪贴板取图：有图片就压一下挂到待发送区，没有就什么也不做。 */
  private pasteImageFromClipboard(): void {
    try {
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      board.getData().then((data: pasteboard.PasteData) => {
        if (!data.hasType(pasteboard.MIMETYPE_PIXELMAP)) {
          return;
        }
        const pixel: image.PixelMap = data.getPrimaryPixelMap();
        compressPixelMap(pixel).then((picked: PickedImage) => {
          this.pendingImages = this.pendingImages.concat([picked]);
          promptAction.showToast({ message: this.tr('已粘贴图片') });
        }).catch(() => undefined);
      }).catch(() => undefined);
    } catch (error) {
      // 剪贴板不可用就算了，不打断输入
    }
  }

  /** 从系统相册选图；选完先压再进待发队列。 */
  private attachImage(): Promise<void> {
    if (this.pickingImages) {
      return Promise.resolve();
    }
    this.pickingImages = true;
    const pick = pickImages(4);
    return pick.then((picked: PickedImage[]) => {
      this.pickingImages = false;
      if (picked.length === 0) {
        return;
      }
      // 预检：单张 base64 超过 3.5MB 就会顶到协议单条上限，直接挡下来并说明原因
      const limit: number = 3500000;
      const accepted: PickedImage[] = [];
      let rejected: number = 0;
      for (const image of picked) {
        if (image.base64.length > limit) {
          rejected++;
        } else {
          accepted.push(image);
        }
      }
      if (rejected > 0) {
        promptAction.showToast({
          message: this.tr('有 ') + rejected + this.tr(' 张图片过大已跳过（单张上限约 3.5MB）')
        });
      }
      if (accepted.length > 0) {
        this.pendingImages = this.pendingImages.concat(accepted);
      }
    }).catch((error: Error) => {
      this.pickingImages = false;
      this.errorMsg = this.tr('图片读取失败：') + error.message;
    });
  }

  /**
   * 图片键点一下先问「相册 / 拍照」，不占第二个按钮的位置。
   * 拍照走系统相机：有摄像头的设备（包括 PC）直接拍，2in1 上系统还可以借附近手机的摄像头。
   */
  private chooseImageSource(): void {
    if (this.pickingImages) {
      return;
    }
    this.imageMenuOpen = true;
    this.refreshNearbyDevices();
  }

  /** 查一次附近设备（首次会弹权限）；拿不到就悄悄不显示那一行。 */
  private refreshNearbyDevices(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    CrossDevice.nearbyNames(context).then((names: string[]) => {
      this.nearbyDevices = names;
    }).catch(() => {
      this.nearbyDevices = [];
    });
  }

  /** 系统「服务协同」菜单：列出附近可用的华为设备，并给出拍照 / 扫描 / 相册三种能力。 */
  @Builder
  CollabMenu() {
    Menu() {
      // 方向有区别：PC 发起时可以点名要手机的「拍照 / 文档扫描 / 相册」；
      // 手机反向往 PC 要，2in1 侧没有能响应拍照/扫描的相机服务，
      // 只剩「图片（相册）」这一种能落到 PC 的图库上。
      if (isPhoneDevice()) {
        createCollaborationServiceMenuItems([
          CollaborationServiceFilter.IMAGE_PICKER
        ], 9)
      } else {
        createCollaborationServiceMenuItems([
          CollaborationServiceFilter.TAKE_PHOTO,
          CollaborationServiceFilter.SCAN_DOCUMENT,
          CollaborationServiceFilter.IMAGE_PICKER
        ], 9)
      }
    }
    .width(280)
  }

  /**
   * 协同回传：对端（手机）拍完/选完，图片字节从这里进来。
   * 状态码见 CrossDeviceCapture 的注释。
   */
  private onCollabState(stateCode: number, bufferType: string, buffer: ArrayBuffer): void {
    const size: number = buffer === undefined ? 0 : buffer.byteLength;
    LinkLog.write('collab', 'state=' + stateCode + ' type=' + bufferType + ' bytes=' + size);
    if (stateCode === 1001202004) {
      CrossDeviceCapture.reset();
      this.collabMsg = this.tr('已在其它设备上开始，请在那台设备拍照/选图…');
      return;
    }
    if (stateCode === 1001202006) {
      this.collabMsg = this.tr('正在回传…');
      return;
    }
    if (stateCode === 0 && size > 0) {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      CrossDeviceCapture.accept(buffer, context.filesDir).then((picked: PickedImage | undefined) => {
        if (picked === undefined) {
          this.collabMsg = this.tr('接收中…（数据还不完整）');
          return;
        }
        this.pendingImages = this.pendingImages.concat([picked]);
        this.collabMsg = '';
        this.imageMenuOpen = false;
        promptAction.showToast({ message: this.tr('已从其它设备取到图片') });
      }).catch(() => {
        this.collabMsg = this.tr('取图失败');
      });
      return;
    }
    if (stateCode === 1001202001 || stateCode === 1001202003) {
      CrossDeviceCapture.reset();
      this.collabMsg = this.tr('已取消');
      return;
    }
    if (stateCode !== 0 && stateCode !== 1001202005) {
      this.collabMsg = this.tr('取图失败（') + stateCode + '）';
    }
  }

  /** 图片键弹出的小菜单（自绘，和别的弹层同一套磨砂）。 */
  @Builder
  ImageSourceSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.imageMenuOpen = false;
        })
      Scroll() {
      Column({ space: 8 }) {
        Text(this.tr('添加图片'))
          .fontSize(this.fs(12))
          .fontColor(this.pal().text3)
          .width('100%')
          .padding({ left: 4, bottom: 2 })
        this.SettingsRow(this.tr('从相册选'), '', false, () => {
          this.imageMenuOpen = false;
          this.attachImage();
        })
        this.SettingsRow(this.tr('拍照'), this.pcHasCameraHint(), false, () => {
          this.imageMenuOpen = false;
          this.capturePhoto();
        })
        // 小窗（悬浮窗/横屏分屏）里行再多也放得下：超出的部分由外层高度封顶挡住
        // 跨设备取图：走系统的「服务协同」（WPS 那条链路）。
        // 手机上系统菜单弹不出来（只闪一个白点），所以只在 PC/平板上显示这一项；
        // 手机要从 PC 拿图，走「PC 把图发到会话 → 手机长按那张图 → 图片加入待发送」。
        if (!isPhoneDevice()) {
          Button() {
            Row({ space: 10 }) {
              Text(this.tr('从其他设备获取'))
                .fontSize(14)
                .fontColor(this.pal().text)
              Blank()
              Text(this.collabMsg.length > 0
                ? this.collabMsg
                : (this.nearbyDevices.length > 0
                  ? this.nearbyDevices.join('、')
                  : this.tr('拍照 / 扫描 / 相册')))
                .fontSize(11)
                .fontColor(this.collabMsg.length > 0 ? '#22D3EE' : this.pal().text3)
                .maxLines(1)
                .constraintSize({ maxWidth: 200 })
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('›')
                .fontSize(15)
                .fontColor(this.pal().text3)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 14, right: 14 })
          .backgroundColor(this.pal().card)
          .borderRadius(12)
          .border({ width: 1, color: this.pal().border })
          .bindMenu(this.CollabMenu)
        }
        Text(this.tr('取消'))
          .fontSize(14)
          .fontColor(this.pal().text2)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 13, bottom: 13 })
          .backgroundColor(this.pal().card)
          .borderRadius(12)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            this.imageMenuOpen = false;
          })
      }
      .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .constraintSize({
        maxWidth: 520,
        maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.72 : 520
      })
      .padding({
        left: this.compactDock() ? 12 : 16,
        right: this.compactDock() ? 12 : 16,
        top: 12,
        bottom: (this.compactDock() ? 12 : 18) + this.bottomSafePadding()
      })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 })
      .border({ width: 1, color: this.pal().border })
    }
    .width('100%')
    .height('100%')
  }

  /** 拍照那行的小字：PC 有自己的摄像头就用本机，否则系统会找附近设备。 */
  private pcHasCameraHint(): string {
    return isPhoneDevice() ? this.tr('系统相机') : this.tr('本机摄像头 · 也可用附近设备');
  }

  /** 拍照（系统相机；有摄像头的设备直接拍，2in1 上由系统决定是否借用附近手机的摄像头）。 */
  private capturePhoto(): Promise<void> {
    if (this.pickingImages) {
      return Promise.resolve();
    }
    this.pickingImages = true;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    return captureImage(context).then((picked: PickedImage | undefined) => {
      this.pickingImages = false;
      if (picked === undefined) {
        return;
      }
      this.pendingImages = this.pendingImages.concat([picked]);
    }).catch((error: Error) => {
      this.pickingImages = false;
      promptAction.showToast({ message: this.tr('拍照失败：') + error.message });
    });
  }

  private removePendingImage(index: number): void {
    const next: PickedImage[] = this.pendingImages.slice();
    next.splice(index, 1);
    this.pendingImages = next;
  }

  /** Display name of a host device: user alias wins over the server-registered name. */
  private displayNameFor(device: RemoteHostDevice): string {
    const alias: string | undefined = this.deviceAliases[device.deviceId];
    if (alias !== undefined && alias.length > 0) {
      return alias;
    }
    return device.name;
  }

  /** Display name of the connected host shown in the chat header. */
  private connectedHostDisplay(): string {
    const id: string = this.connectedDeviceId;
    if (id.length > 0) {
      const alias: string | undefined = this.deviceAliases[id];
      if (alias !== undefined && alias.length > 0) {
        return alias;
      }
    }
    return this.connectedHostName;
  }

  /** 权限预设的中文短标签。 */
  /** 底栏账号文案：邮箱只留 @ 前面且截到 18 字符，避免长数字串撑满一行。 */
  private shortAccount(): string {
    const email: string = this.accountEmail;
    if (email.length === 0) {
      return '';
    }
    const at: number = email.indexOf('@');
    const head: string = at > 0 ? email.substring(0, at) : email;
    return head.length > 18 ? head.substring(0, 18) + '…' : head;
  }

  /** 设备卡的 ⋯ 菜单：改名、清除公钥固定（都收进来，省出名字的宽度）。 */
  private openDeviceMenu(device: RemoteHostDevice): void {
    const sheets: SheetInfo[] = [
      {
        title: this.tr('改名'),
        action: () => {
          this.beginRename(device);
        }
      }
    ];
    if (this.runtime.hasHostPin(device.deviceId)) {
      sheets.push({
        title: this.tr('清除公钥固定'),
        action: () => {
          AlertDialog.show({
            title: this.tr('该主机已固定公钥'),
            message: this.tr('主机重置或更换后，本地固定的公钥会对不上，导致无法连接。\n'
              + '清除后下次连接将重新信任首次看到的公钥。'),
            primaryButton: {
              value: this.tr('取消'),
              action: () => {
              }
            },
            secondaryButton: {
              value: this.tr('清除固定记录'),
              fontColor: '#F85749',
              action: () => {
                this.runtime.forgetHostPin(device.deviceId);
                this.errorMsg = '';
                this.infoMsg = this.tr('已清除该主机的公钥固定记录');
              }
            }
          });
        }
      });
    }
    ActionSheet.show({
      title: device.name.length > 0 ? device.name : device.deviceId,
      message: this.tr('主机操作'),
      sheets: sheets
    });
  }

  /** 会话名是否长到需要跑马灯（> 12 个字符才滚，短名字保持自然宽度）。 */
  private titleNeedsMarquee(): boolean {
    return this.currentSessionTitle.length > 12;
  }

  /** 当前服务器胶囊文案  /** 顶栏切换按钮的文案：只给「官方 / 本地 / 自定义」短标签，长邮箱不该出现在这里。 */
  private accountSwitchLabel(): string {
    const url: string = this.runtime.serverUrl;
    if (url.length === 0) {
      return this.tr('切换账号');
    }
    const host: string = serverHostLabel(url);
    if (url.indexOf('dsh.r2049.cn') >= 0) {
      return this.tr('官方') + ' · ' + host;
    }
    if (url.indexOf('192.168.') >= 0 || url.indexOf('127.0.0.1') >= 0 || url.indexOf('localhost') >= 0) {
      return this.tr('本地') + ' · ' + host;
    }
    return host;
  }

  /** 主机选择页直接切换服务器/账号：列出已保存的登录态，点了就换（不用重输密码）。 */
  private openAccountSwitcher(): void {
    this.showMoreMenu = false;
    this.showServerSwitch = true;
  }

  /** 服务器候选：已保存的登录态 + 内置的官方/本地出口（去重）。 */
  private serverChoices(): ServerChoice[] {
    const out: ServerChoice[] = [];
    const currentUrl: string = this.runtime.serverUrl;
    const currentEmail: string = this.runtime.email;
    const push = (url: string, email: string, profile: SavedProfile | undefined): void => {
      const emailFull: string = email;
      for (const existing of out) {
        // 同一个服务器只留一条（先入为主的是已保存的登录态）
        if (existing.url === url) {
          return;
        }
      }
      const choice: ServerChoice = new ServerChoice();
      choice.url = url;
      choice.account = this.shortEmail(emailFull);
      choice.accountFull = emailFull;
      choice.profile = profile;
      choice.host = serverHostLabel(url);
      choice.label = this.serverTag(url);
      choice.active = url === currentUrl && emailFull === currentEmail;
      out.push(choice);
    };
    for (const profile of this.profilesList) {
      push(profile.baseUrl, profile.email, profile);
    }
    push('https://dsh.r2049.cn', '', undefined);
    push('http://192.168.11.128:8080', '', undefined);
    return out;
  }

  /** 服务器短标签：官方 / 本地 / 自定义。 */
  private serverTag(url: string): string {
    if (url.indexOf('dsh.r2049.cn') >= 0) {
      return this.tr('官方服务器');
    }
    if (url.indexOf('192.168.') >= 0 || url.indexOf('127.0.0.1') >= 0 || url.indexOf('localhost') >= 0) {
      return this.tr('本地服务器');
    }
    return this.tr('自定义服务器');
  }

  /** 邮箱只留前缀并截断，避免长数字串撑行。 */
  private shortEmail(email: string): string {
    const at: number = email.indexOf('@');
    const head: string = at > 0 ? email.substring(0, at) : email;
    return head.length > 16 ? head.substring(0, 16) + '…' : head;
  }

  /** 选中某条服务器：有保存的登录态就直接切，没有就带上地址去登录页。 */
  /** 跨天时插一条日期分隔；同一天不打断。 */
  private shouldShowDayDivider(index: number): boolean {
    const rows: ChatItem[] = this.chatRows();
    if (index <= 0 || index >= rows.length) {
      return false;
    }
    const current: number = rows[index].timestamp;
    const previous: number = rows[index - 1].timestamp;
    if (current <= 0) {
      return false;
    }
    if (previous <= 0) {
      return index === 0;
    }
    return !sameDay(current, previous);
  }

  /** 这条回复是否需要折叠：非流式、没被展开过、且超过 24 行。 */
  private isLongCollapsed(item: ChatItem): boolean {
    if (item.streaming || this.expandedMessages.includes(item.id)) {
      return false;
    }
    return this.textLineCount(item.text) > 24;
  }

  /** 文本行数（粗算，用于判断要不要折叠）。 */
  private textLineCount(text: string): number {
    return text.split('\n').length;
  }

  /** 折叠到前 18 行，行尾加省略提示。 */
  /** 气泡里实际显示的文本：开了打码且没点「看原文」就把 Key/Token 遮掉。 */
  private bubbleText(item: ChatItem): string {
    if (!this.runtime.secretMask || this.revealedSecrets.indexOf(item.id) >= 0) {
      return item.text;
    }
    return maskSecrets(item.text);
  }

  /** 这条气泡是否「被遮挡过，可以展开看原文」。 */
  private showsMaskedHint(item: ChatItem): boolean {
    if (!this.runtime.secretMask || this.revealedSecrets.indexOf(item.id) >= 0) {
      return false;
    }
    return maskSecrets(item.text) !== item.text;
  }

  private collapseText(text: string): string {
    const lines: string[] = text.split('\n');
    if (lines.length <= 18) {
      return text;
    }
    return lines.slice(0, 18).join('\n') + '\n\n…';
  }

  private deviceDetail(): RemoteHostDevice | undefined {
    for (const device of this.devices) {
      if (device.deviceId === this.deviceDetailId) {
        return device;
      }
    }
    return undefined;
  }

  private deviceDetailName(): string {
    const device: RemoteHostDevice | undefined = this.deviceDetail();
    return device === undefined ? '' : device.name;
  }

  private deviceDetailOnline(): boolean {
    const device: RemoteHostDevice | undefined = this.deviceDetail();
    return device === undefined ? false : device.online;
  }

  private deviceDetailOnlineLabel(): string {
    const device: RemoteHostDevice | undefined = this.deviceDetail();
    return device === undefined ? '' : this.hostSeenLabel(device);
  }

  private deviceDetailField(key: string): string {
    const device: RemoteHostDevice | undefined = this.deviceDetail();
    if (device === undefined) {
      return '';
    }
    if (key === 'platform') {
      return device.platform;
    }
    if (key === 'harnessVersion') {
      return device.harnessVersion;
    }
    return device.clientVersion;
  }

  private deviceDetailLastSeen(): string {
    const device: RemoteHostDevice | undefined = this.deviceDetail();
    if (device === undefined || device.lastSeenAt <= 0) {
      return '';
    }
    const date: Date = new Date(device.lastSeenAt);
    const pad = (n: number): string => n < 10 ? '0' + n : '' + n;
    return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate())
      + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
  }

  private deviceDetailFingerprint(): string {
    const device: RemoteHostDevice | undefined = this.deviceDetail();
    if (device === undefined || device.identityKey.length === 0) {
      return '';
    }
    const key: string = device.identityKey;
    return key.length > 24 ? key.substring(0, 12) + '…' + key.substring(key.length - 8) : key;
  }

  private copyDeviceDetail(): void {
    const device: RemoteHostDevice | undefined = this.deviceDetail();
    if (device === undefined) {
      return;
    }
    const lines: string[] = [
      'name: ' + device.name,
      'deviceId: ' + device.deviceId,
      'platform: ' + device.platform,
      'harness: ' + device.harnessVersion,
      'client: ' + device.clientVersion,
      'online: ' + (device.online ? 'yes' : 'no'),
      'lastSeen: ' + this.deviceDetailLastSeen(),
      'identityKey: ' + device.identityKey
    ];
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, lines.join('\n'));
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: this.tr('已复制主机信息') });
    }).catch(() => undefined);
  }

  /** 会话列表实际展示的条目：搜索优先，其次「只看收藏」。 */
  /** 会话列表里出现过的不同工作区（按会话数降序，最多 6 个）。 */
  private sessionWorkspaces(): string[] {
    const counts: Map<string, number> = new Map<string, number>();
    for (const session of this.sessions) {
      if (session.cwd.length === 0) {
        continue;
      }
      counts.set(session.cwd, (counts.get(session.cwd) ?? 0) + 1);
    }
    const keys: string[] = [];
    counts.forEach((count: number, cwd: string) => {
      keys.push(cwd);
    });
    keys.sort((a: string, b: string) => (counts.get(b) ?? 0) - (counts.get(a) ?? 0));
    return keys.slice(0, 6);
  }

  private isArchivedSession(sessionId: string): boolean {
    return this.archivedIds.includes(sessionId);
  }

  private isPinnedSession(sessionId: string): boolean {
    return this.pinnedIds.includes(sessionId);
  }

  private visibleSessions(): HarnessRemoteSession[] {
    const base: HarnessRemoteSession[] = this.sessionSearchActive
      ? this.sessionSearchResults : this.sessions;
    const list: HarnessRemoteSession[] = [];
    for (const session of base) {
      // 归档的会话默认不进列表；搜索时照常给结果，别让搜到的会话凭空消失
      if (this.workspaceFilter.length > 0 && session.cwd !== this.workspaceFilter) {
        continue;
      }
      const archived: boolean = this.isArchivedSession(session.sessionId);
      if (archived && !this.showArchived && !this.sessionSearchActive) {
        continue;
      }
      if (this.favoriteOnly && !this.runtime.isFavoriteSession(session.sessionId)) {
        continue;
      }
      list.push(session);
    }
    // 置顶最先，其次运行中，其余保持服务端给的时间顺序
    const sorted: HarnessRemoteSession[] = list.sort((a: HarnessRemoteSession, b: HarnessRemoteSession) => {
      const aPin: number = this.runtime.isPinnedSession(a.sessionId) ? 1 : 0;
      const bPin: number = this.runtime.isPinnedSession(b.sessionId) ? 1 : 0;
      if (aPin !== bPin) {
        return bPin - aPin;
      }
      const aRunning: number = a.running ? 1 : 0;
      const bRunning: number = b.running ? 1 : 0;
      return bRunning - aRunning;
    });
    // 折叠的工作区：只留第一行当组头（搜索时不折叠，让人看全结果）
    if (this.sessionSearchActive || this.collapsedWorkspaces.length === 0) {
      return sorted;
    }
    const kept: HarnessRemoteSession[] = [];
    const seen: string[] = [];
    for (const session of sorted) {
      const label: string = this.workspaceGroupLabel(session);
      const first: boolean = !seen.includes(label);
      seen.push(label);
      if (first || !this.collapsedWorkspaces.includes(label)) {
        kept.push(session);
      }
    }
    return kept;
  }

  /** 最近访问的会话标题；列表里没有（已归档/换主机）时给个短 id。 */
  private recentSessionTitle(sessionId: string): string {
    for (const session of this.sessions) {
      if (session.sessionId === sessionId) {
        return formatSessionTitle(session);
      }
    }
    return '#' + sessionId.substring(sessionId.length - 6);
  }

  private chooseServerChoice(choice: ServerChoice): void {
    if (this.switchingServer) {
      return;
    }
    this.showServerSwitch = false;
    const profile: SavedProfile | undefined = choice.profile;
    if (profile !== undefined) {
      if (!choice.active) {
        this.runtime.switchProfile(profile);
      }
      return;
    }
    this.prefillAndLogout(choice.url);
  }

  /** 在已保存登录态里按服务器找一条。 */  /** 在已保存登录态里按服务器找一条。 */
  private findProfile(baseUrl: string): SavedProfile | undefined {
    for (const profile of this.profilesList) {
      if (profile.baseUrl === baseUrl) {
        return profile;
      }
    }
    return undefined;
  }

  /** 退出登录并把登录页的服务器地址预填成指定值（点击官方/本地切换时用）。 */
  private prefillAndLogout(baseUrl: string): void {
    this.serverInput = baseUrl;
    this.fieldsPrefilled = true;
    this.runtime.logout();
  }

  /** 文字大小：所有关键字号都过这个函数，改档位就是整体缩放。 */
  private fs(base: number): number {
    return Math.round(base * this.textScaleValue * 10) / 10;
  }

  /**
   * 一条消息要显示的图片：本地刚发的直接在 item.images 里；
   * 历史的只有 attachmentId，从运行时缓存里取（拉不到就是空，不占位）。
   */
  /** 心跳消息折成可读正文；不是心跳就是空串。 */
  private heartbeatBody(item: ChatItem): string {
    const role: string = item.kind === 'user' ? 'user' : 'assistant';
    return heartbeatBodyOf(item.text, role);
  }

  private heartbeatOpen(item: ChatItem): boolean {
    return this.heartbeatExpanded.includes(item.id);
  }

  private toggleHeartbeat(item: ChatItem): void {
    if (this.heartbeatOpen(item)) {
      this.heartbeatExpanded = this.heartbeatExpanded.filter((id: string) => id !== item.id);
      return;
    }
    this.heartbeatExpanded = this.heartbeatExpanded.concat([item.id]);
  }

  /**
   * 这条消息要显示的图片。
   *
   * 本机刚发的图有本地预览（item.images），主机回显时又会带上 attachmentId；
   * 两边是同一张图但字节不完全相同（本地压过、主机是原图），按字节去重去不掉，
   * 于是气泡里同图出现两份。规则：有本地预览就只显示本地预览，没有再按 id 补水。
   */
  private messageImages(item: ChatItem): string[] {
    const local: string[] = [];
    for (const body of item.images) {
      if (body.length > 0) {
        local.push(body);
      }
    }
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    const push = (body: string): void => {
      if (body.length === 0) {
        return;
      }
      // 同一张图可能既在本地预览里、又在主机附件里（字节未必相同），
      // 用「长度 + 前 64 字符」当签名兜底，保证一个气泡里同一张图只画一次。
      const signature: string = body.length + ':' + body.substring(0, 64);
      if (seen.has(signature)) {
        return;
      }
      seen.add(signature);
      out.push(body);
    };
    for (const body of local) {
      push(body);
    }
    for (const attachmentId of item.imageAttachmentIds) {
      push(this.runtime.imageFor(attachmentId));
    }
    return out;
  }

  /** 会话区内容最大宽度：窗口越宽放越宽，不再固定 880。 */
  private chatMaxWidth(): number {
    const w: number = this.windowWidthVp;
    if (w <= 0) {
      return 880;
    }
    if (w >= 1600) {
      return 1180;
    }
    if (w >= 1200) {
      return 1020;
    }
    return 880;
  }

  /** 左侧会话栏宽度：宽窗口下按比例放宽，窄窗口保持 300。 */
  /** 竖屏抽屉宽度（屏宽 82%），跟手位移按它换算。 */
  /**
   * 三栏：会话 | 聊天 | 会话详情。给超宽窗口（2in1 全屏、三折叠三屏展开、大屏平板横放）用，
   * 阈值取 1180vp——再窄右栏会把消息区压到 600 以下。
   */
  private showThreePane(): boolean {
    return this.uiShowInspector && this.windowWidthVp >= 1180
      && this.windowHeightVp >= 560 && this.phase === PHASE_CHAT;
  }

  /**
   * 是否走「会话 + 聊天」双栏。
   * 按断点（窗口宽度 ≥ 600vp）而不是横竖屏判断：平板竖屏、折叠屏展开、PC 窗口都该分栏，
   * 手机横屏（宽 800 但高 360）反而该保持单列。
   */
  private showTwoPane(): boolean {
    // 宽 ≥ 600vp（md 起）且高 ≥ 480vp：手机横屏（840×360）高度不够，仍走单列
    return this.windowWidthVp >= 600 && this.windowHeightVp >= 480
      && this.phase === PHASE_CHAT;
  }

  /**
   * 铰链留白：API 26 的 AvoidAreaType 里没有铰链类型，
   * 只能按「半折态 + 窗口高度」估一个合理间距（不同机型铰链宽度不一样，取 1.2%，夹在 8–24vp）。
   */
  private hingeGapVp(): number {
    const h: number = this.windowHeightVp > 0 ? this.windowHeightVp : 800;
    return Math.round(Math.min(24, Math.max(8, h * 0.012)));
  }

  /** 分栏里会话栏的宽度：用户拖过就用记住的值，否则按窗口比例（夹在 240–460）。 */
  private splitPaneWidth(): number {
    const saved: number = this.runtime.splitWidth;
    const w: number = this.windowWidthVp > 0 ? this.windowWidthVp : 900;
    if (saved > 0) {
      return saved;
    }
    return Math.round(Math.min(460, Math.max(240, w * 0.3)));
  }

  private drawerWidthVp(): number {
    const w: number = this.windowWidthVp > 0 ? this.windowWidthVp : 360;
    return Math.round(w * 0.82);
  }

  /** 松手后归位：过阈值就滑到底，否则弹回并卸载。 */
  private settleDrawer(open: boolean): void {
    if (this.drawerCloseTimer >= 0) {
      clearTimeout(this.drawerCloseTimer);
      this.drawerCloseTimer = -1;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      this.drawerOpen = open ? 1 : 0;
    });
    if (!open) {
      this.drawerCloseTimer = setTimeout(() => {
        this.showSessions = false;
        this.drawerCloseTimer = -1;
      }, 230);
    }
  }

  /** 点按钮/手势完成后展开抽屉。 */
  private openDrawer(): void {
    if (this.showSessions && this.drawerOpen >= 1) {
      return;
    }
    if (this.drawerCloseTimer >= 0) {
      clearTimeout(this.drawerCloseTimer);
      this.drawerCloseTimer = -1;
    }
    this.showSessions = true;
    this.drawerOpen = 0;
    this.getUIContext().animateTo({ duration: 240, curve: Curve.Friction }, () => {
      this.drawerOpen = 1;
    });
  }

  private closeDrawer(): void {
    this.settleDrawer(false);
  }

  /**
   * 顶部安全区：手机/平板有系统状态栏，直接用系统给的高度；
   * 只有 2in1 全屏这种读不到状态栏（=0）的情况才兜底，避免标题被窗口标题栏压住。
   */
  private topSafePadding(): number {
    if (this.topInset > 0) {
      return this.topInset;
    }
    return this.isWideLayout() ? 44 : 12;
  }

  /**
   * 底部安全区：手机只让出导航条，别留多余空白；2in1 全屏底部是系统 Dock，
   * 要多让一些，否则账号行会被 Dock 压掉。
   */
  private bottomSafePadding(): number {
    if (this.isWideLayout()) {
      return Math.max(this.bottomInset, 56);
    }
    // 手机上系统报的导航区高度常常是 50vp 往上（含手势区），按它留白会空一大条，
    // 这里只让出导航条本身的可视高度，多留 8vp 呼吸位。
    // 保留一点呼吸位：贴死到屏幕边缘反而显挤（82px 那版是用户认可的观感）
    return 8;
  }

  /** 设备页内容列宽：按断点给（手机满宽 / 平板 1040 / 2in1 1200），都居中。 */
  private deviceColumnWidth(): number {
    return contentColumnWidth(this.breakpoint, this.windowWidthVp);
  }

  /** 宽屏判断统一入口，避免页面里到处散落 width >= 900 之类的魔法数。 */
  /** 手机窄屏（xs/sm）：输入坞按紧凑口径排，别把输入框挤成一条缝。 */
  private compactDock(): boolean {
    return isCompactWidth(this.breakpoint);
  }

  private isWideLayout(): boolean {
    return isExpandedWidth(this.breakpoint);
  }

  /**
   * 会话行密度：设置里显式选了就听设置（0 自动 / 1 紧凑 / 2 超紧凑），
   * 「自动」时只在分栏下收紧，单列保持宽松版。
   */
  private compactRows(): boolean {
    if (this.runtime.layoutDensity === 1 || this.runtime.layoutDensity === 2) {
      return true;
    }
    return this.showTwoPane() || this.showThreePane();
  }

  /** 超紧凑：会话行不显示轮数与工作区目录，只留标题与时间。 */
  private ultraCompactRows(): boolean {
    return this.runtime.layoutDensity === 2;
  }

  /** 小女仆的出场条件：窗口够高就出来，手机横屏（约 405vp）这种就不挤列表。 */
  private showMascot(): boolean {
    return mascotVisible(this.breakpoint, this.windowHeightVp);
  }

  /** 分栏里会话栏宽度：拖过分隔条就用记住的值，否则按窗口 20%（夹在 260–380）。 */
  private listPanelWidth(): number {
    const saved: number = this.runtime.splitWidth;
    if (saved > 0) {
      return saved;
    }
    const w: number = this.windowWidthVp;
    if (w <= 0) {
      return 300;
    }
    const computed: number = Math.round(w * 0.2);
    return Math.max(260, Math.min(380, computed));
  }

  /** 顶栏数据面徽标：LAN/P2P/TURN 是直连，Relay 是中继（中文界面显示「中继」）。 */
  private transportBadgeText(): string {
    if (this.connectedTransport === 'relay') {
      return this.en() ? 'Relay' : '中继';
    }
    if (this.connectedTransport === 'lan') {
      return 'LAN';
    }
    if (this.connectedTransport === 'p2p') {
      return 'P2P';
    }
    if (this.connectedTransport === 'turn') {
      return 'TURN';
    }
    return '';
  }

  /** 桌宠表情：干活 🐳 · 等你确认 🙋 · 刚做完 ✨ · 待命 🌙。 */
  private petFace(): string {
    const state: string = this.runtime.petState();
    if (state === 'working') {
      return '🐳';
    }
    if (state === 'waiting') {
      return '🙋';
    }
    if (state === 'done') {
      return '✨';
    }
    return '🌙';
  }

  /** 自备桌宠素材的规格说明（写清目录、清单字段与图片要求）。 */
  private petSpecText(): string {
    return this.tr('素材说明') + '\n'
      + this.tr('目录') + '：' + PetPack.userPackPath() + '\n'
      + this.tr('清单') + '：pack.json（' + this.tr('结构同内置包') + '）\n'
      + this.tr('字段') + '：animations.{idle,typing,thinking,happy,sleeping}，'
      + this.tr('每项含 sheet / frameW / frameH / frames[{i,ms}]') + '\n'
      + this.tr('图片') + '：PNG，横向精灵图，帧宽高需与 frameW/frameH 一致；'
      + this.tr('建议单帧 128–256px、整图不超过 4096px 宽') + '\n'
      + this.tr('可选') + '：只提供 idle 也能用，其余状态自动回落到 idle。';
  }

  /** 停掉精灵图帧循环。 */  /** 停掉精灵图帧循环。 */
  private stopPetAnimation(): void {
    if (this.petTimer >= 0) {
      clearTimeout(this.petTimer);
      this.petTimer = -1;
    }
  }

  /** 按当前桌宠状态切动画；同一段动画不重开。 */
  private restartPetAnimation(): void {
    if (!PetPack.ready()) {
      return;
    }
    const sleepy: boolean = this.runtime.petState() === 'idle' && this.petIdleSince > 0
      && Date.now() - this.petIdleSince > 180000 && PetPack.anim('sleeping') !== undefined;
    const next: string = sleepy ? 'sleeping' : PetPack.animNameFor(this.runtime.petState());
    if (next.length === 0 || next === this.petAnim) {
      return;
    }
    this.stopPetAnimation();
    this.petAnim = next;
    this.petFrameCursor = 0;
    const tick = (): void => {
      const anim: PetAnim | undefined = PetPack.anim(this.petAnim);
      if (anim === undefined || anim.frames.length === 0) {
        return;
      }
      const frame = anim.frames[this.petFrameCursor % anim.frames.length];
      this.petFrame = frame.index;
      this.petFrameCursor += 1;
      this.petTimer = setTimeout(tick, Math.max(40, frame.ms));
    };
    tick();
  }

  /** 有面板/抽屉盖在会话上时先收起桌宠，别压在人家的按钮上。 */
  private petOverlayAllowed(): boolean {
    return !this.showSettings && !this.showSessionPanel && !this.previewActive
      && !this.messageActionsOpen && !this.drawerOpenFlag() && !this.tintPickerOpen
      && !this.diagnosticsOpen && !this.filePreviewOpen && !this.inSessionSearchOpen
      && !this.choiceOpen && !this.promptPanelOpen;
  }

  private drawerOpenFlag(): boolean {
    return this.drawerOpen > 0.02;
  }

  /** 桌宠：有鲸娘素材就放精灵图，没有就退回 emoji。 */
  @Builder
  PetWidget() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: 4 }) {
        if (this.petQuip.length > 0) {
          Text(this.petQuip)
            .fontSize(this.fs(11))
            .fontColor(this.pal().text)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            // 和会话气泡用同一个底色与圆角，透明观感一致
            .backgroundColor(this.pal().inputBg)
            .borderRadius(14)
            .border({ width: 1, color: this.pal().border })
            .shadow({ radius: 10, color: 'rgba(0,0,0,0.12)', offsetX: 0, offsetY: 3 })
            .margin({ right: 6 })
        }
      Row({ space: 4 }) {
          if (PetPack.ready() && this.petAnim.length > 0) {
            this.PetSprite()
          } else {
            Text(this.petFace())
              .fontSize(this.runtime.petState() === 'working' ? 22 : 20)
              // 干活时轻微「呼吸」，待命时静止；用 iterations: -1 做无限往返，不额外开定时器
              .scale(this.runtime.petState() === 'working' ? { x: 1.12, y: 1.12 } : { x: 1, y: 1 })
              .animation({
                duration: 1100,
                curve: Curve.EaseInOut,
                iterations: this.runtime.petState() === 'working' ? -1 : 1,
                playMode: PlayMode.Alternate
              })
          }
          if (this.petHint().length > 0) {
            Text(this.petHint())
              .fontSize(10)
              .fontColor(this.pal().text3)
          }
        }
        .padding({ left: 8, right: 10, top: 4, bottom: 4 })
        .backgroundColor(this.pal().card)
        .borderRadius(14)
        .border({ width: 1, color: this.pal().border })
        .margin({ bottom: 4 })
        // 双击优先：onClick 会和 TapGesture(count:2) 抢事件，双击永远轮不到
        .onClick(() => {
          this.onPetTap();
        })
        // 长按 350ms 授权拖动；授权后跟手指走，松手弹回原位并放开授权。
        // 用 parallelGesture 而不是 Sequence：Sequence 一旦结束就再也不会重新开始，
        // 这就是「拖过一次以后再也拖不动」的原因。
        .gesture(GestureGroup(GestureMode.Parallel,
          LongPressGesture({ repeat: false, duration: 350 })
            .onAction(() => {
              this.petArmed = true;
              this.petDragging = true;
              this.tapHaptic();
            }),
          PanGesture({ fingers: 1, distance: 2 })
            .onActionUpdate((event: GestureEvent) => {
              if (!this.petArmed) {
                return;
              }
              this.petDragX = event.offsetX;
              this.petDragY = event.offsetY;
            })
            .onActionEnd(() => {
              if (!this.petArmed) {
                return;
              }
              this.petArmed = false;
              this.petDragging = false;
              this.returnPetWithRandomPath();
            })
            .onActionCancel(() => {
              if (!this.petArmed) {
                return;
              }
              this.petArmed = false;
              this.petDragging = false;
              this.returnPetWithRandomPath();
            })
        ))
      }
      .alignItems(HorizontalAlign.End)
    }
    // 抬到输入坞上方；输入框长高时跟着上移（offset 不参与布局，位置更好控）
    .margin({ right: 14 })
    .offset({ x: this.petDragX, y: -(this.dockHeight + 10) + this.petDragY })
    // 拖动时轻微放大 + 提高层级，松手回弹由 animateTo 负责
    // 锚点放右下角：放大时朝左上「鼓」，宠物不会被推出屏幕
    .scale({ x: this.petDragging ? 2 : 1, y: this.petDragging ? 2 : 1,
      centerX: '100%', centerY: '100%' })
    .animation({ duration: 220, curve: Curve.EaseOut })
    .animation({ duration: 160, curve: Curve.EaseOut })
    .zIndex(this.petDragging ? 80 : 0)
    .hitTestBehavior(HitTestMode.Transparent)
    .width('100%')
    .height('100%')
  }

  /** 双击炸屏用的全屏层：居中放大当前帧，盖满整屏。 */
  @Builder
  PetBoomOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(6,10,20,0.55)')
      Stack({ alignContent: Alignment.TopStart }) {
        Image(this.petPixel())
          .width(this.petSheetWidth())
          .height(this.petFrameHeight())
          .objectFit(ImageFit.Fill)
          .interpolation(ImageInterpolation.None)
          .position({ x: -this.petFrame * this.petFrameWidth(), y: 0 })
      }
      .width(this.petFrameWidth())
      .height(this.petFrameHeight())
      .clip(true)
      .scale({ x: this.petBoomScale, y: this.petBoomScale })
    }
    .width('100%')
    // 铺满整个窗口（含状态栏/顶栏区域），否则顶部会露出聊天界面
    .height(this.windowHeightVp > 0 ? this.windowHeightVp : 800)
    .position({ x: 0, y: -this.topSafePadding() })
    .zIndex(90)
    .opacity(this.petBoomOpacity)
    // 不在炸屏时彻底不参与布局与命中测试，否则它会挡住桌宠的点击
    .visibility(this.petBoomVisible ? Visibility.Visible : Visibility.None)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 把精灵图按帧裁出来显示：外层裁切 + 内层按帧横向偏移。 */
  @Builder
  PetSprite() {
    Stack({ alignContent: Alignment.TopStart }) {
      Image(this.petPixel())
        .width(this.petSheetWidth())
        .height(this.petFrameHeight())
        // Fill：组件已经是「整张精灵图 × 放大倍数」，用 Fill 才能把 52×49 的像素图放大到 104×98
        .objectFit(ImageFit.Fill)
        .interpolation(ImageInterpolation.None)
        .position({ x: -this.petFrame * this.petFrameWidth(), y: 0 })
    }
    .width(this.petFrameWidth())
    .height(this.petFrameHeight())
    .clip(true)
  }

  private petPixel(): image.PixelMap | undefined {
    const anim: PetAnim | undefined = PetPack.anim(this.petAnim);
    return anim === undefined ? undefined : anim.pixel;
  }

  private petFrameWidth(): number {
    const anim: PetAnim | undefined = PetPack.anim(this.petAnim);
    return anim === undefined ? 0 : anim.frameW * PET_SCALE;
  }

  private petFrameHeight(): number {
    const anim: PetAnim | undefined = PetPack.anim(this.petAnim);
    return anim === undefined ? 0 : anim.frameH * PET_SCALE;
  }

  /** 整张精灵图的显示宽度（按真实像素宽 × 缩放）。 */
  private petSheetWidth(): number {
    const anim: PetAnim | undefined = PetPack.anim(this.petAnim);
    return anim === undefined ? 0 : anim.sheetW * PET_SCALE;
  }

  private petHint(): string {
    const state: string = this.runtime.petState();
    if (state === 'working') {
      return this.tr('鲸娘在干活');
    }
    if (state === 'waiting') {
      return this.tr('等你确认');
    }
    if (state === 'done') {
      return this.tr('这轮做完了');
    }
    return '';
  }

  private themeTintLabel(): string {
    const tint: number = this.uiThemeTint;
    if (tint === 1) {
      return this.tr('深海');
    }
    if (tint === 2) {
      return this.tr('森林');
    }
    if (tint === 3) {
      return this.tr('暖沙');
    }
    if (tint === 4) {
      return this.tr('玫紫');
    }
    return this.tr('默认');
  }

  private transportBadgeColor(): string {
    return this.connectedTransport === 'relay' ? '#C88418' : '#1E9E6A';
  }

  private transportBadgeBg(): string {
    return this.connectedTransport === 'relay' ? 'rgba(240,160,32,0.14)' : 'rgba(52,211,153,0.16)';
  }

  private permissionLabel(): string {
    const preset: string = this.runtime.permissionPreset;
    if (preset === 'read-only') {
      return t('只读');
    }
    if (preset === 'workspace-write') {
      return t('可写');
    }
    if (preset === 'danger-full-access') {
      return t('完全');
    }
    return t('权限');
  }

  private currentSessionInfo(): HarnessRemoteSession | undefined {
    for (const session of this.sessions) {
      if (session.sessionId === this.currentSessionId) {
        return session;
      }
    }
    return undefined;
  }

  /** Short contextual facts about the open session, shown above the input bar. */
  private contextPills(): string[] {
    const pills: string[] = [];
    const session: HarnessRemoteSession | undefined = this.currentSessionInfo();
    if (session === undefined) {
      return pills;
    }
    if (session.cwd.length > 0) {
      const label: string = cwdLabel(session.cwd);
      if (label.length > 0) {
        pills.push(label);
      }
    }
    if (session.turns > 0) {
      pills.push(`${session.turns} 轮`);
    }
    if (session.contextPercent > 0) {
      pills.push(`上下文 ${session.contextPercent}%`);
    }
    return pills;
  }

  private beginRename(device: RemoteHostDevice): void {
    this.renamingDeviceId = device.deviceId;
    this.renameInput = this.displayNameFor(device);
  }

  private confirmRename(): void {
    if (this.renamingDeviceId.length > 0) {
      this.runtime.setDeviceAlias(this.renamingDeviceId, this.renameInput);
    }
    this.renamingDeviceId = '';
    this.renameInput = '';
  }

  private cancelRename(): void {
    this.renamingDeviceId = '';
    this.renameInput = '';
  }

  private onlineDeviceCount(): number {
    let count: number = 0;
    for (const device of this.devices) {
      if (device.online) {
        count++;
      }
    }
    return count;
  }

  /** Active palette, re-evaluated whenever the theme or system mode flips. */
  private pal(): Palette {
    return applyTint(this.isDarkUi ? darkPalette() : lightPalette(), this.uiThemeTint, this.isDarkUi);
  }

  /** 读一下 languageMode 再取文案：让 Text 节点依赖到状态，切语言时才会重算。 */
  private tr(key: string): string {
    const mode: number = this.languageMode;
    return t(key);
  }

  /** 同上，用于「按语言换单位」的拼接文案。 */
  private en(): boolean {
    const mode: number = this.languageMode;
    return english();
  }

  /** 会话列表分组：新会话不再一个个孤立，按 今天/昨天/更早 归堆。 */
  /** 列表分组依据：工作区（没有 cwd 的会话归「未分组」）。 */
  private workspaceGroupLabel(session: HarnessRemoteSession): string {
    return session.cwd.length > 0 ? cwdTail(session.cwd) : this.tr('未分组');
  }

  /** 同一工作区被折叠时，只留第一行当「组头」。 */
  private isWorkspaceCollapsed(session: HarnessRemoteSession): boolean {
    return this.collapsedWorkspaces.includes(this.workspaceGroupLabel(session));
  }

  private toggleWorkspaceGroup(label: string): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (const item of this.collapsedWorkspaces) {
      if (item === label) {
        removed = true;
      } else {
        next.push(item);
      }
    }
    if (!removed) {
      next.push(label);
    }
    this.collapsedWorkspaces = next;
  }

  /** 该工作区里有多少会话（折叠时组头要显示条数）。 */
  private workspaceGroupCount(label: string): number {
    let count: number = 0;
    for (const session of this.visibleSessions()) {
      if (this.workspaceGroupLabel(session) === label) {
        count += 1;
      }
    }
    return count;
  }

  private sessionGroupGap(index: number): string {
    const list: HarnessRemoteSession[] = this.visibleSessions();
    if (index < 0 || index >= list.length) {
      return '';
    }
    // 搜索时按时间平铺，不插组头
    if (this.sessionSearchActive) {
      const label: string = sessionGroupLabel(list[index].updatedAt);
      if (index === 0) {
        return label;
      }
      return sessionGroupLabel(list[index - 1].updatedAt) === label ? '' : label;
    }
    const label: string = this.workspaceGroupLabel(list[index]);
    if (index === 0) {
      return label;
    }
    return this.workspaceGroupLabel(list[index - 1]) === label ? '' : label;
  }

  /** 标题旁的连接状态点：重连中黄、已断开红、其余绿。 */
  private connectionDotColor(): string {
    const status: string = this.runtime.reconnectStatus;
    if (status.length > 0) {
      return '#F5A623';
    }
    if (this.phase === PHASE_CONNECTING) {
      return '#F5A623';
    }
    if (!this.networkOnline) {
      return '#F85749';
    }
    return '#34D399';
  }

  /** 设备页顶部横幅：优先显示重连进度，其次提示断网。空串表示不显示。 */
  private linkBannerText(): string {
    if (this.reconnectNotice.length > 0) {
      return this.reconnectNotice;
    }
    if (!this.networkOnline) {
      return this.tr('网络已断开，恢复后自动重连');
    }
    return '';
  }

  /** 设备页底部统计：英文环境换单位，避免模板里嵌死「台 / 在线」。 */
  private hostCountLabel(): string {
    return this.en() ? `${this.devices.length} hosts` : `${this.devices.length} 台主机`;
  }

  private onlineCountLabel(): string {
    return this.en() ? `${this.onlineDeviceCount()} online` : `${this.onlineDeviceCount()} 在线`;
  }

  private themeLabel(mode: number): string {
    if (mode === 1) {
      return this.tr('浅色');
    }
    if (mode === 2) {
      return this.tr('深色');
    }
    return this.tr('跟随系统');
  }

  private themeChoices(): ThemeChoice[] {
    return [
      new ThemeChoice(LANG_SYSTEM, '跟随系统', '跟着系统的深浅色走'),
      new ThemeChoice(1, '浅色', '始终使用浅色界面'),
      new ThemeChoice(2, '深色', '始终使用深色界面')
    ];
  }

  private textScaleChoices(): ThemeChoice[] {
    return [
      new ThemeChoice(0, '小', '0.9×'),
      new ThemeChoice(1, '标准', '1.0×'),
      new ThemeChoice(2, '大', '1.15×'),
      new ThemeChoice(3, '特大', '1.3×')
    ];
  }

  private languageChoices(): ThemeChoice[] {
    return [
      new ThemeChoice(LANG_SYSTEM, '跟随系统', '跟着系统语言走'),
      new ThemeChoice(LANG_ZH, '中文', '始终使用中文界面'),
      new ThemeChoice(LANG_EN, 'English', '始终使用英文界面')
    ];
  }

  /** 连续工具调用折叠：同段 ≥2 条收成一行「N 步」，点开再逐条看。 */
  private chatRows(): ChatItem[] {
    const source: ChatItem[] = this.messages;
    const last: ChatItem | undefined = source.length > 0 ? source[source.length - 1] : undefined;
    const key: string = `${source.length}|${last === undefined ? 0 : last.rev}|${this.languageMode}`
      + `|${this.expandedRuns.join(',')}|${this.textScaleValue}`;
    if (key === this.chatRowsKey) {
      return this.chatRowsCache;
    }
    const rows: ChatItem[] = [];
    let index: number = 0;
    while (index < source.length) {
      const item: ChatItem = source[index];
      if (item.kind !== 'tool') {
        rows.push(item);
        index += 1;
        continue;
      }
      let end: number = index;
      while (end < source.length && source[end].kind === 'tool') {
        end += 1;
      }
      const count: number = end - index;
      if (count < 2) {
        rows.push(item);
        index = end;
        continue;
      }
      const head: ChatItem = source[index];
      const expanded: boolean = this.isRunExpanded(head.id);
      rows.push(this.toolRunItem(source, index, end, expanded));
      if (expanded) {
        for (let cursor: number = index; cursor < end; cursor += 1) {
          rows.push(source[cursor]);
        }
      }
      index = end;
    }
    const merged: ChatItem[] = this.mergeAssistantRows(rows);
    this.chatRowsKey = key;
    this.chatRowsCache = merged;
    return merged;
  }

  /**
   * 连续多段助手文本合并成一个气泡：模型经常把一段话拆成多条消息发出，
   * 不合并的话屏幕上会堆一串宽度不一的小气泡，看着很碎。
   */
  private mergeAssistantRows(rows: ChatItem[]): ChatItem[] {
    const out: ChatItem[] = [];
    let buffer: ChatItem | undefined = undefined;
    for (const row of rows) {
      if (row.kind !== 'assistant') {
        if (buffer !== undefined) {
          out.push(buffer);
          buffer = undefined;
        }
        out.push(row);
        continue;
      }
      const current: ChatItem | undefined = buffer;
      if (current === undefined) {
        const merged: ChatItem = new ChatItem();
        merged.id = row.id;
        merged.kind = 'assistant';
        merged.role = row.role;
        merged.text = row.text;
        merged.reasoning = row.reasoning;
        merged.streaming = row.streaming;
        merged.sessionId = row.sessionId;
        merged.timestamp = row.timestamp;
        merged.seq = row.seq;
        merged.rev = row.rev;
        buffer = merged;
        continue;
      }
      if (row.text.length > 0) {
        current.text = current.text.length > 0 ? `${current.text}\n\n${row.text}` : row.text;
      }
      if (row.reasoning.length > 0) {
        current.reasoning = current.reasoning.length > 0
          ? `${current.reasoning}\n${row.reasoning}` : row.reasoning;
      }
      current.streaming = row.streaming;
      current.rev = current.rev + 1;
    }
    if (buffer !== undefined) {
      out.push(buffer);
    }
    return out;
  }

  private toolRunItem(source: ChatItem[], start: number, end: number, expanded: boolean): ChatItem {
    const head: ChatItem = source[start];
    const row: ChatItem = new ChatItem();
    row.id = `run:${head.id}`;
    row.kind = 'toolrun';
    row.requestRpcId = head.id;
    row.sessionId = head.sessionId;
    row.timestamp = head.timestamp;
    row.rev = expanded ? 1 : 0;
    row.toolName = head.toolName;
    row.text = `${end - start}${t(' 步 · ')}${expanded ? t('收起') : t('展开')}`;
    row.summary = this.toolRunDetail(source, start, end);
    let running: boolean = false;
    let failed: boolean = false;
    for (let cursor: number = start; cursor < end; cursor += 1) {
      const state: string = source[cursor].toolState;
      if (state === 'running') {
        running = true;
      } else if (state === 'failed') {
        failed = true;
      }
    }
    row.toolState = running ? 'running' : (failed ? 'failed' : 'finished');
    return row;
  }

  private toolRunDetail(source: ChatItem[], start: number, end: number): string {
    const names: string[] = [];
    for (let cursor: number = start; cursor < end; cursor += 1) {
      const name: string = source[cursor].toolName;
      if (name.length > 0 && !names.includes(name)) {
        names.push(name);
      }
    }
    if (names.length === 0) {
      return '';
    }
    const shown: string[] = names.length > 3 ? names.slice(0, 3) : names;
    let detail: string = shown.join(' → ');
    if (names.length > 3) {
      detail = `${detail} → …`;
    }
    return detail;
  }

  /** 这张卡片是不是还在等用户作答（决定要不要跟着 waitTick 刷新）。 */
  private isPendingInteraction(item: ChatItem): boolean {
    if (item.kind === 'approval') {
      return item.approvalOutcome.length === 0;
    }
    if (item.kind === 'question') {
      return item.questionOutcome.length === 0;
    }
    return false;
  }

  private reasoningOpen(item: ChatItem): boolean {
    return this.expandedReasoning.includes(item.id);
  }

  private toggleReasoning(item: ChatItem): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (const id of this.expandedReasoning) {
      if (id === item.id) {
        removed = true;
      } else {
        next.push(id);
      }
    }
    if (!removed) {
      next.push(item.id);
    }
    this.expandedReasoning = next;
  }

  private isRunExpanded(headId: string): boolean {
    return this.expandedRuns.includes(headId);
  }

  private toggleRun(headId: string): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (const key of this.expandedRuns) {
      if (key === headId) {
        removed = true;
      } else {
        next.push(key);
      }
    }
    if (!removed) {
      next.push(headId);
    }
    this.expandedRuns = next;
  }

  /** 设备卡第二行：平台 + 主机版本（Host 没上报版本时只显示平台）。 */
  private hostSubtitle(device: RemoteHostDevice): string {
    const head: string = device.platform.length > 0 ? device.platform : this.tr('远程主机');
    let base: string = head;
    if (device.harnessVersion.length > 0) {
      base = `${head} · ${this.tr('主机')} ${device.harnessVersion}`;
    } else if (device.clientVersion.length > 0) {
      base = `${head} · ${this.tr('插件')} ${device.clientVersion}`;
    }
    const seen: string = this.hostSeenLabel(device);
    return device.online ? base : `${base} · ${seen}`;
  }

  /** 设备卡第三行：在线状态用绿点表达，这里只补「最近活动」，避免「在线」重复两遍。 */
  private hostSeenLabel(device: RemoteHostDevice): string {
    if (device.online) {
      return this.tr('在线');
    }
    if (device.lastSeenAt <= 0) {
      return this.tr('离线');
    }
    const diff: number = Date.now() - device.lastSeenAt;
    if (diff < 60000) {
      return this.en() ? 'just offline' : '刚刚离线';
    }
    if (diff < 3600000) {
      const minutes: number = Math.round(diff / 60000);
      return this.en() ? `${minutes}m ago` : `${minutes} 分钟前`;
    }
    if (diff < 86400000) {
      const hours: number = Math.round(diff / 3600000);
      return this.en() ? `${hours}h ago` : `${hours} 小时前`;
    }
    const days: number = Math.round(diff / 86400000);
    return this.en() ? `${days}d ago` : `${days} 天前`;
  }

  /** 设备页标题栏的溢出菜单：退出登录收进菜单，避免和刷新、主题挤成三颗按钮。 */
  private devicesMenu(): MenuElement[] {
    const items: MenuElement[] = [
      {
        value: this.tr('退出登录'),
        action: () => {
          AlertDialog.show({
            title: this.tr('退出登录'),
            message: this.tr('将清除本机保存的主机凭据，需要重新绑定才能连接。'),
            autoCancel: true,
            primaryButton: {
              value: this.tr('取消'),
              action: () => {
              }
            },
            secondaryButton: {
              value: this.tr('退出'),
              fontColor: '#F85749',
              action: () => {
                this.runtime.logout();
              }
            }
          });
        }
      }
    ];
    return items;
  }

  /** Keep the window background and system bars in sync with the active theme. */
  private syncWindowChrome(): void {
    if (this.chromeApplied && this.windowChromeDark === this.isDarkUi) {
      return;
    }
    this.chromeApplied = true;
    this.windowChromeDark = this.isDarkUi;
    const bg: string = this.pal().bg;
    const content: string = this.pal().text;
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      win.setWindowBackgroundColor(bg);
      win.setWindowSystemBarProperties({
        statusBarColor: bg,
        statusBarContentColor: content,
        navigationBarColor: bg,
        navigationBarContentColor: content
      }).catch(() => {
      });
    }).catch(() => {
    });
  }

  build() {
    // 整个界面按语言重建一次：ArkUI 对 @Builder 子树的文案节点不会因为模块级文案表
    // 变化而重算，用 ForEach 的 key 换语言时强制重建，比给每个 Text 打状态依赖可靠。
    Column() {
      ForEach([this.languageMode], (lang: number) => {
        this.RootStack()
      }, (lang: number) => `ui-${lang}-${this.themeMode}`)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  RootStack() {
    Stack() {
      // 背景：顶部一层品牌蓝，底部再压一层青色光晕。
      // 底部这层是给输入坞玻璃「有颜色可透」用的——背后是纯白的话，材质再厚也透不出光感。
      Stack() {
        Column()
          .width('100%')
          .height('100%')
          .radialGradient({ center: ['50%', '0%'], radius: '70%',
            colors: [[this.isDarkUi ? 'rgba(77,107,254,0.18)' : 'rgba(77,107,254,0.10)', 0],
              ['rgba(77,107,254,0)', 1]] })
        Column()
          .width('100%')
          .height('100%')
          .radialGradient({ center: ['50%', '100%'], radius: '58%',
            colors: [[this.isDarkUi ? 'rgba(34,211,238,0.26)' : 'rgba(34,211,238,0.24)', 0],
              ['rgba(34,211,238,0)', 1]] })
        Column()
          .width('100%')
          .height('100%')
          .radialGradient({ center: ['18%', '88%'], radius: '42%',
            colors: [[this.isDarkUi ? 'rgba(147,97,255,0.18)' : 'rgba(147,97,255,0.12)', 0],
              ['rgba(147,97,255,0)', 1]] })
      }
      // 背景层用绝对定位铺满整个窗口（含上下安全区），
      // 否则根容器的 padding 会把渐变内缩，底栏下方那块留白露出纯色底，突然后一块白
      .height(this.windowHeightVp > 0 ? this.windowHeightVp : 800)
      .position({ x: 0, y: -this.topSafePadding() })
      .width('100%')
      .hitTestBehavior(HitTestMode.None)
      Column() {
        if (this.phase === PHASE_BOOT) {
          this.BootScreen()
        } else if (this.phase === PHASE_SETUP) {
          this.SetupScreen()
        } else if (this.phase === PHASE_DEVICES) {
          this.DevicesScreen()
        } else if (this.phase === PHASE_CONNECTING) {
          this.ConnectingScreen()
        } else {
          if (this.showThreePane()) {
            Row() {
              this.SessionsPane()
              Column() {
  Column()
    .width(this.splitDragging ? 2 : 1)
    .height(this.splitDragging || this.splitHover ? '70%' : '0%')
    .backgroundColor(this.splitDragging || this.splitHover
      ? 'rgba(34,211,238,0.70)' : Color.Transparent)
    .borderRadius(1)
}
.width(6)
.height('100%')
.justifyContent(FlexAlign.Center)
.alignItems(HorizontalAlign.Center)
.onHover((isHover: boolean) => {
  this.splitHover = isHover;
})
.gesture(
  PanGesture({ direction: PanDirection.Horizontal, distance: 2 })
    .onActionStart(() => {
      this.splitDragging = true;
      this.splitDragBase = this.splitPaneWidth();
    })
    .onActionUpdate((event: GestureEvent) => {
      this.runtime.setSplitWidth(this.splitDragBase + event.offsetX);
    })
    .onActionEnd(() => {
      this.splitDragging = false;
      this.runtime.setSplitWidth(this.splitPaneWidth());
    })
)
              Column() {
                this.ChatScreen()
              }
              .layoutWeight(1)
              .height('100%')
              Column() {
  Column()
    .width(this.splitDragging ? 2 : 1)
    .height(this.splitDragging || this.splitHover ? '70%' : '0%')
    .backgroundColor(this.splitDragging || this.splitHover
      ? 'rgba(34,211,238,0.70)' : Color.Transparent)
    .borderRadius(1)
}
.width(6)
.height('100%')
.justifyContent(FlexAlign.Center)
.alignItems(HorizontalAlign.Center)
              this.InspectorPane()
            }
            .width('100%')
            .height('100%')
          } else if (this.showTwoPane()) {
            Row() {
              this.SessionsPane()
              // 分隔条：PC 上可以拖着调会话栏宽度，宽度记在本地
              Column() {
  Column()
    .width(this.splitDragging ? 2 : 1)
    .height(this.splitDragging || this.splitHover ? '70%' : '0%')
    .backgroundColor(this.splitDragging || this.splitHover
      ? 'rgba(34,211,238,0.70)' : Color.Transparent)
    .borderRadius(1)
}
.width(6)
.height('100%')
.justifyContent(FlexAlign.Center)
.alignItems(HorizontalAlign.Center)
.onHover((isHover: boolean) => {
  this.splitHover = isHover;
})
.gesture(
  PanGesture({ direction: PanDirection.Horizontal, distance: 2 })
    .onActionStart(() => {
      this.splitDragging = true;
      this.splitDragBase = this.splitPaneWidth();
    })
    .onActionUpdate((event: GestureEvent) => {
      this.runtime.setSplitWidth(this.splitDragBase + event.offsetX);
    })
    .onActionEnd(() => {
      this.splitDragging = false;
      this.runtime.setSplitWidth(this.splitPaneWidth());
    })
)
              Column() {
                this.ChatScreen()
              }
              .layoutWeight(1)
              .height('100%')
            }
            .width('100%')
            .height('100%')
          } else {
            this.ChatScreen()
          }
        }
      }
      .width('100%')
      .height('100%')
      if (this.showSessions && !this.isLandscape) {
        this.SessionsOverlay()
      }
      // 挂载顺序 = 层级顺序：越靠后越在上层。
      // 设置面板在下面，它打开的二级点选必须排在它之后，否则会被压在设置底下点不到。
      // 桌宠浮层：钉在右下角，避开输入坞（嵌在会话列里会被输入框盖住）
      if (this.uiPetEnabled && this.phase === PHASE_CHAT && this.petOverlayAllowed()) {
        this.PetWidget()
      }
      if (this.showSettings) {
        // 外层容器保持稳定：弹出动画挂在这里，只在这块第一次出现/消失时播。
        // 里面的 ForEach 只负责「值变了就重建面板内容」，否则每点一行整块面板都会再弹一次。
        Column() {
          this.SettingsOverlay()
        }
        .width('100%')
        .height('100%')
        .transition(TransitionEffect.translate({ y: 320 })
          .combine(TransitionEffect.opacity(0))
          .animation({ duration: 220, curve: Curve.Friction }))
      }
      if (this.showBrowser) {
        this.FileBrowserOverlay()
      }
      if (this.showSessionPanel) {
        this.SessionPanelOverlay()
      }
      if (this.showModelPicker) {
        this.ModelPickerOverlay()
      }
      if (this.promptPanelOpen) {
        this.PromptPanelOverlay()
      }
      if (this.trajectoryOpen) {
        this.TrajectoryOverlay()
      }
      if (this.workspaceCreateOpen) {
        this.WorkspaceCreateOverlay()
      }
      if (this.composerExpanded) {
        this.ExpandedComposerOverlay()
      }
      if (this.linkDetailOpen) {
        this.LinkDetailOverlay()
      }
      if (this.tintPickerOpen) {
        this.TintPickerOverlay()
      }
      if (this.pluginFormOpen) {
        this.PluginFormOverlay()
      }
      if (this.botsOpen) {
        this.BotsOverlay()
      }
      if (this.gitOpen) {
        this.GitOverlay()
      }
      if (this.hostSwitcherOpen) {
        this.HostSwitcherOverlay()
      }
      if (this.pluginsOpen) {
        this.PluginsOverlay()
      }
      if (this.terminalOpen) {
        this.TerminalOverlay()
      }
      if (this.imageMenuOpen) {
        this.ImageSourceSheet()
      }
      // 协同接收组件：必须真实渲染（1×1 即可，不能 0×0，否则框架不投递数据），
      // 且不能吃触摸（否则会挡住底下的按钮）。
      CollaborationServiceStateDialog({
        onState: (stateCode: number, bufferType: string, buffer: ArrayBuffer): void => {
          this.onCollabState(stateCode, bufferType, buffer);
        }
      })
        .width(1)
        .height(1)
        .hitTestBehavior(HitTestMode.Transparent)
      if (this.webConsoleOpen) {
        this.WebConsoleOverlay()
      }
      if (this.diagnosticsOpen) {
        this.DiagnosticsOverlay()
      }
      if (this.schedulesOpen) {
        this.SchedulesOverlay()
      }
      if (this.sendModeOpen) {
        this.SendModeOverlay()
      }
      if (this.writingMenuOpen) {
        this.WritingMenuOverlay()
      }
      if (this.filePreviewOpen) {
        this.FilePreviewOverlay()
      }
      if (this.inSessionSearchOpen) {
        this.InSessionSearchOverlay()
      }
      if (this.deviceDetailId.length > 0) {
        this.DeviceDetailOverlay()
      }
      if (this.messageActionsOpen) {
        this.MessageActionsOverlay()
      }
      if (this.showMoreMenu) {
        this.MoreMenuOverlay()
      }
      if (this.showServerSwitch) {
        this.ServerSwitchOverlay()
      }
      if (this.deviceMenuId.length > 0) {
        this.DeviceMenuOverlay()
      }
      if (this.choiceOpen) {
        this.ChoiceSheetOverlay()
      }
      // 炸屏：独立全屏层（只在播放期间挂载，平时不参与命中测试）
      if (this.petBoomVisible) {
        this.PetBoomOverlay()
      }
      if (this.previewActive) {
        this.ImagePreviewOverlay()
      }
      // 隐藏的 WebRTC 桥：1x1 透明，仅承载 JS RTCPeerConnection
      Web({ src: $rawfile('webrtc-bridge.html'), controller: this.rtc.controller })
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .fileAccess(false)
        .javaScriptProxy({
          object: this.rtc.proxyObject(),
          name: 'dshBridge',
          methodList: ['onLog', 'onLocalSdp', 'onIce', 'onState', 'onIceState', 'onTransport',
            'onDataOpen', 'onDataClosed', 'onDataBinary', 'onError'],
          controller: this.rtc.controller
        })
        .onPageEnd(() => {
          this.rtc.markReady();
          this.rtc.startSelfTest();
        })
        .width(1)
        .height(1)
        .opacity(0)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.pal().bg)
    // 让页面铺到系统栏下面（内容自己用 padding 避让），否则底部会多出导航条那一条留白
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .padding({ top: this.topSafePadding(), bottom: this.bottomSafePadding() })
    .onAppear(() => {
      this.measureInsets();
    })
  }

  /**
   * 服务器切换面板：自绘列表，选中项有明确的三重反馈
   * （左侧青色竖条 + 高亮底 + 右侧 ✓），按下时行底色再压暗一档。
   */
  @Builder
  ServerSwitchOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.showServerSwitch = false;
        })
      Column({ space: 10 }) {
        Row() {
          Column({ space: 2 }) {
            Text(this.tr('切换服务器'))
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text)
            Text(this.tr('点一下即切换，不用重输密码'))
              .fontSize(11)
              .fontColor(this.pal().text3)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('✕')
            .fontSize(15)
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.showServerSwitch = false;
            })
        }
        .width('100%')
        .padding({ bottom: 4 })
        Scroll() {
          Column({ space: 10 }) {
            ForEach(this.serverChoices(), (choice: ServerChoice) => {
          Row({ space: 12 }) {
            // 单选指示：选中填满青色并带内圈白点
            Stack() {
              Column()
                .width(18)
                .height(18)
                .borderRadius(9)
                .border({ width: 2, color: choice.active ? '#22D3EE' : this.pal().borderStrong })
              if (choice.active) {
                Column()
                  .width(9)
                  .height(9)
                  .borderRadius(4.5)
                  .backgroundColor('#22D3EE')
              }
            }
            .width(18)
            .height(18)
            Column({ space: 3 }) {
              Text(choice.label)
                .fontSize(14)
                .fontWeight(choice.active ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.pal().text)
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(choice.account.length > 0 ? choice.host + ' · ' + choice.account : choice.host)
                .fontSize(11)
                .fontColor(this.pal().text3)
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text(choice.active ? '✓' : '›')
              .fontSize(choice.active ? 17 : 15)
              .fontColor(choice.active ? '#22D3EE' : this.pal().text3)
          }
          .width('100%')
          .padding({ top: 12, bottom: 12, left: 14, right: 14 })
          .backgroundColor(choice.active
            ? 'rgba(34,211,238,0.14)'
            : (this.pressedChoiceKey === choice.url + '|' + choice.account ? this.pal().inputBg : this.pal().card))
          .borderRadius(14)
          .border({
            width: choice.active ? 1.5 : 1,
            color: choice.active ? 'rgba(34,211,238,0.75)' : this.pal().border
          })
          .onTouch((event: TouchEvent) => {
            const key: string = choice.url + '|' + choice.account;
            if (event.type === TouchType.Down) {
              this.pressedChoiceKey = key;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.pressedChoiceKey = '';
            }
          })
          .onClick(() => {
            this.chooseServerChoice(choice);
          })
            }, (choice: ServerChoice) => 'sv-' + choice.url + '|' + choice.account)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.62 : 460 })
        .width('100%')
        Text(this.tr('登录其他服务器…'))
          .fontSize(13)
          .fontColor(this.pal().text2)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(this.pal().chip)
          .borderRadius(14)
          .onClick(() => {
            this.showServerSwitch = false;
            this.runtime.logout();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 480 })
      .padding({ left: 20, right: 20, top: 18, bottom: 24 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: 1, color: this.pal().border })
      .transition(TransitionEffect.translate({ y: 320 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 220, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 设备页「更多」面板：系统菜单在深色/浅色下对比度不受控（退出登录看不清），
   * 改成自己画：每行大字号 + 明确的底色，退出登录用红底白字。
   */
  @Builder
  MoreMenuOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.showMoreMenu = false;
        })
      Column({ space: 10 }) {
        Text(this.tr('更多'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text)
          .width('100%')
        Row({ space: 8 }) {
          Text(this.tr('切换服务器'))
            .fontSize(15)
            .fontColor(this.pal().text)
          Text(this.runtime.email.length > 0 ? this.runtime.email : '')
            .fontSize(11)
            .fontColor(this.pal().text3)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ top: 14, bottom: 14, left: 16, right: 16 })
        .backgroundColor(this.pal().card)
        .borderRadius(14)
        .border({ width: 1, color: this.pal().border })
        .onClick(() => {
          this.showMoreMenu = false;
          this.openAccountSwitcher();
        })
        Row({ space: 8 }) {
          Text('⌁')
            .fontSize(15)
            .fontColor('#22D3EE')
          Text(this.tr('执行轨迹'))
            .fontSize(15)
            .fontColor(this.pal().text)
        }
        .width('100%')
        .padding({ top: 14, bottom: 14, left: 16, right: 16 })
        .backgroundColor(this.pal().card)
        .borderRadius(14)
        .border({ width: 1, color: this.pal().border })
        .onClick(() => {
          this.showMoreMenu = false;
          this.trajectoryOpen = true;
        })
        Text(this.tr('退出登录'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .backgroundColor('#E5484D')
          .borderRadius(14)
          .onClick(() => {
            this.showMoreMenu = false;
            AlertDialog.show({
              title: this.tr('退出登录'),
              message: this.tr('将清除本机保存的主机凭据，需要重新绑定才能连接。'),
              autoCancel: true,
              primaryButton: {
                value: this.tr('取消'),
                action: () => {
                }
              },
              secondaryButton: {
                value: this.tr('退出'),
                fontColor: '#F85749',
                action: () => {
                  this.runtime.logout();
                }
              }
            });
          })
        Text(this.tr('取消'))
          .fontSize(14)
          .fontColor(this.pal().text2)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(this.pal().chip)
          .borderRadius(14)
          .onClick(() => {
            this.showMoreMenu = false;
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 20, right: 20, top: 18, bottom: 26 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: 1, color: this.pal().border })
    }
    .width('100%')
    .height('100%')
  }

  /** 设置面板：主题做成可选列表，不再靠一颗按钮循环切。 */
  @Builder
  SettingsOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.showSettings = false;
        })
      Column() {
        Row() {
          Text(this.tr('设置'))
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Blank()
          Text(this.tr('完成'))
            .fontSize(13)
            .fontColor('#22D3EE')
            .padding({ left: 12, right: 4, top: 6, bottom: 6 })
            .onClick(() => {
              this.showSettings = false;
            })
        }
        .width('100%')
        .padding({ bottom: 6 })
        Scroll() {
          Column() {
          // 只重建「行」，不重建 Scroll 本身：否则每次点一行滚动位置都会被重置，看着像整块弹一下
          ForEach([this.settingsRev], (rev: number) => {
          Column({ space: 16 }) {
            // —— 服务器 ——
            Column({ space: 8 }) {
              Text(this.tr('服务器'))
                .fontSize(11)
                .fontColor(this.pal().text3)
                .width('100%')
                .padding({ left: 4 })
              this.SettingsGroupTitle(this.tr('账号与服务器'))
              this.SettingsRow(this.tr('切换服务器'), this.currentServerSummary(), false, () => {
                this.showSettings = false;
                this.showServerSwitch = true;
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            // —— 布局（分栏/密度，PC 与折叠屏才用得上）——
            Column({ space: 8 }) {
              Text(this.tr('布局'))
                .fontSize(11)
                .fontColor(this.pal().text3)
                .width('100%')
                .padding({ left: 4 })
              this.SettingsGroupTitle(this.tr('列表与布局'))
              this.SettingsRow(this.tr('列表密度'), this.layoutDensityLabel(), false, () => {
                this.openChoice('density');
              })
              this.SettingsRow(this.tr('右侧详情栏'),
                this.uiShowInspector ? this.tr('显示') : this.tr('隐藏'), false, () => {
                  this.uiShowInspector = !this.uiShowInspector;
                  this.settingsRev = this.settingsRev + 1;
                  this.runtime.setShowInspector(this.uiShowInspector);
                })
              if (this.uiSplitWidth > 0) {
                this.SettingsRow(this.tr('会话栏宽度'),
                  this.uiSplitWidth + 'vp', true, () => {
                    this.tapHaptic();
                    this.uiSplitWidth = 0;
                    this.settingsRev = this.settingsRev + 1;
                    this.runtime.setSplitWidth(0);
                    promptAction.showToast({ message: this.tr('已恢复默认宽度') });
                  })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            // —— 通用（低频，点开再选）——
            Column({ space: 8 }) {
              Text(this.tr('通用'))
                .fontSize(11)
                .fontColor(this.pal().text3)
                .width('100%')
                .padding({ left: 4 })
              this.SettingsGroupTitle(this.tr('高级'))
              this.SettingsRow(this.tr('清空本地数据'), this.tr('草稿/提示词/收藏'), true, () => {
                AlertDialog.show({
                  title: this.tr('清空本地数据'),
                  message: this.tr('会删除本机的草稿、提示词、收藏与最近访问，登录态和主机凭据不动。确定吗？'),
                  autoCancel: true,
                  primaryButton: {
                    value: this.tr('取消'),
                    action: () => {
                    }
                  },
                  secondaryButton: {
                    value: this.tr('清空'),
                    fontColor: '#F85749',
                    action: () => {
                      this.runtime.clearLocalPreferences();
                      promptAction.showToast({ message: this.tr('已清空本地数据') });
                    }
                  }
                });
              })
              this.SettingsGroupTitle(this.tr('桌宠与外观'))
              this.SettingsRow(this.tr('首页动态图'),
                !this.uiHomeMascot
                  ? this.tr('关闭')
                  : (this.runtime.homeMascotImage.length > 0 ? this.tr('自定义图片') : this.tr('内置立绘')),
                false, () => {
                  ActionSheet.show({
                    title: this.tr('首页动态图'),
                    message: this.tr('建议 PNG/JPG，比例约 3:4（如 300×400），单边 ≤1024px、文件 ≤1 MB；'
                      + '选图后会自动压到 512px 以内，透明背景请用 PNG。'),
                    sheets: [
                      {
                        title: this.tr('使用内置立绘'),
                        action: () => {
                          this.uiHomeMascot = true;
                          this.settingsRev = this.settingsRev + 1;
                          this.runtime.setHomeMascotImage('');
                          this.runtime.setHomeMascotEnabled(true);
                        }
                      },
                      {
                        title: this.tr('选择自定义图片'),
                        action: () => {
                          this.openHomeMascotPicker();
                        }
                      },
                      {
                        title: this.tr('关闭（不显示）'),
                        action: () => {
                          this.uiHomeMascot = false;
                          this.settingsRev = this.settingsRev + 1;
                          this.runtime.setHomeMascotEnabled(false);
                        }
                      }
                    ]
                  });
                })
              this.SettingsRow(this.tr('桌宠'),
                this.uiPetEnabled ? this.tr('开 · 干活/等确认/完成 四态') : this.tr('关'),
                false, () => {
                  this.uiPetEnabled = !this.uiPetEnabled;
                  this.settingsRev = this.settingsRev + 1;
                  this.runtime.setPetEnabled(this.uiPetEnabled);
                })
              this.SettingsRow(this.tr('桌宠素材'),
                PetPack.ready()
                  ? (PetPack.packSource() + ' · ' + PetPack.animNames())
                  : this.tr('未安装（用 emoji）'),
                false, () => {
                  AlertDialog.show({
                    title: this.tr('桌宠素材规格'),
                    message: this.petSpecText(),
                    autoCancel: true,
                    primaryButton: {
                      value: this.tr('重新加载'),
                      action: () => {
                        PetPack.reload(getContext(this)).then(() => {
                          this.restartPetAnimation();
                          promptAction.showToast({ message: PetPack.ready()
                            ? (this.tr('已加载：') + PetPack.packSource())
                            : this.tr('没有找到可用素材，继续用 emoji') });
                        }).catch(() => undefined);
                      }
                    },
                    secondaryButton: {
                      value: this.tr('关闭'),
                      action: () => undefined
                    }
                  });
                })
              this.SettingsRow(this.tr('主题色'), this.themeTintLabel(), false, () => {
                AlertDialog.show({
                  title: this.tr('主题色'),
                  message: this.tr('换一套氛围色（背景/面板/表面），强调色保持不变'),
                  autoCancel: true,
                  primaryButton: {
                    value: this.tr('取消'),
                    action: () => {
                    }
                  },
                  secondaryButton: {
                    value: this.tr('选择'),
                    action: () => {
                      this.tintPickerOpen = true;
                    }
                  }
                });
              })
              this.SettingsRow(this.tr('精简历史'),
                this.uiCompactHistory ? this.tr('开 · 历史工具输出转摘要') : this.tr('关 · 传完整历史'),
                false, () => {
                  this.uiCompactHistory = !this.uiCompactHistory;
                  this.settingsRev = this.settingsRev + 1;
                  this.runtime.setCompactHistory(!this.runtime.compactHistory).then(() => {
                    promptAction.showToast({ message: this.runtime.compactHistory
                      ? this.tr('已开启：下次打开会话生效') : this.tr('已关闭：下次打开会话生效') });
                  }).catch(() => undefined);
                })
              this.SettingsRow(this.tr('敏感内容打码'),
                this.uiSecretMask ? this.tr('开 · 点气泡看原文') : this.tr('关 · 原文显示'),
                false, () => {
                  this.uiSecretMask = !this.uiSecretMask;
                  this.settingsRev = this.settingsRev + 1;
                  this.runtime.setSecretMask(this.uiSecretMask);
                })
              this.SettingsGroupTitle(this.tr('远程与主机'))
              this.SettingsRow(this.tr('DS-Bot'),
                this.bots.length > 0 ? ('' + this.bots.length + ' ' + this.tr('个')) : this.tr('查看机器人/群组'),
                false, () => {
                  this.openBotsOverlay();
                })
              this.SettingsRow(this.tr('会员'),
                this.membershipLabel(),
                false, () => {
                  this.runtime.refreshMembership();
                  promptAction.showToast({ message: this.tr('正在刷新会员状态…') });
                })
              this.SettingsRow(this.tr('流转到其他设备'),
                this.runtime.continueReady() ? this.tr('在系统任务中心点本应用') : this.tr('先连上主机'),
                false, () => {
                  promptAction.showToast({
                    message: this.tr('长按系统任务中心里的本应用 → 流转；两台设备需登录同一华为账号')
                  });
                })
              if (this.runtime.gitReviewSupported()) {
                this.SettingsRow(this.tr('Git 审查'),
                  this.gitSummary.length > 0 ? this.gitSummary : this.tr('查看工作区改动'),
                  false, () => {
                    this.openGitOverlay();
                  })
              }
              this.SettingsRow(this.tr('插件管理'),
                this.hostPlugins.length > 0
                  ? ('' + this.hostPlugins.length + ' ' + this.tr('个插件包'))
                  : this.tr('查看主机插件'),
                false, () => {
                  this.openPluginsOverlay();
                })
              this.SettingsRow(this.tr('终端'),
                this.terminalRunning ? this.tr('运行中') : this.tr('打开会话终端'),
                false, () => {
                  this.openTerminalOverlay();
                })
              this.SettingsRow(this.tr('Web 控制台'),
                this.runtime.webConsoleUrl.length > 0 ? this.runtime.webConsoleUrl : this.tr('打开宿主机网页版'),
                false, () => {
                  this.openWebConsole();
                })
              this.SettingsRow(this.tr('连接诊断'),
                this.connectedTransport.length > 0 ? this.transportBadgeText() : this.tr('未连接'), false, () => {
                  const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
                  const lines: string[] = [
                    'bundle: cn.r2049.dshremote',
                    'app: ' + appVersion(),
                    'server: ' + this.accountServer,
                    'account: ' + this.accountEmail,
                    'host: ' + this.connectedHostDisplay(),
                    'transport: ' + (this.connectedTransport.length > 0 ? this.connectedTransport : 'none'),
                    'phone-model: ' + this.deviceModelLabel()
                  ];
                  const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, lines.join('\n'));
                  pasteboard.getSystemPasteboard().setData(data).then(() => {
                    promptAction.showToast({ message: this.tr('诊断信息已复制') });
                  }).catch(() => undefined);
                })
              this.SettingsGroupTitle(this.tr('通知与提醒'))
              this.SettingsRow(this.tr('完成通知'),
                this.uiNotifications ? this.tr('开') : this.tr('关'), false, () => {
                  const next: boolean = !this.uiNotifications;
                  this.uiNotifications = next;
                  this.settingsRev = this.settingsRev + 1;
                  this.runtime.notificationsEnabled = next;
                  if (next) {
                    const ability: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
                    this.runtime.requestNotificationPermission(ability).then((granted: boolean) => {
                      if (!granted) {
                        promptAction.showToast({ message: this.tr('系统通知权限未开启') });
                      }
                    }).catch(() => undefined);
                  }
                  this.runtime.notify();
                })
              this.SettingsGroupTitle(this.tr('外观与语言'))
              this.SettingsRow(this.tr('外观'), this.themeLabel(this.themeMode), false, () => {
                this.openChoice('theme');
              })
              this.SettingsRow(this.tr('文字大小'), this.textScaleLabel(), false, () => {
                this.openChoice('scale');
              })
              this.SettingsRow(this.tr('语言'), this.languageLabel(), false, () => {
                this.openChoice('language');
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            // —— 危险操作放最后 ——
            Column({ space: 8 }) {
              Text(this.tr('账号'))
                .fontSize(11)
                .fontColor(this.pal().text3)
                .width('100%')
                .padding({ left: 4 })
              Text(this.tr('退出登录'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 13, bottom: 13 })
                .backgroundColor('#E5484D')
                .borderRadius(12)
                .onClick(() => {
                  this.showSettings = false;
                  AlertDialog.show({
                    title: this.tr('退出登录'),
                    message: this.tr('将清除本机保存的主机凭据，需要重新绑定才能连接。'),
                    autoCancel: true,
                    primaryButton: {
                      value: this.tr('取消'),
                      action: () => {
                      }
                    },
                    secondaryButton: {
                      value: this.tr('退出'),
                      fontColor: '#F85749',
                      action: () => {
                        this.runtime.logout();
                      }
                    }
                  });
                })
              Text(this.buildTag())
                .fontSize(10)
                .fontColor(this.pal().text3)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 4 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ bottom: 8 })
          }, (rev: number) => 'settings-body-' + rev)
          }
          .width('100%')
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        // 拉到顶/到底有回弹，别像撞墙一样硬停
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.66 : 480 })
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
    }
    .width('100%')
    .height('100%')
  }

  /** 设置里的一行：左边标题、右边当前值 + 箭头。 */
  /** 设置面板里的分组标题：小字号 + 分隔线，避免一长条看不清层次。 */
  @Builder
  SettingsGroupTitle(title: string) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(this.fs(11))
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text3)
        .letterSpacing(1)
      Column()
        .layoutWeight(1)
        .height(0.5)
        .backgroundColor(this.pal().border)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 6, bottom: 2 })
  }

  @Builder
  SettingsRow(title: string, value: string, danger: boolean, action: () => void) {
    Row({ space: 10 }) {
      Text(title)
        .fontSize(14)
        .fontColor(danger ? '#F85749' : this.pal().text)
      Blank()
      if (value.length > 0) {
        Text(value)
          .fontSize(12)
          .fontColor(this.pal().text3)
          .maxLines(1)
          .constraintSize({ maxWidth: 170 })
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      Text('›')
        .fontSize(15)
        .fontColor(this.pal().text3)
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 14, right: 14 })
    .backgroundColor(this.pal().card)
    .borderRadius(12)
    .border({ width: 1, color: this.pal().border })
    .onClick(() => {
      this.tapHaptic();
      action();
    })
  }

  /** 壁纸压暗色：淡/中/浓三档，深浅色各一套。 */
  private wallpaperScrim(): string {
    if (this.isDarkUi) {
      return this.uiWallpaperDim === 0 ? 'rgba(10,14,24,0.42)'
        : (this.uiWallpaperDim === 2 ? 'rgba(10,14,24,0.76)' : 'rgba(10,14,24,0.62)');
    }
    // 浅色蒙层压成冷灰蓝而不是奶白：壁纸还在，但不会把整屏刷成一片白，
    // 也不会让壁纸的暖色直接透到气泡上。
    return this.uiWallpaperDim === 0 ? 'rgba(214,223,237,0.34)'
      : (this.uiWallpaperDim === 2 ? 'rgba(206,215,230,0.76)' : 'rgba(210,219,234,0.58)');
  }

  private wallpaperDimLabel(): string {
    if (this.uiWallpaperDim === 0) {
      return this.tr('淡 · 壁纸更明显');
    }
    if (this.uiWallpaperDim === 2) {
      return this.tr('浓 · 更接近纯色');
    }
    return this.tr('中 · 平衡');
  }

  /** 选一张壁纸：压到长边 720、JPEG q70 再存（虚化后不需要高清）。 */
  /** 选一张图当首页立绘：压到 512px 长边存 base64，和壁纸同一套压缩思路。 */
  private async openHomeMascotPicker(): Promise<void> {
    try {
      const picked: PickedImage[] = await pickImages(1);
      if (picked.length === 0) {
        return;
      }
      let base64: string = picked[0].base64;
      try {
        const bytes: Uint8Array = new util.Base64Helper().decodeSync(base64);
        const source: image.ImageSource = image.createImageSource(bytes.buffer as ArrayBuffer);
        const info: image.ImageInfo = await source.getImageInfo();
        const longest: number = Math.max(info.size.width, info.size.height);
        const scale: number = longest > 512 ? 512 / longest : 1;
        const pixel: image.PixelMap = await source.createPixelMap({
          desiredSize: {
            width: Math.max(1, Math.round(info.size.width * scale)),
            height: Math.max(1, Math.round(info.size.height * scale))
          }
        });
        const packer: image.ImagePacker = image.createImagePacker();
        const encoded: ArrayBuffer = await packer.packing(pixel, { format: 'image/jpeg', quality: 82 });
        base64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(encoded));
      } catch (error) {
        logWarn('home mascot compress failed, keep original');
      }
      this.uiHomeMascot = true;
      this.settingsRev = this.settingsRev + 1;
      this.runtime.setHomeMascotImage(base64);
      this.runtime.setHomeMascotEnabled(true);
      promptAction.showToast({ message: this.tr('首页立绘已更新') });
    } catch (error) {
      logWarn('home mascot pick failed: ' + errorMessage(error));
      promptAction.showToast({ message: this.tr('选图失败，换一张试试') });
    }
  }

  /** 打开 Git 审查：拉一次工作区改动清单。 */
  private openGitOverlay(): void {
    this.gitOpen = true;
    this.gitLoading = true;
    this.gitError = '';
    this.gitDiffPath = '';
    this.gitDiffText = '';
    this.gitSelected = [];
    this.runtime.loadGitStatus().then((status: WorkspaceGitStatus) => {
      this.gitFiles = status.files;
      this.gitBranch = status.branch;
      this.gitSummary = (status.branch.length > 0 ? status.branch + ' · ' : '')
        + status.totalFiles + this.tr(' 个文件 · +') + status.totalAdditions + ' −' + status.totalDeletions;
      this.gitLoading = false;
    }).catch((error: Error) => {
      this.gitLoading = false;
      this.gitError = errorMessage(error);
      this.gitSummary = '';
    });
  }

  private openGitDiff(path: string): void {
    this.gitDiffPath = path;
    this.gitDiffText = '';
    this.gitDiffError = '';
    this.runtime.loadGitDiff(path).then((diff: WorkspaceGitDiff) => {
      this.gitDiffText = diff.isBinary ? this.tr('二进制文件，没有文本 diff') : diff.diff;
      if (this.gitDiffText.length === 0) {
        this.gitDiffText = this.tr('没有差异内容');
      }
    }).catch((error: Error) => {
      this.gitDiffError = errorMessage(error);
    });
  }

  private toggleGitFile(path: string): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (const item of this.gitSelected) {
      if (item === path) {
        removed = true;
      } else {
        next.push(item);
      }
    }
    if (!removed) {
      next.push(path);
    }
    this.gitSelected = next;
  }

  /** 把勾选的文件作为一条消息回传，让 agent 针对这些改动继续处理。 */
  private sendGitSelection(): void {
    if (this.gitSelected.length === 0) {
      promptAction.showToast({ message: this.tr('先勾选要处理的文件') });
      return;
    }
    const lines: string[] = [];
    lines.push(this.tr('请针对下面这些工作区改动继续修改：'));
    for (const path of this.gitSelected) {
      lines.push('- ' + path);
    }
    this.gitOpen = false;
    this.runtime.sendPrompt(lines.join(String.fromCharCode(10)));
  }

  /** 打开 DS-Bot 目录：主机没装时给出明确提示。 */
  private openBotsOverlay(): void {
    this.botsOpen = true;
    this.botsLoading = true;
    this.botsError = '';
    this.runtime.fetchBotCatalog().then((rows: BotCatalogRow[]) => {
      this.bots = rows;
      this.botsLoading = false;
    }).catch((error: Error) => {
      this.botsLoading = false;
      const message: string = errorMessage(error);
      if (message.indexOf('BOT_NOT_INSTALLED') >= 0) {
        this.botsError = this.tr('此主机未安装 DS-Bot');
      } else if (message.indexOf('BOT_UNSUPPORTED') >= 0) {
        this.botsError = this.tr('此主机未开放 DS-Bot');
      } else {
        this.botsError = message;
      }
    });
  }

  /** 打开插件管理：读一次宿主的插件清单。 */
  private openPluginsOverlay(): void {
    this.pluginsOpen = true;
    this.pluginsLoading = true;
    this.pluginsError = '';
    this.runtime.loadHostPlugins().then((list: HostPluginBundle[]) => {
      this.hostPlugins = list;
      this.pluginsLoading = false;
      this.pluginsRev = this.pluginsRev + 1;
    }).catch((error: Error) => {
      this.pluginsLoading = false;
      this.pluginsError = errorMessage(error);
      this.pluginsRev = this.pluginsRev + 1;
    });
  }

  /** 启停一个插件包或单个插件。 */
  private toggleHostPlugin(target: string, enabled: boolean, isBundle: boolean): void {
    this.runtime.setHostPluginEnabled(target, enabled, isBundle).then((note: string) => {
      promptAction.showToast({ message: note.length > 0 ? note : this.tr('已修改，重启 Harness 生效') });
      this.openPluginsOverlay();
    }).catch((error: Error) => {
      promptAction.showToast({ message: errorMessage(error) });
    });
  }

  /** 会员状态一句话：未开通 / 有效（到期日）/ 已过期 / 已撤销。 */
  private membershipLabel(): string {
    const status: string = this.runtime.membership.status;
    const expiry: number = this.runtime.membership.expiresAt;
    const date: string = expiry > 0 ? formatDateOnly(expiry) : '';
    if (status === 'active') {
      return date.length > 0 ? this.tr('有效 · 到期 ') + date : this.tr('有效');
    }
    if (status === 'expired') {
      return this.tr('已过期') + (date.length > 0 ? ' · ' + date : '');
    }
    if (status === 'revoked') {
      return this.tr('已撤销');
    }
    if (status === 'none') {
      return this.tr('未开通');
    }
    return this.tr('点此查询');
  }

  /** 打开某个插件的设置表单。 */
  private openPluginForm(title: string, form: PluginSettingsForm | undefined): void {
    if (form === undefined) {
      return;
    }
    this.pluginFormTitle = title;
    this.pluginFormFields = form.fields;
    this.pluginFormNamespace = form.namespace;
    this.pluginFormRevision = form.revision;
    this.pluginFormEditing = '';
    this.pluginFormDraft = '';
    this.pluginFormOpen = true;
  }

  /** 保存一个字段：布尔直接切，其余用编辑框里的草稿编码。 */
  private savePluginField(field: PluginSettingField, draft: string): void {
    const value: Object | undefined = field.encode(draft);
    if (value === undefined) {
      promptAction.showToast({ message: this.tr('格式不对，检查一下再存') });
      return;
    }
    this.runtime.savePluginSetting(this.pluginFormNamespace, this.pluginFormRevision, field.key, value)
      .then(() => {
        promptAction.showToast({ message: this.tr('已保存') });
        this.pluginFormOpen = false;
        this.openPluginsOverlay();
      })
      .catch((error: Error) => {
        promptAction.showToast({ message: errorMessage(error) });
      });
  }

  private toastPluginReadOnly(): void {
    promptAction.showToast({ message: this.tr('这个插件被宿主标记为只读') });
  }

  /** 打开会话终端：拉一个流，输出滚进缓冲区。 */
  private openTerminalOverlay(): void {
    if (this.terminalBusy) {
      return;
    }
    this.terminalBusy = true;
    this.terminalOpen = true;
    this.terminalText = '';
    this.terminalTitle = '';
    this.terminalReady = false;
    this.terminalPending = [];
    this.terminalBridge.onData = (data: string) => {
      this.runtime.writeTerminal(data);
    };
    this.terminalBridge.onReady = () => {
      this.terminalReady = true;
      this.flushTerminalPending();
    };
    this.runtime.openTerminal((data: string) => {
      this.writeTerminalView(data);
    }, (writable: boolean, running: boolean) => {
      this.terminalWritable = writable;
      this.terminalRunning = running;
      if (!running) {
        this.terminalBusy = false;
      }
    }).then((title: string) => {
      this.terminalTitle = title;
      this.terminalBusy = false;
      this.terminalRunning = true;
    }).catch((error: Error) => {
      this.terminalBusy = false;
      this.terminalRunning = false;
      this.terminalText = this.tr('无法打开终端') + '：' + errorMessage(error);
    });
  }

  /** 把一段输出送进 xterm；视图没就绪先缓冲（最多留 2 万字符）。 */
  private writeTerminalView(data: string): void {
    if (!this.terminalReady) {
      this.terminalPending.push(data);
      let total: number = 0;
      for (const chunk of this.terminalPending) {
        total += chunk.length;
      }
      while (total > 20000 && this.terminalPending.length > 0) {
        total -= this.terminalPending[0].length;
        this.terminalPending.shift();
      }
      return;
    }
    try {
      const literal: string = JSON.stringify(data);
      this.terminalController.runJavaScript('window.__dshTerm && window.__dshTerm.write(' + literal + ');');
    } catch (error) {
      logWarn('terminal write failed');
    }
  }

  private flushTerminalPending(): void {
    const chunks: string[] = this.terminalPending;
    this.terminalPending = [];
    for (const chunk of chunks) {
      this.writeTerminalView(chunk);
    }
  }

  private closeTerminalOverlay(): void {
    this.runtime.closeTerminal();
    this.terminalOpen = false;
    this.terminalRunning = false;
    this.terminalWritable = false;
  }

  private sendTerminalInput(): void {
    const text: string = this.terminalInput;
    if (text.length === 0) {
      return;
    }
    this.runtime.writeTerminal(text + String.fromCharCode(13));
    this.terminalInput = '';
  }

  /** 密码登录：有挑战就走第二步，否则先拿挑战。 */
  private submitPasswordLogin(): void {
    const server: string = this.serverInput;
    const challenge: string = this.passwordChallengeServer === server ? this.passwordChallenge : '';
    this.runtime.login(server, this.emailInput, this.passwordInput, challenge, this.twoFactorCode)
      .then((next: string | undefined) => {
        if (next !== undefined && next.length > 0 && this.serverInput === server) {
          this.passwordChallengeServer = server;
          this.passwordChallenge = next;
          this.passwordInput = '';
          this.twoFactorCode = '';
        } else if (this.passwordChallenge.length > 0) {
          this.passwordChallenge = '';
          this.twoFactorCode = '';
        }
      })
      .catch(() => undefined);
  }

  private async openWallpaperPicker(): Promise<void> {
    try {
      const picked: PickedImage[] = await pickImages(1);
      if (picked.length === 0) {
        return;
      }
      let base64: string = picked[0].base64;
      try {
        const bytes: Uint8Array = new util.Base64Helper().decodeSync(base64);
        const source: image.ImageSource = image.createImageSource(bytes.buffer as ArrayBuffer);
        const info: image.ImageInfo = await source.getImageInfo();
        const longest: number = Math.max(info.size.width, info.size.height);
        const scale: number = longest > 720 ? 720 / longest : 1;
        const pixel: image.PixelMap = await source.createPixelMap({
          desiredSize: {
            width: Math.max(1, Math.round(info.size.width * scale)),
            height: Math.max(1, Math.round(info.size.height * scale))
          }
        });
        const packer: image.ImagePacker = image.createImagePacker();
        const encoded: ArrayBuffer = await packer.packing(pixel, { format: 'image/jpeg', quality: 70 });
        base64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(encoded));
      } catch (error) {
        logWarn('wallpaper compress failed, keep original');
      }
      this.wallpaper = base64;
      this.settingsRev = this.settingsRev + 1;
      this.runtime.setWallpaper(base64);
      promptAction.showToast({ message: this.tr('壁纸已更新') });
    } catch (error) {
      logWarn('wallpaper pick failed: ' + errorMessage(error));
    }
  }

  /** 单击/双击的统一入口：320ms 内第二下算双击（炸屏），否则延时 320ms 说俏皮话。 */
  /** 松手回位：先随机折到一个中间点再回原位，总时长约 680ms（原来 340ms 太快）。 */
  private returnPetWithRandomPath(): void {
    const scatter: number = 60;
    const midX: number = this.petDragX * 0.35 + (Math.random() - 0.5) * scatter;
    const midY: number = this.petDragY * 0.35 + (Math.random() - 0.5) * scatter;
    animateTo({ duration: 280, curve: Curve.EaseOut }, () => {
      this.petDragX = midX;
      this.petDragY = midY;
    });
    setTimeout(() => {
      animateTo({ duration: 400, curve: Curve.Friction }, () => {
        this.petDragX = 0;
        this.petDragY = 0;
      });
    }, 280);
  }

  private onPetTap(): void {
    const now: number = Date.now();
    if (now - this.petLastTap < 320) {
      this.petLastTap = 0;
      if (this.petTapTimer >= 0) {
        clearTimeout(this.petTapTimer);
        this.petTapTimer = -1;
      }
      this.playPetBoom();
      return;
    }
    this.petLastTap = now;
    if (this.petTapTimer >= 0) {
      clearTimeout(this.petTapTimer);
    }
    this.petTapTimer = setTimeout(() => {
      this.petTapTimer = -1;
      this.sayPetQuip();
    }, 320);
  }

  /** 点一下桌宠：按当前状态随机说一句俏皮话。 */
  private sayPetQuip(): void {
    if (this.petIdleSince > 0 && Date.now() - this.petIdleSince > 180000) {
      // 睡着被点醒：重新计时，动画切回 idle
      this.petIdleSince = Date.now();
      this.restartPetAnimation();
    }
    const state: string = this.runtime.petState();
    const pool: string[] = state === 'working'
      ? ['别催别催，正在想…', '键盘都要冒烟了', '这活儿有点难，等我捋捋', '先把思路理顺再动手',
        '正在搬砖，勿扰', '再等等，快好了']
      : (state === 'waiting'
        ? ['有个事得你点个头', '你倒是看看我举的手', '卡在这儿了，需要你拍板', '我举着手呢…']
        : (state === 'done'
          ? ['干完啦！', '这波不错吧？', '收工，喝口水', '活儿我拿下了']
          : ['随时待命～', '呼吸中…', '要不咱们聊点别的？', '喝水去吧，我盯着',
            '摸鱼也要有节奏', '在的，叫我干嘛']));
    const index: number = Math.floor(Math.random() * pool.length);
    this.petQuip = pool[index >= pool.length ? 0 : index];
    if (this.petQuipTimer >= 0) {
      clearTimeout(this.petQuipTimer);
    }
    this.petQuipTimer = setTimeout(() => {
      this.petQuipTimer = -1;
      this.petQuip = '';
    }, 2600);
  }

  /** 双击桌宠：放大到铺满屏幕，停一下再缩回去（时间按手感定的，别太突兀）。 */
  private playPetBoom(): void {
    if (this.petBooming) {
      return;
    }
    this.petBooming = true;
    this.tapHaptic();
    const frameW: number = Math.max(1, this.petFrameWidth());
    const frameH: number = Math.max(1, this.petFrameHeight());
    const viewW: number = this.windowWidthVp > 0 ? this.windowWidthVp : 400;
    const viewH: number = this.windowHeightVp > 0 ? this.windowHeightVp : 800;
    // 覆盖整屏所需的倍数（宽高都盖住，取大的那个）；系数 1 = 刚好铺满
    const target: number = Math.max(viewW / frameW, viewH / frameH) * 0.85;
    this.petBoomScale = 1;
    this.petBoomVisible = true;
    animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
      this.petBoomOpacity = 1;
    });
    animateTo({ duration: 580, curve: Curve.Friction }, () => {
      this.petBoomScale = target;
    });
    setTimeout(() => {
      animateTo({ duration: 680, curve: Curve.EaseInOut }, () => {
        this.petBoomScale = 1;
      });
      animateTo({ duration: 520, curve: Curve.EaseIn }, () => {
        this.petBoomOpacity = 0;
      });
      setTimeout(() => {
        this.petBoomVisible = false;
        this.petBooming = false;
      }, 700);
    }, 800);
  }

  /** 轻触反馈：设置行点按给一记很短的振动（拿不到振动器就安静跳过）。 */
  private tapHaptic(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 12 },
        { id: 0, usage: 'touch' }).catch(() => undefined);
    } catch (error) {
      logWarn('vibrate failed');
    }
  }

  private currentServerSummary(): string {
    return this.accountSwitchLabel();
  }

  private textScaleLabel(): string {
    if (this.textScaleMode === 0) {
      return this.tr('小') + ' 0.9×';
    }
    if (this.textScaleMode === 2) {
      return this.tr('大') + ' 1.15×';
    }
    if (this.textScaleMode === 3) {
      return this.tr('特大') + ' 1.3×';
    }
    return this.tr('标准') + ' 1.0×';
  }

  private languageLabel(): string {
    if (this.languageMode === 1) {
      return '中文';
    }
    if (this.languageMode === 2) {
      return 'English';
    }
    return this.tr('跟随系统');
  }

  /** 打开通用设置的选择面板（外观 / 文字大小 / 语言）。 */
  private openChoice(kind: string): void {
    this.choiceKind = kind;
    this.choiceOpen = true;
  }

  /** 布局密度文案：0 自动 / 1 紧凑 / 2 超紧凑。 */
  private layoutDensityLabel(): string {
    const value: number = this.runtime.layoutDensity;
    if (value === 1) {
      return this.tr('紧凑');
    }
    if (value === 2) {
      return this.tr('超紧凑');
    }
    return this.tr('自动（分栏时紧凑）');
  }

  private densityChoices(): ThemeChoice[] {
    return [
      new ThemeChoice(0, this.tr('自动'), this.tr('分栏时自动收紧，单列保持宽松')),
      new ThemeChoice(1, this.tr('紧凑'), this.tr('行高小一点，同屏多两行')),
      new ThemeChoice(2, this.tr('超紧凑'), this.tr('只留标题和时间，隐藏轮数与目录'))
    ];
  }

  /**
   * 登录页是否展开账号密码输入：没有可用的扫码/授权方式时必须露出；
   * 有的话默认收起，用户点「用账号密码登录」再展开（对齐上游 #335）。
   */
  private showPasswordLogin(): boolean {
    if (this.passwordLoginOpen) {
      return true;
    }
    // 已经填了账号/密码就别收起来（providers 晚到时输入框突然消失最恼人）
    if (this.emailInput.length > 0 || this.passwordInput.length > 0) {
      return true;
    }
    return this.providers.length === 0;
  }

  private choiceTitleText(): string {
    if (this.choiceKind === 'theme') {
      return this.tr('外观');
    }
    if (this.choiceKind === 'scale') {
      return this.tr('文字大小');
    }
    if (this.choiceKind === 'density') {
      return this.tr('列表密度');
    }
    return this.tr('语言');
  }

  private choiceItems(): ThemeChoice[] {
    if (this.choiceKind === 'theme') {
      return this.themeChoices();
    }
    if (this.choiceKind === 'scale') {
      return this.textScaleChoices();
    }
    if (this.choiceKind === 'density') {
      return this.densityChoices();
    }
    return this.languageChoices();
  }

  private choiceCurrentValue(): number {
    if (this.choiceKind === 'theme') {
      return this.themeMode;
    }
    if (this.choiceKind === 'scale') {
      return this.textScaleMode;
    }
    if (this.choiceKind === 'density') {
      return this.runtime.layoutDensity;
    }
    return this.languageMode;
  }

  private applyChoice(value: number): void {
    if (this.choiceKind === 'theme') {
      this.runtime.setThemeMode(value);
    } else if (this.choiceKind === 'scale') {
      this.runtime.setTextScaleMode(value);
    } else if (this.choiceKind === 'density') {
      this.runtime.setLayoutDensity(value);
    } else {
      this.runtime.setLanguageMode(value);
    }
    // 字号/密度这类改的是 @State 派生的尺寸，ForEach 不换 key 就不会重排；
    // 这里同时把设置面板版本号推进一格，回到面板时也不用等重开。
    this.settingsRev = this.settingsRev + 1;
    this.choiceOpen = false;
  }

  /** 通用设置的点选面板（带弹出/收回动画）。 */
  @Builder
  ChoiceSheetOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.choiceOpen = false;
        })
      Column({ space: 8 }) {
        Row() {
          Text(this.choiceTitleText())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.choiceOpen = false;
            })
        }
        .width('100%')
        .padding({ bottom: 2 })
        ForEach(this.choiceItems(), (choice: ThemeChoice) => {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text(t(choice.label))
                .fontSize(14)
                .fontColor(this.pal().text)
              Text(t(choice.hint))
                .fontSize(11)
                .fontColor(this.pal().text3)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            if (this.choiceCurrentValue() === choice.value) {
              Text('✓')
                .fontSize(16)
                .fontColor('#22D3EE')
            }
          }
          .width('100%')
          .padding({ top: 12, bottom: 12, left: 14, right: 14 })
          .backgroundColor(this.choiceCurrentValue() === choice.value
            ? 'rgba(34,211,238,0.14)' : this.pal().card)
          .borderRadius(12)
          .border({
            width: this.choiceCurrentValue() === choice.value ? 1.5 : 1,
            color: this.choiceCurrentValue() === choice.value
              ? 'rgba(34,211,238,0.75)' : this.pal().border
          })
          .onClick(() => {
            this.applyChoice(choice.value);
          })
        }, (choice: ThemeChoice) => 'choice-' + choice.value)
      }
      .width('100%')
      .constraintSize({ maxWidth: 480 })
      .padding({ left: 20, right: 20, top: 16, bottom: 22 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 300 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 单台设备的能力菜单（卡片上的 ⋯）：行之间留间距、危险项单独标红。 */
  @Builder
  DeviceMenuOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.deviceMenuId = '';
        })
      Column({ space: 10 }) {
        Column({ space: 3 }) {
          Text(this.deviceMenuTitle())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.tr('主机操作'))
            .fontSize(11)
            .fontColor(this.pal().text3)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        Text(this.tr('查看详情'))
          .fontSize(this.fs(15))
          .fontColor(this.pal().text)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .backgroundColor(this.pal().card)
          .borderRadius(14)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            const target: string = this.deviceMenuId;
            this.deviceMenuId = '';
            this.deviceDetailId = target;
          })
        Text(this.tr('改名'))
          .fontSize(14)
          .fontColor(this.pal().text)
          .width('100%')
          .padding({ top: 13, bottom: 13, left: 16 })
          .backgroundColor(this.pal().card)
          .borderRadius(12)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            const device: RemoteHostDevice | undefined = this.deviceById(this.deviceMenuId);
            this.deviceMenuId = '';
            if (device !== undefined) {
              this.beginRename(device);
            }
          })
        if (this.deviceMenuPinned()) {
          Text(this.tr('清除公钥固定'))
            .fontSize(14)
            .fontColor('#F85749')
            .width('100%')
            .padding({ top: 13, bottom: 13, left: 16 })
            .backgroundColor('rgba(248,87,73,0.10)')
            .borderRadius(12)
            .border({ width: 1, color: 'rgba(248,87,73,0.35)' })
            .onClick(() => {
              const id: string = this.deviceMenuId;
              this.deviceMenuId = '';
              this.confirmForgetPin(id);
            })
        }
        Text(this.tr('取消'))
          .fontSize(13)
          .fontColor(this.pal().text2)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(this.pal().chip)
          .borderRadius(12)
          .onClick(() => {
            this.deviceMenuId = '';
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 460 })
      .padding({ left: 20, right: 20, top: 16, bottom: 22 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 300 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  private deviceMenuTitle(): string {
    const device: RemoteHostDevice | undefined = this.deviceById(this.deviceMenuId);
    if (device === undefined) {
      return '';
    }
    const name: string = this.displayNameFor(device);
    return name.length > 0 ? name : device.deviceId;
  }

  private deviceMenuPinned(): boolean {
    return this.deviceMenuId.length > 0 && this.runtime.hasHostPin(this.deviceMenuId);
  }

  private deviceById(id: string): RemoteHostDevice | undefined {
    for (const device of this.devices) {
      if (device.deviceId === id) {
        return device;
      }
    }
    return undefined;
  }

  private confirmForgetPin(deviceId: string): void {
    AlertDialog.show({
      title: this.tr('该主机已固定公钥'),
      message: this.tr('主机重置或更换后，本地固定的公钥会对不上，导致无法连接。\n'
        + '清除后下次连接将重新信任首次看到的公钥。'),
      primaryButton: {
        value: this.tr('取消'),
        action: () => {
        }
      },
      secondaryButton: {
        value: this.tr('清除固定记录'),
        fontColor: '#F85749',
        action: () => {
          this.runtime.forgetHostPin(deviceId);
          this.errorMsg = '';
          this.infoMsg = this.tr('已清除该主机的公钥固定记录');
        }
      }
    });
  }

  @Builder
  LogoChip() {    Column() {
      Text('DS')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(2)
    }
    .width(72)
    .height(72)
    .borderRadius(22)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
    .shadow({ radius: 30, color: 'rgba(77,107,254,0.5)', offsetX: 0, offsetY: 10 })
  }

  @Builder
  BootScreen() {
    Column({ space: 14 }) {
      Blank()
      this.LogoChip()
      Text('DSH REMOTE')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.pal().text)
        .letterSpacing(6)
        .textShadow({ radius: 16, color: 'rgba(77,107,254,0.55)' })
      LoadingProgress()
        .width(36)
        .height(36)
        .color('#22D3EE')
      Text(this.tr('正在初始化…'))
        .fontSize(13)
        .fontColor(this.pal().text2)
        .letterSpacing(1)
      Blank()
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SetupScreen() {
    Scroll() {
      Column() {
      Column({ space: 14 }) {
      this.LogoChip()
      Column({ space: 6 }) {
        Text('DSH REMOTE')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text)
          .letterSpacing(6)
          .textShadow({ radius: 18, color: 'rgba(77,107,254,0.6)' })
        Text(this.tr('连接你的 DEEPSEEK HARNESS 主机'))
          .fontSize(12)
          .fontColor(this.pal().text2)
          .letterSpacing(1)
      }
      if (this.profilesList.length > 0) {
        Column({ space: 8 }) {
          Text(this.tr('已保存的登录（一键进入）'))
            .fontSize(11)
            .fontColor(this.pal().text3)
            .width('100%')
          ForEach(this.profilesList, (profile: SavedProfile) => {
            Row({ space: 10 }) {
              Column({ space: 2 }) {
                Text(profile.email)
                  .fontSize(13)
                  .fontColor(this.pal().text)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(profile.baseUrl)
                  .fontSize(10)
                  .fontColor(this.pal().text3)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Text(this.tr('进入'))
                .fontSize(11)
                .fontColor('#0B1220')
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .backgroundColor('#22D3EE')
                .borderRadius(10)
            }
            .width('100%')
            .padding({ top: 8, bottom: 8, left: 12, right: 12 })
            .backgroundColor(this.pal().chip)
            .borderRadius(12)
            .border({ width: 1, color: this.pal().border })
            .enabled(!this.busy)
            .onClick(() => {
              this.runtime.switchProfile(profile);
            })
          }, (profile: SavedProfile) => 'login-' + profile.baseUrl + '|' + profile.email)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }
      Row({ space: 8 }) {
        Text(this.tr('常用'))
          .fontSize(11)
          .fontColor(this.pal().text3)
        Text('官方 ' + 'dsh.r2049.cn')
          .fontSize(11)
          .fontColor(this.serverInput.indexOf('dsh.r2049.cn') >= 0 ? '#0B1220' : this.pal().text2)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.serverInput.indexOf('dsh.r2049.cn') >= 0 ? '#22D3EE' : this.pal().chip)
          .borderRadius(9)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            this.serverInput = 'https://dsh.r2049.cn';
          })
        Text(this.tr('本地') + ' 192.168.11.128')
          .fontSize(11)
          .fontColor(this.serverInput.indexOf('192.168.11.128') >= 0 ? '#0B1220' : this.pal().text2)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(this.serverInput.indexOf('192.168.11.128') >= 0 ? '#22D3EE' : this.pal().chip)
          .borderRadius(9)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            this.serverInput = 'http://192.168.11.128:8080';
          })
      }
      .width('100%')
      .padding({ top: 2, bottom: 2 })
      TextInput({ text: this.serverInput, placeholder: this.tr('服务器地址（http://…）') })
        .height(48)
        .backgroundColor(this.pal().chip)
        .fontColor(this.pal().text)
        .placeholderColor(this.pal().text3)
        .caretColor('#22D3EE')
        .borderRadius(14)
        .border({ width: 1, color: this.pal().borderStrong })
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.serverInput = value;
        })
      if (this.showPasswordLogin()) {
      TextInput({ text: this.emailInput, placeholder: this.tr('邮箱') })
        .height(48)
        .backgroundColor(this.pal().chip)
        .fontColor(this.pal().text)
        .placeholderColor(this.pal().text3)
        .caretColor('#22D3EE')
        .borderRadius(14)
        .border({ width: 1, color: this.pal().borderStrong })
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.emailInput = value;
        })
      TextInput({ text: this.passwordInput, placeholder: this.tr('密码') })
        .type(InputType.Password)
        .height(48)
        .backgroundColor(this.pal().chip)
        .fontColor(this.pal().text)
        .placeholderColor(this.pal().text3)
        .caretColor('#22D3EE')
        .borderRadius(14)
        .border({ width: 1, color: this.pal().borderStrong })
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.passwordInput = value;
        })
        .onSubmit(() => {
          this.submitPasswordLogin();
        })
      if (this.passwordChallenge.length > 0 && this.passwordChallengeServer === this.serverInput) {
        TextInput({ text: this.twoFactorCode, placeholder: this.tr('验证码或恢复码') })
          .height(48)
          .backgroundColor(this.pal().chip)
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .caretColor('#22D3EE')
          .borderRadius(14)
          .border({ width: 1, color: 'rgba(34,211,238,0.45)' })
          .padding({ left: 16, right: 16 })
          .onChange((value: string) => {
            this.twoFactorCode = value;
          })
          .onSubmit(() => {
            this.submitPasswordLogin();
          })
        Text(this.tr('重新输入密码'))
          .fontSize(this.fs(11))
          .fontColor('#22D3EE')
          .onClick(() => {
            this.passwordChallenge = '';
            this.twoFactorCode = '';
            this.passwordChallengeServer = '';
          })
      }
      Button(this.tr('登录'))
        .width('100%')
        .height(50)
        .backgroundColor(Color.Transparent)
        .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#3AA6F0', 0.55], ['#22D3EE', 1]] })
        .shadow({ radius: 18, color: 'rgba(77,107,254,0.45)', offsetX: 0, offsetY: 6 })
        .fontColor('#FFFFFF')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .borderRadius(14)
        .enabled(!this.busy)
        .onClick(() => {
          this.submitPasswordLogin();
        })
      } else {
        Row({ space: 6 }) {
          Text(this.tr('用账号密码登录'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .onClick(() => {
              this.passwordLoginOpen = true;
            })
          Text(this.tr('· DeepSeek 账号请用上面的扫码/授权'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
      }
      if (this.providers.length > 0) {
        Column({ space: 8 }) {
          Text(this.tr('扫码 / 浏览器授权登录（选账号对应的提供商）'))
            .fontSize(12)
            .fontColor(this.pal().text2)
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
            ForEach(this.providers, (item: OAuthProvider) => {
              Button(item.displayName)
                .height(38)
                .fontSize(13)
                .fontColor('#22D3EE')
                .backgroundColor(this.pal().chip)
                .borderRadius(19)
                .border({ width: 1, color: this.providerId === item.id ? 'rgba(34,211,238,0.9)' : this.pal().borderStrong })
                .margin(4)
                .enabled(!this.busy)
                .onClick(() => {
                  this.runtime.selectProvider(item.id);
                  this.runtime.startQrLogin(this.serverInput);
                })
            }, (item: OAuthProvider) => item.id)
          }
        }
        .width('100%')
      } else {
        Button(this.tr('扫码 / 浏览器授权登录'))
          .width('100%')
          .height(44)
          .backgroundColor(this.pal().chip)
          .fontColor('#22D3EE')
          .fontSize(14)
          .borderRadius(14)
          .border({ width: 1, color: this.pal().borderStrong })
          .enabled(!this.busy)
          .onClick(() => {
            this.runtime.loadProviders(this.serverInput);
            this.runtime.startQrLogin(this.serverInput);
          })
      }
      if (this.qrUrl.length > 0) {
        Column({ space: 10 }) {
          Text(this.tr('用已登录同一账号的浏览器扫码或点按钮授权'))
            .fontSize(12)
            .fontColor(this.pal().text2)
            .textAlign(TextAlign.Center)
          QRCode(this.qrUrl)
            .width(160)
            .height(160)
            .color('#0B0F19')
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
          Button(this.tr('在浏览器中打开授权页'))
            .width('100%')
            .height(40)
            .backgroundColor(Color.Transparent)
            .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#3AA6F0', 0.55], ['#22D3EE', 1]] })
            .fontColor('#FFFFFF')
            .fontSize(14)
            .borderRadius(12)
            .onClick(() => {
              this.openAuthorizeLink();
            })
          Text(this.qrUrl)
            .fontSize(11)
            .fontColor('#22D3EE')
            .copyOption(CopyOptions.LocalDevice)
            .textAlign(TextAlign.Center)
            .wordBreak(WordBreak.BREAK_ALL)
            .width('100%')
          Button(this.tr('复制授权链接'))
            .height(30)
            .fontSize(12)
            .fontColor(this.pal().text2)
            .backgroundColor(this.pal().border)
            .borderRadius(15)
            .onClick(() => {
              this.copyAuthorizeLink();
            })
          Row({ space: 12 }) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color('#22D3EE')
            Text(this.tr('等待浏览器授权…'))
              .fontSize(12)
              .fontColor(this.pal().text2)
          }
          Button(this.tr('取消'))
            .height(32)
            .fontSize(12)
            .backgroundColor(this.pal().chip)
            .fontColor(this.pal().text2)
            .borderRadius(16)
            .onClick(() => {
              this.runtime.cancelQrLogin();
            })
        }
        .width('100%')
        .padding(12)
        .borderRadius(14)
        .backgroundColor(this.pal().card)
      }
      if (this.busy) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color('#22D3EE')
      }
      if (this.infoMsg.length > 0) {
        Text(this.infoMsg)
          .fontSize(12)
          .fontColor('#34D399')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 6, bottom: 2, left: 16, right: 16 })
      }
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(13)
          .fontColor('#F85749')
          .textAlign(TextAlign.Center)
        if (this.errorMsg.indexOf('设备身份读取失败') >= 0) {
          Row({ space: 8 }) {
            Text('重试')
              .fontSize(12)
              .fontColor(this.pal().text2)
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .backgroundColor(this.pal().chip)
              .borderRadius(14)
              .border({ width: 1, color: this.pal().borderStrong })
              .onClick(() => {
                const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
                this.runtime.retryBootstrap(context);
              })
            Text('重置设备身份')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
              .borderRadius(14)
              .onClick(() => {
                const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
                AlertDialog.show({
                  title: this.tr('重置设备身份'),
                  message: this.tr('安全存储里的私钥已经读不到了。重置会生成一个新的设备身份，'
                    + '需要重新登录，服务器上会把这台设备当成新设备。继续？'),
                  primaryButton: {
                    value: this.tr('取消'),
                    action: () => {
                    }
                  },
                  secondaryButton: {
                    value: this.tr('重置'),
                    fontColor: '#F85749',
                    action: () => {
                      this.runtime.resetIdentityAndRestart(context);
                    }
                  }
                });
              })
          }
          .margin({ top: 8 })
        }
      }
      Row({ space: 10 }) {
        Text(this.buildTag())
          .fontSize(10)
          .fontColor(this.pal().text3)
        Text(this.tr('设置'))
          .fontSize(10)
          .fontColor('#22D3EE')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.pal().chip)
          .borderRadius(9)
          .onClick(() => {
            this.showSettings = true;
          })
      }
      .margin({ top: 4 })
      }
      .padding(24)
      .width('100%')
      .constraintSize({ maxWidth: 640 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  DevicesScreen() {
    Column() {
      // 第一行：标题压在整行正中，按钮独立浮在右侧，标题位置不再被按钮宽度带偏
      Stack({ alignContent: Alignment.Center }) {
        Column({ space: 6 }) {
          Text(this.tr('DSH主机列表'))
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
            .letterSpacing(2)
          Row()
            .width(32)
            .height(3)
            .borderRadius(2)
            .linearGradient({ angle: 90, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
        }
        .alignItems(HorizontalAlign.Center)
        // 按钮组浮在右上角，宽度不参与标题居中计算
        Row({ space: 8 }) {
          Blank()
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.ic_settings'))
              .width(18)
              .height(18)
              .fillColor(this.pal().text2)
          }
          .width(32)
          .height(32)
          .backgroundColor(this.pal().chip)
          .border({ width: 1, color: this.pal().borderStrong })
          .onClick(() => {
            this.showSettings = true;
          })
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.ic_refresh'))
              .width(18)
              .height(18)
              .fillColor(this.pal().text2)
          }
          .width(32)
          .height(32)
          .backgroundColor(this.pal().chip)
          .border({ width: 1, color: this.pal().borderStrong })
          .enabled(!this.busy)
          .onClick(() => {
            this.runtime.refreshDevices();
          })
        }
        .width('100%')
      }
      .width('100%')
      // 宽屏：标题留在顶部，下面的「胶囊 + 主机卡片 + 小人」作为一组垂直居中
      if (this.isWideLayout()) {
        Blank()
      }
      // 第二行：当前服务器胶囊（自己一行，点开切换），不参与标题行竞争
      Row() {
        Row({ space: 6 }) {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor('#22D3EE')
          Text(this.accountSwitchLabel())
            .fontSize(12)
            .fontColor(this.pal().text2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('⌄')
            .fontSize(11)
            .fontColor(this.pal().text3)
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(this.pal().chip)
        .borderRadius(12)
        .border({ width: 1, color: this.pal().border })
        .constraintSize({ maxWidth: 260 })
        .onClick(() => {
          this.openAccountSwitcher();
        })
        Blank()
      }
      .width('100%')
      .padding({ top: 8 })
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 12 })
      if (this.busy) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color('#22D3EE')
          Text(this.switchingServer && this.switchingTo.length > 0
            ? this.tr('正在切换服务器…') + ' ' + serverHostLabel(this.switchingTo)
            : this.tr('正在刷新设备…'))
            .fontSize(13)
            .fontColor(this.pal().text2)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding({ left: 20, right: 20, bottom: 8 })
      }
      if (this.errorMsg.length > 0) {
        Row({ space: 8 }) {
          Column()
            .width(3)
            .height(16)
            .borderRadius(1.5)
            .backgroundColor('#F85749')
          Text(this.errorMsg)
            .fontSize(this.fs(12))
            .fontColor('#F85749')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.runtime.canRetry()) {
            Text(this.runtime.retryLabel())
              .fontSize(this.fs(12))
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
              .borderRadius(10)
              .backgroundColor('#F85749')
              .onClick(() => {
                this.runtime.retryLastError();
              })
          }
          Text('✕')
            .fontSize(this.fs(12))
            .fontColor('#F85749')
            .padding({ left: 6, right: 2, top: 2, bottom: 2 })
            .onClick(() => {
              this.runtime.clearError();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('rgba(248,87,73,0.10)')
        .borderRadius(10)
        .margin({ left: 20, right: 20, bottom: 8 })
      }
      if (this.linkBannerText().length > 0) {
        Row({ space: 8 }) {
          if (this.reconnectNotice.length > 0) {
            LoadingProgress()
              .width(15)
              .height(15)
              .color('#F5A623')
          }
          Text(this.linkBannerText())
            .fontSize(this.fs(12))
            .fontColor('#F5A623')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.reconnectNotice.length > 0) {
            Text(this.tr('停止重连'))
              .fontSize(this.fs(12))
              .fontColor('#F5A623')
              .padding({ left: 8, right: 4, top: 3, bottom: 3 })
              .onClick(() => {
                this.runtime.cancelReconnect();
              })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('rgba(245,166,35,0.12)')
        .borderRadius(10)
        .margin({ left: 20, right: 20, bottom: 8 })
      }
      List({ space: 12 }) {
        ForEach(this.devices, (device: RemoteHostDevice) => {
          ListItem() {
            this.DeviceCard(device)
          }
        }, (device: RemoteHostDevice) => `${device.deviceId}#${this.languageMode}`)
      }
      .width('100%')
      // 宽屏双列：一列会留出大片空白，两列更像桌面端的主机面板
      .lanes(deviceColumns(this.breakpoint, this.devices.length))
      // 列表按内容高度（多台时滚动），剩下的空间交给下面的小人居中，别让她贴底
      .constraintSize({ maxHeight: 560 })
      .padding({ left: 20, right: 20, top: 8, bottom: 12 })
      .scrollBar(BarState.Off)
      // 陪伴小人固定一块高度，上下由两个 Blank 撑开，整页内容在宽屏里垂直居中
      if (this.showMascot()) {
        Column() {
          this.MaidMascot()
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
      if (this.isWideLayout()) {
        Blank()
      }
      if (this.devices.length === 0 && !this.busy) {
        // 空态别只留一行灰字：给一张卡片说清楚下一步该做什么
        Column({ space: 10 }) {
          Text('🖥')
            .fontSize(26)
          Text(this.tr('还没有可用的主机'))
            .fontSize(this.fs(14))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Text(this.tr('在电脑上安装 DSH 并用同一账号登录，主机就会出现在这里'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
            .textAlign(TextAlign.Center)
            .maxLines(2)
          Row({ space: 10 }) {
            Text(this.tr('刷新'))
              .fontSize(this.fs(12))
              .fontColor('#FFFFFF')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
              .borderRadius(10)
              .onClick(() => {
                this.runtime.refreshDevices();
              })
            Text(this.tr('切换服务器'))
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(this.pal().chip)
              .borderRadius(10)
              .border({ width: 1, color: this.pal().border })
              .onClick(() => {
                this.showServerSwitch = true;
              })
          }
          .padding({ top: 2 })
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 18, bottom: 18 })
        .margin({ left: 20, right: 20, top: 8 })
        .backgroundColor(this.pal().card)
        .borderRadius(16)
        .border({ width: 1, color: this.pal().border })
        .alignItems(HorizontalAlign.Center)
      }
      Column()
        .width('100%')
        .height(0.5)
        .backgroundColor(this.pal().border)
        .margin({ top: 8 })
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          // 账号只显示邮箱前缀：google-110176351561077530156@… 那种长串会把整行吃掉
          Text(this.shortAccount())
            .fontSize(12)
            .fontColor(this.pal().text2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          // 版本号跟在服务器域名后面，报障时一眼能报出装的是哪一版
          Text(serverHostLabel(this.accountServer) + ' · v' + appVersion())
            .fontSize(10)
            .fontColor(this.pal().text3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.hostCountLabel() + ' · ' + this.onlineCountLabel())
          .fontSize(12)
          .fontColor(this.pal().text2)
          .maxLines(1)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 10, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: this.deviceColumnWidth() })
  }

  /** 列表下方的陪伴小人：缓慢上下浮 + 轻微摆头，落地处有一圈随呼吸缩放的影子。 */
  @Builder
  MaidMascot() {
    Column({ space: 2 }) {
      // 关掉时不挂载任何一层：底下的影子条也属于立绘，不能留一条横条
      if (this.uiHomeMascot) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width(104)
            .height(12)
            .borderRadius(6)
            .backgroundColor(this.isDarkUi ? 'rgba(0,0,0,0.30)' : 'rgba(90,120,190,0.16)')
            .scale({ x: this.maidBob ? 1 : 0.86 })
            .opacity(this.maidBob ? 0.9 : 0.6)
            .animation({ duration: 2000, curve: Curve.EaseInOut })
          if (this.runtime.homeMascotImage.length > 0) {
            Image(imageDataUri(this.runtime.homeMascotImage))
              .width(158)
              .height(204)
              .objectFit(ImageFit.Contain)
              .translate({ y: this.maidBob ? -7 : 0 })
              .rotate({ angle: this.maidBob ? 1.2 : -1.2 })
              .animation({ duration: 2000, curve: Curve.EaseInOut })
          } else {
            Image($r('app.media.maid_mascot'))
              .width(158)
              .height(204)
              .objectFit(ImageFit.Contain)
              .translate({ y: this.maidBob ? -7 : 0 })
              .rotate({ angle: this.maidBob ? 1.2 : -1.2 })
              .animation({ duration: 2000, curve: Curve.EaseInOut })
          }
        }
        .height(190)
        .width('100%')
      }
      Text(this.tr('选一台主机，继续上次的工作'))
        .fontSize(12)
        .fontColor(this.pal().text3)
        .padding({ top: 2 })
    }
    .width('100%')
    .padding({ top: 2, bottom: 6 })
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  DeviceCard(device: RemoteHostDevice) {
    Row({ space: 14 }) {
      // 主机头像：用电脑图形代替首字母圆圈（在线绿、离线灰）
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image($r('app.media.ic_host'))
          .width(22)
          .height(22)
          .fillColor(device.online ? '#34D399' : this.pal().text3)
        Column()
          .width(9)
          .height(9)
          .borderRadius(4.5)
          .backgroundColor(device.online ? '#34D399' : this.pal().text3)
          .border({ width: 2, color: this.pal().card })
          .margin({ right: 1, bottom: 1 })
      }
      .width(44)
      .height(44)
      .padding(6)
      .backgroundColor(device.online ? 'rgba(52,211,153,0.10)' : this.pal().chip)
      .borderRadius(12)
      .border({ width: 1, color: device.online ? 'rgba(52,211,153,0.28)' : this.pal().border })
      Column({ space: 4 }) {
        if (this.renamingDeviceId === device.deviceId) {
          TextInput({ text: this.renameInput, placeholder: this.tr('输入主机名称') })
            .height(34)
            .fontSize(14)
            .fontColor(this.pal().text)
            .placeholderColor(this.pal().text3)
            .caretColor('#22D3EE')
            .backgroundColor(this.pal().inputBg)
            .borderRadius(10)
            .border({ width: 1, color: 'rgba(34,211,238,0.45)' })
            .padding({ left: 10, right: 10 })
            .onChange((value: string) => {
              this.renameInput = value;
            })
            .onSubmit(() => {
              this.confirmRename();
            })
        } else {
          Text(this.displayNameFor(device).length > 0 ? this.displayNameFor(device) : device.deviceId)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
            // 手机上名字列只有 ~150vp，16sp 单行会把 DESKTOP-R5BVQJJ 截成 DESKTOP-...；
            // 放宽到两行、字号降一档，短名字仍是一行，长名字能看全。
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onHover((isHover: boolean) => {
              const name: string = this.displayNameFor(device);
              this.namePreviewId = isHover && name.length > 12 ? device.deviceId : '';
            })
            .gesture(LongPressGesture()
              .onAction(() => {
                this.namePreviewId = device.deviceId;
              }))
            .bindPopup(this.namePreviewId === device.deviceId, {
              message: this.displayNameFor(device).length > 0 ? this.displayNameFor(device) : device.deviceId,
              placement: Placement.Bottom,
              autoCancel: true,
              onStateChange: (state: PopupStateChangeParam) => {
                if (!state.isVisible && this.namePreviewId === device.deviceId) {
                  this.namePreviewId = '';
                }
              }
            })
        }
        Row({ space: 5 }) {
          Column()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(device.online ? '#34D399' : this.pal().text3)
          // 手机上右侧三个按钮把这一列压得很窄，单行省略会把版本号整段吃掉，
          // 所以允许折到第二行（整卡可点即连接，别指望用户读截断的字）
          Text(this.hostSubtitle(device))
            .fontSize(11)
            .fontColor(this.pal().text3)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.renamingDeviceId === device.deviceId) {
        Row({ space: 8 }) {
          Text(this.tr('取消'))
            .fontSize(12)
            .fontColor(this.pal().text2)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.pal().chip)
            .borderRadius(14)
            .border({ width: 1, color: this.pal().borderStrong })
            .onClick(() => {
              this.cancelRename();
            })
          Text(this.tr('确定'))
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
            .borderRadius(14)
            .onClick(() => {
              this.confirmRename();
            })
        }
      } else {
        Text('⋯')
          .fontSize(15)
          .fontColor(this.pal().text2)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .backgroundColor(this.pal().chip)
          .borderRadius(13)
          .border({ width: 1, color: this.pal().borderStrong })
          .onClick(() => {
            this.deviceMenuId = device.deviceId;
          })
        if (device.online) {
          Text(this.tr('连接'))
            .fontSize(14)
            .fontColor('#FFFFFF')
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
            .borderRadius(20)
            .shadow({ radius: 10, color: 'rgba(77,107,254,0.30)', offsetX: 0, offsetY: 3 })
            .onClick(() => {
              this.runtime.connectDevice(device.deviceId);
            })
        }
      }
    }
    .width('100%')
    .padding({ top: 16, bottom: 16, left: 16, right: 16 })
    .backgroundColor(this.hoverRowId === device.deviceId ? this.pal().inputBg : this.pal().card)
    .borderRadius(18)
    .border({ width: 1, color: this.pal().border })
    .onHover((isHover: boolean) => {
      this.hoverRowId = isHover ? device.deviceId : '';
    })
    // 整行可点即连接；PC 上右键出能力菜单（改名 / 详情 / 清除公钥）
    .onClick(() => {
      if (device.online && this.renamingDeviceId !== device.deviceId) {
        this.runtime.connectDevice(device.deviceId);
      }
    })
    .onMouse((event: MouseEvent) => {
      if (event.action === MouseAction.Press && event.button === MouseButton.Right) {
        this.deviceMenuId = device.deviceId;
      }
    })
  }

  @Builder
  ConnectingScreen() {
    Column({ space: 16 }) {
      Blank()
      this.LogoChip()
      LoadingProgress()
        .width(40)
        .height(40)
        .color('#22D3EE')
      Text(this.tr('正在建立安全连接…'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.pal().text)
        .letterSpacing(1)
      Text((this.connectStage.length > 0 ? this.connectStage : this.tr('NOISE IK 握手 · 能力协商需要几秒'))
        + (this.connectElapsedSec > 0 ? '  ·  ' + this.connectElapsedSec + 's' : ''))
        .fontSize(12)
        .fontColor(this.connectStage.length > 0 ? this.pal().text2 : this.pal().text3)
        .letterSpacing(1)
      Button(this.tr('取消'))
        .height(36)
        .fontSize(14)
        .backgroundColor(this.pal().chip)
        .fontColor(this.pal().text2)
        .borderRadius(18)
        .border({ width: 1, color: this.pal().borderStrong })
        .padding({ left: 20, right: 20 })
        .onClick(() => {
          this.runtime.cancelConnect();
        })
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(13)
          .fontColor('#F85749')
          .textAlign(TextAlign.Center)
        if (this.runtime.canRetry()) {
          Button(this.runtime.retryLabel())
            .height(36)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .padding({ left: 22, right: 22 })
            .borderRadius(18)
            .backgroundColor('#F85749')
            .onClick(() => {
              this.runtime.retryLastError();
            })
        }
      }
      Blank()
    }
    .padding(24)
    .width('100%')
    .height('100%')
  }

  @Builder
  ChatScreen() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 会话壁纸：画在会话自己的 Stack 最底层（放根容器会被会话底色盖住，看着像没加）
      if (this.wallpaper.length > 0) {
        Stack() {
          Image(imageDataUri(this.wallpaper))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(16)
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.wallpaperScrim())
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      Column({ space: this.foldState === 'half' ? this.hingeGapVp() : 0 }) {
      Stack({ alignContent: Alignment.Center }) {
        Row() {
        Row() {
          Text('‹')
            .fontSize(26)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
            .width(38)
            .height(38)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              // 只是回列表，连接保留：同一台主机再进来不重新认证
              this.runtime.keepAliveToDevices();
            })
        }
        .width(this.isLandscape ? 80 : 120)
        .justifyContent(FlexAlign.Start)
          Blank()

        // 三颗图标共用一套尺寸（22 的图形 + 40 的点击区），粗细与视觉重量才对得上
        this.TopIcon($r('app.media.ic_settings'), () => {
          if (!this.runtime.modelCatalogLoaded) {
            this.runtime.refreshModelCatalog();
          }
          this.runtime.refreshPermissionState();
          // 先把键盘收掉，否则会话设置底部（壁纸/连接状态）会被输入法挡住
          try {
            this.getUIContext().getFocusController().clearFocus();
          } catch (error) {
            logWarn('clear focus failed');
          }
          this.showSessionPanel = true;
        })
        this.TopIcon($r('app.media.ic_plus'), () => {
          this.showSessions = false;
          this.drawerOpen = 0;
          this.runtime.createNewSession();
        })
        if (!this.isLandscape) {
          this.TopIcon($r('app.media.ic_menu'), () => {
            this.openDrawer();
            this.runtime.loadWorkspaces();
          })
        }
        }
        .width('100%')

        Column({ space: 2 }) {
          // 主机名做成可按的胶囊：点一下弹主机列表直接切，不用退回设备页
          Row({ space: 6 }) {
            Text(this.connectedHostDisplay())
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 130 })
            if (!this.compactHeader()) {
              Text(this.tr('切换'))
                .fontSize(this.fs(10))
                .fontColor('#22D3EE')
            }
          }
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(this.pal().chip)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            this.runtime.refreshDevices().catch(() => undefined);
            this.hostSwitcherOpen = true;
          })
          Row({ space: 5 }) {
            Column()
              .width(5)
              .height(5)
              .borderRadius(2.5)
              .backgroundColor(this.generating ? '#22D3EE' : '#34D399')
            if (this.renamingSession) {
              TextInput({ text: this.sessionTitleInput, placeholder: this.tr('会话名称') })
                .height(30)
                .fontSize(12)
                .backgroundColor(this.pal().inputBg)
                .fontColor(this.pal().text)
                .borderRadius(8)
                .border({ width: 1, color: this.pal().borderStrong })
                .padding({ left: 8, right: 8 })
                .constraintSize({ maxWidth: 200 })
                .onChange((value: string) => {
                  this.sessionTitleInput = value;
                })
                .onSubmit(() => {
                  this.runtime.renameCurrentSession(this.sessionTitleInput);
                  this.renamingSession = false;
                })
              Text('✓')
                .fontSize(14)
                .fontColor('#34D399')
                .padding({ left: 4, right: 4 })
                .onClick(() => {
                  this.runtime.renameCurrentSession(this.sessionTitleInput);
                  this.renamingSession = false;
                })
            } else {
              Row({ space: 4 }) {
                Column()
                  .width(6)
                  .height(6)
                  .borderRadius(3)
                  .backgroundColor(this.connectionDotColor())
                // 会话名过长时用 TextOverflow.MARQUEE 自己滚，不再硬截成「…」
                Text(this.generating ? this.tr('正在生成…') : this.currentSessionTitle)
                  .fontSize(12)
                  .fontColor(this.generating ? '#22D3EE' : this.pal().text2)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.MARQUEE })
                  .constraintSize({ maxWidth: 190 })
                  .onClick(() => {
                    if (!this.generating && this.currentSessionId.length > 0) {
                      this.sessionTitleInput = this.currentSessionTitle;
                      this.renamingSession = true;
                    }
                  })
                  .gesture(LongPressGesture().onAction(() => {
                    if (this.currentSessionId.length === 0) {
                      return;
                    }
                    ActionSheet.show({
                      title: this.currentSessionTitle.length > 0 ? this.currentSessionTitle : this.tr('会话'),
                      message: this.currentSessionId,
                      sheets: [
                        {
                          title: this.tr('重命名'),
                          action: () => {
                            this.sessionTitleInput = this.currentSessionTitle;
                            this.renamingSession = true;
                          }
                        },
                        {
                          title: this.tr('复制为 Markdown'),
                          action: () => {
                            const data: pasteboard.PasteData = pasteboard.createData(
                              pasteboard.MIMETYPE_TEXT_PLAIN, this.runtime.sessionMarkdown());
                            pasteboard.getSystemPasteboard().setData(data).then(() => {
                              promptAction.showToast({ message: this.tr('会话 Markdown 已复制') });
                            }).catch(() => {
                              promptAction.showToast({ message: this.tr('复制失败') });
                            });
                          }
                        },
                        {
                          title: this.tr('归档会话'),
                          action: () => {
                            this.runtime.archiveCurrentSession();
                          }
                        }
                      ]
                    });
                  }))
              }
              .alignItems(VerticalAlign.Center)
              if (this.connectedTransport.length > 0) {
                Text(this.transportBadgeText())
                  .fontSize(9)
                  .fontColor(this.transportBadgeColor())
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .backgroundColor(this.transportBadgeBg())
                  .borderRadius(5)
                  .margin({ left: 4 })
                  // 点徽标看「走的是哪条路、多快、为什么没直连」，排障不用再翻日志
                  .onClick(() => {
                    this.linkDetailOpen = true;
                  })
              }
              if (sessionBackendBadge(this.currentSessionId).length > 0) {
                Text(sessionBackendBadge(this.currentSessionId))
                  .fontSize(9)
                  .fontColor('#8B5CF6')
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .backgroundColor('rgba(139,92,246,0.14)')
                  .borderRadius(5)
                  .margin({ left: 4 })
              }
              if (this.contextPercent > 0) {
                Text(this.contextPercent + '%')
                  .fontSize(10)
                  .fontColor(this.contextPercent >= 80 ? '#F85749' : this.pal().text3)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .backgroundColor(this.pal().inputBg)
                  .borderRadius(6)
              }
            }
          }
        }
        .constraintSize({ maxWidth: this.windowWidthVp > 0 ? this.windowWidthVp * 0.56 : 200 })
        .alignItems(HorizontalAlign.Center)
        .clip(true)
        // 这层盖在图标上方，必须透明命中，否则齿轮/加号完全点不到
        .hitTestBehavior(HitTestMode.Transparent)
      }
      .width('100%')
      .height(56)
      .padding({ left: 12, right: 12 })
      // 顶栏横条：毛玻璃压住滚过来的消息，内容不硬切
      .backgroundColor(this.isDarkUi ? 'rgba(18,22,34,0.72)' : 'rgba(247,249,255,0.76)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 24] }
      })
      Column()
        .width('100%')
        .height(0.5)
        .backgroundColor(this.pal().border)
      if (this.reconnecting) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(15)
            .height(15)
            .color('#F5A623')
          Text(this.reconnectNotice.length > 0
            ? this.reconnectNotice
            : this.tr('连接中断，正在重连…'))
            .fontSize(this.fs(12))
            .fontColor('#F5A623')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.tr('立即重试'))
            .fontSize(this.fs(12))
            .fontColor('#F5A623')
            .padding({ left: 8, right: 4, top: 3, bottom: 3 })
            .onClick(() => {
              this.runtime.retryReconnectNow();
            })
          Text(this.tr('停止'))
            .fontSize(this.fs(12))
            .fontColor(this.pal().text3)
            .padding({ left: 8, right: 4, top: 3, bottom: 3 })
            .onClick(() => {
              this.runtime.cancelReconnect();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('rgba(245,166,35,0.12)')
        .borderRadius(10)
        .margin({ left: 16, right: 16, top: 6 })
      }
      if (this.errorMsg.length > 0) {
        Row({ space: 8 }) {
          Column()
            .width(3)
            .height(16)
            .borderRadius(1.5)
            .backgroundColor('#F85749')
          Text(this.errorMsg)
            .fontSize(this.fs(12))
            .fontColor('#F85749')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.runtime.canRetry()) {
            Text(this.runtime.retryLabel())
              .fontSize(this.fs(12))
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
              .borderRadius(10)
              .backgroundColor('#F85749')
              .onClick(() => {
                this.runtime.retryLastError();
              })
          }
          Text('✕')
            .fontSize(this.fs(12))
            .fontColor('#F85749')
            .padding({ left: 6, right: 2, top: 2, bottom: 2 })
            .onClick(() => {
              this.runtime.clearError();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('rgba(248,87,73,0.10)')
        .borderRadius(10)
        .margin({ left: 16, right: 16, top: 6 })
      }
      List({ scroller: this.scroller, space: 14 }) {
        if (this.historyHasMore || this.loadingOlderHistory) {
          ListItem() {
            Row({ space: 8 }) {
              Text(this.loadingOlderHistory ? this.tr('加载中…') : this.tr('加载更早的消息'))
                .fontSize(this.fs(12))
                .fontColor(this.loadingOlderHistory ? this.pal().text3 : '#4D6BFE')
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .backgroundColor(this.pal().inputBg)
                .borderRadius(14)
                .border({ width: 1, color: this.pal().border })
                .onClick(() => {
                  if (!this.loadingOlderHistory) {
                    this.runtime.loadOlderHistory();
                  }
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 4, bottom: 2 })
          }
        }
        if (this.messages.length === 0) {
          ListItem() {
            Column({ space: 12 }) {
              if (this.sessionsLoadFailed) {
                Text(this.tr('会话列表加载失败'))
                  .fontSize(13)
                  .fontColor('#F85749')
                Button(this.tr('重试'))
                  .height(34)
                  .fontSize(13)
                  .padding({ left: 24, right: 24 })
                  .backgroundColor(Color.Transparent)
                  .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
                  .fontColor('#FFFFFF')
                  .borderRadius(17)
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.runtime.retrySessionLoad();
                  })
                if (this.busy) {
                  Text(this.tr('正在重新加载…'))
                    .fontSize(11)
                    .fontColor(this.pal().text3)
                }
              } else if (this.busy) {
                Text(this.tr('正在加载会话…'))
                  .fontSize(13)
                  .fontColor(this.pal().text3)
                  .padding(32)
              } else {
                // 空会话别只留一句话：给几条能直接点的提示词，顺手把 slash 入口说清楚
                Column({ space: 8 }) {
                  Text('✨')
                    .fontSize(22)
                  Text(this.tr('发送第一条消息开始对话'))
                    .fontSize(this.fs(13))
                    .fontColor(this.pal().text2)
                  if (this.runtime.prompts.length > 0) {
                    ForEach(this.runtime.prompts.slice(0, 3), (item: string) => {
                      Text(item)
                        .fontSize(this.fs(11))
                        .fontColor(this.pal().text2)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                        .backgroundColor(this.pal().card)
                        .borderRadius(10)
                        .border({ width: 1, color: this.pal().border })
                        .constraintSize({ maxWidth: 260 })
                        .onClick(() => {
                          this.promptInput = item;
                          this.runtime.saveDraft(this.currentSessionId, item);
                        })
                    }, (item: string) => 'empty-prompt-' + item)
                  }
                  Text(this.tr('输入 / 查看主机命令，点星号打开提示词库'))
                    .fontSize(this.fs(10))
                    .fontColor(this.pal().text3)
                    .padding({ top: 2 })
                }
                .alignItems(HorizontalAlign.Center)
                .padding({ top: 30, bottom: 10 })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 40 })
          }
        }
        ForEach(this.chatRows(), (item: ChatItem, index: number) => {
          ListItem() {
            Column({ space: 6 }) {
              if (this.shouldShowDayDivider(index)) {
                Text(dayDividerLabel(item.timestamp, this.en()))
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
                  .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                  .backgroundColor(this.pal().chip)
                  .borderRadius(8)
                  .margin({ top: 8, bottom: 2 })
              }
              this.MessageRow(item)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
          }
        }, (item: ChatItem) => `${item.id}#${item.rev}#${this.languageMode}#${this.textScaleValue}`
          + (this.isPendingInteraction(item) ? `#t${this.waitTick}` : ''))
      }
      .layoutWeight(1)
      .width('100%')
      .constraintSize({ maxWidth: this.chatMaxWidth() })
      // 宽屏下消息区居中，而不是贴着会话栏（2in1/三屏下特别明显）
      .alignSelf(ItemAlign.Center)
      // 多缓存几屏，滚动时少重建气泡（长会话明显）
      .cachedCount(6)
      // 底部留白要盖住「语境胶囊 + 输入坞」的高度，最后一条消息才不会被压在下面；
      // 键盘弹起时胶囊行收起，但仍要留够输入坞（约 46 + 16）的高度
      .padding({ left: 16, right: 16, top: 8, bottom: this.keyboardVisible ? 74 : 132 })
      // PC/横屏常驻滑块，鼠标可以直接拖；竖屏手机上仍然滚才出现
      .scrollBar(this.isLandscape ? BarState.On : BarState.Auto)
      .scrollBarWidth(this.isLandscape ? 6 : 3)
      .scrollBarColor(this.isDarkUi ? 'rgba(255,255,255,0.28)' : 'rgba(31,45,90,0.22)')
      .edgeEffect(EdgeEffect.Spring)
      // 只有「用户手动拖动」才停止跟随；程序化滚动不产生 touch，不会误判。
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Move && this.stickToBottom) {
          this.stickToBottom = false;
        }
      })
      .onReachEnd(() => {
        this.stickToBottom = true;
      })
      // 滚到顶就自动往更早翻一页（按钮仍然留着，翻不动时点它不会重复拉）
      .onReachStart(() => {
        if (this.historyHasMore && !this.loadingOlderHistory) {
          this.runtime.loadOlderHistory();
        }
      })
      // 记住当前停在哪个条目，切走再回来据此恢复位置
      .onScrollIndex((first: number) => {
        if (first < 0 || this.currentSessionId.length === 0) {
          return;
        }
        const rows: ChatItem[] = this.chatRows();
        if (first >= rows.length) {
          return;
        }
        const anchorId: string = rows[first].id;
        if (this.anchorSaveTimer >= 0) {
          clearTimeout(this.anchorSaveTimer);
        }
        this.anchorSaveTimer = setTimeout(() => {
          this.anchorSaveTimer = -1;
          this.scrollAnchors[this.currentSessionId] = anchorId;
        }, 400);
        // 轮次胶囊跟着滚动更新（第几轮）
        const messageIndex: number = first - this.chatItemOffset();
        if (messageIndex >= 0) {
          const position: number = this.runtime.currentTurnPosition(messageIndex);
          if (position > 0 && position !== this.turnPosition) {
            this.turnPosition = position;
          }
        }
      })
      // 右往左横滑唤出会话抽屉：手势只挂在消息区，输入坞的触摸不再被抢
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 10 })
          .onActionStart(() => {
            if (this.isLandscape || this.showSessions) {
              this.drawerDragFromChat = false;
              return;
            }
            this.drawerDragFromChat = true;
            this.drawerDragBase = 0;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (!this.drawerDragFromChat || event.offsetX >= 0) {
              return;
            }
            const width: number = this.drawerWidthVp();
            const progress: number = Math.min(1, Math.max(0, this.drawerDragBase - event.offsetX / width));
            if (progress <= 0) {
              return;
            }
            if (!this.showSessions) {
              this.showSessions = true;
            }
            this.drawerOpen = progress;
          })
          .onActionEnd(() => {
            if (!this.drawerDragFromChat) {
              return;
            }
            this.drawerDragFromChat = false;
            if (this.drawerOpen > 0.32) {
              this.settleDrawer(true);
              this.runtime.loadWorkspaces();
            } else {
              this.settleDrawer(false);
            }
          })
      )
      }
      .width('100%')
      .height('100%')


      // 轮次导航：↑ 上一轮 / ↓ 下一轮 + 当前位置与上一轮用量（对齐 dsh-Go 的轮次导航）
      if (this.runtime.userTurnIndexes().length > 1) {
        Row({ space: 6 }) {
          Text('↑')
            .fontSize(13)
            .fontColor(this.pal().text2)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.jumpTurn(-1);
            })
          Text(this.turnPillText())
            .fontSize(11)
            .fontColor(this.pal().text3)
            .maxLines(1)
            .onClick(() => {
              this.stickToBottom = false;
            })
          Text('↓')
            .fontSize(13)
            .fontColor(this.pal().text2)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.jumpTurn(1);
            })
        }
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(this.pal().card)
        .borderRadius(14)
        .border({ width: 1, color: this.pal().border })
        .margin({ bottom: 4 })
      }
      if (!this.stickToBottom) {
        Row() {
          Text('↓ ' + this.tr('回到最新'))
            .fontSize(12)
            .fontColor(this.pal().text2)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.pal().card)
            .borderRadius(14)
            .border({ width: 1, color: this.pal().border })
            .shadow({ radius: 10, color: 'rgba(0,0,0,0.12)', offsetX: 0, offsetY: 2 })
            .onClick(() => {
              this.stickToBottom = true;
              this.scrollChatToBottom();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ bottom: 96 })
      }
      // 半折悬停（桌面立着那种）：输入坞限制在下半屏，上半留给消息，中间那道间隔就是铰链
      if (this.foldState === 'half') {
        Column() {
          this.ComposerDock()
        }
        .width('100%')
        .constraintSize({ maxHeight: Math.max(180, this.windowHeightVp * 0.42) })
        .justifyContent(FlexAlign.End)
      } else {
        this.ComposerDock()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 底部输入坞：不再是整条玻璃，图片键、输入框、发送键各自一块玻璃，中间留缝。 */
  /** 写作辅助：提示词库 / 全屏编辑（点输入坞上的 ✦ 打开）。 */
  @Builder
  WritingMenuOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(8,12,24,0.45)')
        .onClick(() => {
          this.writingMenuOpen = false;
        })
      Column({ space: 10 }) {
        Row() {
          Column({ space: 3 }) {
            Text(this.tr('写作辅助'))
              .fontSize(this.fs(16))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text)
            Text(this.tr('提示词库可一键填入常用说法；长文用全屏编辑'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .maxLines(2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('✕')
            .fontSize(this.fs(14))
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.writingMenuOpen = false;
            })
        }
        .width('100%')
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(this.tr('提示词库'))
              .fontSize(this.fs(14))
              .fontColor(this.pal().text)
            Text(this.tr('挑一条常用提示词填进输入框'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('›')
            .fontSize(this.fs(15))
            .fontColor(this.pal().text3)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(this.pal().inputBg)
        .borderRadius(14)
        .border({ width: 1, color: this.pal().border })
        .onClick(() => {
          this.writingMenuOpen = false;
          this.promptDraftInput = '';
          this.promptPanelOpen = true;
        })
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(this.tr('全屏编辑'))
              .fontSize(this.fs(14))
              .fontColor(this.pal().text)
            Text(this.tr('整屏写长文，换行不会丢'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .maxLines(1)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('›')
            .fontSize(this.fs(15))
            .fontColor(this.pal().text3)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(this.pal().inputBg)
        .borderRadius(14)
        .border({ width: 1, color: this.pal().border })
        .onClick(() => {
          this.writingMenuOpen = false;
          this.composerExpanded = true;
        })
      }
      .width('100%')
      .constraintSize({ maxWidth: 460 })
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 240 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 180, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 发送方式：排队 / 插话。自定义面板替掉系统 ActionSheet（后者样式和信息层级都别扭）。 */
  @Builder
  SendModeOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(8,12,24,0.45)')
        .onClick(() => {
          this.sendModeOpen = false;
        })
      Column({ space: 10 }) {
        Row() {
          Column({ space: 3 }) {
            Text(this.tr('发送方式'))
              .fontSize(this.fs(16))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text)
            Text(this.runtime.generating
              ? this.tr('正在生成：插话会立刻打断当前这一轮')
              : this.tr('空闲时两种方式没有区别'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .maxLines(2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('✕')
            .fontSize(this.fs(14))
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.sendModeOpen = false;
            })
        }
        .width('100%')
        this.SendModeRow(this.tr('排队发送'), this.tr('本轮结束后再发，不打断'),
          !this.runtime.steerMode, false)
        this.SendModeRow(this.tr('插话打断'), this.tr('立刻发出去，打断当前这一轮'),
          this.runtime.steerMode, true)
      }
      .width('100%')
      .constraintSize({ maxWidth: 460 })
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 240 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 180, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 发送方式的一行：左侧标题+说明，右侧选中标记。 */
  @Builder
  SendModeRow(title: string, hint: string, selected: boolean, steer: boolean) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(this.fs(14))
          .fontColor(this.pal().text)
        Text(hint)
          .fontSize(this.fs(11))
          .fontColor(this.pal().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(selected ? '✓' : '')
        .fontSize(this.fs(14))
        .fontColor(steer ? '#F5A623' : '#22D3EE')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(selected
      ? (steer ? 'rgba(245,166,35,0.14)' : 'rgba(34,211,238,0.12)')
      : this.pal().inputBg)
    .borderRadius(14)
    .border({ width: 1,
      color: selected ? (steer ? 'rgba(245,166,35,0.45)' : 'rgba(34,211,238,0.45)') : this.pal().border })
    .onClick(() => {
      this.runtime.setSteerMode(steer);
      this.sendModeOpen = false;
    })
  }

  /** 手机上生成中的「停止」小方块：贴在输入框内部右上角，不额外占一行宽度。 */
  @Builder
  StopChipOverlay() {
    if (this.compactDock() && this.generating) {
      Column() {
        Column()
          .width(11)
          .height(11)
          .borderRadius(2)
          .backgroundColor('#F85749')
      }
      .width(30)
      .height(30)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor('rgba(248,87,73,0.14)')
      .borderRadius(15)
      .border({ width: 1, color: 'rgba(248,87,73,0.40)' })
      .onClick(() => {
        this.runtime.stopGeneration();
      })
    }
  }

  @Builder
  ComposerDock() {
    Column() {
      Column({ space: 8 }) {
        // 键盘弹起时收起语境胶囊：它正好压在输入法候选条上方，会挡住半个候选框
        if (!this.keyboardVisible && this.contextPills().length > 0) {
          Row({ space: 8 }) {
            ForEach(this.contextPills(), (pill: string) => {
              // 语境提示做成纯文字：带底色的胶囊连排会看成一条横带，压在输入框上方很割裂
              Text(pill)
                .fontSize(this.fs(10))
                .fontColor(this.pal().text3)
                .maxLines(1)
                .opacity(0.9)
            }, (pill: string) => pill)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 2, bottom: 4 })
          .justifyContent(FlexAlign.Start)
        }
      Column() {
        if (this.promptInput.startsWith('/') && this.slashCommands.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.slashCommands, (command: SlashCommand) => {
                Row({ space: 6 }) {
                  Text(command.name)
                    .fontSize(this.fs(12))
                    .fontColor('#22D3EE')
                  if (command.description.length > 0) {
                    Text(command.description)
                      .fontSize(this.fs(11))
                      .fontColor(this.pal().text3)
                      .maxLines(1)
                  }
                }
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor(this.pal().inputBg)
                .borderRadius(9)
                .border({ width: 1, color: this.pal().border })
                .onClick(() => {
                  this.promptInput = command.name + ' ';
                })
              }, (command: SlashCommand) => command.name)
            }
            .padding({ left: 16, right: 16 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ top: 4, bottom: 2 })
        }
        if (this.pendingFiles.length > 0) {
          Row({ space: 8 }) {
            ForEach(this.pendingFiles, (file: PromptFilePart, index: number) => {
              Row({ space: 6 }) {
                Image($r('app.media.ic_attach_file'))
                  .width(this.fs(12))
                  .height(this.fs(12))
                  .fillColor(this.pal().text3)
                  .objectFit(ImageFit.Contain)
                Text(file.bytes > 0 ? file.name + ' · ' + sizeLabel(file.bytes) : file.name)
                  .fontSize(this.fs(11))
                  .fontColor(this.pal().text2)
                  .maxLines(1)
                  .constraintSize({ maxWidth: 170 })
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('✕')
                  .fontSize(this.fs(11))
                  .fontColor(this.pal().text3)
                  .onClick(() => {
                    this.removePendingFile(index);
                  })
              }
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.pal().inputBg)
              .borderRadius(10)
            }, (file: PromptFilePart, index: number) => `${file.receiptId}#${index}`)
            if (this.pendingFiles.length > 1) {
              Text(this.tr('合计') + ' ' + sizeLabel(this.pendingFilesTotalBytes()))
                .fontSize(this.fs(10))
                .fontColor(this.pal().text3)
            }
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 2, bottom: 2 })
        }
        if (this.pendingImages.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.pendingImages, (picked: PickedImage, index: number) => {
                Stack({ alignContent: Alignment.TopEnd }) {
                  if (picked.preview !== undefined) {
                    Image(picked.preview)
                      .width(56)
                      .height(56)
                      .borderRadius(10)
                      .objectFit(ImageFit.Cover)
                  } else {
                    Column()
                      .width(56)
                      .height(56)
                      .borderRadius(10)
                      .backgroundColor(this.pal().chip)
                  }
                  Text(Math.max(1, Math.round(picked.bytes / 1024)) + 'K')
                    .fontSize(this.fs(9))
                    .fontColor('#FFFFFF')
                    .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                    .backgroundColor('rgba(0,0,0,0.45)')
                    .borderRadius(6)
                    .margin({ top: 58, right: 2 })
                  Text('✕')
                    .fontSize(this.fs(11))
                    .fontColor('#FFFFFF')
                    .width(18)
                    .height(18)
                    .textAlign(TextAlign.Center)
                    .backgroundColor('rgba(0,0,0,0.55)')
                    .borderRadius(9)
                    .onClick(() => {
                      this.removePendingImage(index);
                    })
                }
              }, (picked: PickedImage, index: number) => index + ':' + picked.bytes)
            }
            .padding({ left: 16, right: 16 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          .padding({ top: 2, bottom: 2 })
        }
        // 每颗控件各自一块玻璃，中间留缝断开，不再连成一整条
        Row({ space: this.compactDock() ? 6 : 12 }) {
          // 图片：选相册里的图，压完挂在输入框上方，随下一次发送一起交给主机
          Row() {
            if (this.pickingImages) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color('#22D3EE')
            } else {
              Image($r('app.media.ic_image'))
                .width(20)
                .height(20)
                .fillColor(this.pal().text2)
            }
          }
          .width(this.compactDock() ? 40 : 46)
          .height(this.compactDock() ? 40 : 46)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(this.compactDock() ? 20 : 23)
          // 对齐资讯类 App 的底栏光感：厚材质 + 低白度过衬，让下层内容模糊透上来
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
            adaptiveColor: AdaptiveColor.DEFAULT,
            blurOptions: { grayscale: [0, 12] }
          })
          .border({ width: 1,
            color: this.isDarkUi ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.95)' })
          .backgroundColor(this.isDarkUi ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.40)')
          .shadow({ radius: 14,
            color: this.isDarkUi ? 'rgba(0,0,0,0.50)' : 'rgba(31,45,90,0.22)',
            offsetX: 0, offsetY: 6 })
          .clip(true)
          .overlay(this.DockSpot(52), { align: Alignment.Center })
          .onTouch((event: TouchEvent) => {
            this.trackDockLight(event);
          })
          .onClick(() => {
            this.chooseImageSource();
          })
          // 文件键：和图片键同规格，左边再挂一枚
          Row() {
            Image($r('app.media.ic_attach_file'))
              .width(this.fs(18))
              .height(this.fs(18))
              .fillColor(this.pal().text2)
              .objectFit(ImageFit.Contain)
          }
          .width(this.compactDock() ? 30 : 34)
          .height(this.compactDock() ? 40 : 46)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(this.compactDock() ? 20 : 23)
          .backgroundColor(this.isDarkUi ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.40)')
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
            adaptiveColor: AdaptiveColor.DEFAULT,
            blurOptions: { grayscale: [0, 12] }
          })
          .border({ width: 1,
            color: this.isDarkUi ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.95)' })
          .onClick(() => {
            this.attachFile();
          })
          // 提示词库入口：和图片键同规格的小圆玻璃
          Row() {
            Image($r('app.media.ic_prompt'))
              .width(this.fs(17))
              .height(this.fs(17))
              .fillColor(this.pal().text2)
              .objectFit(ImageFit.Contain)
          }
          .width(this.compactDock() ? 30 : 34)
          .height(this.compactDock() ? 40 : 46)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(this.compactDock() ? 20 : 23)
          .backgroundColor(this.isDarkUi ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.40)')
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
            adaptiveColor: AdaptiveColor.DEFAULT,
            blurOptions: { grayscale: [0, 12] }
          })
          .border({ width: 1,
            color: this.isDarkUi ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.95)' })
          .onClick(() => {
            // 一键出「写作辅助」面板：提示词库 / 全屏编辑（长按在鼠标与触控下都不稳，已弃用）
            this.writingMenuOpen = true;
          })
          // 展开：只在有空间时给（手机上会挤占输入框宽度，长文交给全屏编辑入口）
          if (!this.compactDock()) {
          Row() {
            Image($r('app.media.ic_expand'))
              .width(this.fs(16))
              .height(this.fs(16))
              .fillColor(this.pal().text2)
              .objectFit(ImageFit.Contain)
          }
          .width(this.compactDock() ? 30 : 34)
          .height(this.compactDock() ? 40 : 46)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(this.compactDock() ? 20 : 23)
          .backgroundColor(this.isDarkUi ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.40)')
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
            adaptiveColor: AdaptiveColor.DEFAULT,
            blurOptions: { grayscale: [0, 12] }
          })
          .border({ width: 1,
            color: this.isDarkUi ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.95)' })
          .onClick(() => {
            this.composerExpanded = true;
          })
          }
          // 输入框自己就是一块玻璃；换行靠回车，高度随内容长到 5 行再内部滚动
          Stack() {
          TextArea({ text: this.promptInput,
            placeholder: this.generating
              ? (this.compactDock() ? this.tr('正在生成…') : this.tr('正在生成，可插话…'))
              : (this.runtime.steerMode
                ? (this.compactDock() ? this.tr('插话发送…') : this.tr('插话发送（长按发送键切换）'))
                : (this.isWideLayout() ? this.tr('发送消息…（Enter 发送 · Shift+Enter 换行）')
                  : this.tr('发送消息…'))) })
            .width('100%')
            .constraintSize({ minHeight: this.compactDock() ? 44 : 46,
              maxHeight: this.isLandscape ? 160 : (this.isWideLayout() ? 240 : 132) })
            // PC 键盘约定：Enter 换行，Ctrl+Enter（或 ⌘+Enter）发送，Shift+Enter 也按换行。
            // 这里只拦「修饰键+Enter」，其余一律交给 TextArea 默认行为，换行不会被吃掉。
            .onKeyEvent((event: KeyEvent) => {
              if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_ENTER) {
                return;
              }
              // ArkUI 的 KeyEvent 没有 ctrlKey 字段，修饰键要走 getModifierKeyState；
              // 它在 2in1 上偶尔会抛，抛进事件分发会把整页打掉，所以全包在 try 里并留痕。
              try {
                if (this.enterSends()) {
                  // PC：Shift+Enter 换行（交给 TextArea 默认行为），其余直接发
                  if (this.modifierPressed(event, 'Shift')) {
                    return;
                  }
                  this.sendTap();
                } else if (this.ctrlEnterPressed(event)) {
                  this.sendTap();
                }
              } catch (error) {
                LinkLog.write('key', '回车发送异常：' + errorMessage(error));
              }
            })
            // PC 上回车直接发：TextArea 的 onKeyEvent 收不到输入法转发的回车，
            // 得靠 enterKeyType=Send + onSubmit 这条路（手机仍然是回车换行）。
            .enterKeyType(this.enterSends() ? EnterKeyType.Send : EnterKeyType.NEW_LINE)
            .onSubmit(() => {
              if (this.enterSends()) {
                this.sendTap();
              }
            })
            // 聚焦时整块底提亮（等同于两侧按键被点亮），背景层一定可见
            .backgroundColor(this.inputFocused
              ? (this.isDarkUi ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.66)')
              : (this.isDarkUi ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.40)'))
            .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
              colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
              adaptiveColor: AdaptiveColor.DEFAULT,
              blurOptions: { grayscale: [0, 12] }
            })
            .fontColor(this.pal().text)
            .fontSize(this.fs(15))
            .lineHeight(this.fs(22))
            .placeholderColor(this.pal().text3)
            .caretColor('#22D3EE')
            .borderRadius(23)
            .border({ width: 1,
              color: this.isDarkUi ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.95)' })
            .padding({ left: 18, right: 18, top: 12, bottom: 12 })
            .onFocus(() => {
              this.inputFocused = true;
            })
            .onBlur(() => {
              this.inputFocused = false;
            })
            .clip(true)
            // 生成中保持可输入：否则「插话」无从谈起。
            .enabled(true)
            // 光斑放最后画：否则会被 TextArea 自己的玻璃底盖住（这次是真看不见的原因）
            .overlay(this.InputGlow(), { align: Alignment.Center })
            .onFocus(() => {
              if (this.stickToBottom) {
                setTimeout(() => {
                  this.scrollChatToBottom();
                }, 80);
              }
            })
            .onChange((value: string) => {
              this.promptInput = value;
              if (value === '/' && this.slashCommands.length === 0) {
                this.runtime.loadSlashCommands();
              }
              // 草稿落盘做个 400ms 防抖，别每敲一个字就写一次 preferences
              if (this.draftSaveTimer >= 0) {
                clearTimeout(this.draftSaveTimer);
              }
              this.draftSaveTimer = setTimeout(() => {
                this.draftSaveTimer = -1;
                this.runtime.saveDraft(this.currentSessionId, this.promptInput);
              }, 400);
            })
            // 粘贴：剪贴板里是图片就直接挂到待发送区（文本仍按默认插入）
            .onPaste(() => {
              this.pasteImageFromClipboard();
            })
            // 内边距不对称：左边留多点好读，右边贴着发送键留少点
            .padding({ left: this.compactDock() ? 14 : 12, right: this.compactDock() ? 8 : 12,
              top: 10, bottom: 10 })
            // 跟手光斑：坐标就是这块自己的局部坐标
            .overlay(this.DockSpot(96), { align: Alignment.Center })
            .onTouch((event: TouchEvent) => {
              this.trackDockLight(event);
            })
            .onMouse((event: MouseEvent) => {
              this.trackDockMouse(event);
            })
          }
          .layoutWeight(1)
          .constraintSize({ minHeight: this.compactDock() ? 44 : 46,
            maxHeight: this.isLandscape ? 160 : (this.isWideLayout() ? 240 : 132) })
          if (this.generating && !this.compactDock()) {
            Text('■')
              .fontSize(this.fs(16))
              .fontColor('#F85749')
              .width(46)
              .height(46)
              .textAlign(TextAlign.Center)
              .backgroundColor('rgba(248,87,73,0.12)')
              .borderRadius(23)
              .border({ width: 1, color: 'rgba(248,87,73,0.35)' })
              .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
                colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
                adaptiveColor: AdaptiveColor.DEFAULT,
                blurOptions: { grayscale: [0, 12] }
              })
              .shadow({ radius: 12,
                color: this.isDarkUi ? 'rgba(0,0,0,0.50)' : 'rgba(31,45,90,0.22)',
                offsetX: 0, offsetY: 5 })
              .clip(true)
              .overlay(this.DockSpot(52), { align: Alignment.Center })
              .onTouch((event: TouchEvent) => {
                this.trackDockLight(event);
              })
              .onClick(() => {
                this.runtime.stopGeneration();
              })
          }
          if (this.generating && this.compactDock() && this.promptInput.trim().length === 0
            && this.pendingImages.length === 0) {
            // 手机上生成中且没输入：最右边这颗键直接用成「停止」，垂直居中一颗键，不再另占位
            Column() {
              Column()
                .width(13)
                .height(13)
                .borderRadius(3)
                .backgroundColor('#FFFFFF')
            }
            .width(42)
            .height(42)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#F85749')
            .borderRadius(21)
            .shadow({ radius: 12, color: 'rgba(248,87,73,0.40)', offsetX: 0, offsetY: 5 })
            .onClick(() => {
              this.runtime.stopGeneration();
            })
          } else {
          Text('↑')
            .fontSize(this.fs(20))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .width(this.compactDock() ? 42 : 46)
            .height(this.compactDock() ? 42 : 46)
            .textAlign(TextAlign.Center)
            .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
            .borderRadius(23)
            .shadow({ radius: 12, color: 'rgba(77,107,254,0.45)', offsetX: 0, offsetY: 5 })
            .clip(true)
            .opacity(this.reconnecting ? 0.45 : 1)
            .overlay(this.DockSpot(52), { align: Alignment.Center })
            // 不给键盘焦点：焦点落到发送键上时，Enter/Space 会变成「发送」，
            // PC 用户按 Enter 想换行却把消息发出去了。鼠标点它照样能发。
            .focusable(false)
            .onTouch((event: TouchEvent) => {
              this.trackDockLight(event);
            })
            .onClick(() => {
              this.sendTap();
            })
            .onKeyEvent((event: KeyEvent) => {
              if (event.type === KeyType.Down
                && (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE)) {
                this.sendTap();
              }
            })
            .gesture(LongPressGesture().onAction(() => {
              this.sendModeOpen = true;
            }))
          }
        }
        .width('100%')
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const height: number = Number(newValue.height);
          if (height > 0 && Math.abs(height - this.dockHeight) > 0.5) {
            this.dockHeight = height;
          }
        })
      }
      // 这一层不再画玻璃：底板交给按钮行的每一块自己画，中间才断得开
      .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: this.chatMaxWidth() })
      .padding({ left: 12, right: 12, top: 8, bottom: 0 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** Shared sessions list (header + rows); wrapped by the overlay or the landscape pane. */
  @Builder
  SessionsPanelBody() {
    Column() {
      Row() {
        Text('会话')
          .fontSize(this.fs(18))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.pal().text)
        if (this.runtime.favoriteSessions.length > 0) {
          Text('★ ' + this.runtime.favoriteSessions.length)
            .fontSize(this.fs(11))
            .fontColor('#F5A623')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.favoriteOnly ? 'rgba(245,166,35,0.28)' : 'rgba(245,166,35,0.12)')
            .borderRadius(7)
            .margin({ left: 6 })
            .onClick(() => {
              this.favoriteOnly = !this.favoriteOnly;
            })
        }
        if (this.archivedIds.length > 0) {
          Text(this.showArchived
            ? this.tr('收起归档')
            : this.tr('已归档 ') + this.archivedIds.length)
            .fontSize(this.fs(11))
            .fontColor(this.showArchived ? '#22D3EE' : this.pal().text3)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .backgroundColor(this.showArchived ? 'rgba(34,211,238,0.16)' : this.pal().inputBg)
            .borderRadius(7)
            .margin({ left: 6 })
            .onClick(() => {
              this.showArchived = !this.showArchived;
            })
        }
        Text(`${this.visibleSessions().length}`)
          .fontSize(this.fs(12))
          .fontColor(this.pal().text3)
          .margin({ left: 6 })
        Blank()
        Text('＋ 新建')
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor('rgba(34,211,238,0.10)')
          .borderRadius(15)
          .border({ width: 1, color: 'rgba(34,211,238,0.30)' })
          .onClick(() => {
            this.closeDrawer();
            this.runtime.createNewSession();
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 12 })
      Row({ space: 8 }) {
        TextInput({ text: this.sessionSearchInput, placeholder: this.tr('搜索会话…') })
          .layoutWeight(1)
          .height(36)
          .fontSize(this.fs(13))
          .backgroundColor(this.pal().inputBg)
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().border })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.sessionSearchInput = value;
            this.sessionSearchActive = value.trim().length > 0;
            // 每敲一个字就走一次中继 RPC 太贵（一次 400~600ms），加 250ms 防抖
            if (this.searchDebounceTimer >= 0) {
              clearTimeout(this.searchDebounceTimer);
            }
            this.searchDebounceTimer = setTimeout(() => {
              this.searchDebounceTimer = -1;
              this.runtime.searchSessions(this.sessionSearchInput);
            }, 250);
          })
        if (!this.sessionSearchActive && this.runtime.recentSessions.length > 0) {
          Text(this.tr('最近') + (this.recentOpen ? ' ▾' : ' ▸'))
            .fontSize(this.fs(12))
            .fontColor(this.recentOpen ? '#22D3EE' : this.pal().text3)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.recentOpen ? 'rgba(34,211,238,0.12)' : this.pal().inputBg)
            .borderRadius(9)
            .border({ width: 1, color: this.recentOpen ? 'rgba(34,211,238,0.40)' : this.pal().border })
            .onClick(() => {
              this.recentOpen = !this.recentOpen;
            })
        }
        if (this.sessionSearchActive) {
          Text('清除')
            .fontSize(this.fs(12))
            .fontColor(this.pal().text3)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.pal().inputBg)
            .borderRadius(9)
            .border({ width: 1, color: this.pal().border })
            .onClick(() => {
              this.sessionSearchInput = '';
              this.sessionSearchActive = false;
              this.sessionSearchResults = [];
              this.runtime.searchSessions('');
            })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })
      if (this.editingWorkspaceId.length > 0) {
        Row({ space: 8 }) {
          TextInput({ text: this.workspaceTitleInput, placeholder: this.tr('工作区名称') })
            .layoutWeight(1)
            .height(34)
            .fontSize(this.fs(12))
            .backgroundColor(this.pal().inputBg)
            .fontColor(this.pal().text)
            .borderRadius(9)
            .border({ width: 1, color: this.pal().border })
            .onChange((value: string) => {
              this.workspaceTitleInput = value;
            })
          Text('✓')
            .fontSize(this.fs(14))
            .fontColor('#34D399')
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.runtime.renameWorkspace(this.editingWorkspaceId, this.workspaceTitleInput);
              this.editingWorkspaceId = '';
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 2, bottom: 6 })
      }
      if (this.workspaces.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            Text('跟随当前会话')
              .fontSize(this.fs(11))
              .fontColor(this.selectedWorkspaceId.length === 0 ? '#22D3EE' : this.pal().text3)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor(this.selectedWorkspaceId.length === 0
                ? 'rgba(34,211,238,0.12)' : this.pal().inputBg)
              .borderRadius(9)
              .border({ width: 1, color: this.selectedWorkspaceId.length === 0
                ? 'rgba(34,211,238,0.45)' : this.pal().border })
              .onClick(() => {
                this.runtime.setSelectedWorkspace('');
              })
            Text('＋ ' + this.tr('新建'))
              .fontSize(this.fs(11))
              .fontColor('#22D3EE')
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .backgroundColor('rgba(34,211,238,0.10)')
              .borderRadius(9)
              .border({ width: 1, color: 'rgba(34,211,238,0.40)' })
              .onClick(() => {
                this.workspacePathInput = this.runtime.browsePath.length > 0
                  ? this.runtime.browsePath : '';
                this.workspaceNameDraft = '';
                this.workspaceCreateOpen = true;
              })
            ForEach(this.workspaces, (workspace: HarnessWorkspace) => {
              Text(workspace.title.length > 0 ? workspace.title : workspace.path)
                .fontSize(this.fs(11))
                .maxLines(1)
                .constraintSize({ maxWidth: 140 })
                .fontColor(this.selectedWorkspaceId === workspace.workspaceId
                  ? '#22D3EE' : this.pal().text3)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(this.selectedWorkspaceId === workspace.workspaceId
                  ? 'rgba(34,211,238,0.12)' : this.pal().inputBg)
                .borderRadius(9)
                .border({ width: 1, color: this.selectedWorkspaceId === workspace.workspaceId
                  ? 'rgba(34,211,238,0.45)' : this.pal().border })
                .onClick(() => {
                  this.runtime.setSelectedWorkspace(workspace.workspaceId);
                })
                .gesture(LongPressGesture().onAction(() => {
                  ActionSheet.show({
                    title: workspace.title.length > 0 ? workspace.title : workspace.path,
                    message: workspace.path,
                    sheets: [
                      {
                        title: this.tr('浏览文件'),
                        action: () => {
                          this.showBrowser = true;
                          this.runtime.openWorkspace(workspace.workspaceId);
                        }
                      },
                      {
                        title: this.tr('重命名'),
                        action: () => {
                          this.editingWorkspaceId = workspace.workspaceId;
                          this.workspaceTitleInput = workspace.title;
                        }
                      },
                      {
                        title: this.tr('删除工作区'),
                        action: () => {
                          this.runtime.deleteWorkspace(workspace.workspaceId);
                        }
                      }
                    ]
                  });
                }))
            }, (workspace: HarnessWorkspace) => `${workspace.workspaceId}#${this.languageMode}`)
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ top: 2, bottom: 6 })
      }
      Column()
        .width('100%')
        .height(0.5)
        .backgroundColor(this.pal().border)
      if (this.recentOpen && !this.sessionSearchActive && this.runtime.recentSessions.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            Text(this.tr('最近'))
              .fontSize(this.fs(10))
              .fontColor(this.pal().text3)
            ForEach(this.runtime.recentSessions, (id: string) => {
              Text(this.recentSessionTitle(id))
                .fontSize(this.fs(11))
                .fontColor(this.pal().text2)
                .maxLines(1)
                .constraintSize({ maxWidth: 120 })
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .backgroundColor(this.pal().inputBg)
                .borderRadius(9)
                .border({ width: 1, color: this.pal().border })
                .onClick(() => {
                  this.closeDrawer();
                  this.runtime.openSession(id);
                })
            }, (id: string) => 'recent-' + id)
          }
          .padding({ left: 16, right: 16, bottom: 6 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      if (!this.sessionSearchActive && this.sessionWorkspaces().length > 1) {
        Scroll() {
          Row({ space: 8 }) {
            Text(this.tr('工作区'))
              .fontSize(this.fs(10))
              .fontColor(this.pal().text3)
            Text(this.tr('全部'))
              .fontSize(this.fs(11))
              .fontColor(this.workspaceFilter.length === 0 ? '#22D3EE' : this.pal().text3)
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .backgroundColor(this.workspaceFilter.length === 0
                ? 'rgba(34,211,238,0.14)' : this.pal().inputBg)
              .borderRadius(8)
              .onClick(() => {
                this.workspaceFilter = '';
              })
            ForEach(this.sessionWorkspaces(), (cwd: string) => {
              Text(cwdTail(cwd))
                .fontSize(this.fs(11))
                .fontColor(this.workspaceFilter === cwd ? '#22D3EE' : this.pal().text3)
                .maxLines(1)
                .constraintSize({ maxWidth: 110 })
                .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .backgroundColor(this.workspaceFilter === cwd
                  ? 'rgba(34,211,238,0.14)' : this.pal().inputBg)
                .borderRadius(8)
                .onClick(() => {
                  this.workspaceFilter = this.workspaceFilter === cwd ? '' : cwd;
                })
            }, (cwd: string) => 'ws-' + cwd)
          }
          .padding({ left: 16, right: 16, bottom: 6 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      if (this.visibleSessions().length === 0) {
        Column({ space: 6 }) {
          Text(this.sessionSearchActive ? this.tr('没有匹配的会话') : this.tr('还没有会话'))
            .fontSize(this.fs(12))
            .fontColor(this.pal().text3)
          if (!this.sessionSearchActive) {
            Text(this.tr('点右上角「新建」开一个'))
              .fontSize(this.fs(10))
              .fontColor(this.pal().text3)
          }
        }
        .width('100%')
        .padding({ top: 18, bottom: 12 })
        .alignItems(HorizontalAlign.Center)
      }
      List({ space: 8 }) {
        ForEach(this.visibleSessions(),
          (session: HarnessRemoteSession, index: number) => {
          ListItem() {
            Column() {
            if (this.sessionGroupGap(index).length > 0) {
              Row({ space: 6 }) {
                Text(this.tr(this.sessionGroupGap(index)))
                  .fontSize(this.fs(11))
                  .fontColor(this.pal().text3)
                if (!this.sessionSearchActive) {
                  Text('' + this.workspaceGroupCount(this.sessionGroupGap(index)))
                    .fontSize(this.fs(10))
                    .fontColor(this.pal().text3)
                }
                if (!this.sessionSearchActive) {
                  Text(this.collapsedWorkspaces.includes(this.sessionGroupGap(index))
                    ? this.tr('展开') : this.tr('收起'))
                    .fontSize(this.fs(10))
                    .fontColor('#22D3EE')
                }
                Blank()
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: index === 0 ? 0 : 10, bottom: 4 })
              .onClick(() => {
                if (this.sessionSearchActive) {
                  return;
                }
                this.toggleWorkspaceGroup(this.sessionGroupGap(index));
              })
            }
            Row({ space: 10 }) {
              Column()
                .width(3)
                .height(34)
                .borderRadius(1.5)
                .backgroundColor(session.sessionId === this.currentSessionId ? '#4D6BFE' : this.pal().chip)
              Column({ space: 3 }) {
                Text(formatSessionTitle(session))
                  .fontSize(this.fs(14))
                  .fontWeight(session.sessionId === this.currentSessionId ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(session.sessionId === this.currentSessionId ? this.pal().text : this.pal().text2)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Row({ space: 6 }) {
                  Text(formatSessionTime(session.updatedAt))
                    .fontSize(this.fs(11))
                    .fontColor(this.pal().text2)
                  if (session.turns > 0 && !this.ultraCompactRows()) {
                    Text(session.turns + this.tr(' 轮'))
                      .fontSize(this.fs(10))
                      .fontColor(this.pal().text3)
                  }
                  if (cwdTail(session.cwd).length > 0 && !this.ultraCompactRows()) {
                    Text(cwdTail(session.cwd))
                      .fontSize(this.fs(10))
                      .fontColor(this.pal().text3)
                      .maxLines(1)
                      .constraintSize({ maxWidth: 90 })
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  if (this.runtime.draftOf(session.sessionId).length > 0) {
                    Text(this.tr('草稿'))
                      .fontSize(this.fs(9))
                      .fontColor('#F0A020')
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor('rgba(240,160,32,0.14)')
                      .borderRadius(5)
                  }
                  if (this.runtime.pendingConfirmationCount(session.sessionId) > 0) {
                    Text('待确认 ' + this.runtime.pendingConfirmationCount(session.sessionId))
                      .fontSize(this.fs(9))
                      .fontColor('#F5A623')
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor('rgba(245,166,35,0.16)')
                      .borderRadius(5)
                  }
                  if (session.running) {
                    Row({ space: 3 }) {
                      Column()
                        .width(4)
                        .height(4)
                        .borderRadius(2)
                        .backgroundColor('#34D399')
                      Text('运行中')
                        .fontSize(this.fs(10))
                        .fontColor('#34D399')
                    }
                  }
                  if (sessionBackendBadge(session.sessionId).length > 0) {
                    Text(sessionBackendBadge(session.sessionId))
                      .fontSize(this.fs(9))
                      .fontColor('#8B5CF6')
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor('rgba(139,92,246,0.14)')
                      .borderRadius(5)
                  }
                  if (this.isPinnedSession(session.sessionId)) {
                    Text('置顶')
                      .fontSize(this.fs(9))
                      .fontColor('#4D6BFE')
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor('rgba(77,107,254,0.14)')
                      .borderRadius(5)
                  }
                  if (this.isArchivedSession(session.sessionId)) {
                    Text(this.tr('已归档'))
                      .fontSize(this.fs(9))
                      .fontColor(this.pal().text3)
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor(this.pal().inputBg)
                      .borderRadius(5)
                  }
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Text(this.runtime.isFavoriteSession(session.sessionId) ? '★' : '☆')
                .fontSize(this.fs(14))
                .fontColor(this.runtime.isFavoriteSession(session.sessionId) ? '#F5A623' : this.pal().text3)
                .padding({ left: 6, right: 2, top: 6, bottom: 6 })
                .onClick(() => {
                  this.runtime.toggleFavoriteSession(session.sessionId);
                })
            }
            .width('100%')
            .padding({ top: this.compactRows() ? 7 : 10, bottom: this.compactRows() ? 7 : 10,
              left: 12, right: 12 })
            .backgroundColor(session.sessionId === this.currentSessionId
              ? 'rgba(77,107,254,0.14)'
              : (this.hoverRowId === session.sessionId ? this.pal().inputBg : this.pal().card))
            .onHover((isHover: boolean) => {
              this.hoverRowId = isHover ? session.sessionId : '';
            })
            .borderRadius(this.compactRows() ? 12 : 14)
            .opacity(this.isArchivedSession(session.sessionId) ? 0.6 : 1)
            .border({ width: 1,
              color: session.sessionId === this.currentSessionId
                ? 'rgba(77,107,254,0.40)' : this.pal().border })
            .focusable(true)
            .onClick(() => {
              this.closeDrawer();
              this.runtime.openSession(session.sessionId);
            })
            .onKeyEvent((event: KeyEvent) => {
              if (event.type === KeyType.Down
                && (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE)) {
                this.runtime.openSession(session.sessionId);
              }
            })
            // 长按（触屏）和右键（PC）都出同一个会话菜单
            .gesture(LongPressGesture().onAction(() => {
              this.openSessionMenu(session);
            }))
            .onMouse((event: MouseEvent) => {
              if (event.action === MouseAction.Press && event.button === MouseButton.Right) {
                this.openSessionMenu(session);
              }
            })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }, (session: HarnessRemoteSession) =>
          `${session.sessionId}#${this.languageMode}#${this.runtime.pendingConfirmationCount(session.sessionId)}`)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12, top: 10 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 右栏会话详情（三栏模式常驻）：会话概览 + 模型/权限 + 上下文 + 快捷入口。
   * 内容与「齿轮」面板同源，但排成竖排窄栏，避免在超宽窗口里还要点开浮层。
   */
  @Builder
  InspectorPane() {
    Column({ space: 12 }) {
      Column({ space: 3 }) {
        Text(this.tr('会话详情'))
          .fontSize(this.fs(13))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
          .width('100%')
        Text(this.currentSessionTitle.length > 0 ? this.currentSessionTitle : this.tr('新会话'))
          .fontSize(this.fs(11))
          .fontColor(this.pal().text3)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 上下文
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.tr('上下文'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
          Text(this.contextPercent > 0 ? `${this.contextPercent}%` : '—')
            .fontSize(this.fs(12))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.contextPercent >= 80 ? '#F85749' : this.pal().text)
        }
        .width('100%')
        Progress({ value: this.contextPercent, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(4)
          .color(this.contextPercent >= 80 ? '#F85749' : '#22D3EE')
        if (this.contextPercent >= 60) {
          Text(this.tr('压缩上下文'))
            .fontSize(this.fs(11))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('rgba(34,211,238,0.10)')
            .borderRadius(8)
            .onClick(() => {
              this.runtime.sendPrompt('/compact');
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 模型
      Column({ space: 4 }) {
        Text(this.tr('模型'))
          .fontSize(this.fs(11))
          .fontColor(this.pal().text3)
          .width('100%')
        Text(this.modelSummary())
          .fontSize(this.fs(12))
          .fontColor(this.pal().text2)
          .maxLines(2)
          .width('100%')
        Text(this.tr('更换模型'))
          .fontSize(this.fs(11))
          .fontColor('#22D3EE')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor('rgba(34,211,238,0.10)')
          .borderRadius(8)
          .onClick(() => {
            this.runtime.refreshModelCatalog();
            this.showModelPicker = true;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 权限：横向三个小 chip，省下竖排占掉的高度
      Column({ space: 4 }) {
        Text(this.tr('权限'))
          .fontSize(this.fs(11))
          .fontColor(this.pal().text3)
          .width('100%')
        Row({ space: 6 }) {
          ForEach(this.permissionChoices(), (preset: string) => {
            Text(this.permissionChoiceLabel(preset))
              .fontSize(this.fs(10))
              .fontColor(preset === this.permissionPreset ? '#0B1220' : this.pal().text2)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .padding({ top: 4, bottom: 4 })
              .backgroundColor(preset === this.permissionPreset ? '#34D399' : this.pal().inputBg)
              .borderRadius(8)
              .border({ width: 1, color: this.pal().border })
              .onClick(() => {
                this.runtime.selectPermission(preset);
              })
          }, (preset: string) => preset)
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // 定时任务摘要：最多两条，其余进面板看
      if (this.runtime.schedulesSupported && this.runtime.schedules.length > 0) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text(this.tr('定时任务'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Blank()
            Text(this.runtime.schedules.length + this.tr(' 个'))
              .fontSize(this.fs(10))
              .fontColor(this.pal().text3)
              .onClick(() => {
                this.schedulesOpen = true;
              })
          }
          .width('100%')
          ForEach(this.runtime.schedules.slice(0, 2), (schedule: HarnessSchedule) => {
            Column({ space: 1 }) {
              Text(schedule.title.length > 0 ? schedule.title : schedule.id)
                .fontSize(this.fs(11))
                .fontColor(this.pal().text2)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.scheduleSummary(schedule))
                .fontSize(this.fs(9))
                .fontColor(this.pal().text3)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (schedule: HarnessSchedule) => 'insp-' + schedule.id)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // 快捷入口
      Column({ space: 6 }) {
        Text(this.tr('快捷入口'))
          .fontSize(this.fs(11))
          .fontColor(this.pal().text3)
          .width('100%')
        Row({ space: 6 }) {
          Text(this.tr('定时任务'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text2)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.pal().inputBg)
            .borderRadius(8)
            .onClick(() => {
              this.schedulesOpen = true;
              this.runtime.loadSchedules();
            })
          Text(this.tr('诊断'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text2)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.pal().inputBg)
            .borderRadius(8)
            .onClick(() => {
              this.diagnosticsOpen = true;
              // 诊断里要显示系统通知开关，打开时现查一次，别显示上次的旧状态
              this.runtime.refreshNotificationState();
            })
        }
        Row({ space: 6 }) {
          Text(this.tr('导出'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text2)
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(this.pal().inputBg)
            .borderRadius(8)
            .onClick(() => {
              const data: pasteboard.PasteData = pasteboard.createData(
                pasteboard.MIMETYPE_TEXT_PLAIN, this.runtime.sessionMarkdown());
              pasteboard.getSystemPasteboard().setData(data).then(() => {
                promptAction.showToast({ message: this.tr('会话 Markdown 已复制') });
              }).catch(() => undefined);
            })
          Text(this.tr('归档'))
            .fontSize(this.fs(11))
            .fontColor('#F85749')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor('rgba(248,87,73,0.10)')
            .borderRadius(8)
            .onClick(() => {
              this.runtime.archiveCurrentSession();
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      Blank()
      Text(this.connectionSummary())
        .fontSize(this.fs(10))
        .fontColor(this.pal().text3)
        .maxLines(2)
        .width('100%')
    }
    .width(300)
    .padding({ left: 14, right: 14, top: 16, bottom: 16 })
    .margin({ right: 8, top: 8, bottom: 8 })
    .backgroundColor(this.overlayGlass())
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
      adaptiveColor: AdaptiveColor.DEFAULT,
      blurOptions: { grayscale: [0, 12] }
    })
    .borderRadius(18)
    .border({ width: 1, color: this.pal().border })
    .alignItems(HorizontalAlign.Start)
    // 常驻栏没有「打开面板」这个动作，出现时自己补一次模型目录与权限状态
    .onAppear(() => {
      if (!this.runtime.modelCatalogLoaded) {
        this.runtime.refreshModelCatalog();
      }
      this.runtime.refreshPermissionState();
      this.runtime.loadSchedules();
    })
  }

  /** 文件浏览：只读列目录，点目录进入、点 .. 返回上级。 */
  @Builder
  FileBrowserOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.showBrowser = false;
        })
      Column() {
        Row({ space: 10 }) {
          Text('↑ 上级')
            .fontSize(this.fs(12))
            .fontColor(this.pal().text2)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.pal().chip)
            .borderRadius(9)
            .onClick(() => {
              this.runtime.browseUp();
            })
          Text(this.browsePath)
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('关闭')
            .fontSize(this.fs(12))
            .fontColor(this.pal().text3)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => {
              this.showBrowser = false;
            })
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 14, bottom: 8 })
        List({ space: 4 }) {
          ForEach(this.directoryEntries, (entry: DirectoryEntry) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(entry.isDirectory ? '📁' : '📄')
                  .fontSize(this.fs(14))
                Text(entry.name)
                  .fontSize(this.fs(13))
                  .fontColor(this.pal().text)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (!entry.isDirectory && entry.size > 0) {
                  Text(Math.round(entry.size / 1024) + ' KB')
                    .fontSize(this.fs(10))
                    .fontColor(this.pal().text3)
                }
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .onClick(() => {
                const full: string = entry.path.length > 0 ? entry.path : (this.browsePath + '/' + entry.name);
                if (entry.isDirectory) {
                  this.runtime.browseDirectory(full);
                  return;
                }
                this.filePreviewOpen = true;
                this.openFilePreview(full);
              })
            }
          }, (entry: DirectoryEntry) => entry.path.length > 0 ? entry.path : entry.name)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .constraintSize({ maxHeight: '70%' })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 顶栏齿轮面板：把「会话信息 / 模型 / 推理等级 / 权限 / 上下文 / 连接」收在一处。
   * 每一行都带当前值，点哪行改哪个；比原来的 ActionSheet 少一层猜测。
   */
  @Builder
  SessionPanelOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.showSessionPanel = false;
        })
      Scroll() {
      Column() {
      ForEach([this.settingsRev], (rev: number) => {
      Column({ space: 0 }) {
        Row({ space: 8 }) {
          Text('🔍')
            .fontSize(this.fs(13))
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.pal().chip)
            .borderRadius(9)
            .margin({ right: 2 })
            .onClick(() => {
              this.showSessionPanel = false;
              this.inSessionQuery = '';
              this.inSessionSearchOpen = true;
            })
          Column({ space: 2 }) {
            Text(this.tr('会话设置'))
              .fontSize(this.fs(16))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text)
            Text(this.currentSessionTitle.length > 0 ? this.currentSessionTitle : this.tr('新会话'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('✕')
            .fontSize(this.fs(15))
            .fontColor(this.pal().text3)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.showSessionPanel = false;
            })
        }
        .width('100%')
        .padding({ left: 18, right: 12, top: 16, bottom: 8 })

        // —— 模型 ——
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.tr('模型'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Text(this.modelSummary())
              .fontSize(this.fs(14))
              .fontColor(this.pal().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.tr('更换'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('rgba(34,211,238,0.10)')
            .borderRadius(10)
            .onClick(() => {
              this.showSessionPanel = false;
              this.runtime.refreshModelCatalog();
              this.showModelPicker = true;
            })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 12, bottom: 12 })

        // —— 推理等级（当前模型有等级才显示）——
        if (this.currentModelEfforts().length > 0) {
          Column({ space: 6 }) {
            Text(this.tr('推理等级'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .width('100%')
            Scroll() {
              Row({ space: 8 }) {
                ForEach(this.currentModelEfforts(), (effort: string) => {
                  Text(effort)
                    .fontSize(this.fs(11))
                    .fontColor(effort === this.currentModelEffort ? '#0B1220' : this.pal().text2)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .backgroundColor(effort === this.currentModelEffort ? '#22D3EE' : this.pal().inputBg)
                    .borderRadius(10)
                    .border({ width: 1, color: this.pal().border })
                    .onClick(() => {
                      this.runtime.selectModel(this.currentModelProvider, this.currentModelLabel, effort);
                    })
                }, (effort: string) => effort)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 4, bottom: 12 })
        }

        // —— 权限 ——
        Column({ space: 6 }) {
          Text(this.tr('权限'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
            .width('100%')
          Row({ space: 8 }) {
            ForEach(this.permissionChoices(), (preset: string) => {
              Text(this.permissionChoiceLabel(preset))
                .fontSize(this.fs(11))
                .fontColor(preset === this.permissionPreset ? '#0B1220' : this.pal().text2)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(preset === this.permissionPreset ? '#34D399' : this.pal().inputBg)
                .borderRadius(10)
                .border({ width: 1, color: this.pal().border })
                .onClick(() => {
                  this.permissionPreset = preset;
                  this.runtime.selectPermission(preset);
                })
            }, (preset: string) => preset)
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: 12 })

        // —— 上下文 ——
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.tr('上下文'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Text(this.contextPercent > 0 ? `${this.contextPercent}%` : '—')
              .fontSize(this.fs(14))
              .fontColor(this.contextPercent >= 80 ? '#F85749' : this.pal().text)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Row({ space: 8 }) {
            Text(this.tr('导出'))
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor(this.pal().inputBg)
              .borderRadius(10)
              .onClick(() => {
                const data: pasteboard.PasteData = pasteboard.createData(
                  pasteboard.MIMETYPE_TEXT_PLAIN, this.runtime.sessionMarkdown());
                pasteboard.getSystemPasteboard().setData(data).then(() => {
                  promptAction.showToast({ message: this.tr('会话 Markdown 已复制') });
                }).catch(() => {
                  promptAction.showToast({ message: this.tr('复制失败') });
                });
              })
            Text(this.tr('压缩上下文'))
              .fontSize(this.fs(12))
              .fontColor('#22D3EE')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor('rgba(34,211,238,0.10)')
              .borderRadius(10)
              .onClick(() => {
                this.showSessionPanel = false;
                this.runtime.sendPrompt('/compact');
              })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: 12 })

        // —— 文字大小：会话里直接调，改完立刻重排 ——
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.tr('文字大小'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Text(this.textScaleLabel())
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          ForEach(this.textScaleChoices(), (choice: ThemeChoice) => {
            Text(choice.label)
              .fontSize(this.fs(11))
              .fontColor(this.textScaleMode === choice.value ? '#22D3EE' : this.pal().text3)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(this.textScaleMode === choice.value
                ? 'rgba(34,211,238,0.14)' : this.pal().inputBg)
              .borderRadius(8)
              .onClick(() => {
                this.tapHaptic();
                this.runtime.setTextScaleMode(choice.value);
                this.textScaleMode = choice.value;
                this.textScaleValue = this.runtime.textScale();
                this.settingsRev = this.settingsRev + 1;
              })
          }, (choice: ThemeChoice) => 'scale:' + choice.value + ':' + this.textScaleMode)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: 12 })

        // —— 桌宠开关：首页（齿轮面板）就能关，不用翻设置抽屉 ——
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.tr('显示桌宠'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Text(this.uiPetEnabled ? this.tr('显示中') : this.tr('已隐藏'))
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.uiPetEnabled })
            .selectedColor('#4D6BFE')
            .onChange((isOn: boolean) => {
              this.uiPetEnabled = isOn;
              this.settingsRev = this.settingsRev + 1;
              this.runtime.setPetEnabled(isOn);
              this.tapHaptic();
            })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: 12 })

        // —— 会话壁纸 ——
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.tr('会话壁纸'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Text(this.wallpaper.length > 0 ? this.tr('已设置 · 自动虚化') : this.tr('无'))
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.wallpaper.length > 0 ? this.tr('更换') : this.tr('选择'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('rgba(34,211,238,0.10)')
            .borderRadius(10)
            .onClick(() => {
              this.tapHaptic();
              this.openWallpaperPicker();
            })
          if (this.wallpaper.length > 0) {
            Text(this.tr('移除'))
              .fontSize(this.fs(12))
              .fontColor('#F85749')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor('rgba(248,87,73,0.10)')
              .borderRadius(10)
              .onClick(() => {
                this.tapHaptic();
                this.wallpaper = '';
                this.settingsRev = this.settingsRev + 1;
                this.runtime.setWallpaper('');
                promptAction.showToast({ message: this.tr('壁纸已移除') });
              })
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: 12 })

        // —— 壁纸强度（只在设了壁纸时出现）——
        if (this.wallpaper.length > 0) {
          Row({ space: 10 }) {
            Column({ space: 3 }) {
              Text(this.tr('壁纸强度'))
                .fontSize(this.fs(11))
                .fontColor(this.pal().text3)
              Text(this.wallpaperDimLabel())
                .fontSize(this.fs(12))
                .fontColor(this.pal().text2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Text(this.tr('切换'))
              .fontSize(this.fs(12))
              .fontColor('#22D3EE')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .backgroundColor('rgba(34,211,238,0.10)')
              .borderRadius(10)
              .onClick(() => {
                this.tapHaptic();
                const next: number = (this.uiWallpaperDim + 1) % 3;
                this.uiWallpaperDim = next;
                this.settingsRev = this.settingsRev + 1;
                this.runtime.setWallpaperDim(next);
              })
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 4, bottom: 12 })
        }

        // —— 定时任务 ——
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.tr('定时任务'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Text(this.runtime.schedules.length > 0
              ? this.runtime.schedules.length + this.tr(' 个任务')
              : this.tr('还没有'))
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.tr('管理'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .onClick(() => {
              this.schedulesOpen = true;
              this.runtime.loadSchedules();
            })
        }
        .width('100%')
        // 这一行之前漏了左右内边距，导致「定时任务」贴边、值和按钮错位
        .padding({ left: 18, right: 18, top: 4, bottom: 12 })

        // —— 连接 ——
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(this.tr('连接状态'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
            Text(this.connectionSummary())
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text(this.tr('诊断'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .onClick(() => {
              this.diagnosticsOpen = true;
              // 诊断里要显示系统通知开关，打开时现查一次，别显示上次的旧状态
              this.runtime.refreshNotificationState();
            })
          Text(this.tr('断开连接'))
            .fontSize(this.fs(12))
            .fontColor('#F85749')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor('rgba(248,87,73,0.10)')
            .borderRadius(10)
            .onClick(() => {
              this.showSessionPanel = false;
              this.runtime.disconnectAndClose();
            })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4, bottom: 18 })
      }
      .width('100%')
      .constraintSize({ maxWidth: 520 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20, bottomLeft: 0, bottomRight: 0 })
      .border({ width: 1, color: this.pal().border })
      }, (rev: number) => 'session-body-' + rev)
      }
      .width('100%')
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // 面板限高，内容多了自己滚，不再顶出屏幕
      .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.82 : 640 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** 面板里的模型行文案：provider/model @effort。 */
  private modelSummary(): string {
    if (this.currentModelLabel.length === 0) {
      return this.runtime.modelCatalogLoaded ? this.tr('未选择') : this.tr('正在读取模型目录…');
    }
    const head: string = this.currentModelProvider.length > 0
      ? this.currentModelProvider + '/' + this.currentModelLabel
      : this.currentModelLabel;
    return this.currentModelEffort.length > 0 ? head + ' @' + this.currentModelEffort : head;
  }

  /** 当前模型支持哪些推理等级（从目录里找）。 */
  private currentModelEfforts(): string[] {
    for (const option of this.runtime.modelOptions) {
      if (option.model === this.currentModelLabel
        && (this.currentModelProvider.length === 0 || option.provider === this.currentModelProvider)) {
        return option.efforts;
      }
    }
    return [];
  }

  /** 主机报告的预设清单优先；没读到就退回内置三项。 */
  private permissionChoices(): string[] {
    if (this.permissionOptionsList.length > 0) {
      return this.permissionOptionsList;
    }
    return ['read-only', 'workspace-write', 'danger-full-access'];
  }

  private permissionChoiceLabel(preset: string): string {
    if (preset === 'read-only') {
      return this.tr('只读');
    }
    if (preset === 'workspace-write') {
      return this.tr('可写');
    }
    if (preset === 'danger-full-access') {
      return this.tr('完全');
    }
    return preset;
  }

  /** 面板里的连接行：主机 + 数据面。 */
  private connectionSummary(): string {
    const host: string = this.connectedHostDisplay();
    const mode: string = this.transportBadgeText();
    if (host.length === 0) {
      return this.tr('未连接');
    }
    return mode.length > 0 ? host + ' · ' + mode : host;
  }

  /** 模型选择器：底部面板形式，点选后立即切换当前会话的模型。 */
  @Builder
  ModelPickerOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.showModelPicker = false;
        })
      Column() {
        Row() {
          Text('选择模型')
            .fontSize(this.fs(16))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Blank()
          Text('关闭')
            .fontSize(this.fs(13))
            .fontColor(this.pal().text3)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick(() => {
              this.showModelPicker = false;
            })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 16, bottom: 10 })
        if (this.pendingModel !== undefined) {
          Column({ space: 6 }) {
            Text('选择 ' + this.pendingModel!.name + ' 的推理等级')
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
              .width('100%')
              .padding({ left: 18, right: 18 })
            Scroll() {
              Row({ space: 8 }) {
                Text('默认')
                  .fontSize(this.fs(11))
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .backgroundColor(this.pal().inputBg)
                  .borderRadius(9)
                  .border({ width: 1, color: this.pal().border })
                  .onClick(() => {
                    this.runtime.selectModel(this.pendingModel!.provider,
                      this.pendingModel!.model, '');
                    this.pendingModel = undefined;
                    this.showModelPicker = false;
                  })
                ForEach(this.pendingModel!.efforts, (effort: string) => {
                  Text(effort)
                    .fontSize(this.fs(11))
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor('rgba(34,211,238,0.10)')
                    .borderRadius(9)
                    .border({ width: 1, color: 'rgba(34,211,238,0.35)' })
                    .onClick(() => {
                      this.runtime.selectModel(this.pendingModel!.provider,
                        this.pendingModel!.model, effort);
                      this.pendingModel = undefined;
                      this.showModelPicker = false;
                    })
                }, (effort: string) => effort)
              }
              .padding({ left: 18, right: 18 })
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
          }
          .width('100%')
          .padding({ top: 4, bottom: 8 })
        }
        if (this.modelOptions.length === 0) {
          Text('模型目录为空：请确认主机已配置模型服务商')
            .fontSize(this.fs(13))
            .fontColor(this.pal().text3)
            .padding({ left: 18, right: 18, top: 8, bottom: 24 })
        } else {
          List({ space: 6 }) {
            ForEach(this.modelOptions, (option: ModelOption) => {
              ListItem() {
                Row({ space: 10 }) {
                  Column({ space: 2 }) {
                    Text(option.name.length > 0 ? option.name : option.model)
                      .fontSize(this.fs(14))
                      .fontColor(this.pal().text)
                    Text(option.provider + ' · ' + option.model)
                      .fontSize(this.fs(11))
                      .fontColor(this.pal().text3)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (option.model === this.currentModelLabel) {
                    Text('当前')
                      .fontSize(this.fs(11))
                      .fontColor('#22D3EE')
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .backgroundColor('rgba(34,211,238,0.12)')
                      .borderRadius(8)
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                .backgroundColor(this.pal().card)
                .borderRadius(12)
                .border({ width: 1, color: this.pal().border })
                .onClick(() => {
                  if (option.efforts.length > 0) {
                    this.pendingModel = option;
                    return;
                  }
                  this.runtime.selectModel(option.provider, option.model, '');
                  this.showModelPicker = false;
                })
              }
            }, (option: ModelOption) => option.provider + '/' + option.model)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 14, right: 14, bottom: 16 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .constraintSize({ maxHeight: '62%' })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
    }
    .width('100%')
    .height('100%')
  }

  /** Portrait: sessions slide in from the right over a scrim. */
  @Builder
  SessionsOverlay() {
    Stack({ alignContent: Alignment.End }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .opacity(this.drawerOpen)
        .onClick(() => {
          this.closeDrawer();
        })
      Column() {
        this.SessionsPanelBody()
      }
      .width(this.drawerWidthVp())
      .height('100%')
      .backgroundColor(this.pal().panel)
      .border({ width: { left: 0.5 }, color: this.pal().borderStrong })
      // 位移完全由手势进度决定：拉多少露多少，松手才补齐或弹回
      .translate({ x: (1 - this.drawerOpen) * this.drawerWidthVp() })
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
          .onActionStart(() => {
            this.drawerDragBase = this.drawerOpen;
            this.drawerDragFromChat = false;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.drawerDragFromChat) {
              return;
            }
            const width: number = this.drawerWidthVp();
            this.drawerOpen = Math.min(1, Math.max(0, this.drawerDragBase - event.offsetX / width));
          })
          .onActionEnd(() => {
            this.settleDrawer(this.drawerOpen >= 0.55);
          })
      )
    }
    .width('100%')
    .height('100%')
  }

  /** Landscape: sessions stay pinned on the left next to the chat. */
  @Builder
  SessionsPane() {
    Column() {
      this.SessionsPanelBody()
    }
    .width(this.listPanelWidth())
    .margin({ left: 8, top: 8, bottom: 8 })
    .backgroundColor(this.pal().panel)
    .borderRadius(18)
    .border({ width: 1, color: this.pal().border })
    .clip(true)
  }

  @Builder
  MessageRow(item: ChatItem) {
    if (item.kind === 'user') {
      Row() {
        // 纵向容器：气泡在上，排队状态和时间在下（横向排时状态会被宽气泡挤出屏幕）
        Column({ space: 4 }) {
          Column({ space: 6 }) {
            if (this.messageImages(item).length > 0) {
              Column({ space: 6 }) {
                ForEach(this.messageImages(item), (base64: string, index: number) => {
                  Image(imageDataUri(base64))
                    .width(168)
                    .height(168)
                    .borderRadius(10)
                    .objectFit(ImageFit.Cover)
                    .onClick(() => {
                      this.openPreview(imageDataUri(base64));
                    })
                }, (base64: string, index: number) => index + ':' + base64.length)
              }
            }
            if (item.text.length > 0) {
              if (this.heartbeatBody(item).length > 0) {
                Text(this.heartbeatOpen(item) ? item.text : this.heartbeatBody(item))
                  .fontSize(this.fs(this.heartbeatOpen(item) ? 12 : 15))
                  .fontColor('#FFFFFF')
                  .textAlign(TextAlign.Start)
                Text(this.heartbeatOpen(item) ? this.tr('收起巡检原文') : this.tr('查看巡检原文'))
                  .fontSize(this.fs(11))
                  .fontColor('rgba(255,255,255,0.78)')
                  .padding({ top: 2, bottom: 2 })
                  .onClick(() => {
                    this.toggleHeartbeat(item);
                  })
              } else {
                Text(item.text)
                  .fontSize(this.fs(15))
                  .fontColor('#FFFFFF')
                  .textAlign(TextAlign.Start)
              }
            }
            if (item.files.length > 0) {
              Column({ space: 4 }) {
                ForEach(item.files, (label: string, index: number) => {
                  Row({ space: 6 }) {
                    Text('📎')
                      .fontSize(12)
                    Text(label)
                      .fontSize(12)
                      .fontColor('rgba(255,255,255,0.94)')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                  .backgroundColor('rgba(255,255,255,0.16)')
                  .borderRadius(8)
                }, (label: string, index: number) => index + ':' + label)
              }
              .alignItems(HorizontalAlign.Start)
            }
          }
          .padding({ top: 10, bottom: 10, left: 14, right: 14 })
          .linearGradient({ angle: 135, colors: [['#3D5CF6', 0], ['#2E7CF0', 0.6], ['#22D3EE', 1]] })
          .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 6 })
          .alignItems(HorizontalAlign.Start)
          .shadow({ radius: 12, color: 'rgba(61,92,246,0.30)', offsetX: 0, offsetY: 3 })
          if (item.sendState === 'queued') {
            Text(this.tr('断线排队中 · 重连后自动发送'))
              .fontSize(this.fs(10))
              .fontColor('rgba(255,255,255,0.78)')
          }
          // 回合进行中的状态：一行小字 + 两个文字动作，和气泡里其他小标签同样式
          if (item.sendState === 'turn-queued') {
            Row({ space: 6 }) {
              Text(this.tr('排队中'))
                .fontSize(this.fs(10))
                .fontColor('rgba(255,255,255,0.72)')
              Text(this.tr('插队'))
                .fontSize(this.fs(10))
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
                .padding({ left: 4, right: 4 })
                .onClick(() => {
                  this.runtime.promoteQueuedSend(item).then((note: string) => {
                    promptAction.showToast({ message: note });
                  }).catch((error: Error) => {
                    promptAction.showToast({ message: errorMessage(error) });
                  });
                })
              Text('·')
                .fontSize(this.fs(10))
                .fontColor('rgba(255,255,255,0.45)')
              Text(this.tr('撤回'))
                .fontSize(this.fs(10))
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Medium)
                .padding({ left: 4, right: 4 })
                .onClick(() => {
                  this.runtime.withdrawQueuedSend(item).then((note: string) => {
                    promptAction.showToast({ message: note });
                  }).catch((error: Error) => {
                    promptAction.showToast({ message: errorMessage(error) });
                  });
                })
            }
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor('rgba(255,255,255,0.14)')
            .borderRadius(7)
          }
          if (item.sendState === 'turn-steer') {
            Text(this.tr('已插队'))
              .fontSize(this.fs(10))
              .fontColor('rgba(255,255,255,0.72)')
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .backgroundColor('rgba(255,255,255,0.14)')
              .borderRadius(7)
          }
          if (item.sendState === 'withdrawn') {
            Text(this.tr('已撤回'))
              .fontSize(this.fs(10))
              .fontColor('rgba(255,255,255,0.55)')
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .backgroundColor('rgba(0,0,0,0.18)')
              .borderRadius(7)
          }
          if (item.timestamp > 0) {
            Text(formatClock(item.timestamp))
              .fontSize(this.fs(10))
              .fontColor(this.pal().text3)
              .padding({ top: 2 })
          }
        }
        .width('80%')
        .alignItems(HorizontalAlign.End)
        .gesture(LongPressGesture().onAction(() => {
          this.offerMessageActions(item);
        }))
        .onMouse((event: MouseEvent) => {
          if (event.action === MouseAction.Press && event.button === MouseButton.Right) {
            this.offerMessageActions(item);
          }
        })
        .onHover((isHover: boolean) => {
          // 鼠标（PC）停在气泡上才出快捷操作；触屏不走这里，行为不变
          this.hoverMessageId = isHover ? item.id : '';
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      if (this.hoverMessageId === item.id) {
        this.MessageQuickActions(item, true)
      }
    } else if (item.kind === 'assistant') {
      this.AssistantRow(item)
    } else if (item.kind === 'tool') {
      this.ToolRow(item)
    } else if (item.kind === 'toolrun') {
      this.ToolRunRow(item)
    } else if (item.kind === 'approval') {
      this.ApprovalRow(item)
    } else if (item.kind === 'question') {
      this.QuestionRow(item)
    } else if (item.kind === 'notice') {
      this.NoticeRow(item)
    }
  }

  /**
   * 失败/提醒行：上下文超窗、输出截断、主机拒绝等。
   * 以前这些在手机上完全看不到（turn/end 的 reason 被丢掉），现在固定占一行。
   */
  @Builder
  NoticeRow(item: ChatItem) {
    Row() {
      Row() {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(item.noticeKind === 'error' ? '⚠' : '!')
              .fontSize(this.fs(13))
              .fontColor(item.noticeKind === 'error' ? '#F85749' : '#F0A020')
            Text(this.tr(item.text))
              .fontSize(this.fs(13))
              .fontWeight(FontWeight.Medium)
              .fontColor(item.noticeKind === 'error' ? '#F85749' : '#C88418')
              .textAlign(TextAlign.Start)
              .layoutWeight(1)
          }
          .alignItems(VerticalAlign.Top)
          if (item.reason.length > 0) {
            Text(this.tr(item.reason))
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
              .textAlign(TextAlign.Start)
          }
          if (item.actionCommand.length > 0) {
            Button(this.tr('压缩上下文'))
              .height(30)
              .fontSize(this.fs(12))
              .padding({ left: 14, right: 14 })
              .backgroundColor(this.pal().chip)
              .fontColor(this.pal().text)
              .borderRadius(15)
              .enabled(!this.generating && !this.busy)
              .onClick(() => {
                this.runtime.sendPrompt(item.actionCommand);
              })
          }
        }
        .padding({ top: 10, bottom: 10, left: 14, right: 14 })
        .backgroundColor(this.pal().inputBg)
        .borderRadius(14)
        .border({ width: 1, color: item.noticeKind === 'error' ? 'rgba(248,87,73,0.35)' : 'rgba(240,160,32,0.35)' })
        .alignItems(HorizontalAlign.Start)
      }
      .width('88%')
      .constraintSize({ maxWidth: 780 })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
  }

  /** 轻量 Markdown 渲染：代码块、标题、行内代码与粗体标记不再裸露。 */
  @Builder
  MarkdownText(text: string, streaming: boolean) {
    Column({ space: 5 }) {
      // key 里带上 imageVersion：图片解码完成/失败后重建这些行，否则会一直停在「图片加载中」。
      ForEach(markdownLines(streaming ? text + '▍' : text), (line: MdLine, index: number) => {
        if (line.tableHeader.length > 0) {
          Column({ space: 0 }) {
            Row({ space: 0 }) {
              ForEach(line.tableHeader, (cell: string, ci: number) => {
                Text(cell)
                  .fontSize(this.fs(12))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.pal().text)
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .layoutWeight(1)
                  .textAlign(TextAlign.Start)
              }, (cell: string, ci: number) => 'h:' + ci + ':' + cell)
            }
            .width('100%')
            .backgroundColor(this.pal().chip)
            ForEach(line.tableRows, (row: string[], ri: number) => {
              Row({ space: 0 }) {
                ForEach(row, (cell: string, ci: number) => {
                  Text(cell)
                    .fontSize(this.fs(12))
                    .fontColor(this.pal().text2)
                    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                    .layoutWeight(1)
                    .textAlign(TextAlign.Start)
                }, (cell: string, ci: number) => 'c:' + ri + ':' + ci + ':' + cell)
              }
              .width('100%')
              .border({ width: { top: 0.5 }, color: this.pal().border })
            }, (row: string[], ri: number) => 'r:' + ri + ':' + row.join('|'))
          }
          .width('100%')
          .borderRadius(8)
          .border({ width: 1, color: this.pal().border })
          .clip(true)
        } else if (line.imageSrc.length > 0) {
          this.MdImage(line)
        } else if (line.codeLines.length > 0) {
          Column({ space: 0 }) {
            if (line.codeLang.length > 0) {
              Text(line.codeLang)
                .fontSize(this.fs(10))
                .fontColor(this.pal().text3)
                .width('100%')
                .padding({ left: 8, right: 8, top: 6 })
                .textAlign(TextAlign.Start)
            }
            Column({ space: 0 }) {
              ForEach(line.codeLines, (codeLine: string, ci: number) => {
                Text(codeLine.length > 0 ? codeLine : ' ')
                  .fontSize(this.fs(12))
                  .fontFamily('monospace')
                  .fontColor(this.pal().text2)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .copyOption(CopyOptions.LocalDevice)
              }, (codeLine: string, ci: number) => 'code:' + ci + ':' + codeLine)
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 8 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .backgroundColor(this.pal().inputBg)
          .borderRadius(8)
          .clip(true)
          .gesture(LongPressGesture().onAction(() => {
            const data: pasteboard.PasteData = pasteboard.createData(
              pasteboard.MIMETYPE_TEXT_PLAIN, line.codeLines.join(String.fromCharCode(10)));
            pasteboard.getSystemPasteboard().setData(data).then(() => {
              promptAction.showToast({ message: this.tr('已复制整段代码') });
            }).catch(() => undefined);
          }))
        } else if (line.bullet) {
          Row({ space: 6 }) {
            Text('·')
              .fontSize(this.fs(15))
              .fontColor(this.pal().text3)
            Text(line.text)
              .fontSize(this.fs(15))
              .fontColor(this.pal().text)
              .layoutWeight(1)
              .wordBreak(WordBreak.BREAK_ALL)
              .textAlign(TextAlign.Start)
          }
          .width('100%')
        } else if (line.linkUrl.length > 0) {
          Text(line.text)
            .fontSize(this.fs(15))
            .fontColor('#22D3EE')
            .decoration({ type: TextDecorationType.Underline, color: '#22D3EE' })
            .width('100%')
            .textAlign(TextAlign.Start)
            .onClick(() => {
              const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
              context.openLink(line.linkUrl).catch(() => {
                promptAction.showToast({ message: this.tr('无法打开链接') });
              });
            })
        } else {
          Text(line.text)
            .fontSize(line.heading ? 17 : 15)
            .fontWeight(line.heading ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(this.pal().text)
            .width('100%')
            .wordBreak(WordBreak.NORMAL)
            .textAlign(TextAlign.Start)
            .copyOption(CopyOptions.LocalDevice)
        }
      }, (line: MdLine, index: number) => index.toString() + ':' + this.imageVersion)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 手指按下/滑动：光斑跟到触点，并按 180ms 淡入。 */
  private trackDockLight(event: TouchEvent): void {
    const touches: TouchObject[] = event.touches;
    if (event.type === TouchType.Down || event.type === TouchType.Move) {
      if (touches.length === 0) {
        return;
      }
      this.dockLightX = touches[0].x;
      this.dockLightY = touches[0].y;
      this.fadeDockLight(true);
      return;
    }
    // 抬手或被父级手势打断时先留一帧，别一按就灭
    if (this.dockLightHideTimer >= 0) {
      clearTimeout(this.dockLightHideTimer);
    }
    this.dockLightHideTimer = setTimeout(() => {
      this.dockLightHideTimer = -1;
      this.fadeDockLight(false);
    }, 260);
  }

  /** 鼠标悬停也用同一套光斑，桌面/2in1 上鼠标划过就能看到。 */
  private trackDockMouse(event: MouseEvent): void {
    if (event.action === MouseAction.Move || event.action === MouseAction.Press) {
      this.dockLightX = event.x;
      this.dockLightY = event.y;
      this.fadeDockLight(true);
      return;
    }
    if (event.action === MouseAction.Release) {
      this.fadeDockLight(false);
    }
  }

  private fadeDockLight(visible: boolean): void {
    if (visible && this.dockLightHideTimer >= 0) {
      clearTimeout(this.dockLightHideTimer);
      this.dockLightHideTimer = -1;
    }
    const target: number = visible ? 1 : 0;
    if (this.dockLightOpacity === target) {
      return;
    }
    this.getUIContext().animateTo({
      duration: visible ? 160 : 260,
      curve: Curve.EaseOut
    }, () => {
      this.dockLightOpacity = target;
    });
  }

  /** 点开图片：全屏查看，双指缩放 / 拖动 / 双击复位。 */
  private openPreview(src: string): void {
    if (!isRemoteImage(src) && !this.images.has(src)) {
      // 慢链路下 300ms 定时器会落空，改成立即开、overlay 自己显示 loading
      this.loadMdImage(src);
    }
    this.previewSrc = src;
    this.previewScale = 1;
    this.previewOffsetX = 0;
    this.previewOffsetY = 0;
    this.previewActive = true;
  }

  /**
   * 把平移量夹在「放大后仍覆盖屏幕」的范围内。
   * 之前完全不夹：连续拖动会把图整张推出屏幕，看起来就像图丢了。
   */
  private previewClampOffset(): void {
    const maxX: number = Math.max(0, this.windowWidthVp * (this.previewScale - 1) / 2);
    const maxY: number = Math.max(0, this.windowHeightVp * (this.previewScale - 1) / 2);
    this.previewOffsetX = Math.min(maxX, Math.max(-maxX, this.previewOffsetX));
    this.previewOffsetY = Math.min(maxY, Math.max(-maxY, this.previewOffsetY));
  }

  private onPreviewPinchStart(): void {
    this.previewScaleStart = this.previewScale;
  }

  private onPreviewPinchUpdate(scale: number): void {
    this.previewScale = Math.min(6, Math.max(1, this.previewScaleStart * scale));
    this.previewClampOffset();
  }


  private onPreviewGestureEnd(): void {
    if (this.previewScale <= 1.02) {
      this.previewScale = 1;
      this.previewOffsetX = 0;
      this.previewOffsetY = 0;
      return;
    }
    this.previewClampOffset();
  }

  private onPreviewDoubleTap(): void {
    this.previewScale = this.previewScale > 1.05 ? 1 : 2.5;
    this.previewOffsetX = 0;
    this.previewOffsetY = 0;
  }

  /** 读一下 imageVersion，让预览层在图片解码完成后自动重建。 */
  private previewReady(): boolean {
    const version: number = this.imageVersion;
    return this.images.has(this.previewSrc);
  }

  @Builder
  ImagePreviewOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.92)')
        .onClick(() => {
          this.previewActive = false;
        })
      if (isRemoteImage(this.previewSrc)) {
        Image(this.previewSrc)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .scale({ x: this.previewScale, y: this.previewScale })
          .translate({ x: this.previewOffsetX, y: this.previewOffsetY })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PinchGesture({ fingers: 2 })
                .onActionStart(() => { this.onPreviewPinchStart(); })
                .onActionUpdate((event: GestureEvent) => { this.onPreviewPinchUpdate(event.scale); })
                .onActionEnd(() => { this.onPreviewGestureEnd(); }),
              // 这个 Pan 不读 offset（拖动走 onTouch 的屏幕坐标增量），只负责「认领」手势：
              // 否则单指拖动会被下面的会话列表当成滚动吃掉，预览层只收到 Cancel。
              PanGesture()
                .onActionStart(() => { this.previewPanStartX = this.previewOffsetX; this.previewPanStartY = this.previewOffsetY; })
                .onActionUpdate((event: GestureEvent) => {
                  // 放大越多，手指同样的位移走过的「图片内容」越少，手感就越拖沓。
                  // 用 1.5 倍作为基准（那个倍数下手感已确认舒服），往上按倍数放大拖动速度，
                  // 封顶 3 倍，避免高倍时过于灵敏。
                  const gain: number = Math.min(PREVIEW_PAN_MAX_GAIN,
                    Math.max(1, this.previewScale / PREVIEW_PAN_REFERENCE_SCALE));
                  this.previewOffsetX = this.previewPanStartX + event.offsetX * gain;
                  this.previewOffsetY = this.previewPanStartY + event.offsetY * gain;
                  this.previewClampOffset();
                })
                .onActionEnd(() => {
                  this.previewClampOffset();
                }),
              TapGesture({ count: 2 })
                .onAction(() => { this.onPreviewDoubleTap(); })
            )
          )
      } else if (this.previewReady()) {
        Image(this.images.pixel(this.previewSrc))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .scale({ x: this.previewScale, y: this.previewScale })
          .translate({ x: this.previewOffsetX, y: this.previewOffsetY })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PinchGesture({ fingers: 2 })
                .onActionStart(() => { this.onPreviewPinchStart(); })
                .onActionUpdate((event: GestureEvent) => { this.onPreviewPinchUpdate(event.scale); })
                .onActionEnd(() => { this.onPreviewGestureEnd(); }),
              // 这个 Pan 不读 offset（拖动走 onTouch 的屏幕坐标增量），只负责「认领」手势：
              // 否则单指拖动会被下面的会话列表当成滚动吃掉，预览层只收到 Cancel。
              PanGesture()
                .onActionStart(() => { this.previewPanStartX = this.previewOffsetX; this.previewPanStartY = this.previewOffsetY; })
                .onActionUpdate((event: GestureEvent) => {
                  // 放大越多，手指同样的位移走过的「图片内容」越少，手感就越拖沓。
                  // 用 1.5 倍作为基准（那个倍数下手感已确认舒服），往上按倍数放大拖动速度，
                  // 封顶 3 倍，避免高倍时过于灵敏。
                  const gain: number = Math.min(PREVIEW_PAN_MAX_GAIN,
                    Math.max(1, this.previewScale / PREVIEW_PAN_REFERENCE_SCALE));
                  this.previewOffsetX = this.previewPanStartX + event.offsetX * gain;
                  this.previewOffsetY = this.previewPanStartY + event.offsetY * gain;
                  this.previewClampOffset();
                })
                .onActionEnd(() => {
                  this.previewClampOffset();
                }),
              TapGesture({ count: 2 })
                .onAction(() => { this.onPreviewDoubleTap(); })
            )
          )
      }
      if (!isRemoteImage(this.previewSrc) && !this.previewReady()) {
        Column({ space: 10 }) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color('#22D3EE')
          Text(this.images.errorOf(this.previewSrc).length > 0
            ? this.tr('图片加载失败')
            : this.tr('图片加载中…'))
            .fontSize(this.fs(12))
            .fontColor('rgba(255,255,255,0.75)')
        }
        .hitTestBehavior(HitTestMode.None)
      }
      // 顶部：路径 + 关闭
      Row({ space: 10 }) {
        Text(this.previewSrc)
          .fontSize(this.fs(11))
          .fontColor('rgba(255,255,255,0.75)')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('关闭')
          .fontSize(this.fs(13))
          .fontColor('#FFFFFF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor('rgba(255,255,255,0.18)')
          .borderRadius(14)
          .onClick(() => {
            this.previewActive = false;
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14 })
      .position({ x: 0, y: this.topInset + 8 })
    }
    .width('100%')
    .height('100%')
  }

  /** 消息里的图片：远端链接直接交给 Image，主机本地路径走 workspaceFiles/readBytes。 */
  @Builder
  MdImage(line: MdLine) {
    Column({ space: 4 }) {
      if (isRemoteImage(line.imageSrc)) {
        Image(line.imageSrc)
          .width('100%')
          .constraintSize({ maxHeight: 420 })
          .objectFit(ImageFit.Contain)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            this.openPreview(line.imageSrc);
          })
      } else if (this.images.has(line.imageSrc)) {
        Image(this.images.pixel(line.imageSrc))
          .width('100%')
          .constraintSize({ maxHeight: 420 })
          .objectFit(ImageFit.Contain)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().border })
          .onClick(() => {
            this.openPreview(line.imageSrc);
          })
      } else if (this.images.errorOf(line.imageSrc).length > 0) {
        Row({ space: 8 }) {
          Text('🖼')
            .fontSize(13)
          Column({ space: 2 }) {
            Text(t('图片加载失败'))
              .fontSize(12)
              .fontColor(this.pal().text2)
            Text(line.imageSrc)
              .fontSize(10)
              .fontColor(this.pal().text3)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Text(t('重试'))
            .fontSize(11)
            .fontColor('#22D3EE')
            .onClick(() => {
              this.images.forget(line.imageSrc);
              this.loadMdImage(line.imageSrc);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 10, right: 10, top: 10, bottom: 10 })
        .backgroundColor(this.pal().chip)
        .borderRadius(10)
      } else {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color('#22D3EE')
          Text(t('图片加载中…'))
            .fontSize(11)
            .fontColor(this.pal().text3)
        }
        .width('100%')
        .padding(10)
        .backgroundColor(this.pal().chip)
        .borderRadius(10)
      }
      if (line.imageAlt.length > 0) {
        Text(line.imageAlt)
          .fontSize(10)
          .fontColor(this.pal().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onAppear(() => {
      this.loadMdImage(line.imageSrc);
    })
  }

  /** 懒加载：只对主机本地路径发请求，远端链接由 Image 自己拉。 */
  private loadMdImage(src: string): void {
    if (src.length === 0 || isRemoteImage(src)) {
      return;
    }
    if (this.images.has(src) || this.images.isPending(src)) {
      return;
    }
    // 失败过的不要自动重试：重建会再次触发 onAppear，失败图会变成死循环；重试走「重试」按钮。
    if (this.images.errorOf(src).length > 0) {
      return;
    }
    this.images.markPending(src);
    this.runtime.readImageBase64(src).then((base64: string) => {
      if (base64.length === 0) {
        throw new Error('empty');
      }
      return decodeBase64Image(base64);
    }).then((pixel: PixelMap) => {
      this.images.put(src, pixel);
      this.imageVersion = this.imageVersion + 1;
    }).catch((error: Error) => {
      logWarn('md image failed: ' + src + ' — ' + errorMessage(error));
      this.images.fail(src, errorMessage(error));
      this.imageVersion = this.imageVersion + 1;
    });
  }

  /** 会话行菜单：收藏 / 置顶 / 复制标题 / 复制为 Markdown / 归档或取消归档。 */
  private openSessionMenu(session: HarnessRemoteSession): void {
    ActionSheet.show({
    title: formatSessionTitle(session),
    message: session.cwd.length > 0 ? session.cwd : session.sessionId,
    sheets: [
      {
        title: this.runtime.isFavoriteSession(session.sessionId) ? this.tr('取消收藏') : this.tr('收藏'),
        action: () => {
          this.runtime.toggleFavoriteSession(session.sessionId);
        }
      },
      {
        title: this.isPinnedSession(session.sessionId)
          ? this.tr('取消置顶') : this.tr('置顶'),
        action: () => {
          this.runtime.togglePinSession(session.sessionId);
        }
      },
      {
        title: this.tr('复制标题'),
        action: () => {
          const data: pasteboard.PasteData = pasteboard.createData(
            pasteboard.MIMETYPE_TEXT_PLAIN, formatSessionTitle(session));
          pasteboard.getSystemPasteboard().setData(data).then(() => {
            promptAction.showToast({ message: this.tr('已复制标题') });
          }).catch(() => undefined);
        }
      },
      {
        title: this.tr('复制为 Markdown'),
        action: () => {
          this.closeDrawer();
          this.runtime.sessionMarkdownFor(session.sessionId).then((markdown: string) => {
            if (markdown.length === 0) {
              promptAction.showToast({ message: this.tr('这张会话还没有内容') });
              return;
            }
            const data: pasteboard.PasteData = pasteboard.createData(
              pasteboard.MIMETYPE_TEXT_PLAIN, markdown);
            pasteboard.getSystemPasteboard().setData(data).then(() => {
              promptAction.showToast({ message: this.tr('会话 Markdown 已复制') });
            }).catch(() => {
              promptAction.showToast({ message: this.tr('复制失败') });
            });
          }).catch(() => {
            promptAction.showToast({ message: this.tr('导出失败') });
          });
        }
      },
      {
        title: this.isArchivedSession(session.sessionId)
          ? this.tr('取消归档') : this.tr('归档会话'),
        action: () => {
          if (this.isArchivedSession(session.sessionId)) {
            this.runtime.unarchiveSession(session.sessionId);
          } else {
            this.runtime.archiveSession(session.sessionId);
          }
        }
      }
    ]
    });
  }

  /** PC 鼠标悬停时贴在气泡下方的快捷操作（复制 / 引用 / 分叉）。 */
  @Builder
  MessageQuickActions(item: ChatItem, alignEnd: boolean) {
    Row({ space: 6 }) {
      Text(this.tr('复制'))
        .fontSize(this.fs(10))
        .fontColor(this.pal().text3)
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
        .backgroundColor(this.pal().chip)
        .borderRadius(7)
        .onClick(() => {
          const data: pasteboard.PasteData = pasteboard.createData(
            pasteboard.MIMETYPE_TEXT_PLAIN, item.text);
          pasteboard.getSystemPasteboard().setData(data).then(() => {
            promptAction.showToast({ message: this.tr('已复制') });
          }).catch(() => undefined);
        })
      if (item.text.length > 0) {
        Text(this.tr('引用'))
          .fontSize(this.fs(10))
          .fontColor(this.pal().text3)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.pal().chip)
          .borderRadius(7)
          .onClick(() => {
            const quoted: string = item.text.split('\n')
              .map((line: string) => '> ' + line).join('\n') + '\n\n';
            this.promptInput = quoted + this.promptInput;
            this.runtime.saveDraft(this.currentSessionId, this.promptInput);
            promptAction.showToast({ message: this.tr('已引用到输入框') });
          })
      }
      if (item.text.length > 0) {
        Text(this.tr('分享'))
          .fontSize(this.fs(10))
          .fontColor(this.pal().text3)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.pal().chip)
          .borderRadius(7)
          .onClick(() => {
            this.shareText(this.runtime.shareCardText(item));
          })
      }
      if (item.seq > 0 && this.runtime.currentSessionId.length > 0) {
        Text(this.tr('分叉'))
          .fontSize(this.fs(10))
          .fontColor(this.pal().text3)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(this.pal().chip)
          .borderRadius(7)
          .onClick(() => {
            this.runtime.forkCurrentSession(item.seq);
          })
      }
    }
    .width('100%')
    .justifyContent(alignEnd ? FlexAlign.End : FlexAlign.Start)
    .padding({ top: 2 })
  }

  /** 长按消息：复制正文 / 从这里分叉（分叉不再占用长按默认动作）。 */
  private offerMessageActions(item: ChatItem): void {
    this.messageActionText = item.text.length > 0 ? item.text : item.summary;
    this.messageActionKind = item.kind;
    this.messageActionSeq = item.seq;
    this.messageActionTime = item.timestamp;
    this.messageActionCode = extractCodeBlocks(item.text);
    // 用渲染层那一份（已按「长度+前 64 字符」去重）：item.images 里可能同时有本地预览
    // 和主机附件两份同一张图，直接拿来当待发送会变成两张。
    this.messageActionImages = this.messageImages(item);
    this.messageActionsOpen = true;
  }

  /** 点开一个文件：PDF 交给系统 PDF Kit，其它按文本预览。 */
  private openFilePreview(path: string): void {
    const lower: string = path.toLowerCase();
    const isPdf: boolean = lower.endsWith('.pdf');
    this.previewIsPdf = isPdf;
    this.pdfError = '';
    if (!isPdf) {
      this.runtime.previewFile(path);
      return;
    }
    this.runtime.filePreviewPath = path;
    this.runtime.filePreviewLoading = true;
    this.runtime.filePreviewError = '';
    this.runtime.notify();
    this.runtime.readFileBuffer(path).then((buffer: ArrayBuffer) => {
      this.pdfController.loadDocumentFromMemory(buffer).then(() => {
        this.runtime.filePreviewLoading = false;
        this.runtime.notify();
      }).catch((error: Error) => {
        this.pdfError = error.message;
        this.runtime.filePreviewLoading = false;
        this.runtime.notify();
      });
    }).catch((error: Error) => {
      this.pdfError = error.message;
      this.runtime.filePreviewLoading = false;
      this.runtime.notify();
    });
  }

  private copyActionText(): void {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.messageActionText);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: this.tr('已复制') });
    }).catch(() => {
      promptAction.showToast({ message: this.tr('复制失败') });
    });
  }

  @Builder
  AssistantRow(item: ChatItem) {
    Row() {
      // A definite-width inner row gives the bubble a hard wrap budget; the inner
      // Texts carry no percentage width so they can never stretch past the card.
      Row() {
        Column({ space: 6 }) {
          if (item.reasoning.length > 0) {
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                Text(this.tr('思考'))
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
                Text(this.reasoningOpen(item) ? this.tr('收起') : this.tr('展开'))
                  .fontSize(this.fs(10))
                  .fontColor('#22D3EE')
              }
              .onClick(() => {
                this.toggleReasoning(item);
              })
              Text(item.reasoning)
                .fontSize(this.fs(12))
                .fontColor(this.pal().text2)
                .maxLines(this.reasoningOpen(item) ? 400 : 2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .backgroundColor(this.pal().chip)
            .borderRadius(8)
            .alignItems(HorizontalAlign.Start)
          }
          if (item.text.length > 0 && this.heartbeatBody(item).length > 0) {
            // 巡检心跳：默认只显示可读正文，标签原文折叠起来
            this.MarkdownText(this.heartbeatOpen(item) ? item.text : this.heartbeatBody(item),
              item.streaming)
            Text(this.heartbeatOpen(item) ? this.tr('收起巡检原文') : this.tr('查看巡检原文'))
              .fontSize(this.fs(11))
              .fontColor('#22D3EE')
              .padding({ top: 2, bottom: 2 })
              .onClick(() => {
                this.toggleHeartbeat(item);
              })
          } else if (item.text.length > 0) {
            // 敏感内容（Key/Token）默认打码，点一下看原文
            if (this.showsMaskedHint(item)) {
              Text(this.tr('已遮挡敏感内容 · 点此看原文'))
                .fontSize(this.fs(10))
                .fontColor('#22D3EE')
                .padding({ top: 2, bottom: 2 })
                .onClick(() => {
                  this.revealedSecrets = this.revealedSecrets.concat([item.id]);
                })
            }
            // 长回复先折叠到 18 行，避免一条消息把整屏占满
            if (this.isLongCollapsed(item)) {
              this.MarkdownText(this.collapseText(this.bubbleText(item)), item.streaming)
              Text(this.tr('展开全文') + ' · ' + this.textLineCount(item.text) + this.tr(' 行'))
                .fontSize(this.fs(11))
                .fontColor('#22D3EE')
                .padding({ top: 2, bottom: 2 })
                .onClick(() => {
                  this.expandedMessages = this.expandedMessages.concat([item.id]);
                })
            } else {
              this.MarkdownText(this.bubbleText(item), item.streaming)
            }
          }
          if (item.timestamp > 0) {
            Row({ space: 8 }) {
              Text(formatClock(item.timestamp))
                .fontSize(this.fs(10))
                .fontColor(this.pal().text3)
              // 复制回复：不只在长按菜单里，正文下方直接给一个（手机上尤其有用）
              if (item.text.length > 0 && !item.streaming) {
                Text(this.tr('复制回复'))
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .backgroundColor(this.pal().chip)
                  .borderRadius(6)
                  .onClick(() => {
                    const data: pasteboard.PasteData = pasteboard.createData(
                      pasteboard.MIMETYPE_TEXT_PLAIN, item.text);
                    pasteboard.getSystemPasteboard().setData(data).then(() => {
                      promptAction.showToast({ message: this.tr('已复制回复') });
                    }).catch(() => undefined);
                  })
              }
            }
          }
          if (item.streaming && item.text.length === 0 && item.reasoning.length === 0) {
            Row({ space: 8 }) {
              LoadingProgress()
                .width(14)
                .height(14)
                .color('#22D3EE')
              Text('正在思考…')
                .fontSize(this.fs(12))
                .fontColor(this.pal().text2)
            }
          }
        }
        .padding({ top: 10, bottom: 10, left: 14, right: 14 })
        .backgroundColor(this.pal().inputBg)
        .borderRadius(16)
        .alignItems(HorizontalAlign.Start)
        .gesture(LongPressGesture().onAction(() => {
          this.offerMessageActions(item);
        }))
        .onMouse((event: MouseEvent) => {
          if (event.action === MouseAction.Press && event.button === MouseButton.Right) {
            this.offerMessageActions(item);
          }
        })
        .onHover((isHover: boolean) => {
          this.hoverMessageId = isHover ? item.id : '';
        })
      }
      .width('88%')
      .constraintSize({ maxWidth: 780 })
      .justifyContent(FlexAlign.Start)
      if (this.hoverMessageId === item.id) {
        this.MessageQuickActions(item, false)
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
  }

  /** 消息操作：底部面板，带原文预览和图标行，替代黑白的系统 ActionSheet。 */
  @Builder
  MessageActionRow(icon: string, label: string, danger: boolean, action: () => void) {
    Row({ space: 12 }) {
      Text(icon)
        .fontSize(this.fs(14))
        .width(22)
        .textAlign(TextAlign.Center)
        .fontColor(danger ? '#F85749' : '#22D3EE')
      Text(label)
        .fontSize(this.fs(14))
        .fontColor(danger ? '#F85749' : this.pal().text)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
    .backgroundColor(this.pal().card)
    .borderRadius(12)
    .border({ width: 1, color: danger ? 'rgba(248,87,73,0.35)' : this.pal().border })
    .onClick(() => {
      action();
    })
  }

  @Builder
  MessageActionsOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.messageActionsOpen = false;
        })
      Column({ space: 8 }) {
        Row() {
          Column({ space: 1 }) {
            Text(this.tr('消息操作'))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text)
            Text((this.messageActionKind === 'user' ? this.tr('你发送的消息') : this.tr('助手回复'))
              + (this.messageActionTime > 0 ? '  ·  ' + formatClock(this.messageActionTime) : ''))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.messageActionsOpen = false;
            })
        }
        .width('100%')

        // 原文预览：两行就够，让人确认点的是哪条
        if (this.messageActionText.length > 0) {
          Text(this.messageActionText)
            .fontSize(this.fs(12))
            .fontColor(this.pal().text2)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(this.pal().inputBg)
            .borderRadius(12)
            .border({ width: { left: 3 }, color: 'rgba(34,211,238,0.55)' })
        }

        this.MessageActionRow('⧉', this.tr('复制文本'), false, () => {
          this.copyActionText();
          this.messageActionsOpen = false;
        })
        if (this.messageActionCode.length > 0) {
          this.MessageActionRow('{}', this.tr('复制代码块'), false, () => {
            const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.messageActionCode);
            pasteboard.getSystemPasteboard().setData(data).then(() => {
              promptAction.showToast({ message: this.tr('已复制代码') });
            }).catch(() => undefined);
            this.messageActionsOpen = false;
          })
        }
        if (this.messageActionImages.length > 0) {
          this.MessageActionRow('🖼', this.tr('图片加入待发送'), false, () => {
            const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
            const bodies: string[] = this.messageActionImages.slice();
            this.messageActionsOpen = false;
            const tasks: Promise<PickedImage | undefined>[] = [];
            for (const body of bodies) {
              tasks.push(pickedImageFromBase64(body, context.filesDir));
            }
            Promise.all(tasks).then((list: Array<PickedImage | undefined>) => {
              const accepted: PickedImage[] = [];
              for (const one of list) {
                if (one !== undefined) {
                  accepted.push(one);
                }
              }
              if (accepted.length === 0) {
                promptAction.showToast({ message: this.tr('这张图读不出来') });
                return;
              }
              this.pendingImages = this.pendingImages.concat(accepted);
              promptAction.showToast({ message: this.tr('图片已加入待发送') });
            }).catch(() => undefined);
          })
        }
        this.MessageActionRow('❝', this.tr('引用到输入框'), false, () => {
          const quoted: string = this.messageActionText.split('\n')
            .map((line: string) => '> ' + line).join('\n') + '\n\n';
          this.promptInput = quoted + this.promptInput;
          this.runtime.saveDraft(this.currentSessionId, this.promptInput);
          this.messageActionsOpen = false;
        })
        if (this.messageActionSeq > 0 && this.runtime.currentSessionId.length > 0) {
          this.MessageActionRow('⑂', this.tr('从这里分叉'), false, () => {
            this.runtime.forkCurrentSession(this.messageActionSeq);
            this.messageActionsOpen = false;
          })
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 360 })
      .padding({ left: 14, right: 14, top: 12, bottom: 16 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 300 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 文本文件预览：主机上读回来直接显示，二进制给提示。 */
  @Builder
  FilePreviewOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.filePreviewOpen = false;
        })
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Column({ space: 2 }) {
            Text(this.runtime.filePreviewPath.substring(this.runtime.filePreviewPath.lastIndexOf('/') + 1))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.pal().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.runtime.filePreviewPath)
              .fontSize(this.fs(10))
              .fontColor(this.pal().text3)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (this.previewIsPdf && this.pdfError.length === 0) {
            Text(this.pdfFullscreen ? this.tr('还原') : this.tr('全屏'))
              .fontSize(this.fs(12))
              .fontColor('#22D3EE')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor('rgba(34,211,238,0.10)')
              .borderRadius(9)
              .onClick(() => {
                this.pdfFullscreen = !this.pdfFullscreen;
              })
          }
          Text('关闭')
            .fontSize(this.fs(12))
            .fontColor(this.pal().text3)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(this.pal().chip)
            .borderRadius(9)
            .onClick(() => {
              this.filePreviewOpen = false;
            })
        }
        .width('100%')

        if (this.runtime.filePreviewLoading) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color('#22D3EE')
            Text(this.tr('读取中…'))
              .fontSize(this.fs(12))
              .fontColor(this.pal().text2)
          }
          .padding({ top: 12, bottom: 12 })
        } else if (this.previewIsPdf && this.pdfError.length === 0) {
          PdfView({
            controller: this.pdfController,
            pageLayout: pdfService.PageLayout.LAYOUT_SINGLE,
            isContinuous: true,
            showScroll: true,
            pageFit: pdfService.PageFit.FIT_WIDTH
          })
            .width('100%')
            .height(this.pdfFullscreen
              ? '100%'
              : (this.windowHeightVp > 0 ? this.windowHeightVp * 0.62 : 420))
            .borderRadius(this.pdfFullscreen ? 0 : 12)
        } else if (this.previewIsPdf && this.pdfError.length > 0) {
          Text(this.tr('PDF 打开失败：') + this.pdfError)
            .fontSize(this.fs(12))
            .fontColor('#F85749')
            .padding({ top: 12, bottom: 12 })
        } else if (this.runtime.filePreviewError.length > 0) {
          Text(this.runtime.filePreviewError)
            .fontSize(this.fs(12))
            .fontColor('#F85749')
            .padding({ top: 12, bottom: 12 })
        } else {
          Scroll() {
            Text(this.runtime.filePreviewText)
              .fontSize(this.fs(11))
              .fontColor(this.pal().text)
              .fontFamily('monospace')
              .width('100%')
              .textAlign(TextAlign.Start)
              .copyOption(CopyOptions.LocalDevice)
          }
          .width('100%')
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.62 : 420 })
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 620 })
      .padding({ left: 16, right: 16, top: 14, bottom: 20 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
    }
    .width('100%')
    .height('100%')
  }

  /** 主机详情：把 server 上报的字段摊开，指纹/ID 可以一键复制。 */
  @Builder
  DeviceDetailOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.deviceDetailId = '';
        })
      Column({ space: 10 }) {
        Row() {
          Column({ space: 2 }) {
            Text(this.deviceDetailName())
              .fontSize(this.fs(16))
              .fontWeight(FontWeight.Bold)
              .fontColor(this.pal().text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.deviceDetailOnlineLabel())
              .fontSize(this.fs(11))
              .fontColor(this.deviceDetailOnline() ? '#34D399' : this.pal().text3)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('✕')
            .fontSize(this.fs(15))
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.deviceDetailId = '';
            })
        }
        .width('100%')

        this.DetailRow(this.tr('平台'), this.deviceDetailField('platform'))
        this.DetailRow(this.tr('主机版本'), this.deviceDetailField('harnessVersion'))
        this.DetailRow(this.tr('客户端版本'), this.deviceDetailField('clientVersion'))
        this.DetailRow(this.tr('最后在线'), this.deviceDetailLastSeen())
        this.DetailRow(this.tr('设备 ID'), this.deviceDetailId)
        this.DetailRow(this.tr('公钥指纹'), this.deviceDetailFingerprint())

        Text(this.tr('复制全部'))
          .fontSize(this.fs(13))
          .fontColor('#FFFFFF')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 12, bottom: 12 })
          .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
          .borderRadius(12)
          .onClick(() => {
            this.copyDeviceDetail();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 320 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 220, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  DetailRow(label: string, value: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(this.fs(11))
        .fontColor(this.pal().text3)
        .width(76)
      Text(value.length > 0 ? value : '—')
        .fontSize(this.fs(12))
        .fontColor(this.pal().text2)
        .fontFamily('monospace')
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.pal().inputBg)
    .borderRadius(10)
  }

  /** 新建工作区：主机侧只认绝对路径，名称留空就用路径末段。 */
  /** 定时任务：列表 / 投递历史 / 删除；创建走会话里的官方 schedule_create 工具。 */
  @Builder
  SchedulesOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(8,12,24,0.55)')
        .onClick(() => {
          this.schedulesOpen = false;
        })
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.tr('定时任务'))
            .fontSize(this.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          if (this.runtime.schedulesLoading) {
            LoadingProgress()
              .width(14)
              .height(14)
              .color('#22D3EE')
          }
          Blank()
          Text(this.tr('刷新'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.runtime.loadSchedules();
            })
          Text(this.tr('收起'))
            .fontSize(this.fs(13))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.schedulesOpen = false;
            })
        }
        .width('100%')
        Scroll() {
          Column({ space: 8 }) {
            if (!this.runtime.schedulesSupported) {
              Text(this.tr('这台主机没有开启定时任务'))
                .fontSize(this.fs(13))
                .fontColor(this.pal().text2)
                .width('100%')
                .textAlign(TextAlign.Start)
              Text(this.tr('Host 侧的 Remote 插件没有导出 schedule/* 端点，升级插件后这里会自动出现列表。'))
                .fontSize(this.fs(11))
                .fontColor(this.pal().text3)
                .width('100%')
                .textAlign(TextAlign.Start)
            } else if (this.runtime.schedules.length === 0) {
              Text(this.tr('还没有定时任务'))
                .fontSize(this.fs(13))
                .fontColor(this.pal().text2)
                .width('100%')
                .textAlign(TextAlign.Start)
              Text(this.tr('新建要在会话里说一句，由主机上的 agent 用 schedule_create 工具创建（协议不开放客户端直接创建）。'))
                .fontSize(this.fs(11))
                .fontColor(this.pal().text3)
                .width('100%')
                .textAlign(TextAlign.Start)
              Text(this.tr('填入示例：每天 9 点跑一次巡检，结果发到这个会话'))
                .fontSize(this.fs(12))
                .fontColor('#22D3EE')
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .backgroundColor('rgba(34,211,238,0.10)')
                .borderRadius(10)
                .onClick(() => {
                  this.promptInput = this.tr('每天 9 点跑一次巡检，结果发到这个会话');
                  this.runtime.saveDraft(this.currentSessionId, this.promptInput);
                  this.schedulesOpen = false;
                  promptAction.showToast({ message: this.tr('已填入输入框，发送即可让 agent 创建') });
                })
            }
            ForEach(this.runtime.schedules, (schedule: HarnessSchedule) => {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Text(schedule.title.length > 0 ? schedule.title : schedule.id)
                    .fontSize(this.fs(13))
                    .fontColor(this.pal().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (schedule.inactive) {
                    Text(this.tr('已停用'))
                      .fontSize(this.fs(10))
                      .fontColor(this.pal().text3)
                      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      .backgroundColor(this.pal().inputBg)
                      .borderRadius(5)
                  }
                }
                .width('100%')
                Text(this.scheduleSummary(schedule))
                  .fontSize(this.fs(11))
                  .fontColor(this.pal().text2)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                Row({ space: 8 }) {
                  Text(this.tr('历史'))
                    .fontSize(this.fs(11))
                    .fontColor('#22D3EE')
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .onClick(() => {
                      this.runtime.loadScheduleHistory(schedule);
                    })
                  Text(this.tr('删除'))
                    .fontSize(this.fs(11))
                    .fontColor('#F85749')
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .onClick(() => {
                      this.runtime.deleteSchedule(schedule);
                    })
                  Blank()
                }
                .width('100%')
                if (this.runtime.scheduleHistoryId === schedule.id
                  && this.runtime.scheduleHistory.length > 0) {
                  Column({ space: 2 }) {
                    ForEach(this.runtime.scheduleHistory, (delivery: HarnessScheduleDelivery) => {
                      Text(formatSessionTime(delivery.deliveredAt) + ' · '
                        + (delivery.status.length > 0 ? delivery.status : '投递'))
                        .fontSize(this.fs(10))
                        .fontColor(this.pal().text3)
                        .width('100%')
                        .textAlign(TextAlign.Start)
                    }, (delivery: HarnessScheduleDelivery) => delivery.id + delivery.deliveredAt)
                  }
                  .width('100%')
                }
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.pal().inputBg)
              .borderRadius(12)
              .border({ width: 1, color: this.pal().border })
              .alignItems(HorizontalAlign.Start)
            }, (schedule: HarnessSchedule) => schedule.id + schedule.inactive)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('66%')
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 340 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 一条定时任务的一行摘要：类型 + 下次时间 + 上次投递。 */
  private scheduleSummary(schedule: HarnessSchedule): string {
    const parts: string[] = [];
    parts.push(schedule.kind.length > 0 ? schedule.kind : '定时');
    if (schedule.expression.length > 0) {
      parts.push(schedule.expression);
    }
    if (schedule.scheduledAt > 0) {
      parts.push(this.tr('下次 ') + formatSessionTime(schedule.scheduledAt));
    }
    if (schedule.lastDeliveredAt > 0) {
      parts.push(this.tr('上次 ') + formatSessionTime(schedule.lastDeliveredAt));
    }
    return parts.join(' · ');
  }

  /** 主题色选择：5 套氛围色，点一下立即生效。 */
  @Builder
  TintPickerOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(8,12,24,0.45)')
        .onClick(() => {
          this.tintPickerOpen = false;
        })
      Column({ space: 6 }) {
        Row() {
          Text(this.tr('主题色'))
            .fontSize(this.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Blank()
          Text(this.tr('收起'))
            .fontSize(this.fs(13))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.tintPickerOpen = false;
            })
        }
        .width('100%')
        ForEach([0, 1, 2, 3, 4], (tint: number) => {
          Row({ space: 10 }) {
            Text(this.tintName(tint))
              .fontSize(this.fs(14))
              .fontColor(this.pal().text)
            Blank()
            if (this.uiThemeTint === tint) {
              Text('✓')
                .fontSize(this.fs(14))
                .fontColor('#22D3EE')
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(this.uiThemeTint === tint ? this.pal().inputBg : Color.Transparent)
          .borderRadius(12)
          .onClick(() => {
            this.tapHaptic();
            this.uiThemeTint = tint;
            this.runtime.setThemeTint(tint);
          })
        }, (tint: number) => 'tint-' + tint)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 280 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  private tintName(tint: number): string {
    if (tint === 1) {
      return this.tr('深海');
    }
    if (tint === 2) {
      return this.tr('森林');
    }
    if (tint === 3) {
      return this.tr('暖沙');
    }
    if (tint === 4) {
      return this.tr('玫紫');
    }
    return this.tr('默认');
  }

  /** 连接详情：传输路径 / 握手耗时 / 测延迟 / 回落原因（点顶栏传输徽标打开）。 */
  @Builder
  LinkDetailOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(8,12,24,0.45)')
        .onClick(() => {
          this.linkDetailOpen = false;
        })
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.tr('连接详情'))
            .fontSize(this.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Blank()
          Text(this.runtime.latencyTesting ? this.tr('测量中…') : this.tr('测延迟'))
            .fontSize(this.fs(12))
            .fontColor(this.runtime.latencyTesting ? this.pal().text3 : '#22D3EE')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              if (!this.runtime.latencyTesting) {
                this.runtime.measureLatency();
              }
            })
          Text(this.tr('收起'))
            .fontSize(this.fs(13))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.linkDetailOpen = false;
            })
        }
        .width('100%')
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.runtime.connectionDetailLines(), (line: string) => {
              Text(line)
                .fontSize(this.fs(12))
                .fontColor(this.pal().text2)
                .width('100%')
                .textAlign(TextAlign.Start)
            }, (line: string) => line)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .constraintSize({ maxHeight: '56%' })
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 320 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 单个插件的设置：布尔点一下即存，其余用一行输入框编辑后保存。 */
  @Builder
  PluginFormOverlay() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.pluginFormTitle)
          .fontSize(this.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.tr('收起'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .onClick(() => {
            this.pluginFormOpen = false;
          })
      }
      .width('100%')

      List({ space: 8 }) {
        ForEach(this.pluginFormFields, (field: PluginSettingField) => {
          ListItem() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Text(field.key)
                  .fontSize(this.fs(12))
                  .fontColor(this.pal().text)
                  .layoutWeight(1)
                Text(field.value)
                  .fontSize(this.fs(11))
                  .fontColor(this.pal().text3)
                  .maxLines(1)
                  .constraintSize({ maxWidth: 180 })
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .onClick(() => {
                if (field.kind === 'boolean') {
                  this.savePluginField(field, field.value === 'true' ? 'false' : 'true');
                  return;
                }
                this.pluginFormEditing = field.key;
                this.pluginFormDraft = field.value;
              })
              if (field.description.length > 0) {
                Text(field.description)
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
                  .maxLines(2)
              }
              if (this.pluginFormEditing === field.key) {
                Row({ space: 8 }) {
                  TextInput({ text: this.pluginFormDraft, placeholder: this.tr('新值') })
                    .layoutWeight(1)
                    .height(36)
                    .fontSize(this.fs(12))
                    .backgroundColor(this.pal().inputBg)
                    .fontColor(this.pal().text)
                    .borderRadius(8)
                    .padding({ left: 10, right: 10 })
                    .onChange((value: string) => {
                      this.pluginFormDraft = value;
                    })
                  Text(this.tr('保存'))
                    .fontSize(this.fs(12))
                    .fontColor('#22D3EE')
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .onClick(() => {
                      this.savePluginField(field, this.pluginFormDraft);
                    })
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(10)
            .backgroundColor(this.pal().card)
            .borderRadius(10)
            .border({ width: 1, color: this.pal().border })
            .alignItems(HorizontalAlign.Start)
          }
        }, (field: PluginSettingField) => 'field:' + field.key + ':' + this.pluginFormEditing + ':' + field.value)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 18 })
    .backgroundColor(this.pal().bg)
  }

  /** DS-Bot 目录：机器人/群组列表，只读。 */
  @Builder
  BotsOverlay() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.tr('DS-Bot'))
          .fontSize(this.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
        Blank()
        Text(this.tr('刷新'))
          .fontSize(this.fs(12))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.openBotsOverlay();
          })
        Text(this.tr('收起'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.botsOpen = false;
          })
      }
      .width('100%')

      if (this.botsLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color('#22D3EE')
          Text(this.tr('读取 DS-Bot…')).fontSize(this.fs(12)).fontColor(this.pal().text3)
        }
      } else if (this.botsError.length > 0) {
        Text(this.botsError)
          .fontSize(this.fs(12))
          .fontColor('#F5A623')
          .width('100%')
      } else if (this.bots.length === 0) {
        Text(this.tr('暂无机器人或群组'))
          .fontSize(this.fs(12))
          .fontColor(this.pal().text3)
      } else {
        List({ space: 8 }) {
          ForEach(this.bots, (bot: BotCatalogRow) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(bot.room ? '群' : '机')
                  .fontSize(this.fs(10))
                  .fontColor('#22D3EE')
                  .width(22)
                  .height(22)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('rgba(34,211,238,0.12)')
                  .borderRadius(6)
                Column({ space: 2 }) {
                  Text(bot.name)
                    .fontSize(this.fs(13))
                    .fontColor(this.pal().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(bot.room
                    ? ('' + bot.memberIds.length + ' ' + this.tr('个成员'))
                    : (bot.role.length > 0 ? bot.role : this.tr('机器人')) + (bot.model.length > 0 ? ' · ' + bot.model : ''))
                    .fontSize(this.fs(10))
                    .fontColor(this.pal().text3)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                if (bot.pinned) {
                  Text(this.tr('置顶'))
                    .fontSize(this.fs(9))
                    .fontColor('#4D6BFE')
                }
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.pal().card)
              .borderRadius(10)
              .border({ width: 1, color: this.pal().border })
            }
          }, (bot: BotCatalogRow) => 'bot:' + bot.id)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 18 })
    .backgroundColor(this.pal().bg)
  }

  /** Git 审查：左边改动清单（可勾选），右边/下方看单个文件 diff。 */
  @Builder
  GitOverlay() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.tr('Git 审查'))
          .fontSize(this.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
        if (this.gitBranch.length > 0) {
          Text(this.gitBranch)
            .fontSize(this.fs(10))
            .fontColor(this.pal().text3)
        }
        Blank()
        Text(this.tr('刷新'))
          .fontSize(this.fs(12))
          .fontColor('#22D3EE')
          .onClick(() => {
            this.openGitOverlay();
          })
        Text(this.tr('收起'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.gitOpen = false;
          })
      }
      .width('100%')

      if (this.gitLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color('#22D3EE')
          Text(this.tr('读取工作区改动…')).fontSize(this.fs(12)).fontColor(this.pal().text3)
        }
      } else if (this.gitError.length > 0) {
        Text(this.gitError)
          .fontSize(this.fs(12))
          .fontColor('#F5A623')
          .width('100%')
      } else if (this.gitFiles.length === 0) {
        Text(this.tr('工作区没有未提交的改动'))
          .fontSize(this.fs(12))
          .fontColor(this.pal().text3)
      } else {
        Row({ space: 8 }) {
          Text(this.gitSummary)
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.gitSelected.length > 0) {
            Text(this.tr('回传') + ' ' + this.gitSelected.length)
              .fontSize(this.fs(11))
              .fontColor('#22D3EE')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor('rgba(34,211,238,0.12)')
              .borderRadius(8)
              .onClick(() => {
                this.sendGitSelection();
              })
          }
        }
        .width('100%')

        List({ space: 6 }) {
          ForEach(this.gitFiles, (file: WorkspaceGitFile) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(this.gitSelected.includes(file.path) ? '☑' : '☐')
                  .fontSize(this.fs(12))
                  .fontColor(this.gitSelected.includes(file.path) ? '#22D3EE' : this.pal().text3)
                  .onClick(() => {
                    this.toggleGitFile(file.path);
                  })
                Text(file.status.length > 0 ? file.status : 'M')
                  .fontSize(this.fs(10))
                  .fontColor(file.status === 'D' ? '#F85749' : (file.status === 'A' ? '#34D399' : '#F0A020'))
                  .width(14)
                Text(file.path)
                  .fontSize(this.fs(12))
                  .fontColor(this.pal().text2)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .onClick(() => {
                    this.openGitDiff(file.path);
                  })
                Text('+' + file.additions + ' −' + file.deletions)
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
              }
              .width('100%')
              .padding({ left: 8, right: 8, top: 7, bottom: 7 })
              .backgroundColor(this.gitDiffPath === file.path ? this.pal().inputBg : this.pal().card)
              .borderRadius(8)
              .border({ width: 1, color: this.gitDiffPath === file.path
                ? 'rgba(34,211,238,0.45)' : this.pal().border })
              .onClick(() => {
                this.openGitDiff(file.path);
              })
            }
          }, (file: WorkspaceGitFile) => 'git:' + file.path + ':' + file.status
            + ':' + this.gitSelected.includes(file.path))
        }
        .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.32 : 240 })
        .width('100%')
        .scrollBar(BarState.Off)

        if (this.gitDiffPath.length > 0) {
          Text(this.gitDiffPath)
            .fontSize(this.fs(10))
            .fontColor(this.pal().text3)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.gitDiffError.length > 0) {
            Text(this.gitDiffError)
              .fontSize(this.fs(11))
              .fontColor('#F85749')
          } else {
            Scroll() {
              Text(this.gitDiffText)
                .fontSize(this.fs(10))
                .fontFamily('monospace')
                .fontColor(this.pal().text2)
                .width('100%')
                .textAlign(TextAlign.Start)
                .copyOption(CopyOptions.LocalDevice)
            }
            .layoutWeight(1)
            .width('100%')
            .align(Alignment.TopStart)
            .backgroundColor(this.pal().inputBg)
            .borderRadius(8)
            .padding(8)
          }
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 18 })
    .backgroundColor(this.pal().bg)
  }

  /** 顶栏主机名点开的主机切换面板：直接连另一台，不用退回设备页。 */
  @Builder
  HostSwitcherOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.hostSwitcherOpen = false;
        })
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Text(this.tr('切换主机'))
            .fontSize(this.fs(15))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Blank()
          Text(this.tr('收起'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .onClick(() => {
              this.hostSwitcherOpen = false;
            })
        }
        .width('100%')
        if (this.runtime.devices.length === 0) {
          Text(this.tr('还没有主机，先回上一页刷新'))
            .fontSize(this.fs(12))
            .fontColor(this.pal().text3)
            .width('100%')
            .padding({ top: 10, bottom: 10 })
        } else {
          List({ space: 8 }) {
            ForEach(this.runtime.devices, (device: RemoteHostDevice) => {
              ListItem() {
                Row({ space: 10 }) {
                  Column()
                    .width(6)
                    .height(6)
                    .borderRadius(3)
                    .backgroundColor(device.online ? '#34D399' : this.pal().text3)
                  Column({ space: 2 }) {
                    Text(this.displayNameFor(device).length > 0 ? this.displayNameFor(device) : device.deviceId)
                      .fontSize(this.fs(13))
                      .fontColor(this.pal().text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.hostSubtitle(device))
                      .fontSize(this.fs(10))
                      .fontColor(this.pal().text3)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  if (device.deviceId === this.runtime.connectedDeviceId) {
                    Text(this.tr('当前'))
                      .fontSize(this.fs(10))
                      .fontColor('#22D3EE')
                  }
                }
                .width('100%')
                .padding(10)
                .backgroundColor(this.pal().card)
                .borderRadius(10)
                .border({ width: 1, color: device.deviceId === this.runtime.connectedDeviceId
                  ? 'rgba(34,211,238,0.45)' : this.pal().border })
                .onClick(() => {
                  this.hostSwitcherOpen = false;
                  if (device.deviceId !== this.runtime.connectedDeviceId) {
                    this.runtime.connectDevice(device.deviceId).catch(() => undefined);
                  }
                })
              }
            }, (device: RemoteHostDevice) => 'switch:' + device.deviceId + ':' + device.online)
          }
          .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.5 : 360 })
          .width('100%')
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 14, right: 14, top: 12, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
    }
    .width('100%')
    .height('100%')
  }

  /** 插件管理：列出主机插件包与其中的插件，可启停（写操作交给宿主裁决）。 */
  @Builder
  PluginsOverlay() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.tr('插件管理'))
          .fontSize(this.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
        Blank()
        Text(this.tr('刷新'))
          .fontSize(this.fs(12))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.openPluginsOverlay();
          })
        Text(this.tr('收起'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.pluginsOpen = false;
          })
      }
      .width('100%')

      if (this.pluginsLoading) {
        Row({ space: 8 }) {
          LoadingProgress().width(16).height(16).color('#22D3EE')
          Text(this.tr('读取主机插件…')).fontSize(this.fs(12)).fontColor(this.pal().text3)
        }
      } else if (this.pluginsError.length > 0) {
        Text(this.tr('无法读取主机插件：') + this.pluginsError)
          .fontSize(this.fs(12))
          .fontColor('#F85749')
          .width('100%')
      } else if (this.hostPlugins.length === 0) {
        Text(this.tr('主机没有可管理的插件'))
          .fontSize(this.fs(12))
          .fontColor(this.pal().text3)
      } else {
        List({ space: 8 }) {
          ForEach(this.hostPlugins, (bundle: HostPluginBundle) => {
            ListItem() {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Text(bundle.title.length > 0 ? bundle.title : bundle.name)
                    .fontSize(this.fs(14))
                    .fontColor(this.pal().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  if (bundle.version.length > 0) {
                    Text(bundle.version)
                      .fontSize(this.fs(10))
                      .fontColor(this.pal().text3)
                  }
                  Text(bundle.enabled ? this.tr('已启用') : this.tr('未启用'))
                    .fontSize(this.fs(10))
                    .fontColor(bundle.enabled ? '#34D399' : this.pal().text3)
                    .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                    .backgroundColor(bundle.enabled ? 'rgba(52,211,153,0.14)' : this.pal().inputBg)
                    .borderRadius(6)
                    .onClick(() => {
                      if (!bundle.writable) {
                        this.toastPluginReadOnly();
                        return;
                      }
                      this.toggleHostPlugin(bundle.name, !bundle.enabled, true);
                    })
                }
                .width('100%')
                ForEach(bundle.rows, (row: HostPluginRow) => {
                  Row({ space: 8 }) {
                    Text(row.title.length > 0 ? row.title : row.name)
                      .fontSize(this.fs(12))
                      .fontColor(this.pal().text2)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (row.settings !== undefined && row.settings.fields.length > 0) {
                      Text(this.tr('设置'))
                        .fontSize(this.fs(10))
                        .fontColor('#22D3EE')
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .onClick(() => {
                          this.openPluginForm(row.title.length > 0 ? row.title : row.name, row.settings);
                        })
                    }
                    Text(row.enabled ? this.tr('已启用') : this.tr('未启用'))
                      .fontSize(this.fs(10))
                      .fontColor(row.enabled ? '#34D399' : this.pal().text3)
                      .onClick(() => {
                        if (!row.writable) {
                          this.toastPluginReadOnly();
                          return;
                        }
                        this.toggleHostPlugin(row.entryId, !row.enabled, false);
                      })
                  }
                  .width('100%')
                  .padding({ top: 2 })
                }, (row: HostPluginRow) => 'row:' + row.entryId + ':' + row.enabled)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.pal().card)
              .borderRadius(10)
              .border({ width: 1, color: this.pal().border })
            }
          }, (bundle: HostPluginBundle) => 'bundle:' + bundle.name + ':' + bundle.enabled + ':' + this.pluginsRev)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 18 })
    .backgroundColor(this.pal().bg)
  }

  /** 打开 Web 控制台：没配过地址就先给个默认猜测（局域网 + 3080），用户可改。 */
  private openWebConsole(): void {
    const saved: string = this.runtime.webConsoleUrl;
    this.webConsoleInput = saved.length > 0 ? saved : 'http://';
    this.webConsoleOpen = true;
    this.webConsoleError = '';
    if (saved.length > 0) {
      this.loadWebConsole(saved);
    } else {
      this.webConsoleSrc = '';
    }
  }

  private loadWebConsole(url: string): void {
    let normalized: string = url.trim();
    if (normalized.length === 0) {
      return;
    }
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'http://' + normalized;
    }
    this.webConsoleInput = normalized;
    this.webConsoleSrc = normalized;
    this.webConsoleError = '';
    this.webConsoleLoading = true;
    this.runtime.setWebConsoleUrl(normalized);
  }

  /** 说明为什么可能打不开：宿主机的 dsh web 默认只听 127.0.0.1。 */
  private webConsoleHint(): string {
    return this.tr('宿主机要能被手机访问：用 dsh web --host 你的局域网IP 启动，并在防火墙放行端口');
  }

  /** 应用内 Web 控制台：内嵌宿主机的 dsh web 页面（网页版），地址可改、可外部打开。 */
  @Builder
  WebConsoleOverlay() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.tr('Web 控制台'))
          .fontSize(this.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
        Blank()
        Text(this.tr('刷新'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            if (this.webConsoleSrc.length > 0) {
              this.webConsoleController.refresh();
            }
          })
        Text(this.tr('浏览器打开'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.openInBrowser(this.webConsoleSrc.length > 0
              ? this.webConsoleSrc : this.webConsoleInput);
          })
        Text(this.tr('收起'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.webConsoleOpen = false;
            this.webConsoleSrc = '';
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.webConsoleInput, placeholder: 'http://192.168.3.2:3080' })
          .layoutWeight(1)
          .height(38)
          .fontSize(this.fs(13))
          .backgroundColor(this.pal().inputBg)
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().border })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.webConsoleInput = value;
          })
          .onSubmit(() => {
            this.loadWebConsole(this.webConsoleInput);
          })
        Text(this.tr('打开'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(10)
          .backgroundColor(this.isDarkUi ? 'rgba(34,211,238,0.14)' : 'rgba(34,211,238,0.12)')
          .onClick(() => {
            this.loadWebConsole(this.webConsoleInput);
          })
      }
      .width('100%')

      if (this.webConsoleSrc.length === 0) {
        Column({ space: 6 }) {
          Text(this.tr('填宿主机的局域网地址，App 里直接开网页版 DSH'))
            .fontSize(this.fs(12))
            .fontColor(this.pal().text2)
          Text(this.webConsoleHint())
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
        }
        .width('100%')
        .padding(12)
        .backgroundColor(this.pal().card)
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
      } else {
        if (this.webConsoleError.length > 0) {
          Text(this.webConsoleError)
            .fontSize(this.fs(11))
            .fontColor('#F85749')
            .maxLines(2)
            .width('100%')
        }
        Stack() {
          Web({ src: this.webConsoleSrc, controller: this.webConsoleController })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(false)
            .onPageBegin(() => {
              this.webConsoleLoading = true;
              this.webConsoleError = '';
            })
            .onPageEnd(() => {
              this.webConsoleLoading = false;
            })
            .onErrorReceive((event: OnErrorReceiveEvent) => {
              this.webConsoleLoading = false;
              if (!event.request.isMainFrame) {
                return;
              }
              this.webConsoleError = this.tr('打不开：') + event.error.getErrorInfo()
                + ' · ' + this.webConsoleHint();
            })
            .width('100%')
            .height('100%')
            .backgroundColor(this.pal().bg)
          if (this.webConsoleLoading) {
            LoadingProgress()
              .width(28)
              .height(28)
              .color('#22D3EE')
          }
        }
        .layoutWeight(1)
        .width('100%')
        .borderRadius(12)
        .clip(true)
        .border({ width: 1, color: this.pal().border })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor(this.pal().bg)
  }

  /** 会话终端：xterm.js 渲染（ANSI 颜色/清屏都支持），输入走宿主页的输入框。 */
  @Builder
  TerminalOverlay() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Text(this.tr('终端'))
          .fontSize(this.fs(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.pal().text)
        if (this.terminalTitle.length > 0) {
          Text(this.terminalTitle)
            .fontSize(this.fs(10))
            .fontColor(this.pal().text3)
            .maxLines(1)
            .constraintSize({ maxWidth: 140 })
        }
        Blank()
        Text(this.terminalWritable ? this.tr('可输入') : this.tr('只读'))
          .fontSize(this.fs(10))
          .fontColor(this.terminalWritable ? '#34D399' : this.pal().text3)
        Text(this.tr('收起'))
          .fontSize(this.fs(13))
          .fontColor('#22D3EE')
          .padding({ left: 8 })
          .onClick(() => {
            this.closeTerminalOverlay();
          })
      }
      .width('100%')

      Web({ src: $rawfile('terminal.html'), controller: this.terminalController })
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .fileAccess(false)
        .javaScriptProxy({
          object: this.terminalBridge,
          name: 'dshTermBridge',
          methodList: ['onTerminalData', 'onTerminalReady'],
          controller: this.terminalController
        })
        .onPageEnd(() => {
          this.terminalReady = true;
          this.flushTerminalPending();
        })
        .layoutWeight(1)
        .width('100%')
        .borderRadius(10)
        .backgroundColor('#0b1220')

      Row({ space: 8 }) {
        TextInput({ text: this.terminalInput, placeholder: this.tr('输入命令后回车') })
          .layoutWeight(1)
          .height(40)
          .fontSize(this.fs(13))
          .backgroundColor(this.pal().inputBg)
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().border })
          .padding({ left: 12, right: 12 })
          .enabled(this.terminalWritable)
          .onChange((value: string) => {
            this.terminalInput = value;
          })
          .onSubmit(() => {
            this.sendTerminalInput();
          })
        Text(this.tr('发送'))
          .fontSize(this.fs(13))
          .fontColor(this.terminalWritable ? '#22D3EE' : this.pal().text3)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor('rgba(34,211,238,0.10)')
          .borderRadius(10)
          .onClick(() => {
            this.sendTerminalInput();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 18 })
    .backgroundColor(this.pal().bg)
  }
  @Builder
  DiagnosticsOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(8,12,24,0.55)')
        .onClick(() => {
          this.diagnosticsOpen = false;
        })
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.tr('连接诊断'))
            .fontSize(this.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Blank()
          Text(this.tr('自检'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.runtime.runSelfCheck().then((lines: string[]) => {
                this.selfCheckLines = lines;
              }).catch(() => {
                this.selfCheckLines = [this.tr('自检失败：读不到运行时状态')];
              });
            })
          Text(this.tr('存文件'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              const path: string = this.runtime.exportDiagnosticsToFile();
              promptAction.showToast({ message: path.length > 0
                ? this.tr('已保存，可用 hdc file recv 拉走') + '\n' + path
                : this.tr('导出失败（存储不可用）') });
            })
          Text(this.tr('复制'))
            .fontSize(this.fs(12))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              const lines: string[] = this.runtime.diagnosticsLines()
                .concat(['', this.tr('最近事件：')])
                .concat(this.runtime.linkEvents)
                .concat(['', 'link.log: ' + this.runtime.linkLogPath()])
                .concat(this.runtime.linkLogTail());
              const data: pasteboard.PasteData = pasteboard.createData(
                pasteboard.MIMETYPE_TEXT_PLAIN, lines.join('\n'));
              pasteboard.getSystemPasteboard().setData(data).then(() => {
                promptAction.showToast({ message: this.tr('诊断信息已复制') });
              }).catch(() => undefined);
            })
          Text(this.tr('收起'))
            .fontSize(this.fs(13))
            .fontColor('#22D3EE')
            .padding({ left: 8, right: 2, top: 6, bottom: 6 })
            .onClick(() => {
              this.diagnosticsOpen = false;
            })
        }
        .width('100%')
        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.runtime.diagnosticsLines(), (line: string) => {
              Text(line)
                .fontSize(this.fs(12))
                .fontColor(this.pal().text2)
                .width('100%')
                .textAlign(TextAlign.Start)
            }, (line: string) => line)
            if (this.selfCheckLines.length > 0) {
              Column()
                .width('100%')
                .height(0.5)
                .backgroundColor(this.pal().border)
                .margin({ top: 4, bottom: 4 })
              Text(this.tr('自检结果'))
                .fontSize(this.fs(11))
                .fontColor(this.pal().text3)
                .width('100%')
                .textAlign(TextAlign.Start)
              ForEach(this.selfCheckLines, (line: string) => {
                Text(line)
                  .fontSize(this.fs(12))
                  .fontColor(line.startsWith('✓') ? '#3FCF8E'
                    : (line.startsWith('!') ? '#F5A623' : this.pal().text2))
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }, (line: string, index: number) => `check:${index}:${line}`)
            }
            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor(this.pal().border)
              .margin({ top: 4, bottom: 4 })
            Text(this.tr('最近事件'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .width('100%')
              .textAlign(TextAlign.Start)
            if (this.runtime.linkEvents.length === 0) {
              Text(this.tr('还没有记录'))
                .fontSize(this.fs(12))
                .fontColor(this.pal().text3)
                .width('100%')
                .textAlign(TextAlign.Start)
            } else {
              ForEach(this.runtime.linkEvents, (line: string) => {
                Text(line)
                  .fontSize(this.fs(11))
                  .fontColor(this.pal().text2)
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }, (line: string) => line)
            }
            Column()
              .width('100%')
              .height(0.5)
              .backgroundColor(this.pal().border)
              .margin({ top: 4, bottom: 4 })
            Text(this.tr('链路日志（已落盘，重启 App 也保留）'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
              .width('100%')
              .textAlign(TextAlign.Start)
            if (this.runtime.linkLogTail().length === 0) {
              Text(this.tr('还没有记录'))
                .fontSize(this.fs(12))
                .fontColor(this.pal().text3)
                .width('100%')
                .textAlign(TextAlign.Start)
            } else {
              ForEach(this.runtime.linkLogTail(), (line: string) => {
                Text(line)
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
                  .width('100%')
                  .textAlign(TextAlign.Start)
              }, (line: string) => line)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .height('62%')
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 320 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 全屏编辑：写长 prompt 时不受输入坞高度和候选条限制。 */
  @Builder
  ExpandedComposerOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(8,12,24,0.55)')
        .onClick(() => {
          this.composerExpanded = false;
        })
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.tr('编辑消息'))
            .fontSize(this.fs(16))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.pal().text)
          Blank()
          Text(this.promptInput.length + this.tr(' 字'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
          Text(this.tr('收起'))
            .fontSize(this.fs(13))
            .fontColor('#22D3EE')
            .padding({ left: 10, right: 4, top: 6, bottom: 6 })
            .onClick(() => {
              this.composerExpanded = false;
            })
        }
        .width('100%')
        TextArea({ text: this.promptInput,
          placeholder: this.tr('在这里写长消息（Enter 发送 · Shift+Enter 换行）') })
          .layoutWeight(1)
          .width('100%')
          .onKeyEvent((event: KeyEvent) => {
            if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_ENTER) {
              return;
            }
            try {
              if (this.enterSends()) {
                if (this.modifierPressed(event, 'Shift')) {
                  return;
                }
                this.composerExpanded = false;
                this.sendTap();
              } else if (this.ctrlEnterPressed(event)) {
                this.composerExpanded = false;
                this.sendTap();
              }
            } catch (error) {
              LinkLog.write('key', '回车发送异常（长编辑）：' + errorMessage(error));
            }
          })
          .enterKeyType(this.enterSends() ? EnterKeyType.Send : EnterKeyType.NEW_LINE)
          .onSubmit(() => {
            if (this.enterSends()) {
              this.composerExpanded = false;
              this.sendTap();
            }
          })
          .backgroundColor(this.pal().inputBg)
          .fontColor(this.pal().text)
          .fontSize(this.fs(15))
          .borderRadius(14)
          .border({ width: 1, color: this.pal().border })
          .padding(12)
          .onChange((value: string) => {
            this.promptInput = value;
            this.runtime.saveDraft(this.currentSessionId, value);
          })
        Row({ space: 10 }) {
          if (this.pendingImages.length > 0) {
            Text(this.pendingImages.length + this.tr(' 张图待发'))
              .fontSize(this.fs(11))
              .fontColor(this.pal().text3)
          }
          Blank()
          Button(this.tr('发送'))
            .height(40)
            .fontSize(this.fs(14))
            .fontColor('#FFFFFF')
            .padding({ left: 26, right: 26 })
            .borderRadius(20)
            .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
            .enabled(this.promptInput.trim().length > 0 || this.pendingImages.length > 0)
            .onClick(() => {
              this.composerExpanded = false;
              this.sendTap();
            })
        }
        .width('100%')
      }
      .width('100%')
      .height('78%')
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 380 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 200, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  WorkspaceCreateOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.workspaceCreateOpen = false;
        })
      Column({ space: 12 }) {
        Row() {
          Text(this.tr('新建工作区'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.workspaceCreateOpen = false;
            })
        }
        .width('100%')

        Column({ space: 6 }) {
          Text(this.tr('主机上的目录（绝对路径）'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
            .width('100%')
          TextInput({ text: this.workspacePathInput, placeholder: '/home/user/project' })
            .width('100%')
            .height(46)
            .fontSize(this.fs(14))
            .fontColor(this.pal().text)
            .placeholderColor(this.pal().text3)
            .backgroundColor(this.pal().inputBg)
            .borderRadius(12)
            .border({ width: 1, color: this.pal().border })
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.workspacePathInput = value;
            })
          if (this.runtime.browsePath.length > 0) {
            Text(this.tr('填入当前浏览目录') + '：' + this.runtime.browsePath)
              .fontSize(this.fs(10))
              .fontColor('#22D3EE')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .onClick(() => {
                this.workspacePathInput = this.runtime.browsePath;
              })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 6 }) {
          Text(this.tr('显示名称（可留空）'))
            .fontSize(this.fs(11))
            .fontColor(this.pal().text3)
            .width('100%')
          TextInput({ text: this.workspaceNameDraft, placeholder: this.tr('留空则用目录名') })
            .width('100%')
            .height(46)
            .fontSize(this.fs(14))
            .fontColor(this.pal().text)
            .placeholderColor(this.pal().text3)
            .backgroundColor(this.pal().inputBg)
            .borderRadius(12)
            .border({ width: 1, color: this.pal().border })
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.workspaceNameDraft = value;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Text(this.tr('创建'))
          .fontSize(this.fs(14))
          .fontColor('#FFFFFF')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 13, bottom: 13 })
          .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
          .borderRadius(12)
          .onClick(() => {
            const path: string = this.workspacePathInput.trim();
            if (path.length === 0) {
              promptAction.showToast({ message: this.tr('先填一个主机上的绝对路径') });
              return;
            }
            this.runtime.createWorkspace(path, this.workspaceNameDraft.trim());
            this.workspaceCreateOpen = false;
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 320 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 220, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 轨迹条目：只挑工具调用，按 seq 升序。 */
  private trajectoryItems(): ChatItem[] {
    const out: ChatItem[] = [];
    for (const item of this.messages) {
      if (item.kind === 'tool') {
        out.push(item);
      }
    }
    out.sort((a: ChatItem, b: ChatItem) => a.seq - b.seq);
    return out;
  }

  /** 执行轨迹：整个会话的工具调用时间线，点开可看完整参数。 */
  @Builder
  TrajectoryOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.trajectoryOpen = false;
        })
      Column({ space: 8 }) {
        Row() {
          Text(this.tr('执行轨迹'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Text(' ' + this.trajectoryItems().length + '')
            .fontSize(this.fs(12))
            .fontColor(this.pal().text3)
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.trajectoryOpen = false;
            })
        }
        .width('100%')
        .padding({ bottom: 4 })

        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.trajectoryItems(), (item: ChatItem) => {
              Row({ space: 10 }) {
                Column()
                  .width(2)
                  .height(34)
                  .borderRadius(1)
                  .backgroundColor(item.toolState === 'failed'
                    ? 'rgba(248,87,73,0.55)' : this.pal().border)
                Column({ space: 3 }) {
                  Row({ space: 6 }) {
                    Text(item.toolName.length > 0 ? item.toolName : this.tr('工具'))
                      .fontSize(this.fs(13))
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.pal().text)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(item.toolState === 'failed' ? this.tr('失败')
                      : (item.toolState === 'running' ? this.tr('运行中') : this.tr('完成')))
                      .fontSize(this.fs(10))
                      .fontColor(item.toolState === 'failed' ? '#F85749'
                        : (item.toolState === 'running' ? '#22D3EE' : this.pal().text3))
                  }
                  .width('100%')
                  if (item.summary.length > 0) {
                    Text(item.summary)
                      .fontSize(this.fs(11))
                      .fontColor(this.pal().text2)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  if (item.text.length > 0) {
                    Text(item.text)
                      .fontSize(this.fs(10))
                      .fontColor(this.pal().text3)
                      .fontFamily('monospace')
                      .maxLines(3)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(this.pal().card)
              .borderRadius(12)
              .border({ width: 1, color: this.pal().border })
            }, (item: ChatItem) => 'traj-' + item.id + '-' + item.rev)
            if (this.trajectoryItems().length === 0) {
              Text(this.tr('本次会话还没有工具调用'))
                .fontSize(this.fs(12))
                .fontColor(this.pal().text3)
                .padding({ top: 12, bottom: 12 })
            }
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.62 : 420 })
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Auto)
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: 560 })
      .padding({ left: 20, right: 20, top: 16, bottom: 22 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 22, topRight: 22 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 340 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 220, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 当前会话里搜消息：命中片段列表，点一条滚过去。 */
  private inSessionHits(): ChatItem[] {
    const query: string = this.inSessionQuery.trim().toLowerCase();
    if (query.length === 0) {
      return [];
    }
    const out: ChatItem[] = [];
    for (const item of this.messages) {
      if (item.text.toLowerCase().indexOf(query) >= 0) {
        out.push(item);
      }
    }
    return out.slice(0, 40);
  }

  private scrollToMessage(messageId: string): void {
    const rows: ChatItem[] = this.chatRows();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === messageId) {
        this.stickToBottom = false;
        this.scroller.scrollToIndex(i, true);
        return;
      }
    }
  }

  /** 命中片段拆成「前缀 / 命中词 / 后缀」三段，方便分别上色。 */
  private hitParts(text: string): string[] {
    const query: string = this.inSessionQuery.trim();
    const lower: string = text.toLowerCase();
    const index: number = query.length === 0 ? -1 : lower.indexOf(query.toLowerCase());
    if (index < 0) {
      const head: string = text.length > 60 ? text.substring(0, 60) + '…' : text;
      return [head, '', ''];
    }
    const start: number = Math.max(0, index - 20);
    const end: number = Math.min(text.length, index + query.length + 30);
    const before: string = (start > 0 ? '…' : '') + text.substring(start, index);
    const hit: string = text.substring(index, index + query.length);
    const after: string = text.substring(index + query.length, end) + (end < text.length ? '…' : '');
    return [before, hit, after];
  }

  @Builder
  InSessionSearchOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.inSessionSearchOpen = false;
        })
      Column({ space: 8 }) {
        Row() {
          Text(this.tr('搜索本会话'))
            .fontSize(this.fs(15))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Blank()
          Text('✕')
            .fontSize(this.fs(15))
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.inSessionSearchOpen = false;
            })
        }
        .width('100%')
        TextInput({ text: this.inSessionQuery, placeholder: this.tr('输入关键词…') })
          .width('100%')
          .height(42)
          .fontSize(this.fs(13))
          .fontColor(this.pal().text)
          .placeholderColor(this.pal().text3)
          .backgroundColor(this.pal().inputBg)
          .borderRadius(10)
          .border({ width: 1, color: this.pal().border })
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.inSessionQuery = value;
          })
        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.inSessionHits(), (item: ChatItem) => {
              Row({ space: 8 }) {
                Text(item.kind === 'user' ? '我' : '答')
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
                  .width(16)
                Text() {
                  Span(this.hitParts(item.text)[0])
                    .fontColor(this.pal().text2)
                  Span(this.hitParts(item.text)[1])
                    .fontColor('#22D3EE')
                    .fontWeight(FontWeight.Medium)
                  Span(this.hitParts(item.text)[2])
                    .fontColor(this.pal().text2)
                }
                .fontSize(this.fs(11))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                Text(item.timestamp > 0 ? formatClock(item.timestamp) : '')
                  .fontSize(this.fs(10))
                  .fontColor(this.pal().text3)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(this.pal().card)
              .borderRadius(10)
              .border({ width: 1, color: this.pal().border })
              .onClick(() => {
                this.inSessionSearchOpen = false;
                this.scrollToMessage(item.id);
              })
            }, (item: ChatItem) => 'hit-' + item.id)
            if (this.inSessionQuery.trim().length > 0 && this.inSessionHits().length === 0) {
              Text(this.tr('没有匹配的消息'))
                .fontSize(this.fs(11))
                .fontColor(this.pal().text3)
                .padding({ top: 10, bottom: 10 })
            }
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.5 : 320 })
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: 16, right: 16, top: 14, bottom: 18 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
    }
    .width('100%')
    .height('100%')
  }

  /** 本地提示词库：点一条就填进输入框，也可以就地增删。 */
  @Builder
  PromptPanelOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.dialogScrim())
        .onClick(() => {
          this.promptPanelOpen = false;
        })
      Column({ space: 10 }) {
        Row() {
          Text(this.tr('提示词'))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pal().text)
          Blank()
          Text('✕')
            .fontSize(15)
            .fontColor(this.pal().text3)
            .width(30)
            .height(30)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.promptPanelOpen = false;
            })
        }
        .width('100%')

        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.runtime.prompts, (item: string) => {
              Row({ space: 10 }) {
                Text(item)
                  .fontSize(this.fs(13))
                  .fontColor(this.pal().text)
                  .maxLines(3)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text('✕')
                  .fontSize(this.fs(12))
                  .fontColor(this.pal().text3)
                  .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.runtime.removePrompt(item);
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 10, top: 10, bottom: 10 })
              .backgroundColor(this.pal().card)
              .borderRadius(12)
              .border({ width: 1, color: this.pal().border })
              .onClick(() => {
                this.promptInput = item;
                this.runtime.saveDraft(this.currentSessionId, item);
                this.promptPanelOpen = false;
              })
            }, (item: string) => 'prompt-' + item)
            if (this.runtime.prompts.length === 0) {
              Text(this.tr('还没有提示词，下面加一条'))
                .fontSize(this.fs(12))
                .fontColor(this.pal().text3)
                .padding({ top: 6, bottom: 6 })
            }
          }
          .width('100%')
        }
        .constraintSize({ maxHeight: this.windowHeightVp > 0 ? this.windowHeightVp * 0.42 : 300 })
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: this.promptDraftInput, placeholder: this.tr('新增一条提示词…') })
            .layoutWeight(1)
            .height(42)
            .backgroundColor(this.pal().inputBg)
            .fontColor(this.pal().text)
            .fontSize(this.fs(14))
            .placeholderColor(this.pal().text3)
            .borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.promptDraftInput = value;
            })
          Text(this.tr('添加'))
            .fontSize(this.fs(13))
            .fontColor('#FFFFFF')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
            .borderRadius(12)
            .onClick(() => {
              this.runtime.addPrompt(this.promptDraftInput);
              this.promptDraftInput = '';
            })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: 520 })
      .padding({ left: 20, right: 20, top: 16, bottom: 22 })
      .backgroundColor(this.overlayGlass())
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
        colorMode: this.isDarkUi ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        adaptiveColor: AdaptiveColor.DEFAULT,
        blurOptions: { grayscale: [0, 12] }
      })
      .borderRadius({ topLeft: 22, topRight: 22 })
      .border({ width: { top: 0.5 }, color: this.pal().borderStrong })
      .transition(TransitionEffect.translate({ y: 320 })
        .combine(TransitionEffect.opacity(0))
        .animation({ duration: 220, curve: Curve.Friction }))
    }
    .width('100%')
    .height('100%')
  }

  /** 底部弹层的统一底色：半透明 + 背景磨砂，透出后面的会话内容。 */
  /** 窄屏（手机竖屏）顶栏空间紧：隐藏「切换」二字，只留主机名与箭头。 */
  private compactHeader(): boolean {
    return this.windowWidthVp > 0 && this.windowWidthVp < 520;
  }

  private overlayGlass(): string {
    // 透一点才看得出是磨砂：弹层背后的会话内容要能隐约透出来
    return this.isDarkUi ? 'rgba(26,32,48,0.38)' : 'rgba(252,253,255,0.55)';
  }

  /** 弹层背后的遮罩：比面板更淡，避免整体压成一块黑。 */
  private dialogScrim(): string {
    return this.isDarkUi ? 'rgba(4,8,16,0.18)' : 'rgba(20,30,50,0.10)';
  }

  /** 输入框聚焦时的一层柔光：左右两端各留一点扩散，视觉上和两侧按键的光连成一条。 */
  @Builder
  InputGlow() {
    Column()
      .width('100%')
      .height('100%')
      .radialGradient({
        center: ['50%', '42%'],
        radius: 220,
        colors: [
          ['rgba(255,255,255,0.58)', 0],
          ['rgba(255,255,255,0.26)', 0.45],
          ['rgba(255,255,255,0.08)', 0.75],
          ['rgba(255,255,255,0)', 1]
        ]
      })
      .opacity(this.inputFocused ? 1 : 0.72)
      .animation({ duration: 220, curve: Curve.EaseOut })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 单块玻璃上的跟手光斑：谁被按就亮谁，坐标就是那一块自己的局部坐标。 */
  @Builder
  DockSpot(radius: number) {
    Column()
      .width('100%')
      .height('100%')
      .radialGradient({
        center: [this.dockLightX, this.dockLightY],
        radius: radius,
        colors: [
          ['rgba(255,255,255,0.62)', 0],
          ['rgba(255,255,255,0.20)', 0.45],
          ['rgba(255,255,255,0)', 1]
        ]
      })
      .opacity(this.dockLightOpacity)
      .hitTestBehavior(HitTestMode.None)
  }

  /** 顶栏图标：22 的图形 + 40 的点击区，齿轮/加号/三横摆在一起比例才一致。 */
  @Builder
  TopIcon(icon: Resource, action: () => void) {
    Row() {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor(this.pal().text2)
    }
    .width(40)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    // PC/大屏：Tab 能走到、Enter/Space 能按下去（官方无障碍与键盘操作要求）
    .focusable(true)
    .onClick(() => {
      action();
    })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type === KeyType.Down
        && (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE)) {
        action();
      }
    })
  }

  /**
   * 折叠后的连续工具调用：左边一条竖线当时间轴，一行「N 步」，点一下摊开。
   * 不再套整块卡片，聊天流里不抢视线。
   */
  @Builder
  ToolRunRow(item: ChatItem) {
    Row({ space: 10 }) {
      Column()
        .width(2)
        .height(22)
        .borderRadius(1)
        .backgroundColor(item.toolState === 'failed'
          ? 'rgba(248,87,73,0.55)' : this.pal().border)
      if (item.toolState === 'running') {
        LoadingProgress()
          .width(12)
          .height(12)
          .color('#22D3EE')
      } else {
        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(item.toolState === 'failed' ? '#F85749' : '#34D399')
      }
      Text(item.text)
        .fontSize(this.fs(12))
        .fontColor(this.pal().text2)
      if (item.summary.length > 0) {
        Text(item.summary)
          .fontSize(this.fs(11))
          .fontColor(this.pal().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else {
        Blank()
      }
      Text(item.rev === 1 ? '⌃' : '⌄')
        .fontSize(this.fs(12))
        .fontColor(this.pal().text3)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.toggleRun(item.requestRpcId);
    })
  }

  /** 摊开后的单条工具调用：缩进对齐时间轴，只留一行摘要，不再是一块厚卡片。 */
  @Builder
  ToolRow(item: ChatItem) {
    Row({ space: 8 }) {
      if (item.toolState === 'running') {
        LoadingProgress()
          .width(10)
          .height(10)
          .color('#22D3EE')
      } else {
        Column()
          .width(4)
          .height(4)
          .borderRadius(2)
          .backgroundColor(item.toolState === 'failed' ? '#F85749' : this.pal().text3)
      }
      Text(item.toolName)
        .fontSize(this.fs(12))
        .fontColor(this.pal().text2)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (item.summary.length > 0) {
        Text(item.summary)
          .fontSize(this.fs(11))
          .fontColor(this.pal().text3)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else if (item.text.length > 0) {
        Text(item.text)
          .fontSize(this.fs(10))
          .fontColor(this.pal().text3)
          .fontFamily('monospace')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else {
        Blank()
      }
    }
    .width('100%')
    .padding({ top: 3, bottom: 3, left: 24, right: 6 })
    .onClick(() => {
      const payload: string = item.text.length > 0 ? item.text : item.summary;
      if (payload.length === 0) {
        return;
      }
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, payload);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: this.tr('已复制该条命令') });
      }).catch(() => undefined);
    })
  }

  @Builder
  ApprovalRow(item: ChatItem) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Text('!')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#F5A623')
        Text('需要批准')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F5A623')
          .letterSpacing(1)
      }
      Text(item.toolName)
        .fontSize(14)
        .fontColor(this.pal().text)
        .textAlign(TextAlign.Start)
      if (item.reason.length > 0) {
        Text(item.reason)
          .fontSize(12)
          .fontColor(this.pal().text2)
          .textAlign(TextAlign.Start)
      }
      if (item.staleHint.length > 0 && item.approvalOutcome.length === 0) {
        Text(item.staleHint)
          .fontSize(11)
          .fontColor('#F5A623')
          .textAlign(TextAlign.Start)
      }
      if (item.approvalOutcome.length === 0 && item.timestamp > 0) {
        Text(waitLabel(item.timestamp, this.en()) + (waitLooksStale(item.timestamp)
          ? (this.en() ? ' · host may have timed out' : ' · 主机可能已超时') : ''))
          .fontSize(11)
          .fontColor(waitLooksStale(item.timestamp) ? '#F85749' : this.pal().text3)
          .textAlign(TextAlign.Start)
      }
      if (item.approvalOutcome.length === 0) {
        Row({ space: 8 }) {
          Button(this.tr('允许'))
            .layoutWeight(1)
            .height(36)
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
            .fontColor('#FFFFFF')
            .borderRadius(12)
            .onClick(() => {
              this.runtime.respondApproval(item, true);
            })
          Button(this.tr('拒绝'))
            .layoutWeight(1)
            .height(36)
            .fontSize(14)
            .backgroundColor('rgba(248,87,73,0.12)')
            .fontColor('#F85749')
            .borderRadius(12)
            .border({ width: 1, color: 'rgba(248,87,73,0.35)' })
            .onClick(() => {
              this.runtime.respondApproval(item, false);
            })
        }
        .width('100%')
      } else {
        Text(approvalOutcomeLabel(item.approvalOutcome))
          .fontSize(12)
          .fontColor(this.pal().text2)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('rgba(245,166,35,0.09)')
    .borderRadius(14)
    .border({ width: 1, color: 'rgba(245,166,35,0.28)' })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  QuestionRow(item: ChatItem) {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text('?')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#22D3EE')
        Text('需要回答')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#22D3EE')
          .letterSpacing(1)
      }
      ForEach(item.questions, (question: ChatQuestion) => {
        Column({ space: 6 }) {
          if (question.header.length > 0) {
            Text(question.header)
              .fontSize(11)
              .fontColor(this.pal().text2)
              .letterSpacing(0.5)
          }
          Text(question.question)
            .fontSize(14)
            .fontColor(this.pal().text)
            .textAlign(TextAlign.Start)
          if (question.detail.length > 0) {
            Text(question.detail)
              .fontSize(12)
              .fontColor(this.pal().text2)
              .textAlign(TextAlign.Start)
          }
          Flex({ wrap: FlexWrap.Wrap, direction: FlexDirection.Row }) {
            ForEach(question.options, (label: string) => {
              Text(label)
                .fontSize(13)
                .fontColor(question.selectedLabels.includes(label) ? '#FFFFFF' : this.pal().text2)
                .backgroundColor(question.selectedLabels.includes(label) ? '#4D6BFE' : this.pal().chip)
                .borderRadius(14)
                .border({ width: 1,
                  color: question.selectedLabels.includes(label) ? 'rgba(77,107,254,0.8)' : this.pal().borderStrong })
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ right: 6, bottom: 6 })
                .onClick(() => {
                  this.runtime.toggleQuestionOption(item, question, label);
                })
            }, (label: string) => `${question.id}:${label}`)
          }
          .width('100%')
          if (question.multiSelect) {
            Text(this.tr('可多选'))
              .fontSize(11)
              .fontColor(this.pal().text3)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (question: ChatQuestion) => question.id)
      if (item.staleHint.length > 0 && item.questionOutcome.length === 0) {
        Text(item.staleHint)
          .fontSize(11)
          .fontColor('#F5A623')
          .textAlign(TextAlign.Start)
      }
      if (item.questionOutcome.length === 0 && item.timestamp > 0) {
        Text(waitLabel(item.timestamp, this.en()) + (waitLooksStale(item.timestamp)
          ? (this.en() ? ' · host may have timed out' : ' · 主机可能已超时') : ''))
          .fontSize(11)
          .fontColor(waitLooksStale(item.timestamp) ? '#F85749' : this.pal().text3)
          .textAlign(TextAlign.Start)
      }
      if (item.questionOutcome.length === 0) {
        Button(this.tr('提交回答'))
          .width('100%')
          .height(38)
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .linearGradient({ angle: 135, colors: [['#4D6BFE', 0], ['#22D3EE', 1]] })
          .fontColor('#FFFFFF')
          .borderRadius(12)
          .enabled(this.busyAction.length === 0)
          .onClick(() => {
            this.runtime.submitQuestion(item);
          })
      } else {
        Text(questionOutcomeLabel(item.questionOutcome))
          .fontSize(12)
          .fontColor(this.pal().text2)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('rgba(77,107,254,0.08)')
    .borderRadius(14)
    .border({ width: 1, color: 'rgba(77,107,254,0.25)' })
    .alignItems(HorizontalAlign.Start)
  }
}

function deviceAvatarLabel(device: RemoteHostDevice, displayName: string): string {
  const name: string = displayName.trim();
  if (name.length > 0) {
    return name.substring(0, 1).toUpperCase();
  }
  return 'H';
}

/** Last path segment of the session workspace, e.g. '/a/WorkBuddy' -> 'WorkBuddy'. */
function cwdLabel(cwd: string): string {
  let trimmed: string = cwd;
  while (trimmed.length > 1 && trimmed.charAt(trimmed.length - 1) === '/') {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.length === 0) {
    return '';
  }
  const slash: number = trimmed.lastIndexOf('/');
  return slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
}

/** Human label of the server base URL: strip the scheme and any trailing slash. */
function serverHostLabel(url: string): string {
  let label: string = url;
  if (label.startsWith('https://')) {
    label = label.substring(8);
  } else if (label.startsWith('http://')) {
    label = label.substring(7);
  }
  while (label.length > 0 && label.charAt(label.length - 1) === '/') {
    label = label.substring(0, label.length - 1);
  }
  return label.length > 0 ? label : t('未配置服务器');
}

function formatSessionTitle(session: HarnessRemoteSession): string {
  const title: string = session.title.trim();
  if (title.length > 0) {
    return title;
  }
  if (session.blank) {
    return t('新会话');
  }
  const shortId: string = session.sessionId.substring(0, 8);
  return english() ? `Session ${shortId}` : `会话 ${shortId}`;
}

/** 会话行的 Agent 后端徽标：按 sessionId 前缀投影（与上游 Android backend-groups 同口径）。 */
function sessionBackendBadge(sessionId: string): string {
  if (sessionId.startsWith('codex:')) {
    return 'Codex';
  }
  if (sessionId.startsWith('claude:')) {
    return 'Claude';
  }
  if (sessionId.startsWith('cursor:')) {
    return 'Cursor';
  }
  if (sessionId.startsWith('opencode:')) {
    return 'OpenCode';
  }
  if (sessionId.startsWith('antigravity:')) {
    return 'AntiGravity';
  }
  if (sessionId.startsWith('hermes:')) {
    return 'Hermes';
  }
  if (sessionId.startsWith('pi:')) {
    return 'Pi';
  }
  return '';
}

/** 今天 / 昨天 / 更早 —— 会话列表分组用。 */
function sessionGroupLabel(updatedAt: number): string {
  if (updatedAt <= 0) {
    return t('更早');
  }
  const now: Date = new Date();
  const then: Date = new Date(updatedAt);
  const startOfToday: number = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  if (updatedAt >= startOfToday) {
    return t('今天');
  }
  if (updatedAt >= startOfToday - 86400000) {
    return t('昨天');
  }
  return t('更早');
}

function formatSessionTime(updatedAt: number): string {
  if (updatedAt <= 0) {
    return '';
  }
  const date: Date = new Date(updatedAt);
  const now: Date = new Date();
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  const hour: number = date.getHours();
  const minute: number = date.getMinutes();
  const minuteText: string = minute < 10 ? `0${minute}` : `${minute}`;
  if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() && date.getDate() === now.getDate()) {
    return `${hour}:${minuteText}`;
  }
  if (english()) {
    const monthNames: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    const monthName: string = monthNames[month - 1];
    if (date.getFullYear() === now.getFullYear()) {
      return `${monthName} ${day} ${hour}:${minuteText}`;
    }
    return `${monthName} ${day}, ${date.getFullYear()}`;
  }
  if (date.getFullYear() === now.getFullYear()) {
    return `${month}月${day}日 ${hour}:${minuteText}`;
  }
  return `${date.getFullYear()}年${month}月${day}日`;
}

function approvalOutcomeLabel(outcome: string): string {
  if (outcome === 'allowed-once') {
    return t('已允许');
  }
  if (outcome === 'rejected') {
    return t('已拒绝');
  }
  if (outcome === 'cancelled') {
    return t('已取消');
  }
  return t('已失效');
}

function questionOutcomeLabel(outcome: string): string {
  if (outcome === 'answered') {
    return t('已回答');
  }
  if (outcome === 'queued') {
    return t('已提交');
  }
  return t('已取消');
}


/** 消息图片的小缓存：按 src 存解码好的 PixelMap，失败也记下来避免反复请求。 */
class MarkdownImageCache {
  private pixels: Map<string, PixelMap> = new Map<string, PixelMap>();
  private failures: Map<string, string> = new Map<string, string>();
  private pending: Map<string, boolean> = new Map<string, boolean>();

  has(key: string): boolean {
    return this.pixels.has(key);
  }

  /** 调用方先用 has() 判过；这里取不到就是逻辑错误，直接抛出去暴露。 */
  pixel(key: string): PixelMap {
    const hit: PixelMap | undefined = this.pixels.get(key);
    if (hit === undefined) {
      throw new Error('image not cached: ' + key);
    }
    return hit;
  }

  errorOf(key: string): string {
    const hit: string | undefined = this.failures.get(key);
    return hit === undefined ? '' : hit;
  }

  isPending(key: string): boolean {
    return this.pending.has(key);
  }

  markPending(key: string): void {
    this.pending.set(key, true);
  }

  put(key: string, pixel: PixelMap): void {
    this.pending.delete(key);
    this.failures.delete(key);
    this.pixels.set(key, pixel);
    // LRU：一张手机截图解码后约 8~10MB，长会话里不设上限会吃满内存
    while (this.pixels.size > 20) {
      const oldest: string | undefined = this.pixels.keys().next().value;
      if (oldest === undefined || oldest === key) {
        break;
      }
      this.pixels.delete(oldest);
    }
  }

  fail(key: string, reason: string): void {
    this.pending.delete(key);
    this.failures.set(key, reason);
  }

  forget(key: string): void {
    this.pending.delete(key);
    this.failures.delete(key);
    this.pixels.delete(key);
  }
}

/** 本地图片以 data URI 交给 Image / 预览层，省掉一次 PixelMap 编解码。 */
function imageDataUri(base64: string): string {
  return base64.startsWith('data:') ? base64 : 'data:image/jpeg;base64,' + base64;
}

function isRemoteImage(src: string): boolean {
  return src.startsWith('http://') || src.startsWith('https://') || src.startsWith('data:');
}

/** base64 → PixelMap；主机 readBytes 给的是标准 base64。 */
function decodeBase64Image(base64: string): Promise<PixelMap> {
  const bytes: Uint8Array = new util.Base64Helper().decodeSync(base64);
  const source: image.ImageSource = image.createImageSource(bytes.buffer as ArrayBuffer);
  return source.createPixelMap();
}

/** 服务器切换面板的一行。 */
class ServerChoice {
  url: string = '';
  /** 显示用的短账号（截断过）。 */
  account: string = '';
  /** 完整账号，用来判定「是不是当前这条」。 */
  accountFull: string = '';
  label: string = '';
  host: string = '';
  active: boolean = false;
  profile: SavedProfile | undefined = undefined;
}

/** 设置面板里的一项主题选择。 */
class ThemeChoice {
  value: number = 0;
  label: string = '';
  hint: string = '';

  constructor(value: number, label: string, hint: string) {
    this.value = value;
    this.label = label;
    this.hint = hint;
  }
}

/** 一行可直接渲染的 Markdown 内容。 */
/** 只取时分，用于消息操作面板这类小地方。 */
/** 把 markdown 里所有 ``` 代码块内容拼出来（不含围栏），没有就返回空串。 */
function extractCodeBlocks(text: string): string {
  const out: string[] = [];
  const lines: string[] = text.split('\n');
  let inside: boolean = false;
  let buffer: string[] = [];
  for (const line of lines) {
    if (line.trimStart().startsWith('```')) {
      if (inside) {
        out.push(buffer.join('\n'));
        buffer = [];
      }
      inside = !inside;
      continue;
    }
    if (inside) {
      buffer.push(line);
    }
  }
  return out.join('\n\n');
}

/** 两个时间戳是否同一天。 */
function sameDay(a: number, b: number): boolean {
  const da: Date = new Date(a);
  const db: Date = new Date(b);
  return da.getFullYear() === db.getFullYear()
    && da.getMonth() === db.getMonth()
    && da.getDate() === db.getDate();
}

/** 日期分隔文案：今天 / 昨天 / M月d日。 */
function dayDividerLabel(timestamp: number, english: boolean): string {
  if (timestamp <= 0) {
    return '';
  }
  const target: Date = new Date(timestamp);
  const now: Date = new Date();
  const sameAsToday: boolean = sameDay(timestamp, now.getTime());
  const yesterday: Date = new Date(now.getTime() - 86400000);
  const sameAsYesterday: boolean = sameDay(timestamp, yesterday.getTime());
  if (sameAsToday) {
    return english ? 'Today' : '今天';
  }
  if (sameAsYesterday) {
    return english ? 'Yesterday' : '昨天';
  }
  const month: number = target.getMonth() + 1;
  const day: number = target.getDate();
  return english ? `${month}/${day}` : `${month}月${day}日`;
}

/** 取工作区路径的末段，作为会话行的目录提示。 */
function cwdTail(cwd: string): string {
  if (cwd.length === 0) {
    return '';
  }
  const trimmed: string = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
  const cut: number = trimmed.lastIndexOf('/');
  return cut >= 0 ? trimmed.substring(cut + 1) : trimmed;
}

/** 文件大小文案：留一位小数，KB 以下按 B 显示。 */
function sizeLabel(bytes: number): string {
  if (bytes <= 0) {
    return '';
  }
  if (bytes < 1024) {
    return bytes + ' B';
  }
  if (bytes < 1024 * 1024) {
    return Math.round(bytes / 102.4) / 10 + ' KB';
  }
  return Math.round(bytes / 1024 / 102.4) / 10 + ' MB';
}

function waitLabel(since: number, english: boolean): string {
  if (since <= 0) {
    return '';
  }
  const minutes: number = Math.floor((Date.now() - since) / 60000);
  if (minutes < 1) {
    return english ? 'just arrived' : '刚刚到达';
  }
  if (minutes < 60) {
    return (english ? 'waiting ' : '已等待 ') + minutes + (english ? ' min' : ' 分钟');
  }
  const hours: number = Math.floor(minutes / 60);
  const rest: number = minutes % 60;
  return (english ? 'waiting ' : '已等待 ') + hours + (english ? 'h ' : ' 小时 ') + rest
    + (english ? ' min' : ' 分钟');
}

/** 等太久（10 分钟以上）就提醒一句主机可能已经超时。 */
function waitLooksStale(since: number): boolean {
  return since > 0 && Date.now() - since > 10 * 60 * 1000;
}

/** 只到天的日期：会员到期日这类文案用。 */
function formatDateOnly(timestamp: number): string {
  if (timestamp <= 0) {
    return '';
  }
  const date: Date = new Date(timestamp);
  const month: string = date.getMonth() + 1 < 10 ? '0' + (date.getMonth() + 1) : '' + (date.getMonth() + 1);
  const day: string = date.getDate() < 10 ? '0' + date.getDate() : '' + date.getDate();
  return date.getFullYear() + '-' + month + '-' + day;
}

function formatClock(timestamp: number): string {
  if (timestamp <= 0) {
    return '';
  }
  const date: Date = new Date(timestamp);
  const hh: string = date.getHours() < 10 ? '0' + date.getHours() : '' + date.getHours();
  const mm: string = date.getMinutes() < 10 ? '0' + date.getMinutes() : '' + date.getMinutes();
  return hh + ':' + mm;
}

class TerminalBridge {
  onData: (data: string) => void = () => {};
  onReady: () => void = () => {};

  onTerminalData(data: string): void {
    this.onData(data);
  }

  onTerminalReady(): void {
    this.onReady();
  }
}

class MdLine {
  text: string = '';
  code: boolean = false;
  heading: boolean = false;
  bullet: boolean = false;
  /** 非空表示这一行是图片，值是 markdown 里的 src。 */
  imageSrc: string = '';
  imageAlt: string = '';
  /** 非空表示这一行整行就是一个链接。 */
  linkUrl: string = '';
  /** 非空表示这一段是整块代码（不再逐行切成小块）。 */
  codeLines: string[] = [];
  /** 代码块语言标注（```bash 里的 bash），没有就是空串。 */
  codeLang: string = '';
  /** 非空表示这一块是 GFM 表格：表头 + 数据行（每行是单元格文本）。 */
  tableHeader: string[] = [];
  tableRows: string[][] = [];
}

/** 一行里切出来的片段：要么是文字，要么是一张图。 */
class MdSegment {
  text: string = '';
  imageSrc: string = '';
  imageAlt: string = '';
  isImage: boolean = false;
}

/** 预览拖动的基准倍数：这个放大倍数下 1:1 的手感已被确认舒服。 */
const PREVIEW_PAN_REFERENCE_SCALE: number = 1.5;
/** 放大后拖动速度的上限倍数，避免高倍时过于灵敏。 */
const PREVIEW_PAN_MAX_GAIN: number = 4;

/** 把行内代码的占位符还原回原文（这些片段已排除在图片解析之外）。 */
function restoreCodeSpans(text: string, spans: string[]): string {
  let out: string = text;
  for (let i = 0; i < spans.length; i += 1) {
    out = out.split('\u0001' + String(i) + '\u0001').join(spans[i]);
  }
  return out;
}

/** 把一行里的 ![](src) 逐个切出来，其余当文字。 */
function splitMdImages(body: string): MdSegment[] {
  const out: MdSegment[] = [];
  let cursor: number = 0;
  while (cursor < body.length) {
    const start: number = body.indexOf('![', cursor);
    if (start < 0) {
      break;
    }
    const labelEnd: number = body.indexOf('](', start + 2);
    if (labelEnd < 0) {
      break;
    }
    const urlEnd: number = body.indexOf(')', labelEnd + 2);
    if (urlEnd < 0) {
      break;
    }
    const src: string = body.substring(labelEnd + 2, urlEnd).trim();
    if (src.length === 0) {
      cursor = urlEnd + 1;
      continue;
    }
    const before: string = body.substring(cursor, start).trim();
    if (before.length > 0) {
      const textSeg: MdSegment = new MdSegment();
      textSeg.text = before;
      out.push(textSeg);
    }
    const imageSeg: MdSegment = new MdSegment();
    imageSeg.isImage = true;
    imageSeg.imageSrc = src;
    imageSeg.imageAlt = body.substring(start + 2, labelEnd).trim();
    out.push(imageSeg);
    cursor = urlEnd + 1;
  }
  const rest: string = body.substring(cursor).trim();
  if (rest.length > 0) {
    const textSeg: MdSegment = new MdSegment();
    textSeg.text = rest;
    out.push(textSeg);
  }
  return out;
}

/** 把 Markdown 拆成可渲染的行，并去掉会裸露的标记符号。 */
function markdownLines(source: string): MdLine[] {
  const out: MdLine[] = [];
  const raw: string[] = source.split(String.fromCharCode(10));
  let inCode: boolean = false;
  let codeLang: string = '';
  let codeBuffer: string[] = [];
  for (const original of raw) {
    const line: string = original.trimEnd();
    if (line.trim().startsWith('```')) {
      if (inCode) {
        // 收尾：把缓冲的代码行合成一个整块，保留缩进（不再 trimStart）
        if (codeBuffer.length > 0) {
          const block: MdLine = new MdLine();
          block.codeLines = codeBuffer.slice();
          block.codeLang = codeLang;
          out.push(block);
        }
        codeBuffer = [];
        codeLang = '';
        inCode = false;
      } else {
        inCode = true;
        codeLang = line.trim().substring(3).trim();
      }
      continue;
    }
    if (inCode) {
      codeBuffer.push(original);
      continue;
    }
    if (line.trim().length === 0) {
      continue;
    }
    // GFM 表格：连续的 | 行合成一张表，第二行是 ---|--- 分隔行
    if (line.trim().startsWith('|') && line.indexOf('|', line.indexOf('|') + 1) > 0) {
      const rows: string[][] = [];
      let cursor: number = raw.indexOf(original);
      while (cursor < raw.length) {
        const candidate: string = raw[cursor].trim();
        if (!candidate.startsWith('|')) {
          break;
        }
        const cells: string[] = [];
        for (const cell of candidate.split('|')) {
          cells.push(cell.trim());
        }
        // 首尾一定是空串（行首/行尾的竖线），去掉
        if (cells.length > 0 && cells[0].length === 0) {
          cells.shift();
        }
        if (cells.length > 0 && cells[cells.length - 1].length === 0) {
          cells.pop();
        }
        rows.push(cells);
        cursor += 1;
      }
      // 至少要表头 + 分隔行
      if (rows.length >= 2) {
        let dataStart: number = 1;
        const separator: string = rows[1].join('');
        if (/^[-: ]+$/.test(separator)) {
          dataStart = 2;
        }
        const table: MdLine = new MdLine();
        table.tableHeader = rows[0];
        for (let i = dataStart; i < rows.length; i++) {
          table.tableRows.push(rows[i]);
        }
        out.push(table);
        // 跳过已经吃掉的表格行
        for (let i = 0; i < cursor - 1; i++) {
          raw.shift();
        }
        continue;
      }
    }
    const entry: MdLine = new MdLine();
    let body: string = line.trim();
    if (body.startsWith('### ')) {
      entry.heading = true;
      body = body.substring(4);
    } else if (body.startsWith('## ')) {
      entry.heading = true;
      body = body.substring(3);
    } else if (body.startsWith('# ')) {
      entry.heading = true;
      body = body.substring(2);
    } else if (body.startsWith('- ') || body.startsWith('* ')) {
      entry.bullet = true;
      body = body.substring(2);
    }
    // 行内代码里的字面量不是 Markdown：先摘出来，否则 `![](/x.png)` 会被当成图片去主机取文件。
    const codeSpans: string[] = [];
    body = body.replace(/`([^`]*)`/g, (match: string, inner: string) => {
      codeSpans.push(inner);
      return '\u0001' + String(codeSpans.length - 1) + '\u0001';
    });
    body = body.split('`').join('');
    body = body.split('**').join('');
    body = body.split('__').join('');
    // 图片单独出行：文字段沿用当前标记（标题/列表），图片段单独成行
    const segments: MdSegment[] = splitMdImages(body);
    if (segments.length === 0) {
      continue;
    }
    for (const segment of segments) {
      if (segment.isImage) {
        const imageLine: MdLine = new MdLine();
        imageLine.imageSrc = segment.imageSrc;
        imageLine.imageAlt = segment.imageAlt;
        out.push(imageLine);
        continue;
      }
      const textLine: MdLine = new MdLine();
      textLine.heading = entry.heading;
      textLine.bullet = entry.bullet;
      // 整行 [文字](url) → 可点击；行内链接降级成「文字（url）」，避免裸露 markdown
      const wholeLink: RegExpMatchArray | null = segment.text.match(/^\[([^\]]+)\]\(([^)\s]+)\)$/);
      if (wholeLink !== null) {
        textLine.linkUrl = wholeLink[2];
        textLine.text = wholeLink[1];
      } else {
        textLine.text = segment.text.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g,
          (match: string, label: string, url: string) => `${label}（${url}）`);
      }
      textLine.text = restoreCodeSpans(textLine.text, codeSpans);
      if (textLine.text.length > 0) {
        out.push(textLine);
      }
    }
  }
  return out;
}
