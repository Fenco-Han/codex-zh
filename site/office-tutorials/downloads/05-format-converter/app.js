const elements = {
  fileInput: document.querySelector('#fileInput'),
  dropZone: document.querySelector('#dropZone'),
  typeSelect: document.querySelector('#typeSelect'),
  delimiterSelect: document.querySelector('#delimiterSelect'),
  convertButton: document.querySelector('#convertButton'),
  sourceInput: document.querySelector('#sourceInput'),
  jsonOutput: document.querySelector('#jsonOutput'),
  tablePreview: document.querySelector('#tablePreview'),
  markdownPreview: document.querySelector('#markdownPreview'),
  statusText: document.querySelector('#statusText'),
  downloadJsonButton: document.querySelector('#downloadJsonButton'),
  downloadHtmlButton: document.querySelector('#downloadHtmlButton'),
  downloadMarkdownHtmlButton: document.querySelector('#downloadMarkdownHtmlButton')
};

let currentFileName = 'converted';
let lastJson = '';
let lastCsvHtml = '';
let lastMarkdownHtml = '';

const sampleCsv = `姓名,城市,手机号,来源
李敏,上海,13800138000,公众号
王强,北京,13900139000,小红书
陈晨,广州,13600136000,抖音
周雨,杭州,13500135000,门店`;

function setStatus(message, isError = false) {
  elements.statusText.textContent = message;
  elements.statusText.style.color = isError ? '#b42318' : '#667085';
}

function inferType(fileName, text) {
  const selected = elements.typeSelect.value;
  if (selected !== 'auto') return selected;
  const lowerName = (fileName || '').toLowerCase();
  if (lowerName.endsWith('.csv')) return 'csv';
  if (lowerName.endsWith('.md') || lowerName.endsWith('.markdown')) return 'markdown';
  return looksLikeCsv(text) ? 'csv' : 'markdown';
}

function looksLikeCsv(text) {
  const lines = text.trim().split(/\r?\n/).filter(Boolean).slice(0, 4);
  if (lines.length < 2) return false;
  const delimiter = detectDelimiter(text);
  return lines.every(line => parseCsvLine(line, delimiter).length > 1);
}

function detectDelimiter(text) {
  const selected = elements.delimiterSelect.value;
  if (selected !== 'auto') return selected === 'tab' ? '\t' : selected;
  const firstLines = text.split(/\r?\n/).slice(0, 5).join('\n');
  const candidates = [',', ';', '\t', '|'];
  let best = ',';
  let bestScore = -1;
  for (const candidate of candidates) {
    const counts = firstLines.split(/\r?\n/).filter(Boolean).map(line => parseCsvLine(line, candidate).length);
    const score = counts.reduce((sum, count) => sum + count, 0) - new Set(counts).size;
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}

function parseCsv(text, delimiter = ',') {
  const rows = [];
  let row = [];
  let value = '';
  let insideQuotes = false;

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];

    if (char === '"') {
      if (insideQuotes && next === '"') {
        value += '"';
        index += 1;
      } else {
        insideQuotes = !insideQuotes;
      }
      continue;
    }

    if (char === delimiter && !insideQuotes) {
      row.push(value);
      value = '';
      continue;
    }

    if ((char === '\n' || char === '\r') && !insideQuotes) {
      if (char === '\r' && next === '\n') index += 1;
      row.push(value);
      if (row.some(cell => cell !== '')) rows.push(row);
      row = [];
      value = '';
      continue;
    }

    value += char;
  }

  row.push(value);
  if (row.some(cell => cell !== '')) rows.push(row);
  return rows;
}

function parseCsvLine(line, delimiter) {
  return parseCsv(line, delimiter)[0] || [];
}

function rowsToObjects(rows) {
  if (!rows.length) return { headers: [], records: [] };
  const headers = rows[0].map((header, index) => header.trim() || `column_${index + 1}`);
  const records = rows.slice(1).map(row => {
    const record = {};
    headers.forEach((header, index) => {
      record[header] = row[index] ?? '';
    });
    return record;
  });
  return { headers, records };
}

function renderTable(headers, records) {
  if (!headers.length) return '<div class="empty">CSV 没有可预览的数据。</div>';
  const head = headers.map(header => `<th>${escapeHtml(header)}</th>`).join('');
  const body = records.map(record => {
    const cells = headers.map(header => `<td>${escapeHtml(record[header] ?? '')}</td>`).join('');
    return `<tr>${cells}</tr>`;
  }).join('');
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

function markdownToHtml(markdown) {
  const lines = markdown.replace(/\r\n?/g, '\n').split('\n');
  const html = [];
  const paragraph = [];
  let inCode = false;
  let codeLines = [];
  let listType = null;

  const flushParagraph = () => {
    if (!paragraph.length) return;
    html.push(`<p>${inlineMarkdown(paragraph.join(' '))}</p>`);
    paragraph.length = 0;
  };
  const closeList = () => {
    if (!listType) return;
    html.push(`</${listType}>`);
    listType = null;
  };
  const openList = type => {
    if (listType === type) return;
    closeList();
    html.push(`<${type}>`);
    listType = type;
  };

  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      if (inCode) {
        html.push(`<pre><code>${escapeHtml(codeLines.join('\n'))}</code></pre>`);
        codeLines = [];
        inCode = false;
      } else {
        flushParagraph();
        closeList();
        inCode = true;
      }
      continue;
    }
    if (inCode) {
      codeLines.push(line);
      continue;
    }
    if (!trimmed) {
      flushParagraph();
      closeList();
      continue;
    }

    const heading = trimmed.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      flushParagraph();
      closeList();
      const level = heading[1].length;
      html.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
      continue;
    }

    const quote = trimmed.match(/^>\s?(.+)$/);
    if (quote) {
      flushParagraph();
      closeList();
      html.push(`<blockquote>${inlineMarkdown(quote[1])}</blockquote>`);
      continue;
    }

    const unordered = trimmed.match(/^[-*+]\s+(.+)$/);
    if (unordered) {
      flushParagraph();
      openList('ul');
      html.push(`<li>${inlineMarkdown(unordered[1])}</li>`);
      continue;
    }

    const ordered = trimmed.match(/^\d+[.)]\s+(.+)$/);
    if (ordered) {
      flushParagraph();
      openList('ol');
      html.push(`<li>${inlineMarkdown(ordered[1])}</li>`);
      continue;
    }

    paragraph.push(trimmed);
  }

  if (inCode) html.push(`<pre><code>${escapeHtml(codeLines.join('\n'))}</code></pre>`);
  flushParagraph();
  closeList();
  return html.join('\n');
}

function inlineMarkdown(text) {
  let result = escapeHtml(text);
  result = result.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, '<img alt="$1" src="$2">');
  result = result.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
  result = result.replace(/`([^`]+)`/g, '<code>$1</code>');
  result = result.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  result = result.replace(/__([^_]+)__/g, '<strong>$1</strong>');
  result = result.replace(/\*([^*]+)\*/g, '<em>$1</em>');
  result = result.replace(/_([^_]+)_/g, '<em>$1</em>');
  return result;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"]/g, char => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;'
  }[char]));
}

function buildHtmlDocument(title, body) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(title)}</title>
  <style>body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif;margin:2rem;line-height:1.7;color:#172033}table{border-collapse:collapse;width:100%}th,td{border:1px solid #d9e2ef;padding:.55rem .7rem;text-align:left;vertical-align:top}th{background:#eef4ff}pre{background:#111827;color:#f9fafb;padding:1rem;border-radius:.75rem;overflow:auto}code{background:#f2f4f7;padding:.1rem .25rem;border-radius:.25rem}pre code{background:transparent;padding:0}blockquote{border-left:4px solid #bfdbfe;margin-left:0;padding-left:1rem;color:#475467}</style>
</head>
<body>
${body}
</body>
</html>`;
}

function convert() {
  const text = elements.sourceInput.value;
  if (!text.trim()) {
    setStatus('请先选择文件或粘贴内容。', true);
    return;
  }

  const type = inferType(currentFileName, text);
  resetOutputs();

  if (type === 'csv') {
    const delimiter = detectDelimiter(text);
    const rows = parseCsv(text, delimiter);
    const { headers, records } = rowsToObjects(rows);
    lastJson = JSON.stringify(records, null, 2);
    lastCsvHtml = renderTable(headers, records);
    elements.jsonOutput.textContent = lastJson;
    elements.tablePreview.classList.remove('empty');
    elements.tablePreview.innerHTML = lastCsvHtml;
    elements.downloadJsonButton.disabled = false;
    elements.downloadHtmlButton.disabled = false;
    setStatus(`CSV 转换完成：${records.length} 行，${headers.length} 列。`);
    return;
  }

  lastMarkdownHtml = markdownToHtml(text);
  elements.markdownPreview.classList.remove('empty');
  elements.markdownPreview.innerHTML = lastMarkdownHtml;
  elements.downloadMarkdownHtmlButton.disabled = false;
  setStatus('Markdown HTML 预览已生成。');
}

function resetOutputs() {
  lastJson = '';
  lastCsvHtml = '';
  lastMarkdownHtml = '';
  elements.jsonOutput.textContent = '等待 CSV 输入...';
  elements.tablePreview.className = 'preview empty';
  elements.tablePreview.textContent = '等待 CSV 输入...';
  elements.markdownPreview.className = 'markdown-preview empty';
  elements.markdownPreview.textContent = '等待 Markdown 输入...';
  elements.downloadJsonButton.disabled = true;
  elements.downloadHtmlButton.disabled = true;
  elements.downloadMarkdownHtmlButton.disabled = true;
}

function downloadText(fileName, text, mimeType) {
  const blob = new Blob([text], { type: `${mimeType};charset=utf-8` });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = fileName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
}

function baseName(fileName) {
  return (fileName || 'converted').replace(/\.[^.]+$/, '') || 'converted';
}

elements.fileInput.addEventListener('change', async event => {
  const file = event.target.files[0];
  if (!file) return;
  currentFileName = file.name;
  elements.sourceInput.value = await file.text();
  setStatus(`已读取本地文件：${file.name}`);
  convert();
});

elements.dropZone.addEventListener('dragover', event => {
  event.preventDefault();
  elements.dropZone.classList.add('dragging');
});
elements.dropZone.addEventListener('dragleave', () => elements.dropZone.classList.remove('dragging'));
elements.dropZone.addEventListener('drop', async event => {
  event.preventDefault();
  elements.dropZone.classList.remove('dragging');
  const file = event.dataTransfer.files[0];
  if (!file) return;
  currentFileName = file.name;
  elements.sourceInput.value = await file.text();
  setStatus(`已读取本地文件：${file.name}`);
  convert();
});

elements.convertButton.addEventListener('click', convert);
elements.sourceInput.addEventListener('input', () => setStatus('内容已修改，点击“转换 / 预览”刷新结果。'));
elements.downloadJsonButton.addEventListener('click', () => downloadText(`${baseName(currentFileName)}.json`, lastJson, 'application/json'));
elements.downloadHtmlButton.addEventListener('click', () => downloadText(`${baseName(currentFileName)}-table.html`, buildHtmlDocument(`${baseName(currentFileName)} 表格`, lastCsvHtml), 'text/html'));
elements.downloadMarkdownHtmlButton.addEventListener('click', () => downloadText(`${baseName(currentFileName)}.html`, buildHtmlDocument(baseName(currentFileName), lastMarkdownHtml), 'text/html'));

if (!elements.sourceInput.value.trim()) {
  elements.sourceInput.value = sampleCsv;
  currentFileName = '示例客户名单.csv';
  convert();
}
