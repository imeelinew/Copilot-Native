# 项目源码知识覆盖

本快照经过源码核对；哈希校验只会拒绝过期证据，不会自动认可改动。

代码只能证明实现，个人职责、团队分工、上线效果与性能数字未获确认。

## mobile-shop

### QG-01 项目范围与实际技术栈

可覆盖提问：介绍一下轻购项目；商城整体架构是什么；电商项目有哪些模块

轻购是移动端电商 Web 前端，代码包含登录注册、商品浏览和搜索、商品详情、购物车、地址管理、订单确认、订单列表及 AI 导购页面。当前依赖包含 Vue 3、TypeScript、Vue Router、Vant、Axios、Sass 和 Vite。入口注册 Vue Router，页面状态主要由 ref、computed、watch 管理；当前 package.json 没有 Pinia 依赖，入口也未注册 Pinia。

**边界：** 这是仓库功能描述，不证明个人贡献。不能因掌握 Pinia 或使用 Vue 就宣称本项目用 Pinia 管理购物车；不能把这个前端仓库说成已实现 Spring Boot、MySQL、Redis 后端。

依据：package.json:13、src/main.ts:10、src/router/index.ts:20

### QG-02 登录凭证与路由守卫

可覆盖提问：登录流程怎么做；token存在哪里；未登录能直接访问详情吗

登录页面调用 loginApi，成功且有 accessToken 时用 setToken 保存。token 工具在 localStorage 中使用固定名称 token 存储动态凭证。请求拦截器读取凭证并设置 Authorization: Bearer。路由守卫检查是否有 Token；白名单是 /login、/register、/guide，其他路由未登录时跳转登录页，query.redirect 保存原地址。登录成功使用 router.replace 返回 redirect，没有则到 /home。

**边界：** 前端判断 Token 是否存在，不是在浏览器里验证签名或后端权限。未见自动刷新 Token 的实现。不能宣称 HttpOnly Cookie、refresh token 或无感续期已完成。

依据：src/utils/token.ts:1、src/utils/request.ts:33、src/router/index.ts:91、src/views/LoginView.vue:48

### QG-03 登录失效统一处理

可覆盖提问：token过期怎么办；多个接口同时401会怎样

响应拦截器同时处理业务错误码 A00004 和 HTTP 401，调用 handleUnauthorized 清除本地 Token；若当前不是登录/注册页，则记录原路径并用 router.replace 跳转登录。redirectingToLogin 防止同时重复跳转。业务码失效还会以 rejected Promise 交给调用方处理。

**边界：** 旧资料“还没有统一处理401”不符合当前代码。统一跳转不是自动续期；不能把这个实现描述成刷新 Token。

依据：src/utils/request.ts:4、src/utils/request.ts:7、src/utils/request.ts:46

### QG-04 商品搜索与历史记录

可覆盖提问：搜索历史怎么去重；商品搜索怎么做；搜索列表有无限滚动吗

显式搜索由 doSearch 发起 searchProducts，参数包含商品名称与分页信息，返回 records 更新商品列表。搜索历史在 localStorage 中保存，最近搜索放最前，去重后最多保留10条。热门搜索请求失败或没有结果时使用本地候选词。300ms 防抖作用于 AI 搜索联想输入，不应说整个商品查询接口都被同一防抖自动触发。

**边界：** 本地热门词是兜底展示，不是业务后端返回的实时热度排行。不能从分页参数推断当前页面已经实现无限滚动。

依据：src/views/SearchView.vue:59、src/views/SearchView.vue:80、src/views/SearchView.vue:154、src/api/search.ts:4、src/types/search.ts:1

### QG-05 搜索联想防抖与请求竞态

可覆盖提问：连续输入时旧请求覆盖新结果怎么办；防抖和取消为什么都需要

handleSuggestionInput 先清除旧定时器并取消已发出的请求，同时递增 suggestionRequestId；等待300ms后创建新的 AbortController 并请求联想。响应返回时比较 requestId，只允许最新输入更新结果和加载状态。清空输入、执行显式搜索和页面卸载都会停止联想请求。取消与请求编号分别提供中止请求和防止过期结果更新的保护。

**边界：** 当前取消和请求编号已实现，不是待改进项。这里只涉及联想链路，不能推广为所有接口都有取消、去重和乱序保护。

依据：src/views/SearchView.vue:28、src/views/SearchView.vue:40、src/views/SearchView.vue:119、src/views/SearchView.vue:185

### QG-06 搜索联想缓存与格式降级

可覆盖提问：搜索缓存是LRU吗；AI返回格式错误怎么办

联想函数使用trim后转小写的关键词作为缓存键。缓存是当前页面运行期的内存Map，TTL为5分钟，最多30个键，达到限制时删除最先插入的键。返回文本处理顺序为：先按换行或逗号拆分→去编号并trim→去空项→每项截到10个字符→取前5条→检查所得数组长度是否为5；因此原始6条会取前5条并接受，不是拒绝超过5条的原始响应。不足5条或请求失败时转本地规则。兜底先匹配品类规则，没匹配则用当前关键词拼接热卖/新品/推荐/优惠/排行榜，并非全部固定词。主动取消继续抛AbortError；成功结果和降级结果都可能进入缓存。

**边界：** 处理顺序不能改说成“先取5条再清洗”。缓存不是Redis、localStorage、LRU或数据库缓存；刷新页面会丢失。联想兜底与热门搜索的固定候选是两条不同流程，不能混为一谈。格式校验不保证建议语义准确。

依据：src/ai/searchSuggestions.ts:11、src/ai/searchSuggestions.ts:40、src/ai/searchSuggestions.ts:65、src/ai/searchSuggestions.ts:84、src/ai/searchSuggestions.ts:97

### QG-07 AI 请求层与服务端函数边界

可覆盖提问：AI请求怎么封装；密钥放哪里；取消和超时怎么区分

前端 requestAI 通过业务基础地址下的 /ai/chat POST 发送 promptText，使用 AbortController 提供默认10秒超时并接受外部取消。仓库另有 functions/ai/chat.js：从服务端环境读取密钥，校验请求和提示词长度，再转发 OpenAI 兼容接口并返回 text。函数的默认模型是 glm-5.3-flash，可通过环境变量覆盖。

**边界：** 静态代码只能证明存在请求层和函数实现，不能证明部署时前端的 /ai/chat 一定路由到这个函数，也不能确认线上模型及环境变量。前端 isAvailable 当前恒为true，不是真实配置检测。此链路不是 Copilot Native 的 DeepSeek 配置。

依据：src/ai/providers/openai.ts:8、src/ai/providers/openai.ts:14、functions/ai/chat.js:2、functions/ai/chat.js:12

### QG-08 购物车扁平化、选择与总价

可覆盖提问：购物车全选反选怎么实现；购物车总价由谁计算

后端购物车结构包含店铺、优惠分组和商品。cartItems 计算属性遍历三层结构得到商品对象数组，保留原对象引用。selectedBasketIds 从已选对象提取ID；allChecked 使用非空数组加 every 判断全选。全选修改商品 checked。watch 监听已选ID并请求 totalPay 接口；没有选中项时总价归零。价格展示来自接口，不是仅在前端相加。

**边界：** 没有依据证明后端优惠规则、库存校验或最终价格计算由候选人实现。当前总价请求没有看到与联想相同的编号乱序保护，不能声称所有总价竞态已消除。

依据：src/views/CartView.vue:19、src/views/CartView.vue:23、src/views/CartView.vue:36、src/views/CartView.vue:48、src/api/cart.ts:10

### QG-09 购物车数量请求保护

可覆盖提问：快速点加号会不会重复请求；购物车数量是绝对值还是增量

updatingBasketIds 用 Set 记录正在更新的购物车项；同一 basketId 请求未结束时直接返回，模板禁用该项步进器。新数量转换为相对于当前数量的 delta，调用 changeItem。成功后更新数量或删除商品，并重新获取总价；finally 删除处理中标记。购物车和地址首次加载用 Promise.all 并行获取。

**边界：** 这是同一购物车项的前端保护，不是全局排队、后端幂等或分布式锁；不同商品仍可同时更新。旧笔记说该保护尚待实现已过时。

依据：src/views/CartView.vue:14、src/views/CartView.vue:88、src/views/CartView.vue:118、src/views/CartView.vue:182、src/views/CartView.vue:65、src/types/cart.ts:1

### QG-10 订单确认、地址选择与临时状态

可覆盖提问：购物车到下单怎么传数据；为什么订单用sessionStorage；换地址后怎么更新订单

购物车结算把 basketIds 和 addrId 保存到 sessionStorage.confirmOrder 后进入确认页。立即购买保存单独的 orderItem 参数。确认页读取并解析临时数据，重新查询地址，使用当前默认地址或首个地址更新 addrId，再调用确认订单接口。地址页在来自购物车或订单的选择模式下调用设置默认地址接口，成功后返回上一页。

**边界：** 地址选择改变的是后端默认地址，不只是前端本次订单局部选择。sessionStorage保存临时参数，不是订单持久化数据库，也不能信任为最终价格或库存。

依据：src/views/CartView.vue:123、src/views/ProductDetailView.vue:129、src/views/OrderConfirmView.vue:15、src/views/AddressView.vue:247、src/views/AddressView.vue:219

### QG-11 下单、支付及订单列表

可覆盖提问：下单和支付的流程；取消支付会怎样；支付是否接微信支付宝

确认页把店铺备注、checkoutItems 和 addrId 发送 submitOrder。成功取得订单号后先移除 confirmOrder，再显示支付确认弹窗；取消支付进入待支付提示，确认后调用 payOrder，payType固定为1。订单列表按待付款、待发货、待收货、已完成分别保存分页状态，每页10条；加载失败回退页码，可调用支付与确认收货接口并刷新当前页签。

**边界：** 临时参数是在拿到订单号后清除，不是支付成功才清除。当前仓库是前端调用支付接口，不能证明接入微信/支付宝、支付回调、订单事务、库存原子扣减或真实资金流。

依据：src/views/OrderConfirmView.vue:50、src/api/order.ts:23、src/views/MyOrderView.vue:33、src/views/MyOrderView.vue:52、src/views/MyOrderView.vue:137

### QG-12 商品详情、卖点与导购

可覆盖提问：商品详情怎么加载；AI卖点和AI导购有什么区别

商品详情、收藏状态和评论并行加载，再单独生成商品卖点。SKU选择影响加入购物车和立即购买参数。卖点通过共享AI请求层生成，异常时使用分类或通用本地文案；成功文本当前仅按换行拆分。GuideView 调用 /guide/recommend 获取推荐结果，并可进入商品详情。

**边界：** 卖点没有搜索联想那样的严格数量校验，通用兜底也不是固定4条。导购只见前端接口调用，不能宣称已在此仓库实现商品检索、向量数据库、RAG推荐或模型训练。

依据：src/views/ProductDetailView.vue:36、src/views/ProductDetailView.vue:105、src/ai/productSellingPoints.ts:23、src/views/GuideView.vue:20、src/api/guide.ts:4

### QG-13 路由懒加载与部署恢复

可覆盖提问：发版后旧页面分包404怎么处理；为什么路由懒加载

路由页面使用动态 import，Layout 同步导入。setupDeploymentRecovery 监听 vite:preloadError 与路由动态加载错误；用 sessionStorage 记录目标地址避免立即重复恢复，刷新URL带 _app_reload 参数。成功进入目标路由后移除恢复记录。入口注册该恢复逻辑。

**边界：** 可以解释减少首屏一次加载代码和恢复旧分包失败的作用，但没有测量数据，不能声称首屏提升某个百分比或保证零失败。

依据：src/router/index.ts:5、src/utils/deploymentRecovery.ts:18、src/utils/deploymentRecovery.ts:26、src/main.ts:8

### QG-14 页面结构、状态归属与组件通信

可覆盖提问：购物车为什么没用Pinia；组件之间怎么传值；项目目录怎么分层

轻购入口main.ts创建Vue应用，安装router并挂载App。根路由Layout承载RouterView和TabBar，首页、分类、购物车、我的为子页面，详情、搜索、地址、订单等独立路由按需加载。页面各自用ref保存请求结果、loading和用户输入，computed派生选择和展示状态，watch响应依赖变化。购物车数据由接口取回，而不是放在全局store。商品规格ActionPanel通过props接收skuList/selectedSku，通过confirm事件把选中的SKU回传给详情页，父页面维护最终选择。这样能讲清页面、业务请求和展示组件的分工。

**边界：** 源码没有Pinia/Vuex、全局事件总线、全站KeepAlive缓存或复杂领域分层。组件状态不等于跨页面持久化。技术选择的作用可解释，不能编造当时选型会议。

依据：src/main.ts:1、src/components/Layout.vue:7、src/components/TabBar.vue:2、src/components/ActionPanel.vue:66、src/router/index.ts:1、src/App.vue:1

### QG-15 首页聚合与分类联动

可覆盖提问：首页数据怎么加载；从首页如何跳到指定分类；快速切分类会乱吗

HomeView初始化用Promise.all并行请求轮播、公告、商品分组，分别写入ref，finally结束骨架加载。商品点击携带prodId进入详情。点首页分类时在sessionStorage写fromHome标记，并在query.value携带分类名；CategoryView初始化映射分类名到侧栏索引，然后移除标记、请求分类列表并加载选中类别的商品。分类API取得categoryName后映射为Vant需要的text，商品使用data.records；切换分类重新请求，失败清空商品并提示，分类整体失败保留错误文案和重试入口。

**边界：** 分类名到索引为本地固定映射，不能说后端动态配置。首页Promise.all任一失败会进入catch；分类请求没有联想模块的取消和编号保护，快速切换竞态仍可改进。

依据：src/views/HomeView.vue:38、src/views/CategoryView.vue:11、src/api/category.ts:8、src/api/home.ts:3、src/types/home.ts:1

### QG-16 登录注册表单校验与重复提交

可覆盖提问：登录密码做了AES吗；怎么防止重复登录提交；注册有什么表单验证

登录和注册使用Vant表单，用户名规则为3到16位字母数字下划线，密码规则为6到16位数字。两页提交函数都先检查submitting，开始请求前置true，finally恢复，避免同页重复提交。登录调用/login提交userName/passWord，成功取得accessToken才保存并回跳；注册调用/user/register，成功提示后延时两秒转登录。仓库虽有encryptPassword工具，当前这两个页面没有导入或调用它，实际请求参数直接使用表单值。

**边界：** 不能把存在的AES工具说成登录已加密；传输安全要看实际HTTPS和后端。本前端校验不能替代服务端校验，未见密码强度策略、短信登录、找回密码或刷新Token流程。

依据：src/views/LoginView.vue:48、src/views/RegisterView.vue:14、src/utils/encrypt.ts:5、src/api/userInfo.ts:3

### QG-17 请求封装、鉴权与安全边界

可覆盖提问：请求层如何统一错误处理；token放localStorage安全吗；delete参数如何传

Axios请求实例集中设置业务基础URL和5秒超时，提供get/post/put/del薄封装，delete有数据时放config.data。请求拦截器按需附加Bearer凭证，响应成功分支返回response.data而非完整AxiosResponse，登录失效业务码或HTTP401集中处理。组件通过src/api按功能调用，避免到处重复拼请求。Token保存在localStorage，方便刷新后读取，但能被同源JavaScript访问，不能称为安全隔离；可把HttpOnly Cookie、严格输入输出处理等作为后续方案，不能说已实现。

**边界：** 没有自动重试队列、refresh token、请求签名、统一全接口取消或CSRF方案的证据。不能把前端路由守卫视为后端接口授权。

依据：src/utils/request.ts:28、src/utils/token.ts:1、src/router/index.ts:93

### QG-18 地址增删改、默认地址与地区级联

可覆盖提问：地址管理怎么实现；省市区如何懒加载；为什么默认地址不能直接删除

AddressView用list/add/edit三种mode复用页面。加载地址映射成Vant的id/name/tel/address/isDefault；编辑保留整条原对象editingAddress，提交时按mode选择新增或更新。省市区按pid请求：先pid=0取省，选择上级时按需取children，最后一次保存三级ID和名称。保存前检查收件人、电话、详细地址和区ID。删除先验证当前编辑对象是否默认，再对比列表默认项ID，默认地址要求先切换默认项，其他地址经确认弹窗后删除。订单/购物车选择模式由query.from判断，点选会调用设置默认地址接口，成功再返回。

**边界：** 选择收货地址会改变服务端默认地址，不是单次订单独立地址状态。前端目前只是非空检查，不能说已校验全部手机号/地址合法性。省市区请求未见乱序保护。

依据：src/views/AddressView.vue:20、src/api/address.ts:19、src/views/OrderConfirmView.vue:15

### QG-19 SKU规格选择与父子组件数据流

可覆盖提问：商品规格选择是怎么做的；子组件如何通知父组件；无效SKU组合怎么办

详情响应内skuList取为规格候选，默认选择第一条。ActionPanel的propertyMap遍历每个sku.properties，把分号分组、冒号分割的属性收集到以属性名为键的Set，用于去重展示选项。selectedSku通过immediate watch初始化selectedProps；点击属性更新所选值，再按Object.entries顺序拼回properties字符串，用全等find查找SKU，找到则emit confirm给父页。父页更新selectedSku、关闭规格面板，加购发送prodId/skuId/shopId/count且basketId为0，立即购买则保存单个orderItem。

**边界：** 字符串匹配依赖属性顺序，匹配不到时回退旧selectedSku；没有完整不可选组合禁用、库存联动算法的证据。不能说所有SKU组合都已严格校验。

依据：src/components/ActionPanel.vue:23、src/views/ProductDetailView.vue:100、src/api/cart.ts:3

### QG-20 订单分页、状态切换与失败恢复

可覆盖提问：订单列表如何加载更多；切换订单tab会保留数据吗；加载失败页码怎么处理

订单列表为四个tab分别创建{current,load,finished,list}，状态码分别1、2、3、5。loadData检查正在加载或已结束后返回，页码先加一，每页请求10条；第一页替换列表，后续追加，按空记录、总页数或不足10条判断结束，异常时页码回退，finally清加载标记。切换tab当前实现先resetTab再加载第一页，而不是保留旧列表不刷新。入口query.active经整数和范围检查选择初始tab。付款和确认收货验证订单号，弹窗确认后调用接口，成功刷新当前tab，金额转数值失败显示0.00。

**边界：** 没有订单WebSocket推送；分页隔离不等于缓存所有tab并永久免请求。支付接口调用不证明真实支付渠道或后端事务。

依据：src/views/MyOrderView.vue:10、src/api/order.ts:19、src/views/MineView.vue:26

### QG-21 AI导购的输入、结果和业务跳转

可覆盖提问：自然语言导购如何实现；推荐是不是RAG；导购与搜索联想区别

GuideView维护query/loading/result，输入trim后少于2个字符提示，提交前清空旧结果并置加载中，调用getGuideRecommendations，POST /guide/recommend带query。success为false或请求失败显示提示，finally结束加载；界面提供示例需求，推荐结果类型含需求总结、推荐商品及解释，点商品携prodId进入详情。GuideFab按钮只是router.push到/guide，路由白名单允许未登录进入导购页。

**边界：** 这个仓库可证明输入和推荐结果消费，不能证明推荐后端如何检索商品、生成排名、调用模型或用了向量库。AI搜索联想、卖点、导购是不同流程。

依据：src/views/GuideView.vue:20、src/api/guide.ts:4、src/types/guide.ts:1、src/components/GuideFab.vue:14

### QG-22 详情加载、收藏评论与AI卖点降级

可覆盖提问：AI很慢会不会卡住商品页；商品收藏如何同步；卖点接口异常怎么办

loadProductDetail从query解析prodId，无有效ID时结束加载；并行请求详情、收藏状态、评论，详情imgs按逗号拆图片，取skuList默认首项，先结束商品主体loading再异步生成卖点，所以AI慢不应被描述成主体一直阻塞。收藏接口addOrCancel成功后重新拉取收藏状态再更新展示。卖点把商品名、价格、描述拼成提示词，请求共享tryAI；失败按品类给本地文案，否则通用三条，页面记录openai或fallback来源。

**边界：** 商品主体三个接口用Promise.all，任一失败可能影响整体赋值。卖点成功只按换行拆，未做搜索联想同等清洗校验；AI文案不是可验证的商品真实性保证。

依据：src/views/ProductDetailView.vue:36、src/ai/productSellingPoints.ts:23、src/api/product.ts:13

### QG-23 个人中心、订单数量与退出登录

可覆盖提问：个人中心如何加载订单数量；退出登录都清理了什么

MineView在onMounted调用getOrderCount取得各状态订单数量，finally关闭loading，点击订单入口携query.active进入订单列表。退出通过removeToken删除localStorage凭证并router.replace到/login；当前页面没有调用服务端登出接口，也没有全局清空搜索历史的逻辑。页面订单入口与订单列表四个tab索引对应。

**边界：** 不能宣称登出使服务端JWT立即失效、清理所有浏览器数据或多端同步退出。

依据：src/views/MineView.vue:21、src/api/order.ts:3、src/utils/token.ts:11

### QG-24 骨架加载、空态与界面反馈

可覆盖提问：项目如何处理加载和空白页面；骨架屏怎么复用

ContentSkeleton按home/list/detail/profile/form/lines变体和rows渲染不同占位结构，用role=status、aria-live=polite和内容加载中标签表达加载状态。首页、分类、详情、购物车、地址、个人中心、订单等页面按各自loading切换占位和内容。业务操作主要用Vant Toast反馈成功/失败，删除或支付等部分流程使用确认Dialog，分类有整体错误文案与重试。

**边界：** 统一骨架组件不代表所有页面都实现相同容错或完整无障碍。不能凭占位效果宣称有真实首屏耗时优化数据。

依据：src/components/ContentSkeleton.vue:2、src/views/CategoryView.vue:44、src/views/CartView.vue:11

### QG-25 移动端适配与Vant按需引入

可覆盖提问：移动端如何适配不同屏幕；为什么两个rootValue；Vant怎么按需加载

main.ts导入amfe-flexible，PostCSS的postcss-pxtorem转换px，普通源码rootValue为75、Vant源码为37.5，propList为全部属性；两种基准对应项目样式和组件样式。vite用unplugin-vue-components搭配VantResolver自动导入组件，并用unplugin-auto-import的resolver处理相关API；部分Toast/Dialog样式仍在页面显式导入。TabBar设置safe-area-inset-bottom，Layout承载主内容和固定底栏。

**边界：** 是rem适配，不能说采用vw全量适配或已有全机型测试。Vant组件自动导入不代表Vue所有API都不需要import；性能收益没有实测数字。

依据：src/main.ts:2、postcss.config.cjs:4、vite.config.ts:20、src/components/TabBar.vue:2

### QG-26 购物车到订单的端到端链路

可覆盖提问：从选商品到支付完整流程是什么；立即购买和购物车结算有何区别

完整链路是商品详情选择SKU和数量→调用changeItem加购→购物车拉店铺/优惠/商品三层列表并扁平派生→勾选basketIds请求totalPay→sessionStorage暂存结算参数→确认页重新拉最新地址并调用confirm→submit携checkoutItems、店铺备注、addrId生成订单→拿到订单号清临时参数→用户确认才调pay→订单列表按状态查询并可支付/收货。立即购买跳过购物车，用orderItem进入同一确认流程。最终价格和业务校验应以服务端为准，前端负责参数组织和交互。

**边界：** 前端没有支付回调、库存锁、优惠计算或订单事务源码。不能补成“已实现秒杀、高并发、分布式订单系统”。

依据：src/views/ProductDetailView.vue:129、src/views/CartView.vue:123、src/views/OrderConfirmView.vue:50、src/api/order.ts:15

### QG-27 项目亮点、技术取舍与可改进项

可覆盖提问：项目最有挑战的地方；有哪些不足；有什么性能优化；为什么不用更复杂方案

可用作技术展开的具体实现：AI联想同时做300ms防抖、AbortController取消、请求编号保护、5分钟30项Map缓存和格式失败降级；购物车按basketId防重复数量更新；动态import失败有部署恢复；订单页按tab隔离分页与失败回退。可解释这些做法分别解决频繁请求、过期响应覆盖、等待时间和失败体验。仍可改进的源码事实：购物车总价请求无编号保护；SKU字符串匹配依赖顺序；分类/地址级联缺竞态保护；多个any弱化类型约束。

**边界：** 这提供“可以分享的实现和取舍”，不证明本人曾遇到某次线上事故或主导优化。没有压测、QPS、转化率或耗时对比数据，不要编造。

依据：src/views/SearchView.vue:119、src/ai/searchSuggestions.ts:11、src/views/CartView.vue:48、src/components/ActionPanel.vue:68

### QG-28 构建、部署范围与未实现能力

可覆盖提问：有没有SSR或虚拟列表；用什么测试；Redis缓存在哪里；项目如何打包部署

package.json的build并行执行vue-tsc类型检查和Vite构建，开发支持/api代理重写去掉前缀，业务默认基础URL另由request层决定。public有站点图标/manifest文件，但这些本身不能证明离线能力。仓库核心是浏览器SPA前端，源码没有Pinia、SSR、虚拟列表、WebSocket、自动刷新Token或自动化测试脚本的依据。路由懒加载和防抖可解释作用，性能结论需要测量。

**边界：** 构建脚本存在不证明本轮已执行或通过；不存在某依赖不意味着不能另行服务实现。后端未知应明确无法从当前仓库确认，不能用常见电商架构补事实。

依据：package.json:6、vite.config.ts:30、public/site.webmanifest:1、src/utils/request.ts:29

### QG-29 AI代理校验与前后端边界

可覆盖提问：AI代理如何保护密钥；接口有没有限流；请求参数如何校验

functions/ai/chat.js仅接受POST，检查Origin与当前URL的origin一致（缺Origin时不触发此项拒绝），从服务端环境读模型密钥；解析JSON并校验promptText非空且不超过1200字符，maxTokens限制1到300，以环境配置或默认兼容模型转发chat/completions，成功从choices[0].message.content提取text；无密钥、无效格式、上游错误或空结果分别返回错误状态，响应Cache-Control为no-store。前端只发提示词、tokens和温度，不携模型密钥。

**边界：** Origin比较不是完整身份鉴权、限流或防滥用；当前代码未见这些能力。仓库函数与实际业务域名的路由对应需要部署证据，不可断言线上必走该函数。

依据：functions/ai/chat.js:12、src/ai/providers/openai.ts:14

## datapilot-rebuild

### CITY-01 项目范围与技术栈

可覆盖提问：介绍城市视图；数据可视化项目的架构

城市视图是城市数据可视化管理前端。页面包含城市仪表盘、仪表盘管理与详情、图表管理与编辑、地图、3D场景、AI对话、用户、角色和个人资料。依赖包含React 19、TypeScript、Redux Toolkit、redux-persist、React Router、Ant Design、ECharts、React Three Fiber、Drei、高德地图JS API、Axios和Vite。

**边界：** 仓库当前代码不能证明个人职责、团队规模或真实政务生产环境，也不能证明后端数据库和数据采集由候选人实现。

依据：package.json:12、src/router/index.tsx:39

### CITY-02 全局状态与持久化范围

可覆盖提问：为什么用Redux；哪些状态持久化；刷新页面登录态怎么保留

store通过combineReducers合并auth和app。auth保存token与user，setAuth和clearAuth统一更新；app保存theme。redux-persist 使用浏览器localStorage，并通过whitelist持久化auth和app。布局折叠等状态用组件内部useState，不在当前appSlice中。

**边界：** 不能说所有页面数据、布局状态或图表配置都保存进Redux；持久化不是浏览器安全存储或后端会话验证。

依据：src/store/index.ts:20、src/store/authSlice.ts:5、src/store/appSlice.ts:11、src/layouts/MainLayout/index.tsx:114、src/types/auth.ts:1

### CITY-03 请求鉴权与登录失效

可覆盖提问：城市项目的401怎么处理；拦截器怎么获取token

Axios实例以/api为baseURL，超时10秒。请求拦截器从store读取token并添加Bearer。响应拦截器对带数值code且不为200的业务响应抛错误，其中业务401清空auth；HTTP401也清空auth，但HTTP分支排除登录接口。受保护路由随token/user状态变化跳转登录。

**边界：** 不是Axios直接操作路由跳转，也不是自动刷新Token。业务401分支没有与HTTP401相同的登录接口排除条件。

依据：src/utils/request.ts:5、src/utils/request.ts:10、src/utils/request.ts:26、src/components/RequireAuth.tsx:7

### CITY-04 角色菜单与页面权限

可覆盖提问：权限怎么实现；隐藏菜单能防越权吗；动态路由是后端生成的吗

权限工具将data_analyst映射为analyst。菜单过滤递归处理子菜单，允许当前角色或仍有可见子项时保留节点；super_admin直接保留全部。页面权限使用pagePermissions路径表，详情及编辑页匹配所属路径前缀。RequireAuth先检查token和user，再检查角色能否访问路径；GuestOnly防止已登录用户再次进入登录页。

**边界：** 当前前端页面访问规则是本地角色路径表，不是实时由后端权限树驱动全部路由；没有匹配的路径当前默认允许。前端控制不能替代后端授权。

依据：src/utils/permission.ts:4、src/utils/permission.ts:21、src/utils/permission.ts:36、src/components/RequireAuth.tsx:23、src/layouts/MainLayout/index.tsx:126、src/types/menu.ts:1

### CITY-05 仪表盘并行请求与刷新

可覆盖提问：仪表盘怎么刷新；数据是实时推送的吗；五个接口一个失败怎么办

仪表盘一次用Promise.all并行请求概览、事件统计、设施统计、交通排行、最新事件五项，全部成功后写入各页面状态。页面使用useMemo构建部分统计项和图表option。初次加载后每300000毫秒即5分钟刷新，卸载时清理定时器；任一请求失败进入统一错误提示。

**边界：** 这是轮询，不是WebSocket实时推送。没有各卡片独立容错更新，也不能仅凭Promise.all声称缩短多少毫秒。

依据：src/pages/Dashboard/index.tsx:70、src/pages/Dashboard/index.tsx:107、src/pages/Dashboard/index.tsx:137、src/types/dashboard.ts:1

### CITY-06 CSV导出实际方式

可覆盖提问：如何导出CSV；为什么下载后要释放URL

城市或事件导出调用后端/export/cities或/export/events，参数format=csv，Axios指定responseType=blob。浏览器通过URL.createObjectURL生成临时地址，用a标签触发下载，然后移除元素并revokeObjectURL释放对象URL。

**边界：** 当前是下载后端生成的数据文件，不是前端把图表或表格数据手动拼接成CSV，也不是ECharts截图导出。

依据：src/pages/Dashboard/index.tsx:115、src/utils/download.ts:4、src/types/download.ts:1

### CITY-07 数据源级联与图表预览

可覆盖提问：图表编辑器怎么实现；切换数据源为什么清空字段

图表编辑器先选择归属仪表盘及数据源，再选择表、X/Y字段、标题和类型。数据源变化清空表、字段和预览并请求表列表；表变化清空字段与预览并请求字段。预览调用/datasources/:id/query，由返回rows生成option。支持新建和编辑，保存datasourceId、queryConfig、类型及位置等配置后返回仪表盘详情。

**边界：** 真实数据预览指前端使用查询API结果，不能据此证明上游数据采集质量、生产数据规模或后台SQL由候选人实现。当前级联请求未看到请求编号保护，不能声称已经处理所有切换竞态。

依据：src/pages/ChartEditor/index.tsx:140、src/pages/ChartEditor/index.tsx:159、src/pages/ChartEditor/index.tsx:179、src/pages/ChartEditor/index.tsx:231、src/api/datasource.ts:34、src/types/datasource.ts:1、src/types/dashboardManage.ts:1

### CITY-08 图表数据映射与资源释放

可覆盖提问：图表如何适应容器大小；ECharts内存泄漏怎么避免；折线图保持时间顺序吗

formatChartOption对rows按Y字段数值降序复制排序：饼图最多8条、散点10条、柱/折线12条。根据类型构建option，散点将X/Y转数值。ChartRenderer按需注册四种图表及必要组件与CanvasRenderer，使用ResizeObserver监听容器并resize；卸载或主题改变时断开observer并dispose实例，option变化调用setOption。

**边界：** 排序和截取是当前具体展示策略，不能说折线图自动保持时间序列顺序；不是无限数据可视化或大规模渲染优化的证明。

依据：src/utils/chart.ts:13、src/utils/chart.ts:24、src/utils/chart.ts:29、src/components/ChartRenderer/index.tsx:10、src/components/ChartRenderer/index.tsx:53、src/types/chart.ts:1

### CITY-09 地图模式、数据来源与清理

可覆盖提问：高德地图如何接入；环境接口部分失败怎么办；切换地图模式怎么清理

高德JS API 2.0通过loader初始化，页面有城市、环境、交通三种模式。城市列表最多取20条，逐城环境请求使用Promise.allSettled，允许部分环境接口失败；交通数据也独立捕获失败。城市模式显示Marker，环境模式用AQI等级颜色绘制Circle，点击后显示信息。模式切换清理覆盖物，卸载destroy地图。

**边界：** 底图来自高德，城市/环境/交通业务值来自本项目业务API，不应说都由高德实时提供。环境圆是可视化覆盖物，不证明真实污染扩散半径。

依据：src/pages/MapView/index.tsx:129、src/pages/MapView/index.tsx:191、src/pages/MapView/index.tsx:234、src/pages/MapView/index.tsx:259

### CITY-10 交通热力与周边距离

可覆盖提问：热力图数据怎么转换；附近城市距离如何算；是导航距离吗

交通模式筛选有效经纬度及拥堵值，降序排序后把congestionIndex映射为HeatMap的count；另有圆形覆盖物分支，cleanup解除热力图地图绑定。周边城市计算调用distanceKm，以Haversine球面距离公式估算两地距离，再按用户选择的radiusKm过滤。

**边界：** 球面距离不是道路行驶距离、导航路线或交通耗时。数据是业务API结果，不等于高德实时交通图层。

依据：src/pages/MapView/index.tsx:284、src/pages/MapView/index.tsx:315、src/pages/MapView/index.tsx:432、src/utils/geo.ts:3

### CITY-11 3D指标柱图与本地城市沙盘

可覆盖提问：3D沙盘如何实现；楼层如何展开；3D柱子高度怎么计算

3D页面有model城市沙盘和chart指标柱图两种模式。柱图从城市API取数据，按人口/面积/GDP所选指标排序，按最大值映射高度为1.2+(值/最大值)*4.8，并沿圆周摆放。Canvas建立场景，OrbitControls控制视角，CityColumn用useFrame实现缩放生长。沙盘建筑来自本地sandboxZones，使用几何体生成建筑，选择建筑后可把楼层间距展开。

**边界：** 指标柱图使用接口数据；本地沙盘不是接口城市的GIS建筑模型、BIM或真实城市数字孪生。不要把沙盘的静态楼层配置说成实时建筑数据。

依据：src/pages/Scene3D/index.tsx:142、src/pages/Scene3D/index.tsx:158、src/pages/Scene3D/components/CityColumn.tsx:25、src/pages/Scene3D/sandboxZones.ts:10、src/pages/Scene3D/components/CitySandbox.tsx:32

### CITY-12 AI对话持久化与SSE

可覆盖提问：AI对话如何保持上下文；流式回复如何解析；聊天记录保存在哪

AI页通过业务API读取、创建、删除会话并保存消息。发送时将当前messages加上新用户消息POST到/api/ai/chat，携带Bearer。前端用ReadableStream reader及TextDecoder解析双换行分隔的SSE事件，处理JSON中type为text、fallback、thinking的content并追加到回复；完成后把回复保存到会话接口。

**边界：** 本仓库只有前端解析与接口调用，不能证明后端采用哪家模型、是否使用RAG、数据库结构或工具调用。该SSE格式是业务事件格式，不应说直接按OpenAI的choices.delta.content解析。

依据：src/pages/AIChat/index.tsx:101、src/pages/AIChat/index.tsx:139、src/pages/AIChat/index.tsx:161、src/api/ai.ts:9

### CITY-13 用户、角色和权限配置界面

可覆盖提问：用户和角色管理有哪些操作；权限树和路由是什么关系

用户界面通过API提供分页、用户名/角色/状态筛选，支持新建、编辑、删除、状态变更、重置密码。角色界面提供CRUD及权限树勾选，把勾选权限ID发送给角色权限接口。前端用于菜单与路由的角色路径规则仍是本地permission.ts，不是自动读取此权限树驱动全部页面。

**边界：** 界面功能与前端路由权限是两条不同的数据链路，不能合并成“动态权限树自动生成全部路由”。不能依据前端API声明证明后端操作都已通过运行验证。

依据：src/pages/UserManage/index.tsx:31、src/pages/RoleManage/index.tsx:102、src/api/admin.ts:15、src/api/admin.ts:43、src/utils/permission.ts:4、src/types/admin.ts:1

### CITY-14 页面懒加载与错误恢复

可覆盖提问：React路由分包失败怎么恢复；错误边界怎么处理

路由使用lazyWithRetry包装动态import，Suspense显示加载状态。识别分包加载错误时用sessionStorage按chunkName记录时间，超过30秒窗口可自动reload，同窗口再次失败则抛出错误，交给外层AppErrorBoundary。成功import后清除对应记录，主题通过Redux驱动Ant Design与图表。

**边界：** 有明确重试窗口，但没有性能测量或线上故障率数据。不能描述成无限重试或无错误恢复。

依据：src/utils/lazyWithRetry.ts:18、src/router/index.tsx:7、src/router/index.tsx:41、src/App.tsx:73

### CITY-15 应用启动、布局导航与页面结构

可覆盖提问：项目整体结构怎么组织；刷新后怎么恢复登录态；移动端菜单如何适配

main.tsx通过StrictMode包裹Redux Provider、PersistGate和BrowserRouter再渲染App，等持久化状态恢复后进入路由。根路由RequireAuth内是MainLayout，Outlet展示仪表盘、图表、地图、3D、AI和管理页面，登录页GuestOnly，未知地址跳/dashboard。MainLayout根据角色过滤菜单，按当前路径计算选中项、展开父节点和面包屑；用Grid.useBreakpoint判断lg以下移动视口，以Drawer替代桌面Sider，导航后关闭抽屉，折叠/抽屉状态是本地useState。

**边界：** 这是SPA和本地静态路由定义，不是SSR、微前端或后端直接下发React组件。布局状态不在Redux持久化范围内。

依据：src/main.tsx:2、src/router/index.tsx:39、src/layouts/MainLayout/index.tsx:113

### CITY-16 验证码登录、认证与重定向

可覆盖提问：验证码如何实现；登录后如何保存身份；登录失效后谁负责跳转

Login先getCaptcha取得captchaId和svg，清空旧状态后把UTF8 SVG转base64 data URL展示，缺关键字段显示加载错误。提交用户名、密码、captchaId、captchaCode，业务成功后dispatch setAuth存token和user，再replace到/dashboard；失败或异常重新加载验证码，finally关闭loading。RequireAuth要求token和user同时存在，并检查角色路径权限；HTTP401/业务401清auth后由路由状态驱动回登录，GuestOnly根据token避免重复进入登录页。

**边界：** 未实现登录前原路径回跳，也未见refresh token或浏览器验证JWT签名。验证码生成与校验在后端，本仓库不能证明其算法。

依据：src/pages/Login/index.tsx:29、src/api/auth.ts:11、src/components/RequireAuth.tsx:7

### CITY-17 图表编辑向导、编辑回填与保存配置

可覆盖提问：编辑图表如何回填；图表配置存了什么；仪表盘支持拖拽吗

ChartEditor按路由id区分新建/编辑，初始化并行加载前100个仪表盘和数据源，可用query.dashboardId预选归属；编辑时取图表详情，回填标题、类型、数据源、表、X/Y，依次加载表和字段后进入配置步骤。上一步/下一步按步骤验证Form字段，预览先query数据再formatChartOption生成option。保存统一构造ChartInput：dashboardId/datasourceId/title/chartType/queryConfig，chartConfig空对象，position固定{x:0,y:0,w:6,h:4}，sortOrder为0，再选择create或update并回详情。

**边界：** 前端传位置不代表已经实现可拖拽仪表盘布局。当前没有自定义SQL编辑器、自由图表插件或全量级联请求竞态保护。

依据：src/pages/ChartEditor/index.tsx:91、src/api/chartManage.ts:19、src/api/datasource.ts:34、src/types/chartManage.ts:10

### CITY-18 图表列表筛选、分页与两类预览

可覆盖提问：图表列表怎么筛选分页；列表预览和编辑器预览有什么不同

ChartManage用page/pageSize/total以及关键词、仪表盘和图表类型维护列表；输入keyword与提交的searchKeyword分离，真正搜索在回车/按钮提交后更新，清空输入可清搜索。loadCharts带筛选参数调/charts，详情操作跳编辑路由。列表预览打开Modal、清旧option，再POST /charts/:id/preview获取后端直接返回的ECharts option交ChartRenderer；这不同于编辑器预览和仪表盘详情用datasource.query返回rows再前端映射。删除成功后重新加载列表，重置同时清筛选并回第一页。

**边界：** 不要把所有预览说成同一数据转换链路，也不能称为前端筛选全部数据。当前表格分页不是虚拟列表。

依据：src/pages/ChartManage/index.tsx:65、src/api/chartManage.ts:31、src/pages/ChartEditor/index.tsx:179

### CITY-19 仪表盘管理、复制与详情容错

可覆盖提问：复制仪表盘怎么做；一张图查询失败会影响整个页面吗；为什么没按position布局

DashboardManage查询第一页20条，可按提交关键词搜索；创建Form成功后清表单并刷新，克隆调用/dashboards/:id/clone，删除成功重载，actionId表示进行中的复制/删除。详情先取仪表盘及charts，再Promise.all并行对每张有数据源和queryConfig的图表调用query；每个图表内部catch后返回data=null，保留其他成功结果。缺数据、查询失败或option无法生成展示空态。当前用Row/Col每张span=8排列，不依据position坐标执行拖拽布局。

**边界：** 复制是调用后端接口，不能确认后端如何复制关联关系或处理事务。管理列表当前固定第一页，不是无限分页。详情单图容错与首页五接口整体失败策略不同。

依据：src/pages/DashboardManage/index.tsx:41、src/pages/DashboardDetail/index.tsx:42、src/api/dashboardManage.ts:18

### CITY-20 用户管理、筛选与个人资料上传

可覆盖提问：用户管理怎么做分页筛选；头像上传完整流程；编辑不改密码如何处理

UserManage将用户名输入和已提交搜索词分开，带page/pageSize/status/roleId请求/users；支持创建、编辑、删除、PATCH状态及重置密码。编辑不填新密码时删掉password字段，避免空值覆盖。重置密码调用后端接口并用可复制文本展示返回的新密码。Profile从/auth/me加载资料，头像上传先限制2MB，FormData的file发送/upload/avatar，取返回URL暂存；用户点击保存时才PUT/users/:id带avatar，成功同步setAuth里的user，保留token并清密码框。

**边界：** 头像上传成功不等于资料已保存；accept只提示文件类型，当前上传函数仅校验大小。后端图片校验、权限、密码加密策略未知，不能宣称已确认。

依据：src/pages/UserManage/index.tsx:31、src/pages/Profile/index.tsx:48、src/api/admin.ts:36、src/utils/avatar.ts:3

### CITY-21 角色权限树与前端访问规则的区别

可覆盖提问：权限树怎么回显；后端改了角色权限前端路由会自动变化吗；按钮级权限做了吗

RoleManage并行取角色列表和权限树，toTreeData递归转换为Ant Tree节点；打开某角色配置取详情，通过collectIds递归收集已有权限ID回显，保存PUT/roles/:id/permissions带permissionIds。角色本身支持名称/编码/描述的增删改。菜单和RequireAuth另用permission.ts本地角色表：data_analyst归一化analyst，super_admin直接放行，详情/编辑路径继承列表前缀，未匹配路径默认允许。树配置和本地访问表目前没有自动绑定。

**边界：** 不能称为后端权限树动态生成全站路由或按钮级权限。前端隐藏入口不能替代后端鉴权，后端实际授权不能从接口定义推出。

依据：src/pages/RoleManage/index.tsx:12、src/api/admin.ts:62、src/utils/permission.ts:4、src/components/RequireAuth.tsx:5

### CITY-22 主题切换与图表生命周期

可覆盖提问：暗色模式如何实现；切换主题为什么要重建图表；ResizeObserver怎么清理

appSlice初始theme读取系统prefers-color-scheme，toggleTheme在light/dark切换，Redux持久化app；App根据当前theme给Ant Design ConfigProvider算法，布局Menu/Sider也消费theme。ChartRenderer用ref持DOM和ECharts实例，主题变化时effect先cleanup断ResizeObserver并dispose旧实例，再按新主题init；另一个effect依赖theme和option调用setOption，避免重建后丢配置。容器尺寸变化调用resize，页面卸载同样释放资源。

**边界：** 不是只更新CSS class，也不是每次option变化就销毁重建。未见后续持续监听系统主题变化的逻辑，不能宣称始终自动跟随系统。

依据：src/store/appSlice.ts:5、src/App.tsx:1、src/components/ChartRenderer/index.tsx:1、src/layouts/MainLayout/index.tsx:25

### CITY-23 AI多轮会话、消息存储与流式完整链路

可覆盖提问：AI怎么记住前文；刷新聊天记录还能看到吗；创建会话和保存消息顺序

AIChat挂载读前50个会话，打开会话加载messages；发送构造requestMessages=[...messages,userMessage]，界面先加空assistant。若没conversationId先创建，以问题前24字符作标题；随后先保存user消息，再把完整requestMessages的role/content发/api/ai/chat，带Bearer。每个片段累加到末条assistant，流结束把拼接内容作为assistant存回会话接口并刷新会话列表。messages变化自动滚到底部。新会话清id和messages，删除当前会话也清空本地显示。

**边界：** 会话持久化通过业务后端API，未见前端localStorage保存聊天消息。当前没有token预算截断、摘要压缩、取消生成或失败事务回滚；不能说这些已具备。

依据：src/pages/AIChat/index.tsx:101、src/api/ai.ts:9、src/types/ai.ts:4

### CITY-24 SSE跨分片解析与当前异常边界

可覆盖提问：流式响应分成半条JSON怎么办；SSE和WebSocket有何区别；流式解析有哪些不足

流式fetch检查response.ok和body，getReader逐块读取。TextDecoder按stream:!done解码，buffer保留上一块不完整内容，用双换行分事件，末尾剩余段留待下块。每个完整事件找首条data:解析JSON，只处理type为text/fallback/thinking的非空content，追加到assistantChunks和界面。解析失败console.error继续；结束无片段给默认回复，网络失败追加失败文案，finally恢复sending。

**边界：** 这不是完整通用SSE库：当前按

分隔，只取首条data，不处理多行data、
变体及流结束无分隔的剩余事件；没有重连/断点续传。thinking被作为普通展示内容，不是隐藏推理通道。若被问不足应明确是可改进项。

依据：src/pages/AIChat/index.tsx:139、src/api/ai.ts:28

### CITY-25 首页统计与不同页面的失败策略

可覆盖提问：多个接口怎么并发和容错；Promise.all和allSettled在项目哪里用；刷新会不会重叠

Dashboard概览用默认对象补缺失字段，事件统计和数组用空值校验，useMemo生成统计卡片和图表option，交通排行复制后reverse形成横向展示。它用Promise.all五接口全成功才统一写state，任一失败不会实现其余新数据的独立提交。地图环境请求用allSettled逐项取成功，仪表盘详情则在单图查询内部catch返回null。这三个模块的容错粒度不同。首页300000ms轮询，清理interval，支持手动刷新和后端CSV下载。

**边界：** 不能把地图的allSettled容错说成首页已实现；当前没有请求重叠保护、页面可见性暂停轮询或实时推送证据。

依据：src/pages/Dashboard/index.tsx:70、src/pages/MapView/index.tsx:139、src/pages/DashboardDetail/index.tsx:62

### CITY-26 地图坐标、热力层与周边分析边界

可覆盖提问：地图如何避免重复初始化；周边分析覆盖所有城市吗；热力图插件失败怎么降级

地图实例独立effect异步load高德JS API2.0及HeatMap插件，cancelled防卸载后初始化，cleanup destroy。业务城市最多20条，城市mode用Marker，环境mode用AQI分级颜色的半径50000米Circle。交通点先过滤有限数值并按congestionIndex降序，HeatMap count映射拥堵指数；不可用时最多60个圆兜底，并另加前20个热点标记，选中热点聚焦地图。非交通模式选城市画radiusKm*1000米范围圆；nearbyCities用Haversine距离筛选并排序，地图相关effect移除各自覆盖层。

**边界：** 周边只在当前已加载城市集合中计算，不能叫全量地理检索；距离非道路路线。可视化圆不是污染传播模型或精确地理边界；业务数据不是高德实时交通。

依据：src/pages/MapView/index.tsx:111、src/utils/geo.ts:3、src/api/dashboard.ts:38

### CITY-27 3D指标可视化、交互和动画

可覆盖提问：3D柱子怎么生长；为什么动画用ref而不是state；点击柱子如何联动面板

Scene3D获取城市接口数据，用useMemo按population/area/gdp复制排序，最大值至少1，高度为1.2+(value/max)*4.8并计算排名。SceneContent用三角函数把柱子放半径5的圆周上，OrbitControls提供阻尼、缩放范围和可选自动旋转。CityColumn每次height变化用useLayoutEffect把group.scale.y设0.01，再useFrame按delta递增至1，悬浮和选中改变发光强度，点击stopPropagation回传城市ID，Html展示城市名和指标。

**边界：** 动画改变Three对象ref，不是每帧setState；没有GPU实例化、大规模性能测试或GIS真实建模证据。GlowRing组件文件存在但当前场景未使用，不能描述成已接入核心流程。

依据：src/pages/Scene3D/index.tsx:142、src/pages/Scene3D/components/CityColumn.tsx:2、src/types/3d.ts:1

### CITY-28 本地沙盘几何建模与楼层展开

可覆盖提问：建筑模型从哪里来；楼层展开如何实现；这是数字孪生吗

沙盘数据来自sandboxZones本地配置，定义建筑位置、楼层、颜色和用途等，CitySandbox按配置渲染ZoneModel。楼层以boxGeometry堆叠，树木由cylinder/sphere几何体组合，地面和路网由box构成。选中建筑stopPropagation后回传zoneId，当前选择使用材质发光、底环和Html标签突出；只有选中且exploded为true时floorGap=0.18，否则0，通过楼层y位置和屋顶高度计算实现展开。OrbitControls目标跟随建筑位置；切换模式Canvas以key重建，选择新建筑时取消展开。

**边界：** 静态演示园区不是真实城市GIS/BIM模型，也没有物联网实时楼层数据、模型文件导入、物理碰撞或复杂补间动画。

依据：src/pages/Scene3D/sandboxZones.ts:1、src/pages/Scene3D/components/CitySandbox.tsx:20、src/pages/Scene3D/index.tsx:223

### CITY-29 部署代理、下载与资源URL处理

可覆盖提问：前后端跨域怎么解决；代理如何兼容流式回复；头像地址怎么处理

开发Vite把/api代理到业务后端，生产functions/api/[[path]].js接住/api路径，保留pathname/query，复制请求headers并删除host和X-City-Proxy-Key，非GET/HEAD透传body，redirect为manual，直接返回上游fetch响应；这能保留流式响应而非先读JSON。头像resolveAvatarUrl将文件名或avatars路径规整到/api/avatars，对非头像外链只接受https，用户表Avatar消费它。CSV下载由Blob对象URL和a标签触发并释放。

**边界：** 代理代码不能证明线上DNS/证书/部署健康或具有授权验证、限流。不要把后端HTTP转发说成端到端全链路HTTPS。个人中心头像直接用返回URL，不能说所有头像位置都经过同一归一化。

依据：vite.config.ts:8、functions/api/[[path]].js:1、src/utils/avatar.ts:3、src/utils/download.ts:4

### CITY-30 技术取舍、亮点与尚未覆盖的能力

可覆盖提问：项目最大的难点；做了哪些性能优化；还可以怎么改进；为什么没用WebSocket

可展开的具体模块是图表数据源/表/字段级联和统一渲染、角色菜单与页面控制、地图多模式及独立失败处理、3D本地沙盘与接口指标分离、AI会话与流式解析。实际优化含路由动态加载、ECharts按需注册、ResizeObserver和dispose、页面派生数据useMemo；这些能解释机制但没有收益测量。当前缺口包括级联请求竞态保护、SSE尾包/换行兼容和取消、首页单卡容错与轮询防重叠、权限树与路由规则的动态联动。

**边界：** 依赖和源码未见WebSocket、SSR、虚拟列表、微前端、ECharts百万级数据优化或自动化测试脚本。不能把useMemo说成必然提升性能，不能编造个人负责范围、生产用户数和优化百分比。

依据：package.json:6、src/pages/ChartEditor/index.tsx:140、src/pages/AIChat/index.tsx:146、src/pages/Dashboard/index.tsx:107、src/components/ChartRenderer/index.tsx:10

### CITY-31 错误边界、路由分包失败与重试限制

可覆盖提问：React页面渲染报错如何恢复；为什么错误边界用类组件；错误边界能捕获所有请求异常吗

App用AppErrorBoundary包AppRouter，resetKey为当前pathname；MainLayout也在页面内容处使用边界。类组件getDerivedStateFromError保存错误，componentDidCatch记录日志，首次失败安排150ms后清空error重试一次。若再次出错保留Alert和手动刷新按钮；路径resetKey变化会清定时器、重置计数和错误，卸载也clearTimeout。路由lazyWithRetry只对已识别的分包加载错误考虑自动reload，以chunkName在sessionStorage记录时间，30秒内重复失败会抛给边界；普通导入错误直接抛出。

**边界：** 错误边界主要处理子树渲染/生命周期错误，不是所有异步请求或事件异常的全局兜底。不能说无限自动重试、自动修复业务错误或静默吞掉所有错误。

依据：src/components/AppErrorBoundary.tsx:17、src/App.tsx:73、src/layouts/MainLayout/index.tsx:249、src/utils/lazyWithRetry.ts:10
