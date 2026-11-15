# Consent Chat

Windows 电脑运行唯一 HTTPS 聊天服务器；一个或多个客户端 APK 连接该服务器，服务端管理 APK 也可远程管理同一台电脑。服务端离线时，客户端在本机加密排队，恢复连接后自动补传。不使用 Supabase。

## 当前功能

- `lib/main_server.dart` 在 Windows 上启动服务器界面；构建为 Android 服务端 APK 时显示远程管理界面。手机管理端将客户端消息列表与邀请码管理分为独立页面，均支持搜索及按连接时间、最近聊天时间、姓名/邀请码/备注拼音首字母升降序排序。
- 多个客户端 APK 使用 HTTPS 和唯一邀请码连接电脑服务器，不要求公网 IP 白名单。管理端 APK 可创建邀请码、查看客户端、管理会话并发送消息。
- 两端聊天支持文字、图片/视频相册、文件和语音；图片与视频从同一个相册入口选择。附件按分块流式传输，不设置应用层单文件或总存储配额；服务端使用剩余磁盘空间，磁盘不足或传输失败会明确显示错误。
- 双方消息通过左右位置、颜色和头像区分，时间戳独立显示在气泡外；客户端头像由客户端上传，服务端头像可针对每个客户端单独上传，并可点击头像查看大图；图片消息不显示文件名。客户端备注保存在服务端并显示在聊天页上方。
- 客户端自动读取手机名称用于管理员识别；选择附件后立即显示包含文件名和大小的消息卡片，后台分块传输并显示环形百分比、准备中/上传中/失败/已发送状态。失败或离线消息保留在聊天记录，可重试；不会因文件过大而静默丢弃。下载按需分块写入文件，不把完整附件或 Base64 内容载入内存。
- 邀请码详情显示绑定客户端的姓名、手机名称、客户端 ID、IP 和活动时间，并支持搜索及按状态筛选；客户端不收集身份证号。
- 服务端持续保存聊天记录和附件，附件以逐客户端加密分块保存在应用支持目录的磁盘文件中，Hive 仅保存附件元数据；服务端重启后仍可下载，客户端卸载不会删除服务端副本。管理端可在聊天页选择一条或多条消息永久删除，删除附件消息时也会清理不再被引用的附件。撤销邀请码不会删除该客户端或服务器上的历史记录。
- 手机端可从管理端或客户端页面顶部上传运行日志。Windows 服务端在 EXE 同级的 `logs/` 下分别保存 `windows-server.log`、`server-mobile.log` 和 `client-mobile.log`；日志按 JSON 行记录并轮转，上传内容不包含消息正文、邀请码或访问令牌。
- 每个客户端使用独立邀请码。客户端文字、附件及服务端返回给客户端的聊天内容均使用该邀请码和固定后缀 `54864849632Jcx@z` 派生 AES-256/HMAC 密钥加密；HTTPS 另加一层传输加密。邀请码只可绑定一个手机；Android 客户端通过应用签名范围内的 Android ID 哈希识别同一手机，卸载重装后恢复原绑定和服务端聊天记录。确认同一邀请码被其他手机使用时，邀请码会失效并撤销关联授权；管理员可重新分配邀请码。
- 服务端本机的客户端详情会显示可复制的设备标识，并可输入名称编译绑定到该 Android 设备的 APK，产物保存到 `D:\talk\dist\chat_client_<名称>.apk`。客户端会在邀请码页面和任何聊天服务请求之前校验设备标识；不匹配时不会连接服务器。
- 试用 APK 通过 `scripts/build-client.ps1 -Trial` 编译，构建当天写入有效日期，按北京时间比较 Android 系统网络时间。试用版仅支持 Android 13 及以上；系统网络时间不可用或日期不符时会直接停止，不回退使用可手动修改的手机时间。
- 服务端明确返回邀请码无效或授权已撤销后，客户端会先保存本地锁定标记并停止后台连接，再删除该客户端本地缓存的聊天记录、头像、待发队列、加密待发附件、已下载/解密附件及客户端日志；同一次安装后续启动不再请求服务器。卸载会清除应用私有状态，因此重新安装后仍需先向服务器验证一次才能再次保存锁定状态。设备设置、服务器地址和黑名单标记不会随聊天记录一起删除；清理只作用于客户端，不会删除服务端已记录的客户端 IP 或聊天记录。
- 客户端离线消息元数据保存在设备加密 Hive 队列；待发送附件在应用私有目录按客户端密钥分块加密后保存，网络恢复后自动补传。过期一小时的消息不再显示在聊天窗口；未成功补传的队列项仍保留并继续重试。
- 客户端连续检测到电脑服务器不可达后会停止后台连接并退出；重新启动客户端后会重新连接。
- 客户端安装包由 Android 安装到系统管理的 `/data/app/` 目录，应用数据保存在隔离的私有目录。缓存消息和待发送队列存于 AES 加密 Hive 数据库，数据库密钥由 Android 安全存储保护；普通文件管理器不能直接读取这些内容。附件打开时会解码到应用临时目录。
- iPhone 客户端使用独立的 iOS 工程 `ios/`，支持前台聊天、附件和语音；iOS 会在应用进入后台后暂停普通网络轮询，因此不能保证像 Android 前台服务一样持续接收后台消息或提醒。
- 客户端凭有效且唯一的邀请码连接，不要求管理员预先允许公网 IP；服务端可读取解密后的消息，这不是端到端加密（E2EE）。

## 运行服务器

1. 在电脑启动 Consent Chat EXE，设置管理员口令和 HTTPS 端口（默认 `8443`）。程序会自动生成并加密保存自签 TLS 证书和私钥，不需要手动寻找或选择证书文件；服务器监听电脑所有 IPv4 网卡。
2. 如果手机和电脑在同一 Wi-Fi，可使用电脑局域网 IP；路由器需关闭客户端隔离。
3. 不同 Wi-Fi 或手机流量访问时，电脑必须有公网可达地址并配置防火墙/端口转发。若宽带使用 CGNAT，使用公网 VPS 或隧道。
4. 在客户端 APK 和服务端管理 APK 输入电脑的 HTTPS 地址。客户端填写姓名和专属邀请码，手机名称由应用自动读取；管理端使用管理员口令连接。首次连接时应用会自动处理服务器信任校验，不需要用户手动查看证书或指纹。管理员可在手机管理端创建邀请码，并在客户端列表中管理会话。
5. 保持电脑、EXE 和网络在线。服务端 EXE 关闭时，客户端不能发送到服务器，但发件会加密保存在客户端本地，重新连接后自动补传。

总构建脚本默认检测电脑活动默认路由网卡上的局域网 IPv4 地址，以 HTTPS 端口 `8443` 作为连接地址，并将同一个地址注入服务端 EXE、服务端 APK 和客户端 APK；此步骤不会修改电脑网卡配置。也可通过 `-ServerUrl 'https://你的域名或IP:端口'` 手动指定地址。地址会以异或/Base64 形式注入程序，便于普通搜索时不直接显示，但这不是加密，逆向分析仍可还原。服务端监听电脑所有 IPv4 网卡。局域网地址可能由路由器动态分配；若需固定，可在路由器为电脑设置 DHCP 地址保留。跨网络访问建议指定固定公网 IP 或 DDNS 域名，并设置路由器端口转发和防火墙。

不要公开分享管理员口令或客户端邀请码。应用会自动验证并固定服务器身份；服务器身份异常时客户端会停止连接。固定后缀写在应用代码中，不是独立秘密。请使用高熵、每客户端唯一的邀请码。

## 构建

Android/Windows 构建环境需要 Flutter、Android SDK、Java 21；Windows EXE 还需要 Visual Studio 的 **Desktop development with C++** 工作负载。iOS IPA 必须在安装了 Xcode 的 macOS 上构建，Windows 不能直接编译 iOS 应用。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

总脚本会依次构建服务端 APK、客户端 APK 和 Windows 服务端，并将每次构建的最终文件更新到 `dist/`。iOS 必须单独在 Mac 上构建。也可以单独运行以下脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-client.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -Trial
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-client.ps1 -ServerUrl 'https://chat.example.com:8443'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-server.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

将项目复制到已安装 Xcode 的 Mac 后，在项目目录运行 iOS 构建脚本，并传入聊天服务器的 HTTPS 地址：

```bash
bash scripts/build-ios.sh https://192.168.1.14:8443
```

脚本会生成已签名的 IPA 至 `dist/ConsentChat-iOS/ConsentChat-Client.ipa`。请先在 Mac 的 Xcode 中登录 Apple Developer 账号，并为 `ios/Runner.xcworkspace` 配置签名团队；将 IPA 安装到 iPhone 或分发给他人还需符合 Apple 的签名与分发要求。Windows 上的 `build-ios.bat` 仅说明该平台限制，不会尝试在 Windows 编译。

`build-release.ps1` 默认同样自动检测局域网地址；跨网络或需指定域名时，可传入 `-ServerUrl 'https://域名或IP:8443'`。当前应用版本已升级至 `0.1.1+2`。

总脚本命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

构建前脚本会请求 Gradle 停止其构建守护进程，并重试清理 `build/` 目录；如果文件仍被其他程序占用，会明确报错，不会强制结束不明的 Java 或其他进程。

所有构建产物都放在 `dist/ConsentChat-Windows/`：

- `ConsentChat-Client.apk`：客户端 APK
- `chat_client_<名称>.apk`：服务端详情页为单台设备编译的客户端 APK，位于 `D:\talk\dist`
- `chat_client_trial_<日期>.apk`：当天有效的 Android 试用 APK，位于 `D:\talk\dist`
- `ConsentChat-Server.apk`：服务端管理 APK
- `consent_chat.exe` 和同目录运行文件：Windows 服务端
- `data/`：Windows 应用资源

后续重新编译仍运行上面的命令，输出目录不变。它只对本次 PowerShell 进程设置执行策略，不会更改系统设置。也可以在 VS Code 任务中运行“Build all release files to dist”。

APK 构建目前沿用项目现有的调试签名配置；这便于内部试用，但不等同于正式发布签名。不要把调试签名视作防篡改机制；设备绑定是客户端本地校验，无法阻止有能力修改 APK 的使用者绕过。

## 验证

```powershell
flutter test
flutter analyze
```
