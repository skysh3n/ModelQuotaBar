# 大模型额度 · ModelQuotaBar

一个 macOS 桌面小组件，用来盯着你买的大模型套餐还剩多少额度。

目前适配 **通义千问 Token Plan（个人版）**，显示 5 小时 / 每周 / 每月三个窗口的剩余比例、重置时间、套餐到期天数。架构按「多厂商」设计，后续加别家套餐只需新增一个 Provider，不用动界面。

> 简体中文优先。界面文案、错误提示都是中文。

## 功能

- **桌面小组件**：小尺寸显示主窗口剩余百分比，中尺寸额外列出其余窗口。
- **主应用**：额度明细、Cookie 配置、刷新间隔、小组件展示方式。
- **多厂商架构**：`QuotaProvider` 协议 + 自动生成的配置表单，接新厂商不用改 UI。
- **凭据存钥匙串**：Cookie 等价于登录态，只进 Keychain，不落 UserDefaults、不写文件、不同步 iCloud。

## 系统要求

- macOS 14 (Sonoma) 或更高
- 构建需要 Xcode（小组件扩展必须由系统认可的签名加载）
- 运行**不需要**开发者账号：用 Xcode 免费 Apple ID 生成的证书即可

## 构建与安装

```bash
git clone https://github.com/skysh3n/ModelQuotaBar.git
cd ModelQuotaBar
open ModelQuotaBar.xcodeproj
```

在 Xcode 里：

1. 左侧选中 **ModelQuotaBar** 工程 → **TARGETS** 下的 `ModelQuotaBar` → **Signing & Capabilities** → **Team** 选上你的账号。
2. 对 `QuotaWidget` target 做同样的操作，**两个 target 必须选同一个 Team**（它们靠 App Group 交换数据）。
3. 如果 `App Groups` 那一栏报红，把 `group.com.skysh3n.ModelQuotaBar` 改成你自己的（比如 `group.<你的TeamID>.ModelQuotaBar`），同时改 `Sources/QuotaCore/SharedStore.swift` 里的 `appGroupID`。
4. 直接按 ⌘R 运行。

命令行构建：

```bash
TEAM_ID=你的TeamID ./scripts/build.sh
cp -R dist/ModelQuotaBar.app /Applications/
```

## 配置：拿到控制台 Cookie

百炼**没有**开放查询套餐用量的 OpenAPI，所以只能复用控制台自己的接口，需要你提供登录态 Cookie。

1. 打开 <https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan/personal> 并登录。
2. 按 `F12` 打开开发者工具 → **Network** 标签 → 刷新页面。
3. 在请求列表里找任意一个发往 `bailian-cs.console.aliyun.com` 的请求，点开 → **Request Headers** → 找到 `Cookie`。
4. 把 `login_aliyunid_ticket` 的**值**复制出来（只复制值就行，整段 Cookie 也能用）。
5. 在「大模型额度」的「额度来源 → 通义千问 Token Plan」里粘贴，站点选「中国大陆站」，点「测试连接」。

会话通常几周后过期。过期后重复上面步骤换一条即可，主应用会提示「登录会话已失效」。

## 把小组件放到桌面

在桌面空白处**右键 → 编辑小组件**，搜索「大模型额度」，把小尺寸或中尺寸拖到桌面。

小组件的刷新由系统调度，主应用每次刷新后会主动通知它重画。若长时间没变化，打开主应用点一次「刷新」。

## 已知限制

- **只支持 Token Plan 个人版**。团队版走的是另一套 BSS 接口，尚未支持。
- **不支持 Coding Plan**。它是按请求次数计费的另一条产品线。
- **不显示 token 消耗**。官方明确不提供该数据，套餐只按 Credits 抵扣。
- 用量接口是控制台内部接口，阿里云改动接口时可能失效。失效时错误提示会尽量说明原因。
- 小组件不能自己发网络请求（沙盒 + 刷新预算限制），数据永远由主应用抓取后写入共享容器。

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
./scripts/test.sh     # 编译并运行单元测试
./scripts/build.sh    # 构建 .app
NO_SIGN=1 ./scripts/build.sh   # 只验证能否编译
```

测试不依赖 XCTest，用的是 `Tests/QuotaCoreTests/TestSupport.swift` 里自带的小型执行器。这样做是因为只装 Command Line Tools 的机器上既没有 `XCTest.framework` 也没有 `xcrun xctest`，而本项目希望在任何 Mac 上都能跑测试。

## 项目结构

```
ModelQuotaBar.xcodeproj/      Xcode 工程（两个 target）
App/                          主应用：窗口界面、配置、后台刷新
Widget/                       WidgetKit 小组件扩展
Sources/QuotaCore/            与界面无关的核心：模型、Provider 协议、网关客户端
Tests/QuotaCoreTests/         单元测试
scripts/                      构建与测试脚本
```

`Sources/QuotaCore` 被两个 target 各自直接编译进自己的模块，而不是做成 framework——小组件扩展依赖 framework 需要在工程里做嵌入，收益不大。

## 免责声明

本项目通过非公开的控制台接口读取你自己的套餐用量，用途是方便自己看余额。请仅查询自己账号的数据，不要用于批量抓取或转发给第三方。接口由阿里云控制，可能随时变更。

## License

MIT，见 [LICENSE](LICENSE)。