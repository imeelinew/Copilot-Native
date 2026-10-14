import Foundation
import Observation

@MainActor
@Observable
final class SpeechSettings {
    // Put the frontend stack and unusual project names first: the streaming pass
    // has a 100-token budget; the enabled second pass accepts up to 5,000 words.
    static let defaultHotwords: [String] = [
        "Vue", "React", "TypeScript", "Vue Router", "Vuex", "Pinia", "Redux Toolkit",
        "React Router", "Axios", "Vite", "Webpack", "ECharts", "Three.js", "React Three Fiber",
        "Ant Design", "Vant", "Element Plus", "Element UI", "轻购", "城市视图", "智服工单",
        "JavaScript", "HTML5", "CSS3", "HTML", "CSS", "ES6", "ES6+", "Vue 2", "Vue 3", "React 19",
        "Hooks", "Composition API", "Options API", "setup", "script setup", "ref", "reactive",
        "computed", "watch", "watchEffect", "nextTick", "provide", "inject", "v-model", "v-if", "v-show",
        "keep-alive", "Teleport", "Suspense", "useState", "useEffect", "useMemo", "useCallback",
        "useRef", "useContext", "useReducer", "React.memo", "Fiber", "虚拟 DOM", "Diff 算法",
        "组件化", "函数组件", "组件通信", "生命周期", "响应式原理", "双向绑定", "单向数据流",
        "Proxy", "Object.defineProperty", "依赖收集", "状态管理", "redux-persist", "createSlice",
        "createAsyncThunk", "Redux", "路由守卫", "动态路由", "路由 meta", "Hash 路由", "History 路由",
        "Sass", "SCSS", "PostCSS", "Vue CLI", "Babel", "ESLint", "Prettier", "npm", "pnpm",
        "package.json", "ES Modules", "CommonJS", "Tree Shaking", "Code Splitting", "HMR",
        "热更新", "懒加载", "按需加载", "模块化", "构建优化", "Git", "GitHub", "GitHub Actions",
        "commit", "merge", "rebase", "revert", "reset", "分支管理", "版本回退", "CI/CD",
        "高德地图", "高德地图 JS API", "AMap", "WebGL", "Canvas", "SVG", "ResizeObserver",
        "requestAnimationFrame", "Promise.all", "CSV", "GDP", "数据可视化", "仪表盘", "数据源",
        "级联选择", "动态图表", "图表实例", "地图标记点", "空气质量", "三维数据柱", "容器适配",
        "移动端电商", "购物车", "订单确认", "地址选择", "搜索联想", "卖点生成", "本地推荐",
        "sessionStorage", "localStorage", "防抖", "节流", "降级处理", "格式校验", "价格联动",
        "企业工单", "工单流转", "SLA", "待分配", "待处理", "处理中", "待回访", "超时标记",
        "多条件筛选", "分页检索", "处理时间线", "角色权限", "访问控制", "操作权限", "权限菜单",
        "Token", "JWT", "RBAC", "HTTP", "HTTPS", "CORS", "Cookie", "Session", "OAuth",
        "RESTful", "JSON", "Fetch", "WebSocket", "SSE", "XSS", "CSRF", "请求拦截器",
        "响应拦截器", "登录鉴权", "登录失效", "会话持久化", "跨域", "预检请求", "同源策略",
        "强缓存", "协商缓存", "Cache-Control", "ETag", "Last-Modified", "HTTP/2", "TCP", "DNS",
        "Node.js", "Express", "Koa", "NestJS", "SQL", "数据库原理", "数据结构", "算法设计",
        "闭包", "原型链", "作用域", "this", "事件循环", "Event Loop", "微任务", "宏任务",
        "Promise", "async/await", "异步编程", "事件委托", "事件冒泡", "事件捕获", "深拷贝", "浅拷贝",
        "泛型", "类型推断", "类型守卫", "联合类型", "交叉类型", "interface", "type", "keyof",
        "Flexbox", "Grid", "BFC", "盒模型", "层叠上下文", "语义化", "响应式布局", "移动端适配",
        "rem", "vw", "媒体查询", "回流", "重绘", "重排", "虚拟列表", "内存泄漏", "垃圾回收",
        "首屏优化", "LCP", "CLS", "INP", "SSR", "SSG", "CSR", "SEO", "无障碍",
        "Obelisk", "Kit", "Yorune", "Window", "Vitals", "Drizzle", "Auvol", "Crypta", "CodexBar",
        "SQLite", "FTS5", "Cloudflare", "Worker", "D1", "离线书签", "字段合并", "全文检索",
        "中文拼音匹配", "跨应用粘贴", "Subsonic API", "AVFoundation", "播放队列", "辅助功能 API",
        "Accessibility", "Dock", "多屏", "AppKit", "Swift", "SwiftUI", "资源采样", "签名更新",
        "Sparkle", "WASAPI", "Core Audio", "UDP", "PCM", "抖动缓冲", "Keychain", "Touch ID",
        "加密媒体库", "自动锁定", "Codex", "Claude Code", "DSH", "OpenCode", "Cursor", "AI Coding"
    ]
    private static let legacyHotwords = "Swift, SwiftUI, SwiftData, AppKit, Actor, Redis, MySQL, JVM, Spring Boot, Kubernetes"
    var apiKey: String { didSet { defaults.set(apiKey, forKey: "speechAPIKey") } }
    var hotwords: String { didSet { defaults.set(hotwords, forKey: "speechHotwords") } }
    var automaticAnswers: Bool { didSet { defaults.set(automaticAnswers, forKey: "speechAutomaticAnswers") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKey = defaults.string(forKey: "speechAPIKey") ?? ""
        let savedHotwords = defaults.string(forKey: "speechHotwords")
        if savedHotwords == nil || savedHotwords == Self.legacyHotwords {
            let initialHotwords = Self.defaultHotwords.joined(separator: ", ")
            hotwords = initialHotwords
            defaults.set(initialHotwords, forKey: "speechHotwords")
        } else {
            hotwords = savedHotwords ?? ""
        }
        automaticAnswers = defaults.object(forKey: "speechAutomaticAnswers") as? Bool ?? true
    }

    var words: [String] {
        var seen = Set<String>()
        return Array(hotwords.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(5_000))
    }
}

enum SpeechError: LocalizedError {
    case message(String)
    case service(Int, String)
    case invalidPacket
    case audioBacklog
    case permissionRequired

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .service(let code, let message): "语音服务错误 \(code)：\(message)"
        case .invalidPacket: "语音服务返回了无法解析的数据"
        case .audioBacklog: "音频发送积压，正在重新连接；请重述未识别的内容"
        case .permissionRequired: "当前 App 尚未获得系统音频录制授权。请点击“系统权限”授权；如果开关已打开，请关闭后重新开启，并完全退出再打开 App。"
        }
    }

    var canRetry: Bool {
        switch self {
        case .service(let code, _): code >= 50_000_000
        case .message, .invalidPacket, .permissionRequired: false
        case .audioBacklog: true
        }
    }
}
