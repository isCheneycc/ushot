# Codex 执行任务：开发一款原生 macOS 截图应用

你现在是一名资深 macOS 应用工程师、图形编辑器工程师和产品设计工程师。请直接在当前仓库中落地开发，不要只输出方案、伪代码或示例代码。

## 一、工作原则

1. 先检查当前目录、Git 状态、已有工程、已安装 Xcode 与 SDK，再决定如何初始化或修改工程。
2. 如果当前仓库不是空的，必须复用现有结构，禁止无理由重建、覆盖或删除已有代码。
3. 如果当前仓库为空，创建一个可以被 Xcode 正常打开、编译和运行的原生 macOS 工程。
4. 不要因为缺少项目名、图标或签名证书而停下来询问。先使用本文给出的临时默认值，并将它们集中到可替换配置中。
5. 不要停留在架构分析。完成架构文档后立即进入编码，并持续执行：
   - 修改代码；
   - 编译；
   - 运行单元测试；
   - 修复编译错误与测试失败；
   - 再进入下一阶段。
6. 每完成一个阶段，都要保证仓库处于可编译状态。禁止一次性堆积大量未经编译验证的代码。
7. 遇到不确定的 Apple API 可用性时，不要凭记忆猜测。检查本机 macOS SDK、Xcode Quick Help、Swift interface 或头文件，以本机实际 SDK 为准。
8. 只使用公开 API，禁止私有 API、逆向系统组件或依赖未公开的 WindowServer 接口。
9. 第一版优先不引入第三方运行时依赖。可以使用 Apple 原生框架和系统命令。确有必要增加依赖时，先说明原因、许可证、替代方案和影响。
10. 所有截图、编辑和历史数据默认只在本地处理，不上传，不埋点，不加入遥测。
11. 最终不要只告诉我“如何做”，而要汇报实际完成的文件、构建结果、测试结果、运行方式和仍存在的限制。

---

## 二、产品约束

### 平台

- 仅支持 macOS。
- 最低版本：macOS 14 Sonoma。
- 仅支持 Apple Silicon，构建架构为 `arm64`。
- 不支持 Intel Mac，不需要 `x86_64` 或 Universal Binary。
- 不上架 Mac App Store。
- 分发方式：GitHub Releases 提供 `.dmg`；当前无独立官网。
- 项目为开源项目；未来部分新增能力可能采用买断制或订阅制。
- 第一版不接入账号、服务器、支付、订阅、许可证校验或云同步，但架构需要能在未来加入功能授权层。
- 全原生开发，禁止 Electron、Tauri、Flutter、React Native、WebView 主界面或 Vue 混合方案。

### 已确认项目信息

- Product Name：`Ushot`
- Bundle Identifier：`io.github.ischeneycc.ushot`
- Marketing Version：`0.1.0`
- Build Version：`1`
- Deployment Target：`macOS 14.0`
- Architecture：`arm64`
- 默认语言：跟随系统
- 首批本地化：简体中文、英文
- 默认导出格式：PNG
- 开源许可证：`Apache-2.0`；随应用分发自身及第三方许可证文本。

把 Product Name、Bundle ID、版本号等放入 `.xcconfig` 或同等集中配置，后续能够一次性替换。

---

## 三、产品术语

统一采用以下名称，代码、界面、文档中保持一致：

1. **快速标注模式 / Quick Annotation Overlay**
   - 对启用快速标注的截图，图片悬浮在所有普通应用窗口上方；
   - 非区域截图按设置在图片下方显示紧凑工具栏；区域截图在冻结桌面的蓝框确认态直接显示完整的标注与截图输出工具并额外提供 Pin，但不显示仅对置顶图有意义的鼠标穿透、临时隐藏图片和打开完整编辑器，不提前显示裁剪图；复制/保存成功后结束截图，Pin 后则变成默认只读的置顶图并隐藏整条工具栏；
   - 用户不需要先进入完整编辑器即可完成常用标注；
   - 这是原需求中类似 Snipaste 的交互，但不得复制其视觉、图标或布局。

2. **独立画布编辑器 / Canvas Editor**
   - 独立、可调整尺寸的编辑窗口；
   - 具有画布、工具区、上下文属性面板、图层管理和缩放能力；
   - 这是原需求中类似 CleanShot X 面板的能力参考，但必须形成原创信息架构和视觉设计，不得照抄。

3. **置顶截图 / Pinned Shot**
   - 截图以独立浮动面板长期停留在桌面上；
   - 可移动、缩放、拖拽导出、复制、保存、重新编辑和关闭；
   - 允许同时存在多个置顶截图。

---

## 四、第一版明确范围

### 必须完成的截图模式

1. 自由区域截图。
2. 窗口截图，移动鼠标时自动识别并高亮候选窗口。
3. 当前鼠标所在显示器的全屏截图。
4. 指定显示器截图。
5. 全部显示器截图。
6. 多显示器环境下正确工作，包括显示器位于主屏左侧、右侧、上方或下方以及坐标为负数的情况。
7. 尽量支持跨显示器自由区域选择；如果第一轮实现受限，底层几何模型也必须按全局桌面坐标设计，禁止写死为单屏。

### 第一版明确不做

- 滚动长截图。
- 延时截图。
- 录屏。
- GIF 录制。
- OCR。
- 截图翻译。
- 二维码识别。
- AI 能力。
- 自动添加 Mac 窗口外壳、设备模型或仿系统窗口框。

这些能力不要出现在可点击但无实现的正式界面中。可以在能力枚举、协议和路线图中预留，但不要留下会误导用户的空按钮。

---

## 五、默认交互和设置

### 默认开启

- 菜单栏常驻。
- 全局快捷键系统启用。
- 截图完成后显示置顶截图。
- 截图完成后显示底部快速标注工具栏。
- 窗口截图保留窗口阴影。
- 默认颜色空间显示为 sRGB。
- 默认导出 PNG。

### 默认关闭

- Dock 图标。
- 开机启动。
- 自动复制到剪贴板。
- 自动保存到目录。
- 自动进入独立画布编辑器。
- 截图历史。
- 同时保存原图和编辑图。
- 捕获鼠标指针。
- 截图完成后的角落缩略图。
- 网络访问和遥测。

### 默认快捷键

快捷键必须可自定义、可检测冲突、可恢复默认。先使用以下临时默认值，并集中定义，后续可以轻易修改：

- 自由区域截图：`Control + Option + A`
- 窗口截图：`Control + Option + W`
- 当前显示器截图：`Control + Option + F`
- 指定显示器截图：`Control + Option + D`
- 全部显示器截图：`Control + Option + M`
- 取色器：`Control + Option + C`
- 屏幕标尺：`Control + Option + R`

实现全局快捷键时，优先封装 Apple 原生 `RegisterEventHotKey` 能力，隐藏在 `GlobalHotKeyManaging` 协议后。不要使用会监听所有键盘输入的宽泛事件监控作为常规方案。快捷键注册失败时必须保留旧快捷键并提示冲突，不能静默失效。

---

## 六、技术栈

### 必须使用

- Swift。
- SwiftUI：设置页、菜单内容、普通表单、属性面板等。
- AppKit：截图遮罩、跨屏窗口、置顶面板、复杂画布、鼠标事件、拖拽和窗口层级。
- ScreenCaptureKit：
  - `SCShareableContent`
  - `SCContentFilter`
  - `SCScreenshotManager`
  - 为未来取色器实时采样或录屏预留 `SCStream` 抽象。
- Core Graphics：几何、位图、合成、矢量标注渲染。
- Core Image：模糊、马赛克、蒙版和图像效果。
- Image I/O：PNG 编码、元数据和颜色配置写入。
- AppKit `NSColorSpace` / Core Graphics ColorSpace：颜色空间转换。
- ServiceManagement `SMAppService`：开机启动。
- OSLog：结构化日志。
- XCTest：单元测试和必要的集成测试。
- Swift Concurrency：异步截图、图像处理和状态协调。

### 构建约束

- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- `ARCHS = arm64`
- `ONLY_ACTIVE_ARCH` 按 Debug/Release 合理设置。
- 启用 Hardened Runtime。
- 不启用 App Sandbox，除非当前仓库已经有明确且经过验证的 Sandbox 方案。
- 默认以 accessory/menu-bar app 运行，不显示 Dock 图标。
- 支持用户在设置中动态切换 Dock 图标；隐藏 Dock 时使用 `.accessory`，不要使用导致应用不能创建窗口的 activation policy。
- 代码签名 Team 在本地可保持未配置，不能把个人证书信息提交到仓库。

### 依赖原则

- 第一版尽量零第三方运行时依赖。
- 不为了快捷键、菜单栏、图像编辑或颜色转换引入大型库。
- 不引入跨平台 UI 框架。
- 项目生成工具如果必须使用，只能作为开发依赖，并把配置文件一并提交；最终 `.xcodeproj` 或 `.xcworkspace` 必须可直接打开。

---

## 七、建议架构

不要为了“模块化”制造大量只有一个文件的空模块，但需要清晰分层。建议使用一个 Xcode workspace、一个 App target、若干本地 Swift Package 或 framework target：

```text
ScreenshotApp/
├─ App/
│  ├─ ScreenshotApp.swift
│  ├─ AppDelegate.swift
│  ├─ AppEnvironment.swift
│  ├─ AppCommands.swift
│  └─ StatusBarController.swift
├─ Core/
│  ├─ Capture/
│  ├─ Geometry/
│  ├─ ImagePipeline/
│  ├─ Annotation/
│  ├─ ColorManagement/
│  ├─ Export/
│  ├─ History/
│  ├─ HotKeys/
│  ├─ Permissions/
│  ├─ Settings/
│  ├─ FeatureGating/
│  └─ Logging/
├─ Features/
│  ├─ CaptureOverlay/
│  ├─ WindowCapture/
│  ├─ PinnedShot/
│  ├─ QuickAnnotation/
│  ├─ CanvasEditor/
│  ├─ ColorPicker/
│  ├─ ScreenRuler/
│  ├─ History/
│  └─ Settings/
├─ Resources/
│  ├─ Assets.xcassets
│  ├─ Localizable.xcstrings
│  └─ AppIcon.appiconset
├─ Tests/
├─ UITests/
├─ docs/
└─ scripts/
```

关键协议建议：

```swift
protocol ScreenCapturing
protocol FrameStreaming
protocol CapturePermissionChecking
protocol GlobalHotKeyManaging
protocol AnnotationRendering
protocol ImageExporting
protocol ScreenshotHistoryStoring
protocol FeatureEntitlementChecking
protocol UpdateChecking
```

未来收费能力只能通过 `FeatureEntitlementChecking` 或等价能力层进入功能模块，不允许把付费判断散落在截图核心和绘制核心中。第一版默认实现 `OpenSourceEntitlementProvider`，所有已实现功能均可用。

### 捕获状态机

建立明确状态机，防止重复触发和窗口残留：

```text
idle
→ checkingPermission
→ preparingContent
→ selecting（区域截图在 mouse-up 后继续停留，等待复制、保存或 Pin 之一显式提交）
→ capturing
→ presentingPinnedShot
→ quickEditing / canvasEditing
→ exporting
→ idle
```

必须支持取消、异常恢复和重复触发保护。截图会话的准入检查和 `idle → checkingPermission` 转换必须是一个原子操作；已有会话（包括尚未复制、保存或 Pin 的区域确认态）存在时，再次触发任意截图快捷键只能非模态地拒绝并记录日志，不能重置或取消原会话，更不能在高层遮罩背后弹出会独占输入的模态错误框。只有已经获得准入所有权的会话自身发生失败时，才允许它回到可再次截图的稳定状态。

---

## 八、截图核心

### 统一数据模型

建立可扩展的请求和结果模型，不要让每个页面直接调用 ScreenCaptureKit：

```swift
enum CaptureMode {
    case region
    case window
    case currentDisplay
    case selectedDisplay
    case allDisplays

    // 仅预留，不在第一版提供 UI：
    // case delayed
    // case scrolling
    // case recording
    // case gif
}

struct CaptureRequest {
    let mode: CaptureMode
    let showsCursor: Bool
    let includesWindowShadow: Bool
    let excludesOwnApplication: Bool
}

struct CapturedImage {
    let image: CGImage
    let colorSpace: CGColorSpace?
    let pixelSize: CGSize
    let logicalSize: CGSize
    let scale: CGFloat
    let sourceMetadata: CaptureSourceMetadata
}
```

如全部显示器模式需要保留多个原始结果，可设计：

```swift
struct MultiDisplayCaptureResult {
    let composite: CapturedImage
    let displays: [DisplayCapture]
}
```

### 权限

- 首次截图前检查屏幕录制权限。
- 没有权限时显示清晰的原生说明界面，解释用途并提供前往系统设置的操作。
- 权限被拒绝或之后被撤回时，不崩溃、不无限重试。
- 权限变化后支持重新检查。
- 第一版不应要求辅助功能权限；屏幕标尺、取色器、快捷键和普通截图均应在不获取 Accessibility 权限的前提下工作。

### 自由区域截图

建议流程：

1. 在显示遮罩前，获取当前可共享显示器和应用列表。
2. 排除本应用的所有窗口。
3. 先对相关显示器生成冻结快照，并保留按前后顺序排列的 ScreenCaptureKit 窗口信息，再显示选区遮罩，避免把遮罩本身截进去，也避免底层内容在用户选择时变化。鼠标移动时默认吸附最上层窗口；点击接受候选，拖动超过阈值则立即切回普通手动画框。可选的 Accessibility 权限只用于把窗口候选细化到按钮、文本框、侧边栏、面板等内部元素，不得让普通窗口吸附依赖该权限，也不得查询 Ushot 自己的遮罩。
4. 每个显示器创建独立透明无边框遮罩窗口，由一个全局 `CaptureOverlayCoordinator` 协调。
5. 选区使用全局桌面坐标，不能假设主屏原点为唯一原点。
6. mouse-up 后不得立即生成可见的裁剪截图或置顶图；立即进入无窗口动画的确认态并让输入事件返回，裁剪不得阻塞主线程。继续显示冻结桌面的选中像素、外部遮罩和唯一一套可交互的蓝色八点缩放框，但所有全屏冻结遮罩窗口此时必须切换为仅显示且忽略鼠标事件，由透明标注窗口成为唯一输入所有者。八个圆点的中心必须精确落在蓝色边框上，放大的透明命中范围只能位于真实选区之外，不能缩进圆点或改变输出范围；四条完整边线都必须能调整尺寸并显示相应方向光标，不能要求鼠标只命中八个圆点。在选区上方叠放与真实选区完全同框的透明标注层：边线命中由外层缩放框处理，其余内部事件必须明确路由给标注层，不能因 AppKit 翻转坐标系、透明视图命中顺序或全屏遮罩窗口而丢失。在选择工具下拖动空白画布应移动完整截图范围，标注保留画布内坐标并随画布一起移动；该事务必须与边缘缩放明确区分。在附近显示预先准备、可复用的完整标注与截图输出工具栏，在其末尾额外加入 Pin 和取消；鼠标穿透、临时隐藏图片和打开完整编辑器必须等到 Pin 后才显示。内部可以缓存冻结像素用于效果与最终合成，但缓存不是已完成截图。初次确认、每一帧实时拉伸和 mouse-up 提交必须先落到同一个全局桌面整点坐标网格，不能实时显示小数点坐标而仅在松手时取整，否则 Retina 像素相位改变会让静止标注轻微位移或闪动。确认态拖动边线或八点时，透明标注层必须作为原全局桌面文档的 1:1 视口同步更新：边缘变化只能裁切或露出内容，中间帧不得移动、横纵拉伸已有标注及其八点，也不得让横线或竖线的线宽发生变化。mouse-up 后再从原冻结桌面刷新缓存，并将标注文档及撤销/重做历史重定位到最终选区。
7. 完整工具栏中的标注、撤销/重做、颜色和线宽必须直接作用于冻结选区上的透明编辑层。复制或保存成功后才合成输出，并立即关闭遮罩、选区、标注层和工具栏；取消保存面板不得结束确认。Pin 合成同一结果、关闭遮罩并原位进入默认只读的置顶态。取消、复制和保存不得删除或替换已有置顶图。
8. 支持：
   - 拖拽创建选区；
   - 拖动选区；
   - 八方向缩放手柄；
   - `Esc` 取消；
   - 方向键微调 1 point；
   - `Shift + 方向键` 微调 10 points；
   - `Space` 拖动选区；
   - 显示尺寸；
   - 鼠标附近像素放大镜；
   - 最小选区限制；
   - 边界约束。
9. 截图时不能包含遮罩、工具栏、取色放大镜或本应用其他窗口。

### 窗口截图

- 使用 `SCShareableContent` 获取当前可见窗口。
- 排除：
  - 本应用窗口；
  - 不可见窗口；
  - 尺寸为零或明显无意义的系统窗口；
  - 不应捕获的遮罩和桌面辅助窗口。
- 鼠标移动时根据窗口层级和 frame 解析最上层候选窗口，并显示原创高亮边框。
- 点击后用 `SCContentFilter(desktopIndependentWindow:)` 或本机 SDK 中正确公开接口捕获该窗口。
- 默认保留窗口阴影，设置中允许关闭。
- 正确处理窗口跨屏、部分位于屏幕外、最小化、关闭、捕获瞬间消失等情况。
- 对受保护内容或系统返回空白图像时给出明确提示。

### 当前显示器和指定显示器

- 当前显示器：以鼠标所在屏幕为准。
- 指定显示器：进入显示器选择态，每块屏幕显示编号、名称和分辨率，点击后截图。
- 当前显示器与指定显示器均支持是否包含鼠标指针的设置。
- 全屏截图必须保留显示器原生像素，不要把 Retina 结果错误地缩成逻辑点尺寸。

### 全部显示器

- 生成一张按 macOS 桌面排列方式组合的图片。
- 对显示器间隙使用透明背景。
- 混合缩放比例时，以所有显示器中的最大 backing scale 作为组合画布比例，保持逻辑空间关系；同时在结果中保留各显示器原始图像和 scale，避免未来丢失信息。
- 编写单元测试覆盖：
  - 左右排列；
  - 上下排列；
  - 负坐标；
  - 1x 与 2x 混合；
  - 不同分辨率；
  - 显示器之间存在空隙。

### 坐标系统

建立单一 `ScreenGeometry` / `CoordinateTransformer`，集中处理：

- AppKit 全局屏幕坐标；
- ScreenCaptureKit display/window frame；
- Core Graphics 图片像素坐标；
- 自定义画布坐标；
- 顶部原点与底部原点转换；
- backing scale；
- 多屏负坐标；
- crop rect 的像素对齐。

禁止在各功能文件中散落 `y = height - y`、乘 2、除 2 等临时修正。

---

## 九、截图完成后的置顶面板

### PinnedShotPanel

- 使用 AppKit `NSPanel` 或合适的自定义 `NSWindow`。
- 默认位于普通应用窗口之上，但不要覆盖系统安全提示和关键系统 UI。
- 能出现在当前 Space、其他 Space、全屏应用和 Stage Manager 场景中。
- 默认不抢占当前应用焦点。
- 用户点击文字工具或需要键盘输入时才合理激活。
- 区域截图在冻结桌面的确认态使用透明标注层和完整的标注与截图输出工具栏并额外提供 Pin，不显示独立裁剪预览，也不显示鼠标穿透、临时隐藏图片和打开完整编辑器；显式 Pin 后提交并保留编辑结果、关闭遮罩、退出标注编辑、隐藏整条工具栏，图片本体才进入只读、可移动并保持宽高比缩放的置顶态，之后重新显示工具栏时才恢复这三个置顶图控制。
- 只读置顶图本体 hover 时显示张开的小手；鼠标按下的当下（即使尚未产生位移、尚未跨过系统拖动阈值）必须立即显示抓住的小手，并由应用统一管理按下、移动和松开，全程不得与普通箭头或张开小手来回闪烁；八个边缘/角落命中区域分别显示对应的水平、垂直或对角缩放光标。
- 置顶图右键菜单提供“复制截图”和“显示/隐藏工具栏”；显示工具栏时允许继续编辑，隐藏时必须结束编辑并恢复只读。
- 支持：
  - 自由移动；
  - 保持宽高比缩放；
  - 原始尺寸恢复；
  - 多张同时存在；
  - 透明度调整；
  - 点击穿透开关；
  - 临时隐藏；
  - 关闭；
  - 拖入 Finder、邮件、浏览器、聊天工具等；
  - 复制和保存；
  - 打开独立画布编辑器。
- 置顶图关闭后，如果未保存、未复制且未开启历史，数据应释放。
- 监听内存压力，清理不再需要的渲染缓存。

### 底部快速标注工具栏

- 工具栏作为置顶面板的附属窗口或同一窗口内区域，不允许成为与图片位置脱离的孤立浮窗。
- 默认位于图片底部，空间不足时自动翻转到顶部或调整位置。
- 工具栏应紧凑、原创、符合 macOS 视觉习惯。
- 不能直接复制 Snipaste 或 CleanShot X 的图标排序、形状或样式。
- 使用 SF Symbols 时保留可访问性标签；不存在合适系统图标时绘制原创矢量图标。
- 支持键盘快捷操作和 VoiceOver 标签。
- 颜色按钮必须打开原生二级菜单，而不是直接打开系统调色板。新安装以红、橙、黄、绿、蓝、紫六色和红色默认值开始，但完整的非空有序调色板由设置的编辑器页统一管理：六个出厂颜色和用户颜色都可以移除、重新添加或替换，并可单独恢复出厂六色；工具栏只消费这份设置。删除颜色时必须选择仍在调色板中的替代色，并原子重定向所有引用它的默认值，已有标注颜色不得改变。文字、矩形和椭圆分别拥有独立默认颜色；活动文字输入或已选标注改色只修改该对象，新建文字必须恢复设置中的文字默认色。文字默认使用系统字体，设置页可选择已安装字体。

---

## 十、非破坏性标注模型

不要把每次编辑直接永久画进位图。以可编辑文档作为唯一事实来源，导出时才扁平化。

### 文档模型

```swift
struct AnnotationDocument: Codable, Identifiable {
    let id: UUID
    var schemaVersion: Int
    var baseImageReference: ImageReference
    var canvasSize: CGSize
    var crop: CropState
    var rotation: RotationState
    var background: BackgroundStyle
    var annotations: [AnnotationItem]
}
```

`AnnotationItem` 至少覆盖：

- 矩形。
- 椭圆。
- 直线。
- 箭头。
- 自由画笔。
- 文字。
- 序号标记。
- 马赛克。
- 模糊。
- 高亮。
- 聚光灯。

每个元素至少具有：

- 唯一 ID。
- z-order。
- 几何信息。
- 样式。
- 透明度。
- 变换。
- 可见性。
- 锁定状态。
- 命中测试区域。

### 渲染

- 基础图片以 `CGImage` 为主，不要把 `NSImage` 作为内部唯一像素真相。
- 使用 Core Graphics 渲染矢量标注。
- 模糊和马赛克通过 Core Image + mask 非破坏性生成。
- 模糊和马赛克与创建时的底图像素区域完全绑定：创建后允许选择，但不显示八个缩放点，也不显示检查器缩放控制；鼠标拖动、边缘拖动、方向键、对齐、分布或检查器都不能移动或调整其大小。
- 聚光灯框选拖动阶段保持整张原图不变，只显示普通选区边框；鼠标松开提交后，矩形聚焦区保持原图，聚焦区外叠加半透明暗色遮罩。调整截图画布大小时，已提交的遮罩必须逐帧覆盖当前实时画布范围，新露出的区域立即变暗，不能等松开鼠标后再补齐。已提交标注的交互显示与最终导出复用同一渲染路径。
- 渲染器必须能：
  - 生成实时预览；
  - 生成指定像素尺寸的最终图；
  - 导出带正确颜色配置的 PNG；
  - 为拖拽和剪贴板生成数据；
  - 在 Quick Annotation 与 Canvas Editor 间复用。
- 对模糊和马赛克建立合理缓存，拖动时使用低成本预览，结束操作后再生成高质量结果。

### 编辑能力

第一版必须具有：

- 选择、移动、缩放、旋转适用元素。
- 删除。
- 复制、粘贴。
- 图层前移、后移、置顶、置底。
- 撤销、重做。
- 线宽。
- 描边色。
- 填充色。
- 透明度。
- 箭头样式。
- 文字字体大小、字重、颜色、对齐。
- 序号自动递增。
- 裁剪。
- 90 度旋转。
- 圆角。
- 阴影。
- 背景留白。
- 背景透明或纯色。
- 导出时扁平化。

明确不实现 Mac 窗口框、设备外壳和仿系统标题栏模板。

---

## 十一、快速标注模式

快速标注模式应覆盖高频操作，不只是一个截图预览：

- 选择。
- 矩形。
- 椭圆。
- 直线。
- 箭头。
- 画笔。
- 文字。
- 序号。
- 马赛克。
- 模糊。
- 高亮。
- 聚光灯。
- 裁剪。
- 撤销、重做。
- 复制。
- 保存。
- 拖拽。
- 打开独立画布编辑器。
- 完成编辑后保持置顶。
- 关闭。

交互要求：

- 点击工具后可立即在图上绘制。
- 工具属性用小型 popover 或上下文面板，不用打开完整设置页。
- 文字输入使用真实文本编辑控件，支持中文输入法，不要在 keyDown 中自行拼输入法文本。
- `Esc` 逐级执行：取消当前绘制 → 退出当前工具 → 关闭选中状态；不能一按就误关整张图。
- `Delete` 删除选中元素。
- `Command + Z` / `Command + Shift + Z` 撤销重做。
- `Command + C` 在有元素选中时复制元素；无元素选中时复制最终图片。
- 所有快捷行为要有明确焦点规则，避免影响用户当前前台应用。

---

## 十二、独立画布编辑器

创建原创布局，不照抄任何竞品。建议布局：

- 中央：可缩放、可平移画布。
- 左侧：窄型工具轨。
- 顶部：撤销、重做、缩放、导出、完成等全局命令。
- 右侧：根据当前工具或选中元素变化的属性检查器。
- 右侧可切换图层列表。
- 底部状态栏：像素尺寸、缩放比例、颜色空间、文件状态。

必须支持：

- Quick Annotation 的所有工具。
- 聚光灯。
- 画布缩放与平移。
- 适合窗口、100%、放大、缩小。
- 图层列表、重命名、隐藏、锁定、排序。
- 更精确的裁剪和旋转。
- 圆角、阴影、背景留白和背景色。
- 多选。
- 对齐和基础分布能力。
- 保存导出。
- 返回置顶模式时保留所有可编辑元素。
- 多个编辑器窗口之间状态隔离。

不要把 Quick Annotation 和 Canvas Editor 写成两套互不兼容的标注系统；两者必须共享 `AnnotationDocument`、渲染器、命令和撤销模型。

---

## 十三、取色器

### 支持的颜色空间

界面名称统一为：

1. sRGB，默认。
2. Display P3。
3. Generic RGB，中文显示“通用 RGB”。
4. Adobe RGB (1998)。

不要使用含糊的“普通 RGB”或错误拼写“Adobe RHG”。

### 功能

- 全屏或多屏取色。
- 鼠标附近显示像素放大镜。
- 中央像素有明确十字标记。
- 显示：
  - 当前显示器；
  - 屏幕坐标；
  - 颜色空间；
  - RGB 分量；
  - Alpha；
  - sRGB 时显示 HEX；
  - Display P3 时额外提供 `color(display-p3 r g b)` 形式；
  - Generic RGB 和 Adobe RGB 显示明确的空间名称和数值，避免把不同空间的相同数字误导为同一种颜色。
- 单击复制当前首选表示。
- `Command + C` 复制。
- 方向键按 1 pixel 微调采样点。
- `Shift + 方向键` 按 10 pixels 移动。
- `Esc` 退出。
- 设置中保存上次使用的颜色空间，但首次启动默认为 sRGB。
- 颜色转换使用系统颜色管理能力，禁止手写错误的矩阵转换。
- 采样结果必须标记其颜色空间；导出或复制时不得丢失上下文。

性能要求：

- 鼠标移动和放大镜显示流畅。
- 可以根据实际性能选择小范围重复截图或 ScreenCaptureKit frame stream，但必须隐藏在 `FrameStreaming` / `PixelSampling` 抽象后，为未来录屏能力复用采集层。
- 不允许为取色器请求 Accessibility 权限。

---

## 十四、屏幕标尺

第一版屏幕标尺至少实现：

- 覆盖所有显示器。
- 鼠标拖拽测量线段或矩形。
- 实时显示：
  - 宽度；
  - 高度；
  - 直线距离；
  - 起点和终点坐标；
  - point；
  - 对应物理 pixel。
- 在 Retina 与非 Retina 混合屏上明确当前测量所在屏幕的 scale。
- `Shift` 约束为水平、垂直或 45 度。
- 方向键微调端点。
- `Command + C` 复制测量结果。
- `Esc` 退出。
- 支持重新开始测量。
- 不获取 Accessibility 权限。
- 与截图遮罩复用屏幕几何和窗口管理基础设施，但状态相互隔离。

区域截图支持基于公开 ScreenCaptureKit 窗口信息和可选 Accessibility API 的元素吸附；屏幕标尺本身仍不请求或依赖 Accessibility，且任何模式都不得使用私有 API。

---

## 十五、菜单栏、Dock 和设置

### 菜单栏

菜单至少包含：

- 截取区域。
- 截取窗口。
- 截取当前显示器。
- 选择显示器截图。
- 截取全部显示器。
- 取色器。
- 屏幕标尺。
- 历史记录，仅在开启后显示或可用。
- 设置。
- 关于。
- 退出。

菜单项展示当前快捷键。

### Dock 图标

- 默认不显示。
- 设置中可实时切换。
- 显示 Dock 图标时使用普通应用 activation policy。
- 隐藏时切回 accessory。
- 切换不能导致置顶截图、设置页或编辑器丢失。
- 当用户同时关闭菜单栏图标和 Dock 图标时，必须给出警告，确保仍有全局快捷键或可恢复入口。

### 开机启动

- 使用 `SMAppService.mainApp` 注册和取消注册。
- 设置页显示当前状态与失败原因。
- 默认关闭。

### 设置页

使用原生 macOS 设置结构，至少包含：

1. General
   - 菜单栏图标。
   - Dock 图标。
   - 开机启动。
   - 启动时行为。
2. Capture
   - 捕获鼠标。
   - 窗口阴影。
   - 智能区域吸附开关、Accessibility 状态与授权入口；窗口吸附无需该权限。
   - 非区域截图的自动置顶；区域截图始终由选区确认工具栏中的 Pin 显式触发。
   - 显示快速工具栏。
   - 自动复制。
   - 自动保存。
   - 自动打开画布编辑器。
3. Output
   - 默认格式。
   - 文件名模板。
   - 默认目录。
   - 是否保留颜色配置。
4. Editor
   - 其他工具默认颜色。
   - 文字、矩形、椭圆的独立默认颜色。
   - 文字默认字体（默认系统字体）。
   - 线宽。
   - 字号。
   - 背景。
5. Color Picker
   - 默认颜色空间。
   - 复制格式。
6. Shortcuts
   - 所有全局快捷键。
   - 冲突提示。
   - 恢复默认。
7. History
   - 开关。
   - 保留时长。
   - 最大数量。
   - 清空。
8. Advanced
   - 日志级别。
   - 重置设置。
   - 打开数据目录。

设置使用可迁移的 Codable schema 或明确版本化的 SettingsStore，不要在业务代码中到处直接使用字符串键的 `UserDefaults`。

---

## 十六、剪贴板、保存和拖拽

### 剪贴板

- 复制最终渲染图片。
- 提供常见兼容数据类型，例如 PNG/TIFF，根据目标应用兼容性决定。
- 复制颜色时使用纯文本。
- 不把内部文档结构暴露到系统剪贴板，除非有自定义 pasteboard type 且实现了版本控制。

### 保存

- 默认不自动保存。
- 手动保存使用 `NSSavePanel`。
- 默认文件名类似：
  `Screenshot-2026-07-31-22.35.08.png`
- 文件名模板可配置。
- PNG 写入颜色配置，不能无意中把 Display P3 截图当作无配置 sRGB 保存。
- 保存失败要给出可恢复错误，不丢失当前编辑状态。
- 自动保存开启后，目录失效或无权限时应暂停自动保存并提示，不要静默丢图。

### 拖拽

- 置顶截图和画布编辑器均支持拖出。
- 尽量同时支持图像数据和文件承诺，使 Finder、邮件、浏览器、聊天软件都能接收。
- 拖拽过程中不能提前销毁临时文件。
- 临时文件在安全时机清理。

---

## 十七、历史记录

历史默认关闭，但开启后必须真正可用。

建议使用透明、可迁移的文件结构，而不是把大图直接塞进数据库：

```text
~/Library/Application Support/<bundle-id>/History/
└─ <capture-uuid>/
   ├─ base.png
   ├─ preview.png
   ├─ document.json
   └─ metadata.json
```

要求：

- `document.json` 包含 `schemaVersion`。
- 图片文件和元数据使用原子写入。
- 历史开启时保存可再次编辑的 AnnotationDocument。
- 历史列表支持预览、打开、复制、导出、删除。
- 默认建议保留 30 天或 500 条，但所有默认值集中定义并可在设置中修改。
- 关闭历史后不再保存新记录，不擅自删除旧记录。
- 提供清空历史操作并二次确认。
- 历史损坏时跳过损坏项并记录日志，不能导致应用启动失败。

---

## 十八、颜色管理

颜色正确性是产品要求，不是装饰性功能。

1. 捕获结果记录源 `CGColorSpace`。
2. 基础图片、渲染上下文、导出结果的颜色空间关系必须明确。
3. 标注颜色在进入渲染器时转换到当前工作空间。
4. 默认尽量保留源截图颜色配置。
5. sRGB、Display P3、Generic RGB、Adobe RGB (1998) 使用系统提供的颜色空间对象。
6. 不使用仅靠数值复制的方式“转换”颜色空间。
7. PNG 通过 Image I/O 写入正确颜色配置或 profile 信息。
8. 为颜色转换编写测试，允许合理浮点误差。
9. 在普通 sRGB 显示器上预览 P3 内容时使用系统色彩管理，不手动裁剪成错误颜色。
10. 取色器的数值和最终图片的嵌入 profile 必须分开处理：取色显示可转换，原图保存默认应保留源配置。

---

## 十九、窗口与 Space 行为

为不同窗口定义清晰角色：

### CaptureOverlayPanel

- 无边框。
- 用于截图选择。
- 覆盖对应显示器。
- 在全屏应用和不同 Space 中可见。
- 不出现在 Window 菜单和 Dock。
- 捕获完成或取消后必须完整销毁。

### RegionSelectionToolbarPanel

- 仅在有效区域 mouse-up 后显示于选区附近，并始终位于遮罩窗口之上。
- 必须复用完整的标注与截图输出工具集，并在原工具栏末尾额外加入 Pin 和取消；不得退化为只有 Pin/取消的精简栏，但确认态必须隐藏仅适用于置顶图的鼠标穿透、临时隐藏图片和打开完整编辑器。
- 有效选区进入确认态后仍可通过唯一一套八点缩放框调整；不得叠加第二套仅绘制而不可命中的控制点，也不得用独立截图预览替换冻结选区。缩放松手后从原冻结画面刷新内部缓存并重映射完整编辑历史。
- 复制或保存成功后必须销毁全部 CaptureOverlayPanel、透明标注层和工具栏并结束截图；Pin 则合成结果、销毁遮罩、隐藏整条工具栏并把同一窗口转为只读置顶图。取消连同确认态一起销毁，保存面板取消除外。

### PinnedShotPanel

- 浮动层级。
- 可跨 Space。
- 默认不激活应用。
- 可根据设置允许点击穿透。
- 文字输入或复杂编辑时可成为 key window。

### ToolbarPanel

- 作为 PinnedShotPanel 的 child window 或内部视图。
- 与父窗口共同移动和关闭。
- 不独立出现在窗口切换器中。

### CanvasEditorWindow

- 普通可调整尺寸窗口。
- 显示 Dock 图标关闭时仍可正常打开。
- 用户进入编辑器时允许应用激活。

### SettingsWindow

- 单例。
- 重复打开时聚焦已有窗口。

需要验证：

- Mission Control。
- 多 Space。
- 全屏应用。
- Stage Manager。
- 外接屏拔插。
- 显示器排列变化。
- 系统休眠和唤醒。

---

## 二十、错误处理与日志

使用统一错误类型，例如：

```swift
enum ScreenshotAppError: LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case noWindowAvailable
    case contentUnavailable
    case captureFailed(underlying: Error)
    case exportFailed(underlying: Error)
    case shortcutConflict
    case historyCorrupted
}
```

要求：

- 用户可理解的本地化提示。
- 技术细节进入 OSLog。
- 日志中禁止记录截图像素、OCR 内容、文件内容或用户隐私数据。
- 对权限拒绝、屏幕拔出、窗口消失、保存失败、快捷键冲突、颜色转换失败有明确处理。
- Debug 构建可提供诊断面板；Release 默认不显示低层日志。

---

## 二十一、性能要求

- 截图触发后尽快进入可操作状态，目标是常见 M 系列设备上从快捷键到遮罩出现没有明显停顿。
- 选区拖动、标注绘制、缩放和平移保持流畅。
- 图像处理放在合适的后台任务中，所有 AppKit/SwiftUI 状态更新回到 MainActor。
- 不在主线程重复编码 PNG。
- 大图渲染使用缓存和分辨率分级。
- 多张置顶截图时控制解码和渲染缓存。
- 遇到内存压力释放可重建缓存。
- 不为了首屏显示预先初始化未来录屏或 GIF 模块。
- 使用 Instruments 可验证的方式组织性能热点，并在 `docs/PERFORMANCE.md` 记录测量方法。

---

## 二十二、可访问性和视觉

- 支持浅色、深色和高对比度。
- 尊重 Reduce Motion。
- 所有工具按钮有 tooltip 和 accessibility label。
- 选区尺寸、工具状态不能只靠颜色表达。
- 键盘可操作。
- 字体使用系统字体。
- 界面符合 macOS 习惯，避免把移动端按钮样式直接搬到桌面。
- 视觉方向：克制、精确、轻量、现代；使用材质时保持可读性。
- 不复制任何竞品的商标、图标、素材、像素级布局或独特视觉资产。

---

## 二十三、为未来功能预留边界

第一版不实现，但架构必须避免未来推翻：

### 滚动长截图

预留独立的 `ScrollCaptureEngine`，未来可能有：

- 用户手动滚动 + 自动拼接。
- 浏览器或普通应用自动滚动。
- Accessibility 权限作为可选扩展。

不要让第一版普通截图依赖 Accessibility。

### 录屏

预留：

- `FrameStreaming`
- `AudioCapturing`
- `RecordingSession`
- `MediaOutputSink`

静态截图和录屏可以共享内容发现和过滤，但不能把视频帧逻辑塞进 `SCScreenshotManager` 单帧实现中。

### GIF

预留独立编码器和帧时间线，不在第一版加入空 UI。

### 延时截图

未来作为 CaptureRequest 的调度层，不要把倒计时逻辑耦合进各捕获模式。

### 付费能力

预留：

```swift
enum AppFeature {
    case basicCapture
    case quickAnnotation
    case canvasEditor
    case colorPicker
    case ruler
    case scrollingCapture
    case screenRecording
    case gifExport
}
```

第一版 `OpenSourceEntitlementProvider` 对所有已实现功能返回可用。未来付费实现替换 provider，不修改 CaptureCore。

### 自动更新

第一版不强制接入。定义 `UpdateChecking` 协议和 No-op 实现即可，未来官网分发可接入更新框架。

---

## 二十四、测试要求

### 单元测试

至少覆盖：

1. 多显示器坐标转换。
2. 负坐标。
3. 1x/2x scale 转换。
4. region crop 像素对齐。
5. all-displays composite 布局。
6. AnnotationDocument 编解码。
7. 各标注元素命中测试。
8. 撤销、重做。
9. 图层排序。
10. 裁剪、旋转后的坐标。
11. 颜色空间转换。
12. 文件名模板。
13. History schema 与损坏恢复。
14. Settings migration。
15. 快捷键冲突后的回滚。
16. 状态机取消和错误恢复。

### 可测试性

- `ScreenCapturing` 提供 mock，测试不依赖真实屏幕录制权限。
- `GlobalHotKeyManaging` 提供 fake。
- `ScreenshotHistoryStoring` 使用临时目录。
- 图像渲染使用小尺寸 golden/reference image 或像素断言，但避免脆弱到系统字体微小变化就全部失败。
- UI 测试至少覆盖设置页打开、Dock 切换逻辑和编辑器基本工具切换。

### 手工验证矩阵

在 `docs/MANUAL_TESTING.md` 创建清单：

- M 系列 Mac 内建 Retina 屏。
- 单外接屏。
- 1x + 2x 混合屏。
- 外接屏在主屏左、右、上、下。
- 全屏 App。
- Stage Manager。
- 多 Space。
- 浅色/深色。
- 不同显示器颜色 profile。
- 屏幕录制权限未授权、拒绝、授权后、撤回后。
- 外接屏在截图过程中断开。
- 窗口在选择过程中关闭。
- 多张置顶截图。
- 中文输入法编辑文字。
- 拖入 Finder、邮件和至少一种聊天应用。

---

## 二十五、构建和分发

### 本地构建

提供并验证等价命令：

```bash
xcodebuild \
  -scheme ScreenshotApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

测试命令：

```bash
xcodebuild \
  -scheme ScreenshotApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

以实际 scheme/workspace 名称为准，并在 README 写出准确命令。

### Release

创建脚本：

```text
scripts/
├─ build-release.sh
├─ package-dmg.sh
└─ notarize.sh
```

要求：

- 使用系统 `hdiutil` 生成 `.dmg`，避免不必要依赖。
- 支持 Developer ID Application 签名。
- 支持 Hardened Runtime。
- 支持 `xcrun notarytool` 提交公证。
- 支持 stapling。
- 所有证书名、Team ID、Apple ID、keychain profile 通过环境变量或本机 keychain 注入。
- 禁止把任何密钥、密码、证书或个人 Team 信息提交到仓库。
- 未配置签名时也能生成仅供本地测试的 unsigned Debug/Release build。
- 在 `docs/RELEASING.md` 写出完整流程。

---

## 二十六、实施阶段

严格按阶段推进，每阶段结束都编译和测试。

### Phase 0：仓库和架构

- 检查环境和现有代码。
- 创建：
  - `docs/ARCHITECTURE.md`
  - `docs/ROADMAP.md`
  - `docs/DECISIONS_NEEDED.md`
  - `docs/MANUAL_TESTING.md`
  - `STATUS.md`
- 初始化工程和集中配置。
- 建立 App shell、日志、依赖容器和测试 target。
- 确保空壳可构建运行。

### Phase 1：菜单栏、设置、权限和快捷键

- 菜单栏常驻。
- 默认 accessory 模式。
- Dock 图标动态切换。
- Settings 窗口。
- Screen Capture 权限流程。
- `SMAppService` 开机启动。
- 全局快捷键注册、修改、冲突处理。
- 单元测试和构建。

### Phase 2：截图核心

按顺序实现：

1. 当前显示器截图。
2. 指定显示器截图。
3. 全部显示器截图。
4. 窗口截图。
5. 自由区域截图。
6. 多显示器和坐标测试。

每完成一个模式立即编译和测试，禁止五种模式一次写完才验证。

### Phase 3：置顶截图

- PinnedShotPanel。
- 多张并存。
- 移动、缩放、透明度、点击穿透。
- 复制、保存、拖拽、关闭。
- 跨 Space/全屏行为。
- 工具栏容器。

### Phase 4：标注核心和快速标注

先实现文档模型、渲染器、命令系统和 Undo，再实现工具：

1. 选择。
2. 矩形/椭圆。
3. 直线/箭头。
4. 画笔。
5. 文字。
6. 序号。
7. 高亮。
8. 模糊/马赛克。
9. 裁剪。
10. 导出。

每个工具完成后补测试。

### Phase 5：独立画布编辑器

- 共享 AnnotationDocument。
- 画布缩放、平移。
- 工具轨和属性面板。
- 图层列表。
- 聚光灯。
- 圆角、阴影、背景留白、背景色。
- 多选、对齐、排序。
- 与置顶模式往返。

### Phase 6：取色器和屏幕标尺

- 完成四种颜色空间。
- 像素放大镜。
- 复制格式。
- 多屏采样。
- 标尺 point/pixel 测量。
- 测试 Retina/非 Retina。

### Phase 7：历史、发布和质量

- 历史开关及可编辑记录。
- 本地化。
- 可访问性。
- 性能检查。
- Release/DMG/notarization scripts。
- README、CONTRIBUTING、PRIVACY、RELEASING 文档。
- 全量构建和测试。

---

## 二十七、第一版验收标准

只有满足以下条件才算第一版完成：

1. 在 macOS 14+、Apple Silicon 上可构建运行。
2. 默认菜单栏常驻、Dock 不显示。
3. 全局快捷键可触发截图，且可修改、检测冲突。
4. 未授权屏幕录制权限时有完整引导，应用不崩溃。
5. 区域、窗口、当前显示器、指定显示器、全部显示器均能截图。
6. 截图不包含本应用遮罩和工具栏。
7. Retina 和多显示器截图尺寸正确，无明显偏移、倒置或模糊。
8. 截图完成后默认以置顶面板显示，并带底部快速标注工具栏。
9. 多张置顶截图可以同时存在。
10. 快速标注工具可用，修改后可继续编辑，不是立即烧进位图。
11. 独立画布编辑器可打开同一文档并保留图层。
12. 矩形、椭圆、线、箭头、画笔、文字、序号、马赛克、模糊、高亮、聚光灯、裁剪、旋转均可用。
13. 圆角、阴影、背景留白可用，但没有 Mac 外壳和设备框。
14. 撤销、重做和图层修改稳定。
15. 复制、保存、拖拽可用。
16. 取色器支持 sRGB、Display P3、Generic RGB、Adobe RGB (1998)，默认 sRGB。
17. 屏幕标尺能显示 point 和实际 pixel。
18. 自动复制、自动保存、自动进入编辑器、历史等设置可用且默认关闭。
19. 开机启动可切换。
20. Debug build 和测试通过。
21. Release 构建和 DMG 脚本存在并有文档。
22. 无私有 API、无遥测、无不必要网络请求。
23. 所有 required 功能不能只是空壳按钮或 TODO。

---

## 二十八、执行时的输出要求

在开发过程中持续更新 `STATUS.md`，格式至少包括：

```markdown
# Current Status

## Completed
- ...

## In Progress
- ...

## Build
- Command:
- Result:

## Tests
- Command:
- Result:

## Known Issues
- ...

## Next Concrete Step
- ...
```

当本次 Codex 工作结束时，在终端回复中提供：

1. 实际完成了哪些阶段。
2. 新增和修改的关键文件。
3. 实际执行过的构建命令及结果。
4. 实际执行过的测试命令及结果。
5. 如何打开和运行应用。
6. 需要用户手工授予什么权限。
7. 哪些功能已经真实可用。
8. 哪些功能仍未完成，必须具体到文件或模块，禁止只写“部分功能待完善”。
9. 是否存在编译警告。
10. 下一步最具体的代码任务。

现在开始检查当前仓库并执行。不要先向我复述需求，也不要只生成计划。
> Historical planning artifact. Product identity, distribution, privacy, and
> update decisions in `AGENTS.md`, `README.md`, and `docs/ARCHITECTURE.md`
> supersede conflicting requirements below.
