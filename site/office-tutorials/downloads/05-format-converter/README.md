# 本地 CSV / Markdown 网页转换工具

这是一个纯前端离线工具，打开 `index.html` 就能使用。转换逻辑全部在浏览器本地完成，不需要服务器，也不会上传文件到外网。

## 文件说明

- `index.html`：网页入口，双击即可打开。
- `styles.css`：页面样式。
- `app.js`：CSV / Markdown 解析与下载逻辑。
- `examples/客户名单.csv`：从资料目录复制过来的 CSV 样例。
- `examples/会议纪要.md`：从资料目录复制过来的 Markdown 样例。
- `examples/sample-customers.csv`：可读中文 CSV 示例。
- `examples/sample-meeting.md`：可读中文 Markdown 示例。

## 使用方法

1. 双击打开 `index.html`。
2. 点击上传区域选择 `.csv`、`.md` 或 `.markdown` 文件，也可以直接把内容粘贴到文本框。
3. 点击“转换 / 预览”。
4. CSV 文件会生成 JSON 结果和表格预览。
5. Markdown 文件会生成 HTML 预览。
6. 需要保存结果时，点击对应的“下载 JSON”或“下载 HTML”。

## 支持能力

### CSV

- 自动识别逗号、分号、Tab、竖线分隔符。
- 支持双引号包裹字段。
- 支持字段内双引号转义，例如 `""`。
- 输出 JSON 数组。
- 生成浏览器表格预览。

### Markdown

支持常见 Markdown：

- 一级到六级标题。
- 无序列表和有序列表。
- 引用块。
- 代码块和行内代码。
- 链接、图片、粗体、斜体。

## 隐私说明

这个工具没有网络请求代码，也没有后端服务。文件通过浏览器 File API 在本机读取，转换结果通过 Blob 在本机下载。

如果处理特别敏感的资料，可以先断网再打开 `index.html` 使用。

## 注意事项

- 浏览器直接打开本地文件即可，不需要安装 Node.js、Python 或其他依赖。
- Markdown 解析覆盖日常办公场景，不是完整 CommonMark 规范实现。
- 如果原始样例文件打开后显示乱码，可能是资料源编码已经不一致；可以使用 `examples/sample-customers.csv` 和 `examples/sample-meeting.md` 测试工具效果。
