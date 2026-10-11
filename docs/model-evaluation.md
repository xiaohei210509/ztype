# ztype 模型与续写协议评测

评测日期：2026-10-09。本机合成样例，不读取、上传或学习用户文档。
本项目及所有测试资产独立于其他补全软件。

## 用户确认的产品方向

输入补全应允许猜测用户接下来可能想写的内容。天气、数字、日期、原因、
私人安排和时间承诺可以成为候选，不需要预先出现在原文中。准确性重点在
语言、语法、上下文衔接和不重复输入，不等于把候选当成已核实的事实。
所有写入仍须用户显式接受。

因此已移除“未见数字”“未经支持的时间承诺”和 `because` 后禁止续写的
过滤规则。允许创意续写，但依然不自动回写，不允许文档文本变成角色标记。

## 三类模型

| 模型 | 定位 | 资产体积 | 本次判断 |
| --- | --- | --- | --- |
| Qwen3-1.7B-Q8_0 | 通用聊天模型，原有官方资产 | 约 1.83 GB | 改善续写协议后暂时继续使用 |
| Gemma 3 1B keyboard Q4_K_M | 第三方键盘预测微调，英文 | 814,268,224 bytes | 当前导出权重与运行时上的衔接不佳，未集成 |
| Qwen3-1.7B-Base Q4_K_M | 基础自回归模型，第三方量化 | 1,107,409,024 bytes | 能续写，但常滑入教材或翻译练习语境，未集成 |

键盘模型按发布者格式、无换行光标标记和裸文本分别测试。按发布者格式，
`hi, today` 得到 `1.`，`Hello, how are` 得到 `How`；替代格式也有重复和
不自然输出。此结论只针对所测试资产、版本和协议，不代表所有专用模型。
发布者的 Hit@5 是下一 token 的前五候选指标，不能当成 ztype 句子准确率。
该模型的英文限制也不能覆盖 ztype 的中文使用需求。

Gemma 派生模型的模型卡标注与基础模型条款需要进一步核对。本次仅本地
评估，不把它打包分发，也不把其 Apache 标签当成完整许可结论。

## 22 条探索性样例

每种协议一轮，覆盖短前缀、截图例子、英文词尾、否定上下文、后缀、邮件、
技术文本、中文及混合文本。不存在唯一正确的开放续写，也未进行用户接受率
或盲评。下面只报告请求延迟，不报告“准确率”。

| 协议 | P50 | P95 |
| --- | --- | --- |
| 原聊天调用，原有严格提示词，24-token 预算 | 107 ms | 284 ms |
| 键盘模型，发布者格式，24-token 预算 | 99 ms | 248 ms |
| 基础模型裸文本，24-token 预算 | 334 ms | 404 ms |
| 开放草稿续写与词尾约束，探索脚本，16-token 预算 | 241 ms | 372 ms |

不是完全同条件的模型能力排名：体积、量化、token 预算、提示词、生成长度
与 tokenization 请求数不同，原聊天接口还会复述输入或直接停止。
推理概率仅用于探索留证，不用于宣称事实可信度。

本机原始评测输出不随源码发布。可使用 `script/compare_models.py` 在
`Benchmarks/` 下重新生成对照结果。实验脚本会保留服务端原始响应，
包括停止原因与 token 概率。

## 应用实际调用链

原模型不变，改用原生 `/completion`、预填草稿、任务示例和词尾约束。
动态文档编码时 `parse_special=false`，可信模板单独编码并缓存。
原生接口只返回新生成的部分；停止标点恢复到候选中，英文预算截断会去掉
可能未完成的最后一个词。候选与光标后文本有重叠时只保留实际缺失部分。

21 条集成样例使用应用同一个 Swift 客户端，16-token 预算，关闭概率输出：
本轮 P50 140 ms、P95 300 ms，模型加载 1,477 ms，空闲区间 CPU 样本 0.2%。
这不是严格冷启动平均值，不含停顿等待、AX 查询或模型加载的显示总延迟，
也不是 GPU/整机功耗或续航测量。保留原有低电量、热状态和按需卸载策略。

| 光标前文本 | 本轮显示候选 |
| --- | --- |
| `hi, today` | ` is a great day.` |
| `hi, today's` | ` weather is nice.` |
| `Please review the applica` | `bility of the proposed solution.` |
| `I look forward to hearing` | ` from you.` |
| `I cannot attend the meeting tomorrow because ` | `of a scheduling conflict.` |
| `The result is still being measured. The latency is ` | `123 milliseconds.` |
| `我们需要先确认问题的原因，然后再` | `制定相应的解决方案。` |
| `这次先不要发布，等测试` | `完成后再进行发布。` |

该轮仍有一条英文技术句混入中文，以及一个词尾样例未给出续写。显示
19/21 只表示候选覆盖，不是正确率。可使用 `script/benchmark.py --output
Benchmarks/integrated-completion.json` 重新生成集成结果。真实输入仍可能产生不自然的词语、
语法或上下文偏差；不声称这已经解决所有质量问题。

## 来源

- 键盘微调模型卡：`https://huggingface.co/RitwikSehrawat/gemma-3-1b-kbd-q4km`
- 官方基础模型卡：`https://huggingface.co/Qwen/Qwen3-1.7B-Base`
- 测试量化来源：`https://huggingface.co/mradermacher/Qwen3-1.7B-Base-GGUF`
- 固定运行时协议：`https://raw.githubusercontent.com/ggml-org/llama.cpp/b11429/tools/server/README.md`
- Gemma 条款：`https://ai.google.dev/gemma/terms/`
- 专用续写研究背景：`https://research.google/blog/smart-compose-using-neural-networks-to-help-write-emails/`

后续专用训练应直接评估真实前缀、词尾、否定和多语言续写，而不是只比较
聊天问答榜单。没有使用本次样例训练模型，也没有启动后台学习。
