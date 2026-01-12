# 为什么需要 Complete Reload？

## 问题根源

### 1. **Emacs 的 `require` 机制**

当你使用 `(require 'fuji-rag-graphlit)` 时，Emacs 会：
1. 检查 `fuji-rag-graphlit` 是否在 `features` 列表中
2. 如果在，**直接跳过加载**，认为已经加载过了
3. 如果不在，才加载文件并添加到 `features`

### 2. **`eval-buffer` 的局限性**

`eval-buffer` 只是**重新执行**buffer 中的代码，但：
- ❌ 不会更新 `features` 列表
- ❌ 不会替换已经定义的函数（如果使用 `defun`）
- ❌ 其他已经 `require` 了这个模块的代码还在使用旧版本

### 3. **`provide` 语句的重要性**

文件末尾的 `(provide 'fuji-rag-graphlit)` 告诉 Emacs：
- "这个文件提供了 `fuji-rag-graphlit` 功能"
- 将 `fuji-rag-graphlit` 添加到 `features` 列表

**如果没有 `provide`**：
- `require` 每次都会重新加载文件
- 但 `eval-buffer` 不会触发 `require`

## 解决方案

### 方案 1：使用 `load-file`（推荐开发时使用）

```elisp
M-x load-file RET /path/to/fuji-rag-graphlit.el RET
```

**优点**：
- ✅ 强制重新加载，无论是否已经 require
- ✅ 会重新定义所有函数
- ✅ 立即生效

### 方案 2：使用 `unload-feature` + `require`

```elisp
(unload-feature 'fuji-rag-graphlit t)
(require 'fuji-rag-graphlit)
```

**优点**：
- ✅ 正确处理 features 列表
- ✅ 卸载旧的定义

### 方案 3：添加开发辅助函数

在你的 init.el 中添加：

```elisp
(defun fuji-reload ()
  "Reload all Fuji modules during development."
  (interactive)
  (dolist (feature '(fuji fuji-configure fuji-rag fuji-rag-graphlit fuji-extractor))
    (when (featurep feature)
      (unload-feature feature t)))
  (require 'fuji)
  (message "Fuji reloaded!"))
```

然后只需要：`M-x fuji-reload`

## 为什么这次特别需要？

因为：
1. 我们修改了**多个文件**（fuji.el, fuji-configure.el, fuji-rag-graphlit.el）
2. 这些文件之间有 `require` 依赖关系
3. 只 eval 一个文件不会更新其他已加载的模块

## 最佳实践

**开发时**：
- 修改后使用 `load-file` 或 `fuji-reload`
- 不要依赖 `eval-buffer`

**生产环境**：
- 重启 Emacs 或 daemon
- 或者在 init.el 中正确 `require`
