# GitHub 新手使用说明

这份说明用于第一次把 MTP Guardian 上传到 GitHub，并完成后续修改、下载和发布新版本。

## 一、账号和仓库怎么命名

应该使用一个 GitHub 账号作为“总入口”，每个应用建立一个独立仓库。不要为每个应用注册一个 GitHub 账号。

推荐结构：

```text
GitHub 账号：你的用户名
应用仓库：iphone-mtp-auto-copy
应用展示名：MTP Guardian
```

以后增加其他应用时：

```text
你的用户名/
├── iphone-mtp-auto-copy
├── another-tool
└── a-third-tool
```

如果以后有五个以上应用，再考虑创建 GitHub Organization 作为统一品牌。现在不需要。

## 二、第一次创建仓库

1. 打开 https://github.com/ 并注册或登录。
2. 点击右上角 `+`，选择 `New repository`。
3. 填写：

```text
Repository name: iphone-mtp-auto-copy
Description: Reliable iPhone to Windows photo/video transfer over MTP with automatic retry and recovery.
Visibility: Public
```

4. 初次上传已有文件时，建议不要勾选自动创建 README、`.gitignore` 或 License，因为本项目已经包含这些文件。
5. 点击 `Create repository`。

创建后，在仓库右侧 `About` 区域填写：

```text
Description: Reliable iPhone to Windows photo/video transfer over MTP with automatic retry and recovery.
Topics: iphone, ios, mtp, windows, file-transfer, photo-transfer, video-transfer, powershell, media-archive, backup
```

## 三、最简单的上传方式：网页上传

1. 进入新建的仓库。
2. 点击 `Add file` > `Upload files`。
3. 打开本地目录：

```text
E:\github\iphone-mtp-auto-copy
```

4. 把目录里的文件拖进上传页面。
5. Commit message 填写：

```text
Initial release: MTP Guardian v1.0.0
```

6. 点击 `Commit changes`。

注意：不要上传 `logs`、`mtp-auto-copy.config.json` 或个人截图。

## 四、推荐方式：GitHub Desktop

第一次长期使用 GitHub，建议安装 GitHub Desktop：

https://desktop.github.com/

### 上传新项目

1. 安装并打开 GitHub Desktop，登录 GitHub。
2. 选择 `File > Add local repository`。
3. 选择目录：

```text
E:\github\iphone-mtp-auto-copy
```

4. 点击 `Publish repository`。
5. 名称确认：

```text
iphone-mtp-auto-copy
```

6. 取消 `Keep this code private`，然后发布。

### 修改并上传

1. 在本地编辑文件。
2. 回到 GitHub Desktop，左侧会显示改动。
3. 在左下角填写 Summary，例如：

```text
Improve retry statistics
```

4. 点击 `Commit to main`。
5. 点击右上角 `Push origin`。

### 下载和同步

- 点击 `Fetch origin` 获取 GitHub 上的更新。
- 点击 `Pull origin` 把远程更新拉到本地。
- 仓库页面点击 `Code > Download ZIP` 下载完整源码。

## 五、命令行上传方式

如果你愿意使用 Git 命令：

```powershell
cd E:\github\iphone-mtp-auto-copy
git init -b main
git config user.name "你的名字"
git config user.email "你的GitHub邮箱"
git add .
git commit -m "Initial release: MTP Guardian v1.0.0"
git remote add origin https://github.com/你的用户名/iphone-mtp-auto-copy.git
git push -u origin main
```

以后修改：

```powershell
git status
git diff
git add .
git commit -m "Describe your change"
git push
```

更新前建议先同步：

```powershell
git pull --rebase
```

## 六、网页修改文件

1. 打开仓库。
2. 点击要修改的文件，例如 `README.md`。
3. 点击右上角铅笔图标 `Edit this file`。
4. 修改内容。
5. 在页面底部填写 Commit message。
6. 点击 `Commit changes`。

## 七、创建 v1.0.0 Release

1. 进入仓库首页。
2. 点击右侧 `Releases`，再点击 `Create a new release`。
3. 填写：

```text
Tag: v1.0.0
Release title: MTP Guardian v1.0.0
```

4. 上传发布包：

```text
MTP-Guardian_v1.0.0.zip
```

5. 写 Release notes：

```markdown
Initial public release.

- Automatic MTP recovery
- Copy error dialog handling
- Deferred retries for failed files
- Monthly folder mapping
- Final statistics and failure report
```

6. 点击 `Publish release`。

以后每次更新：

```text
v1.0.1
v1.1.0
v2.0.0
```

小修复使用最后一位，新功能使用中间一位，大改版使用第一位。

## 八、别人如何下载

### 下载源码

仓库页面：

```text
Code > Download ZIP
```

### 下载发布包

仓库右侧：

```text
Releases > 选择版本 > Assets > MTP-Guardian_v1.0.0.zip
```

发布包是普通用户最应该下载的版本。

## 九、仓库第一次发布前检查

- `README.md` 是否说明了项目用途
- 是否没有个人路径、真实照片文件名或密码
- `logs` 和 `mtp-auto-copy.config.json` 是否未上传
- Release 是否附带了 ZIP
- License 是否确认

## 十、总名称和一个应用一个名字

现在采用：

```text
账号：你的 GitHub 用户名
应用：MTP Guardian
仓库：iphone-mtp-auto-copy
```

这是最适合第一次使用的结构。以后增加应用时继续建立新仓库，不需要重新建立账号。

个人资料页可以填写：

```text
Display name: 你的名字或昵称
Bio: Practical Windows tools for media transfer and automation.
```

以后如果希望把自己所有工具汇总成一个品牌，可以再创建 GitHub Organization，例如一个中性的工具品牌；现在一个个人账号加独立应用仓库就够了。
