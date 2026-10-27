# kremote.koplugin

用手机浏览器遥控 [KOReader](https://github.com/koreader/koreader) 的插件：在 Kindle 上起一个极简 HTTP 服务，手机连同一个 Wi-Fi，打开网页就能翻页、切章节、调字号、调前光、切夜间模式，并实时看到书名、页码、百分比和电量。

不碰蓝牙、不碰内核、不需要 root，只用一个 Lua 写的非阻塞 HTTP 服务。

![遥控面板](docs/panel.png)

## 为什么不是蓝牙

Kindle 的蓝牙栈只注册了 A2DP/HFP 音频 profile，没有 SPP 串口服务，也没有 BLE GATT server。要收自定义指令就得自己搬一套蓝牙协议栈接管系统蓝牙（约 20MB，且有变砖风险）。相比之下 Wi-Fi 方案零风险，还能双向通信——手机能读回 Kindle 的状态，这是单向蓝牙信号做不到的。

没有路由器也没关系：手机开热点、Kindle 连热点，就是一个私有局域网。

## 功能

**已实现**

| 分组 | 能力 |
|---|---|
| 翻页 | 上一页 / 下一页（EPUB 和 PDF 都有效） |
| 章节 | 上一章 / 下一章 |
| 排版 | 字号 + / − |
| 显示 | 夜间模式、强制全刷 |
| 前光 | 0–24 档亮度滑杆，支持左右步进键 |
| 状态 | 书名、作者、当前页/总页、百分比、电量、充电态、亮度档位，每 2 秒自动刷新 |
| 系统 | 重启 KOReader、退出 KOReader |
| 菜单 | 启动/停止服务、显示访问地址、开机自动启动 |

**做不到的**

- **音量、朗读**：设备没有扬声器（能读到音频设备不代表能发声）
- **实时屏幕镜像**：e-ink 每次全刷 1 秒以上，当第二块显示器不现实
- **依赖屏幕坐标的操作**：选中文字、手写批注、点具体某个菜单按钮。这类操作本质是"在某个像素位置点一下"，坐标随排版和字体会变，没法可靠映射

## 兼容性

在 **Kindle Basic 3（代号 rex，固件 5.18.1.1.1，KOReader v2026.07.1）** 上开发和实测。

需要：

- KOReader 自带 LuaSocket（官方发行版都有，`common/socket.lua` + `common/socket/`）
- 没有前光的机型也能用，只是亮度那一行会自动隐藏

## 安装

把整个目录放到 KOReader 的 `plugins/` 下，目录名必须保持 `kremote.koplugin`：

```bash
# 方式一：直接在设备上 clone（需先在 KOReader 里启动 SSH 或终端）
cd /mnt/us/koreader/plugins
git clone https://github.com/FightingJoey/kremote.koplugin.git

# 方式二：电脑上下载后拷贝（USB 或 scp）
scp -r kremote.koplugin root@<kindle-ip>:/mnt/us/koreader/plugins/
```

放好之后**重启 KOReader**（插件只在启动时加载），然后打开一本书，进菜单 **工具 → 手机遥控 → 启动遥控服务**，屏幕上会显示访问地址。

建议顺手勾上「打开 KOReader 时自动启动」。

> **macOS 用户注意**：用 Finder 拖拽到 Kindle（FAT32）会生成 `._*` 和 `.__*` 的 AppleDouble 文件。这些文件会让某些插件加载失败，装完记得在设备上清理：`find /mnt/us/koreader/plugins/kremote.koplugin -name "._*" -delete`。

## 使用

手机连同一个 Wi-Fi，浏览器打开 `http://<Kindle的IP>:18080`。

**重要：Kindle 的 `iptables` INPUT 默认策略是 `DROP`**，出厂只放行 SSH 的 2222 端口。所以任何新端口的服务即使正常监听，外部也连不上——本机 `127.0.0.1` 却完全正常，非常容易误判成"插件没加载"。

插件会在启动服务时自动补一条放行规则（幂等，已有则跳过）：

```bash
iptables -I INPUT 1 -i wlan0 -p tcp --dport 18080 -m conntrack --ctstate NEW -j ACCEPT
```

停止服务时只删除**自己加的**那条，不会误删别的规则。Kindle 重启或 Wi-Fi 重连后规则可能被系统重刷，插件会在 KOReader 唤醒时再补一次。

## HTTP API

面板就是用这些接口拼出来的，你也可以自己写脚本或快捷指令调用。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 手机控制面板（HTML） |
| GET | `/api/status` | 当前状态 JSON |
| GET | `/api/next` | 下一页 |
| GET | `/api/prev` | 上一页 |
| GET | `/api/chapter_next` | 下一章 |
| GET | `/api/chapter_prev` | 上一章 |
| GET | `/api/font_inc` | 字号 +1 |
| GET | `/api/font_dec` | 字号 −1 |
| GET | `/api/night` | 切换夜间模式 |
| GET | `/api/refresh` | 强制全刷 |
| GET | `/api/light?n=12` | 设置前光档位（0–24，超范围自动夹取） |
| GET | `/api/restart` | 重启 KOReader |
| GET | `/api/quit` | 退出 KOReader |

`/api/status` 返回示例：

```json
{"ok":1,"title":"书名","authors":"作者","page":2358,"pages":6935,
 "percent":34.0,"battery":49,"charging":0,"night":0,"light":12,"lightmax":24}
```

**状态码**：`200` 成功；`404` 未知路径；`409` 该动作需要先打开一本书（书架上点翻页会走到这里）；`500` 动作执行出错，响应体带 `error` 字段。

退出码：动作用 `200` 表示"已派发"，不代表 UI 已经完成渲染。

## 实现要点

- **非阻塞 HTTP**：`httpcore.lua` 自己实现的最小 HTTP/1.1 解析器，`accept`/`recv` 全部非阻塞，由 `UIManager:scheduleIn(0.15, ...)` 驱动，不占 UI 线程。参考了 KOReader 自带的 `simpletcpserver.lua` 的做法。
- **翻页**走 `GotoViewRel` 事件，和官方自动翻页插件 `autoturn` 用的是同一行调用，`ReaderRolling` 和 `ReaderPaging` 都实现了它，所以 EPUB 和 PDF 通用。
- **亮度**走 `Device:getPowerDevice():setIntensity(n)`，不直接写 `/sys/class/backlight`。直接写 sysfs 会让 KOReader 记录的档位和硬件实际值脱节，下次它恢复亮度时会把你的设置覆盖掉。
- **常驻插件**：没有设 `is_doc_only = true`，所以书架和阅读界面各会加载一份实例。两份实例通过模块级的 `SERVER` 表共享同一个服务，避免重复 `bind` 端口。动作按"当前是否有打开的文档"派发。
- **不干预自动休眠**：不设置 `PluginShare.pause_auto_suspend`。Kindle 按自己的 30 分钟超时休眠，省电。但手机发来的**动作**（翻页、调亮度等）会计为一次用户操作，重置 AutoSuspend 的计时——否则你正用手机连续翻页，手指没碰屏幕，设备会中途睡过去。**纯 `/api/status` 轮询不算**，所以放下手机 30 分钟照样休眠。
- **重启**不调用 `UIManager:restartKOReader()`。那实质是 `quit(85)`，依赖启动脚本看到 85 后重新拉起，而 Kindle 的 `koreader.sh` 末尾是 `exit ${RETURN_VALUE}`，没有这个循环——所以官方那条路在 Kindle 上只会退出。插件改成退出后由后台 shell 用 `kpm launch` 重新拉起。

## 测试

`tests/` 下是开发时用的设备端验证脚本，需要拷贝到设备上，用 KOReader 自带的 luajit 跑：

```bash
# HTTP 层：状态码、Content-Length、连续请求不粘包
/mnt/us/koreader/luajit tests/test_httpcore.lua

# 插件链路：mock 掉 KOReader 的 UI 层，验证状态采集、路由分派、事件名
/mnt/us/koreader/luajit tests/test_plugin.lua

# IP 探测
/mnt/us/koreader/luajit tests/test_ip.lua
```

`tests/panel_preview.html` 是面板的本地预览版，内置假数据，改 UI 时可以直接在电脑浏览器里看效果，不用反复传设备。

裸跑 `luajit` 没有 KOReader 的 `package.path`，所以脚本开头要 `require("setupkoenv")`。

## 已知限制

- **无鉴权**。同一 Wi-Fi 下任何人知道 IP 就能翻你的书。自己家里用没问题，公共网络下建议改成手动启动而不是自动启动。要加 token 鉴权的话，改动很小。
- **休眠后连不上**。Kindle 休眠会断 Wi-Fi，碰一下设备唤醒即可，服务会跟着进程一起回来（`onResume` 会补防火墙规则）。这条路径在真实休眠/唤醒循环下的表现还没做过严格验证。
- **只覆盖 KOReader**。原生阅读器界面不归它管。

## 卸载

删掉整个 `kremote.koplugin` 目录，重启 KOReader。插件不写系统文件、不改配置，删完就干净了（`settings.reader.lua` 里可能留下一个 `kremote_auto` 键，无副作用）。

## License

[MIT](LICENSE)
