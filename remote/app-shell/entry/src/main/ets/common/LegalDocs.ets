/**
 * 合规法律文本与开源声明（Privacy Policy / User Agreement / Open Source Notices）。
 * 描述事实：Agent Mobile 仅在用户的手机与用户自己配置的电脑网关之间直连通信，
 * 开发者不运营任何中心化用户数据服务器，也不收集个人隐私数据。
 */

export type LegalDocKind = 'privacy' | 'terms' | 'licenses';

export function legalTitleOf(kind: LegalDocKind): string {
  if (kind === 'privacy') {
    return '隐私政策';
  }
  if (kind === 'terms') {
    return '用户协议';
  }
  return '开源组件许可声明';
}

export function legalBodyOf(kind: LegalDocKind): string {
  if (kind === 'privacy') {
    return PRIVACY_POLICY_TEXT;
  }
  if (kind === 'terms') {
    return USER_AGREEMENT_TEXT;
  }
  return OPEN_SOURCE_NOTICES_TEXT;
}

export const PRIVACY_POLICY_TEXT: string = [
  '生效日期：2026 年 11 月 25 日',
  '适用应用：Agent Mobile（HarmonyOS 客户端）',
  '',
  '一、我们如何处理你的数据',
  '1. 本地直连架构：Agent Mobile 是一款连接你本人桌面端 AI 网关的远程客户端。你的会话列表、对话消息、工作区文件预览与终端指令仅在你配对的手机与电脑之间直接传输，不经过开发者自建云端服务器。',
  '2. 本地存储的数据：为保持配对连接与使用体验，应用会在本机应用沙箱中保存你的主机地址、配对名称、匿名随机设备标识、X25519 密钥对、会话草稿与最近会话缓存。其中访问令牌与私钥材料优先存入鸿蒙系统资产安全库（Asset Store Kit）。',
  '3. 主动提交的反馈与附件：仅当你主动在「反馈与支持」中提交工单时，应用会将你填写的问题描述、可选联系方式、基础运行环境（应用版本、系统版本、机型与网络类型）、匿名随机安装标识及你主动挑选的截图/录屏/日志文件发送至开发者自建的 Cloudflare Worker 与 R2 存储用于排查问题；未提交反馈时不会向该服务发送任何业务数据。',
  '4. 不收集范围：本应用不收集通讯录、精准位置、通话记录、短信或与远控功能无关的任何个人隐私，不包含第三方广告或行为追踪 SDK。',
  '',
  '二、系统权限用途说明',
  '1. 网络访问（INTERNET）与网络状态（GET_NETWORK_INFO）：用于局域网直连、公网隧道通信以及在 Wi-Fi 与蜂窝网络切换时自动选择最优入口。',
  '2. 相机与相册/文件选择器：仅在你主动点击「扫码配对」「拍照」「选图」或「传文件」时由系统安全选择器临时授权读取单次选中内容，不会后台扫描相册或存储目录。',
  '3. 通知与振动反馈（VIBRATE）：开启任务通知或触感反馈后，本地轮询与振动仅在授权后触发；若你开启后台系统推送且已同意本隐私政策，应用才会向华为 Push Kit 申请设备令牌并生成单机随机防刷凭据（保存在系统资产安全库），退后台/离屏后配对电脑网关仅会将匿名 Push Token、通知事件与（默认开启且可关闭的）会话标题经 Cloudflare 推送中继转发至华为 Push Kit，绝不经由中继上传对话正文或工作区内容。',
  '',
  '三、端到端加密与安全建议',
  '当配对电脑支持并启用 Noise_IK_25519_ChaChaPoly_SHA256 端到端加密时，常规 RPC 请求负载会在传输前完成加密。公网远程访问强烈建议通过 HTTPS 反向代理或安全隧道开启，避免在不受信任的公共网络中使用明文 HTTP。',
  '',
  '四、你的控制权与数据清除',
  '你可以随时在「设置 -> 连接与设备」中撤销或移除任意已配对电脑凭据，在「设置 -> 数据与存储」中一键清理全部本地缓存、草稿，或通过「关于与协议」导出运行诊断日志，也可通过卸载应用清除全部本地数据。'
].join('\n');

export const USER_AGREEMENT_TEXT: string = [
  '生效日期：2026 年 11 月 25 日',
  '适用应用：Agent Mobile（HarmonyOS 客户端）',
  '',
  '一、服务说明',
  'Agent Mobile 提供移动端与桌面端 AI Agent 网关（包括 DSH、Codex、Claude Code、OpenCode、Antigravity 等兼容后端）之间的配对连接、会话协同、工作区查看与交互控制能力。',
  '',
  '二、授权使用范围与安全责任',
  '1. 你应仅将本应用连接至本人拥有或明确获得授权访问的计算机设备。',
  '2. 请妥善保管配对二维码、6 位一次性配对码与访问令牌，避免在不安全环境中展示或泄露。发现设备遗失时，请立即在电脑端设置面板中点击「撤销」该设备授权。',
  '3. 本应用可执行代码变更查看、命令行终端操作及审批确认等高权限工作区动作，请务必在确认操作内容安全后再行授权执行。',
  '',
  '三、免责与知识产权',
  '1. 因网络波动、第三方隧道中断、电脑端程序未启动或宿主配置变更造成的连接异常，本应用将尽量提供诊断信息，但无法保证脱离网络环境的可用性。',
  '2. 本应用客户端主体代码基于 Apache-2.0 许可证发布，第三方开源组件及其许可详见应用内「开源组件许可声明」。'
].join('\n');

export const OPEN_SOURCE_NOTICES_TEXT: string = [
  'Agent Mobile 客户端主体代码采用 Apache License 2.0 开源许可。',
  '',
  '----------------------------------------',
  '1. Noise Protocol Framework (Revision 34)',
  '   许可：Public Domain (CC0 1.0 Universal)',
  '   说明：Noise_IK_25519_ChaChaPoly_SHA256 协议规范依据公开文档独立实现，所有底层密码学原语（X25519、ChaCha20-Poly1305、SHA-256、HMAC）均直接调用鸿蒙系统原生 @kit.CryptoArchitectureKit 接口。',
  '',
  '2. HarmonyOS / OpenHarmony 系统套件',
  '   包含：ArkUI、AbilityKit、CryptoArchitectureKit、NetworkKit、ArkData、ArkWeb、CoreFileKit、AssetStoreKit、UIDesignKit、ScanKit。',
  '   说明：由鸿蒙系统运行时与 SDK 工具链提供。',
  '',
  '3. 桌面端配套网关组件（agent-mobile-gateway）',
  '   主体许可：Apache License 2.0',
  '   运行时依赖：qrcode（^1.5.4，MIT License，仅用于桌面端面板生成 SVG 配对二维码）。'
].join('\n');
