import Foundation

// Exercise the production lexical retrieval and evidence validation without downloading MLX.
// Semantic retrieval is additive; baseline coverage must remain usable without it.
actor LocalKnowledgeEmbedding {
    static let modelID = "test-unavailable"
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { throw AIClientError.invalidResponse }
    func embed(_ texts: [String], isQuery: Bool = false) async throws -> [[Float]] { throw AIClientError.invalidResponse }
}

@main
struct InterviewKnowledgeTests {
    static func main() async throws {
        let factsURL = URL(filePath: CommandLine.arguments[1])
        let engine = InterviewKnowledgeEngine(factsURL: factsURL, inMemory: true)
        let status = try await engine.load()
        precondition(status.projectCount == 60 && status.staleCount == 0)
        let cases: [(String, InterviewProjectScope, [String])] = [
            ("介绍一下轻购的整体架构", .automatic, ["QG-01", "QG-14"]),
            ("商城登录以后是怎么回到原页面的", .mobileShop, ["QG-02"]),
            ("好几个接口都返回401会不会一直跳登录", .mobileShop, ["QG-03"]),
            ("搜索过的词为什么不会重复，关掉后还有吗", .mobileShop, ["QG-04"]),
            ("搜索联想里之前的请求比新请求晚返回怎么办", .automatic, ["QG-05"]),
            ("你们的搜索缓存怎么淘汰，过期后怎么办", .mobileShop, ["QG-06"]),
            ("AI请求超时与主动取消有什么区别", .mobileShop, ["QG-07"]),
            ("购物车为什么要把后端数据扁平化", .automatic, ["QG-08"]),
            ("购物车步进器连续点击怎么防重复", .automatic, ["QG-09"]),
            ("结算前选好的地址是怎么传过去的", .mobileShop, ["QG-10"]),
            ("订单提交成功但是用户不付款怎么办", .mobileShop, ["QG-11"]),
            ("商品详情上的AI文案失败如何处理", .automatic, ["QG-22"]),
            ("发版之后用户浏览器里的旧分包失效了怎么办", .mobileShop, ["QG-13"]),
            ("购物车的状态存在Pinia里面吗", .automatic, ["QG-01", "QG-14"]),
            ("首页进入分类页怎么定位左侧选项", .mobileShop, ["QG-15"]),
            ("登录密码是不是用了AES加密以后再发送", .mobileShop, ["QG-16"]),
            ("Axios的delete接口如果有body怎么传", .mobileShop, ["QG-17"]),
            ("省市区列表是一次加载的吗", .mobileShop, ["QG-18"]),
            ("不同颜色尺寸的SKU如何找到对应规格", .automatic, ["QG-19"]),
            ("订单加载第二页失败时会不会漏数据", .mobileShop, ["QG-20"]),
            ("AI导购是用向量数据库推荐商品吗", .mobileShop, ["QG-21"]),
            ("退出登录是不是会清掉所有搜索历史", .mobileShop, ["QG-23"]),
            ("项目骨架屏有哪些形状，可以共用吗", .mobileShop, ["QG-24"]),
            ("Vant和业务页面px转rem为什么不一样", .mobileShop, ["QG-25"]),
            ("讲一下选商品加购物车到付款的完整业务链路", .mobileShop, ["QG-26"]),
            ("项目的亮点和不足有哪些", .mobileShop, ["QG-27"]),
            ("商城有没有SSR和虚拟列表", .automatic, ["QG-28"]),
            ("AI代理服务有做参数校验和限流吗", .mobileShop, ["QG-29"]),
            ("介绍城市视图的技术栈", .automatic, ["CITY-01"]),
            ("Redux刷新后哪些状态还在", .city, ["CITY-02"]),
            ("token没了以后是拦截器直接跳路由的吗", .city, ["CITY-03"]),
            ("隐藏左侧菜单以后用户输入URL还能进吗", .city, ["CITY-04"]),
            ("仪表盘更新是websocket推送吗", .automatic, ["CITY-05"]),
            ("导出的CSV是前端拼字符串吗", .city, ["CITY-06"]),
            ("图表编辑器切换数据源后旧字段怎么处理", .automatic, ["CITY-07"]),
            ("ECharts在容器变化和页面卸载时怎么办", .city, ["CITY-08"]),
            ("高德地图上环境信息是高德提供的吗", .automatic, ["CITY-09"]),
            ("附近城市算的是开车的距离吗", .city, ["CITY-10"]),
            ("三维柱图的高度如何与人口对应", .city, ["CITY-11", "CITY-27"]),
            ("聊天历史怎么保存，发送时带什么上下文", .city, ["CITY-12", "CITY-23"]),
            ("权限树配置好了会自动生成全部路由吗", .city, ["CITY-13", "CITY-21"]),
            ("页面的JS文件加载失败会不会无限刷新", .city, ["CITY-14"]),
            ("小屏幕下侧栏怎样显示", .city, ["CITY-15"]),
            ("验证码图片是怎么显示的", .city, ["CITY-16"]),
            ("编辑已有图表如何回显，保存什么位置数据", .city, ["CITY-17"]),
            ("列表预览和编辑器预览是不是一回事", .city, ["CITY-18"]),
            ("一个图表查询报错会导致仪表盘整个失败吗", .city, ["CITY-19"]),
            ("头像上传完为什么还需要保存个人资料", .city, ["CITY-20"]),
            ("勾选角色权限如何传到后端", .city, ["CITY-21"]),
            ("暗色切换时图表怎样更新实例", .city, ["CITY-22"]),
            ("新增AI对话先保存用户问题还是等回复完成", .city, ["CITY-23"]),
            ("流式响应一半JSON分到下个包怎么办", .city, ["CITY-24"]),
            ("同样是多个接口，地图和首页失败处理有何不同", .city, ["CITY-25"]),
            ("热力图组件不可用能否降级", .city, ["CITY-26"]),
            ("3D动画每帧会用setState吗", .city, ["CITY-27"]),
            ("建筑楼层分离是导入模型还是自己画的", .city, ["CITY-28"]),
            ("代理会不会等AI响应全部完成才转发", .city, ["CITY-29"]),
            ("你项目有没有性能实测数据和优化空间", .city, ["CITY-30"]),
            ("React组件渲染报错后怎么恢复", .city, ["CITY-31"]),
            ("介绍一下你的项目", .automatic, ["QG-01", "CITY-01"]),
            ("说说项目是做什么的", .city, ["CITY-01"]),
        ]
        var failures: [String] = []
        for (question, scope, expected) in cases {
            let result = try await engine.retrieve(question: question, scope: scope, previousProject: nil, previousQuestion: nil)
            let ids = Set(result.passages.map(\.id))
            if !expected.allSatisfy(ids.contains) { failures.append("\(question) expected \(expected) got \(result.passages.map(\.id))") }
            if let project = scope.projectID {
                precondition(result.passages.allSatisfy { $0.projectID == nil || $0.projectID == project })
            }
        }
        // General mode never borrows project claims, even if a name appears in the question.
        let general = try await engine.retrieve(question: "轻购和城市视图中的useEffect和watch", scope: .general, previousProject: nil, previousQuestion: nil)
        precondition(general.projectIDs.isEmpty && general.passages.allSatisfy { $0.projectID == nil })
        let both = try await engine.retrieve(question: "比较这两个项目的架构和状态管理", scope: .automatic, previousProject: nil, previousQuestion: nil)
        precondition(Set(both.projectIDs) == Set(["mobile-shop", "datapilot-rebuild"]))
        precondition(Set(both.passages.map(\.id)).isSuperset(of: ["QG-01", "CITY-01"]))
        let first = try await engine.retrieve(question: "轻购搜索联想为什么要取消请求", scope: .automatic, previousProject: nil, previousQuestion: nil)
        let second = try await engine.retrieve(question: "那缓存呢", scope: .automatic, previousProject: "mobile-shop", previousQuestion: "轻购搜索联想为什么要取消请求", previousPassageIDs: first.passages.map(\.id))
        let third = try await engine.retrieve(question: "如果它报错了怎么办", scope: .automatic, previousProject: "mobile-shop", previousQuestion: "那缓存呢", previousPassageIDs: second.passages.map(\.id))
        precondition(second.projectIDs == ["mobile-shop"] && third.projectIDs == ["mobile-shop"])
        precondition(third.passages.contains { $0.id == "QG-06" })
        let switched = try await engine.retrieve(question: "那城市视图的图表如何保存", scope: .automatic, previousProject: "mobile-shop", previousQuestion: "那缓存呢", previousPassageIDs: third.passages.map(\.id))
        precondition(switched.projectIDs == ["datapilot-rebuild"] && switched.passages.allSatisfy { $0.projectID != "mobile-shop" })
        let other = try await engine.retrieve(question: "那另一个项目的状态管理呢", scope: .automatic, previousProject: "mobile-shop", previousQuestion: "轻购如何保存状态")
        precondition(other.projectIDs == ["datapilot-rebuild"] && other.passages.allSatisfy { $0.projectID != "mobile-shop" })
        let wrongFeature = try await engine.retrieve(question: "城市视图的购物车怎么计算总价", scope: .automatic, previousProject: nil, previousQuestion: nil)
        precondition(wrongFeature.projectIDs == ["datapilot-rebuild"] && wrongFeature.passages.allSatisfy { $0.projectID != "mobile-shop" })
        let selected = try await engine.retrieve(question: "仪表盘怎么做", scope: .mobileShop, previousProject: nil, previousQuestion: nil)
        precondition(selected.projectIDs == ["mobile-shop"] && selected.passages.allSatisfy { $0.projectID != "datapilot-rebuild" })
        try await testStaleEvidence(factsURL: factsURL)
        for failure in failures { FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8)) }
        precondition(failures.isEmpty, "\(failures.count) retrieval misses")
        print("PASS: \(cases.count) held-out retrieval questions, project isolation, comparison, chained followups, explicit switch and stale/missing evidence")
        if CommandLine.arguments.contains("--live") {
            try await testLiveAnswers(engine: engine)
        }
    }

    static func testStaleEvidence(factsURL: URL) async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "copilot-knowledge-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: factsURL)) as! [String: Any]
        let all = document["facts"] as! [[String: Any]]
        let fact = all.first { $0["id"] as? String == "QG-05" }!
        let sources = fact["sources"] as! [[String: Any]]
        for source in sources {
            let relative = source["path"] as! String
            let destination = temp.appending(path: "Dev/mobile-shop/" + relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: URL(filePath: NSHomeDirectory()).appending(path: "Dev/mobile-shop/" + relative), to: destination)
            }
        }
        document["facts"] = [fact]
        let snapshot = temp.appending(path: "facts.json")
        try JSONSerialization.data(withJSONObject: document).write(to: snapshot)
        let engine = InterviewKnowledgeEngine(home: temp, factsURL: snapshot, inMemory: true)
        let status = try await engine.load()
        precondition(status.projectCount == 1)
        let changed = temp.appending(path: "Dev/mobile-shop/" + (sources[0]["path"] as! String))
        try Data("changed implementation".utf8).write(to: changed)
        let stale = try await engine.retrieve(question: "搜索联想", scope: .mobileShop, previousProject: nil, previousQuestion: nil)
        precondition(stale.passages.isEmpty && stale.warning != nil)
        let reloaded = try await engine.load()
        precondition(reloaded.projectCount == 0 && reloaded.staleCount == 1)
        try FileManager.default.removeItem(at: changed)
        let missing = try await engine.load()
        precondition(missing.projectCount == 0 && missing.staleCount == 1)
    }

    @MainActor static func testLiveAnswers(engine: InterviewKnowledgeEngine) async throws {
        let defaults = UserDefaults(suiteName: "com.eli.CopilotNative")!
        let settings = RemoteAISettings(defaults: defaults, loadKey: { defaults.string(forKey: "remoteAIApiKey") ?? "" })
        guard let configuration = settings.activeConfiguration else { fatalError("No active AI configuration") }
        let questions: [(String, InterviewProjectScope)] = [
            ("轻购搜索联想的请求和缓存怎么做的，有哪些边界？", .mobileShop),
            ("城市视图的权限树配置好以后，路由就自动按权限生成了吗？", .city),
            ("城市视图的3D城市模型是怎么实现的，是实时数字孪生吗？", .city),
        ]
        for (question, scope) in questions {
            let evidence = try await engine.retrieve(question: question, scope: scope, previousProject: nil, previousQuestion: nil)
            var answer = ""
            for try await chunk in ChatCompletionClient().streamAnswer(for: question, configuration: configuration, context: evidence) { answer += chunk }
            precondition(!answer.isEmpty)
            print("LIVE QUESTION: \(question)\nEVIDENCE: \(evidence.passages.map(\.id))\nANSWER:\n\(answer)\n")
        }
    }
}
