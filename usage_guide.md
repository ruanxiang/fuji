# Fuji (负笈) 快速入门指南

## 1. 前置检查 (Check Health)
首先，确保您的环境设置正确。运行命令：`M-x fuji-check-health`。
- **Marker**: 必须显示 "OK"。如果显示 "MISSING"，请运行 `M-x fuji-configure` 配置路径。
- **Token Gen**: 必须显示 "OK"。如果显示 "FAILED"，请运行 `M-x fuji-configure` 并提供您的 Graphlit Secret。

## 2. 开始对话
运行命令：
`M-x fuji-ref-chat`

## 3. 选择论文
- 将出现文件选择对话框。
- 浏览并选择您的 PDF 文件。
- **提示**: 您可以导航进入目录。

## 4. 处理过程 (仅首次)
- 如果是首次选择此 PDF，Fuji 将使用 `marker` 将其转换为 Markdown。
- **状态**: 您将看到 "Processing PDF with Marker..."。
- **视觉反馈**: 一个名为 `*Fuji Marker Output*` 的 Buffer 将会打开，显示内部进度。
- **首次运行警告**: 第一次运行时，Marker 需要下载大型 AI 模型（数 GB）。这可能需要 **5-10 分钟**。请耐心等待，并留意打开的 Buffer 中的下载进度。
- **成功**: 您将看到 "Chat ready for [filename]"，并且一个新的聊天 Buffer 将被打开。
- **失败**: 请检查 `*Fuji Marker Output*` Buffer 中的错误信息。

## 性能调优

### Marker 处理
在没有 GPU 的机器上，Marker 处理可能会比较慢。Fuji 提供了三种模式来应对：
1. **Auto (运行 Marker)**: 全自动多模态处理（提取文本、公式和图像）。推荐拥有 GPU 或高性能 CPU 的用户使用。
2. **Skip (纯文本)**: 跳过 Marker，直接使用 `pdftotext` 快速将文本导入 Graphlit。适合不需要分析图表的快速阅读场景。
3. **Load Local Result (加载本地结果)**: 提示您选择包含预生成 Marker 结果的目录。

### 低配置硬件推荐工作流
- **批量预处理**: 在空闲时间，使用带 GPU 的机器运行 Marker 并保存结果。
- **本地加载**: 在低配置设备上使用 `fuji-ref-chat` 中的 "Load Local Result" 选项，瞬间加载这些结果。
- **缓存优先**: Fuji 会缓存所有 Marker 结果。一旦处理过一次，再次打开、切换模式或重启会话都是秒开。

## 5. 对话
- 一个名为 `*Fuji-Chat: filename*` 的新 Buffer 将会打开。
- 这是一个标准的 `gptel` Buffer。
- 输入您的问题（例如：“总结这篇论文”）并按 `C-c RET` 发送。
- 系统将向 Graphlit 查询论文的相关上下文，并结合 GPT-4 Vision/Text 模型进行回答。

## 维护
- **清理缓存**: 如果您想重新处理某个 PDF，请删除 `~/.emacs.d/fuji-cache/` 或您配置的缓存目录中对应的文件夹。
- **更新配置**: `M-x fuji-configure`。
