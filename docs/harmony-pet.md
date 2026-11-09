# 桌宠（鲸娘）接入说明

> 适用于鸿蒙客户端 `0.17.119+`。桌宠素材**不在仓库里**，见文末「授权与分发」。
> 手机端：会话右下角；点一下说话，双击炸屏，待命 3 分钟会睡着。

## 素材包格式

沿用 dsh-go 的宠物包（`pack.json` + 横向精灵图）：

```
resources/rawfile/pets/whale-girl/
├─ pack.json
├─ idle.png        # 13 帧，52×49
├─ typing.png      # 14 帧，53×57
├─ thinking.png    # 17 帧，55×60
├─ happy.png       # 11 帧，59×55
└─ sleeping.png    # 见 pack.json
```

`pack.json` 里每段动画的字段：

| 字段 | 含义 |
|---|---|
| `sheet` | 精灵图文件名 |
| `frameW` / `frameH` | 单帧宽高（像素） |
| `cols` | 一行有几帧 |
| `frames[]` | `{ i: 列序号, ms: 停留毫秒 }`，可以重复播某几帧做小动作 |

客户端只解码实际用到的几段（`idle/typing/thinking/happy/sleeping`），其余不加载，省内存。

## 状态映射

| 会话状态 | 动画 |
|---|---|
| 正在生成 | `typing` |
| 等你确认（审批/问答） | `thinking` |
| 刚做完（4 秒内） | `happy` |
| 待命超过 3 分钟 | `sleeping` |
| 其它 | `idle` |

- 渲染：外层 `Stack` 裁切，内层整张精灵图按 `-帧序号 × 帧宽` 横向偏移；
- 缩放：`PET_SCALE = 1.2`，像素风用 `ImageInterpolation.None` 保持锐利；
- 播放：`setTimeout` 链按 `frames[].ms` 逐帧推进，状态切换时重启动画；
- 位置：右下角浮层，`offset` 跟随输入坞高度，输入框长高时自动上移。

## 交互

| 手势 | 行为 |
|---|---|
| 单击 | 按当前状态随机说一句俏皮话（气泡 2.6s 自动收起） |
| 双击 | 炸屏：580ms 放大到覆盖屏幕 → 停 800ms → 680ms 缩回 |
| 长按 | 导出诊断文件（`hdc file recv` 可拉走） |

## 没有素材时

`PetPack.ready()` 为 false，界面自动回退到原来的 emoji 桌宠（🐳/🙋/✨/🌙），
功能（点按提示、长按导诊断）不受影响。

## 授权与分发（重要）

鲸娘 / Deepy 的美术素材版权归 DSH-TUI，**不在 dsh-go 的 AGPL-3.0 范围内**，原作者声明
「以修改版或衍生作品再发布时请换成自己的名称和素材」。

因此本仓库：

- `harmony/entry/src/main/resources/rawfile/pets/` 已加入 `.gitignore`，**不含任何 PNG**；
- 只提交 `PetPack.ets` 这类代码；
- 本机自用的 HAP 可以带素材，但**不要对外分发带素材的安装包**。

要给别人用，请换成自己画的素材，或让使用者自行放入自己的宠物包。
