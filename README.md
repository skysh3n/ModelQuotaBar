# 大模型额度 · ModelQuotaBar

一个 macOS 桌面小组件，用来盯着你买的大模型套餐/余额还剩多少。

目前适配 **通义千问 Token Plan（个人版）** 和 **DeepSeek 开放平台余额**。千问显示 5 小时 / 每周 / 每月窗口的剩余比例、重置时间、套餐到期天数；DeepSeek 显示充值余额。架构按「多厂商」设计，后续加别家只需新增一个 Provider，不用动界面。

> 简体中文优先。界面文案、错误提示都是中文。

## 功能

- **桌面小组件**：小尺寸显示主窗口剩余百分比或账户余额，中尺寸额外列出其余窗口。
- **主应用**：额度明细、凭据配置、小组件展示方式。
- **实时刷新**：每个来源按自己的节奏轮询（DeepSeek 余额接口轻，约 5 秒一轮；千问走控制台网关，5 分钟一轮），回到前台或系统唤醒时立即刷新；**关掉主窗口后仍在后台刷新**，桌面小组件跟着更新。
- **多厂商架构**：`QuotaProvider` 协议 + 自动生成的配置表单，接新厂商不用改 UI。
- **凭据本地保存**：Cookie / API Key 存在 `~/Library/Application Support/ModelQuotaBar/credentials.json`，权限位 0600。
- **零额外能力依赖**：不需要 App Group、不需要登录 Apple 开发者网站，Xcode 里选一次团队就能构建。

## 系统要求

- macOS 14 (Sonoma) 或更高
- 构建需要 Xcode，并且需要在 Xcode 里登录一个 **Apple ID（免费的就行）** 用于签名
- 本仓库只发源码：面向愿意自己构建的使用者。要给不懂 Xcode 的人用，见「已知限制」。

## 构建与安装

```bash
git clone https://github.com/skysh3n/ModelQuotaBar.git
cd ModelQuotaBar
open ModelQuotaBar.xcodeproj
```

在 Xcode 里：

1. 用 Apple ID 登录 Xcode（免费即可）：`Xcode → Settings… → Accounts → +`。
2. 左侧选中 **ModelQuotaBar** 工程 → **TARGETS** 下的 `ModelQuotaBar` → **Signing & Capabilities** → **Team** 选上你的账号。
3. 对 `QuotaWidget` target 做同样的操作。两个 target 能签名即可，**不需要 App Group 之类的额外能力**。
4. 直接按 ⌘R 运行。

命令行构建：

```bash
TEAM_ID=你的TeamID ./scripts/build.sh
cp -R dist/ModelQuotaBar.app /Applications/
```

> **iCloud 同步目录的坑。** 如果仓库放在「桌面」「文档」这类开了 iCloud 同步的目录里，FileProvider 会给构建产物附加扩展属性，`codesign` 会报 `resource fork, Finder information, or similar detritus not allowed`。脚本默认把构建目录放到仓库外（`~/Library/Caches/ModelQuotaBar/`）来避开；若仍遇到，把仓库移到不同步的目录即可。

### 为什么必须签名

WidgetKit 扩展只有在带**有效代码签名**时才会被系统加载；未签名或 ad-hoc 签名的扩展会被 `pluginkit` 静默忽略，小组件库里根本搜不到。免费 Apple ID 登录后 Xcode 生成的证书就够自己用。

### 数据怎么从主应用流到小组件

小组件扩展必须带沙盒权限（没有它系统不加载），而沙盒应用只能读自己的容器；主应用则刻意**不开沙盒**，于是可以直接写进小组件的容器目录：

```
~/Library/Containers/com.skysh3n.ModelQuotaBar.widget/Data/Library/Application Support/ModelQuotaBar/
```

主应用每次刷新后把额度快照写进这个目录并通知系统重画小组件，小组件只读不写。这样就不需要 App Group——App Group 是受限权限，用了就必须有 provisioning profile，也就必须登录 Apple ID 并让 Xcode 联网生成 profile，对「clone 下来自己构建」的使用者门槛太高。

注意：改 `QuotaWidget` 的 bundle ID 时，要同步改 `Sources/QuotaCore/SharedStore.swift` 里的 `widgetBundleIdentifier`，共享目录就是从它推出来的。

## 配置：拿到控制台 Cookie

百炼**没有**开放查询套餐用量的 OpenAPI，所以只能复用控制台自己的接口，需要你提供登录态 Cookie。

1. 打开 <https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal> 并登录。
2. 按 `F12` 打开开发者工具 → **Network** 标签 → 刷新页面。
3. 在请求列表里找任意一个发往 `bailian-cs.console.aliyun.com` 的请求，点开 → **Request Headers** → 找到 `Cookie`。
4. 把 `login_aliyunid_ticket` 的**值**复制出来（只复制值就行，整段 Cookie 也能用）。
5. 在「大模型额度」的「额度来源 → 通义千问 Token Plan」里粘贴，站点选「中国大陆站」，点「测试连接」。

会话通常几周后过期。过期后重复上面步骤换一条即可，主应用会提示「登录会话已失效」。

## 配置：DeepSeek 余额

DeepSeek 有公开的余额接口，配置简单：

1. 打开 <https://platform.deepseek.com/> 登录。
2. 右上角「API 密钥」里创建或复制一个 `sk-…` Key。
3. 在「大模型额度」的「额度来源 → DeepSeek」里粘贴，点「测试连接」。

余额每 5 秒左右自动刷新一次，你在别处跑 DeepSeek API 消耗余额时，桌面小组件会跟着掉。

## 把小组件放到桌面

在桌面空白处**右键 → 编辑小组件**，搜索「大模型额度」，把小尺寸或中尺寸拖到桌面。

小组件的刷新由系统调度，主应用每次刷新后会主动通知它重画。若长时间没变化，打开主应用点一次「刷新」。

## 关于凭据存储

Cookie 等价于你的阿里云登录态，本来最该放钥匙串。但这个项目是由使用者各自本地构建、各用自己的证书签名的，而**钥匙串按代码签名识别调用方**——每次重新编译签名都会变，macOS 会把程序当成另一个应用，于是每次启动都弹一次系统密码框。为了避开这个交互，凭据改为存成文件：

```
~/Library/Application Support/ModelQuotaBar/credentials.json
```

权限位收成 `0600`，只有属主可读写。这比钥匙串弱一档（同一用户账号下的进程仍可读），对一个只用来看自己套餐余量的工具是划算的折中。如果你不接受，可以改回 `SecItem*` 接口，代价是每次重新编译都要重新授权。

## 已知限制

- **只面向愿意自己构建的使用者**。WidgetKit 扩展必须由 Apple 签发的证书签名才会被系统加载；要把「双击就能用」的 .dmg 发给普通用户，需要付费 Apple Developer Program（$99/年）的 Developer ID 证书并做公证。本项目不打算付这笔钱，所以只发源码。
- **只支持 Token Plan 个人版**。团队版走的是另一套 BSS 接口，尚未支持。
- **不支持 Coding Plan**。它是按请求次数计费的另一条产品线。
- **不显示 token 消耗**。官方明确不提供该数据，套餐只按 Credits 抵扣。
- 用量接口是控制台内部接口，阿里云改动接口时可能失效。失效时错误提示会尽量说明原因。
- **「实时」靠轮询，不是服务端推送**：服务端没有推送能力，DeepSeek 每 5 秒轮询一次是逼近实时的唯一手段；关掉主窗口后进程仍在后台刷新，但退出（⌘Q）后小组件会停在最后一次数据。
- **DeepSeek 显示的是充值余额**，不是按时间窗口的配额，所以没有百分比和重置时间。
- 小组件不能自己发网络请求（沙盒 + 刷新预算限制），数据永远由主应用抓取后写入共享目录，所以主应用得保持运行。

## 新增一个厂商

1. 在 `Sources/QuotaCore/Providers/` 下新建目录，实现 `QuotaProvider`：

   ```swift
   public enum YourProvider: QuotaProvider {
       public static let metadata = ProviderMetadata(
           id: ProviderID("your-provider"),
           vendor: "厂商名",
           plan: "套餐名",
           summary: "一句话说明查的是什么",
           consoleURL: URL(string: "https://…"))

       public static let credentialFields: [CredentialField] = [
           CredentialField(id: "apiKey", title: "API Key", kind: .secret),
       ]

       public static func fetchSnapshot(credential: ProviderCredential) async throws -> QuotaSnapshot {
           // 返回 QuotaSnapshot，窗口用 QuotaWindow 表达
       }
   }
   ```

2. 在 `Sources/QuotaCore/ProviderRegistry.swift` 的 `all` 里加一行 `YourProvider.descriptor`。
3. 在 `Tests/QuotaCoreTests/` 补一组解析测试，用真实的响应结构。

界面不用改：设置表单由 `credentialFields` 生成，额度卡片直接渲染 `QuotaSnapshot`。

## 开发

```bash
./scripts/test.sh                    # 编译并运行单元测试
TEAM_ID=你的TeamID ./scripts/build.sh  # 用你的证书签名构建 .app
NO_SIGN=1 ./scripts/build.sh         # 只验证能否编译（产物的小组件不会被系统加载）
```

测试不依赖 XCTest，用的是 `Tests/QuotaCoreTests/TestSupport.swift` 里自带的小型执行器。这样做是因为只装 Command Line Tools 的机器上既没有 `XCTest.framework` 也没有 `xcrun xctest`，而本项目希望在任何 Mac 上都能跑测试。

## 项目结构

```
ModelQuotaBar.xcodeproj/      Xcode 工程（两个 target）
App/                          主应用：窗口界面、配置、后台刷新（不开沙盒）
Widget/                       WidgetKit 小组件扩展（只带沙盒权限）
Sources/QuotaCore/            与界面无关的核心：模型、Provider 协议、网关客户端、共享存储
Tests/QuotaCoreTests/         单元测试
scripts/                      构建、测试与图标生成脚本
```

`Sources/QuotaCore` 被两个 target 各自直接编译进自己的模块，而不是做成 framework——小组件扩展依赖 framework 需要在工程里做嵌入，收益不大。

## 免责声明

本项目通过非公开的控制台接口读取你自己的套餐用量，用途是方便自己看余额。请仅查询自己账号的数据，不要用于批量抓取或转发给第三方。接口由阿里云控制，可能随时变更。

## License

MIT，见 [LICENSE](LICENSE)。