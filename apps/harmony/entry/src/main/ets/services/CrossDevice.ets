import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { PermissionRequestResult } from '@kit.AbilityKit';
import { logWarn } from '../util/Log';

/**
 * 附近设备：用来判断「跨设备」这一项能不能显示。
 *
 * 鸿蒙这边公开的能力只有「发现同一华为账号下的可信设备」，
 * 相册跨设备读取系统没开放接口；真正能跨设备的是系统相机选择器
 * （2in1 上它会列出附近手机的摄像头）。所以这里的职责只有两个：
 *   1. 申请 DISTRIBUTED_DATASYNC（发现设备要用）；
 *   2. 返回在线设备名，界面据此决定显示/隐藏「用附近设备拍照」。
 */
const PERMISSION: Permissions = 'ohos.permission.DISTRIBUTED_DATASYNC';

export class CrossDevice {
  private static manager: distributedDeviceManager.DeviceManager | undefined = undefined;
  private static denied: boolean = false;

  private static ensureManager(context: common.UIAbilityContext): distributedDeviceManager.DeviceManager | undefined {
    if (CrossDevice.manager !== undefined) {
      return CrossDevice.manager;
    }
    try {
      CrossDevice.manager = distributedDeviceManager.createDeviceManager('cn.r2049.dshremote');
    } catch (error) {
      logWarn('cross device: 创建 DeviceManager 失败');
      return undefined;
    }
    return CrossDevice.manager;
  }

  private static async ensurePermission(context: common.UIAbilityContext): Promise<boolean> {
    if (CrossDevice.denied) {
      return false;
    }
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const state: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, [PERMISSION]);
      const granted: boolean = state.authResults.length > 0 && state.authResults[0] === 0;
      if (!granted) {
        CrossDevice.denied = true;
      }
      return granted;
    } catch (error) {
      CrossDevice.denied = true;
      return false;
    }
  }

  /** 附近在线设备的名字（不含自己）；拿不到就返回空数组。 */
  static async nearbyNames(context: common.UIAbilityContext): Promise<string[]> {
    const granted: boolean = await CrossDevice.ensurePermission(context);
    if (!granted) {
      return [];
    }
    const manager: distributedDeviceManager.DeviceManager | undefined = CrossDevice.ensureManager(context);
    if (manager === undefined) {
      return [];
    }
    try {
      const list: distributedDeviceManager.DeviceBasicInfo[] = manager.getAvailableDeviceListSync();
      const out: string[] = [];
      for (const device of list) {
        if (device.deviceName !== undefined && device.deviceName.length > 0) {
          out.push(device.deviceName);
        }
      }
      return out;
    } catch (error) {
      logWarn('cross device: 取设备列表失败');
      return [];
    }
  }
}
