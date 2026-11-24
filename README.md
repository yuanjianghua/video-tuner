# video-tuner

**自动为本机调优文生视频（Wan 系列 / ComfyUI）的一键工具。**
One-click text-to-video auto-tuner: detects your hardware, picks a runnable model tier, proves it with a real generation, and writes launchers.

姊妹项目：[llama-tuner](https://github.com/yuanjianghua/llama-tuner)（同一个方法论：检测硬件 → 生成计划 → **真实启动实测** → 一键脚本。只是把 llama.cpp 换成了 ComfyUI + Wan）。

---

## 这个工具是什么 / 不是什么

✅ **是**：ComfyUI 便携版的“自动装机 + 自动选型 + 真实验证 + 一键启动”外壳。你双击一个文件，它负责：装引擎、装 GGUF 节点、按显存/内存下载对的 Wan 模型、跑一次真实的小规模生成来证明能跑、失败自动降档、生成桌面快捷方式。

❌ **不是**：视频引擎本身（扩散采样是 ComfyUI + Wan 模型做的，本项目不重复造轮子）；**不支持文生图**以外的图像任务；**不做** 14B 在 16GB 内存上的“硬撑”（见下）。

## 硬件底线（如实）

| 档位 | 模型 | 输出 | 显存 | 内存 | 5 秒片段耗时（8GB 笔记本卡实测口径） |
|---|---|---|---|---|---|
| T0 | Wan 2.1 1.3B | 480p 16fps | ≥6GB | ≥8GB | ~20-45 分钟 |
| **T1** | **Wan 2.2 TI2V 5B Q4** | 480p 24fps | ≥8GB | ≥16GB | **~25-45 分钟** |
| **T2** | **Wan 2.2 TI2V 5B Q4** | 720p 24fps | ≥8GB | ≥16GB | **~50-90 分钟** |
| T3 | Wan 2.2 14B 双模 Q4 + lightx2v 4步 | 480p | ≥8GB | **≥32GB** | ~15-30 分钟 |
| T4 | 同上 | 720p | ≥12GB | ≥32GB | ~40-90 分钟 |
| T5 | Hunyuan 1.5 | 480p | ≥16GB | ≥32GB | ~1.5-3 小时 |

**为什么 14B 锁 32GB 内存**：14B 在 16GB 内存上能“开机”，但双阶段权重+文本编码器会把内存顶满、靠页面文件硬换，按小时计的生成大概率中途崩掉白跑。宁可拒绝，不给你假希望。加了内存后重跑 `tune.cmd` 自动解锁。

**没有 NVIDIA 显卡就不支持**：CPU 生成视频是“按小时每秒”的自虐，本工具明确不做（检测到你有机有卡但驱动坏了会报出来并给出装驱动指引）。

## 怎么用（小白三步）

1. **先解压**：下载 zip 后必须“全部解压”到文件夹，不要在压缩文件预览里直接双击运行。
2. **双击 `tune.cmd`**：自动完成 装引擎(约2GB压缩包，解压后约15GB) → 下模型(10-25GB，优先 ModelScope/HF 镜像) → 真实小规模生成验证 → 生成 `start_video_engine.cmd` / `stop_video_engine.cmd` 和桌面快捷方式。
3. **之后日常**：双击桌面「启动VideoEngine」打开 ComfyUI 网页界面；命令行生成一条片段：
   `powershell -File tune.ps1 -Generate -Prompt "一只橘猫在窗台上打哈欠，阳光，纪录片风格"`

## 参数

```
tune.ps1                        # 全流程（已验证过则秒复用）
tune.ps1 -SkipValidate          # 只看计划，不启动任何东西（绝不碰正在运行的引擎）
tune.ps1 -Force                 # 硬件/模型没变也重新实测
tune.ps1 -Generate -Prompt "..."  # 按已验证档位生成一条完整片段（几十分钟起，见上表）
tune.ps1 -EngineDir D:\x        # 指定已有 ComfyUI 便携版
tune.ps1 -NoDownload            # 全离线：只报告现状
```

## 常见问题

- **GitHub 下载慢/断**：引擎包 8 段并行 + 每段断点续传，失败会重试并切换线路；仍失败就去 releases 页手动下载 `.7z` 解压，`-EngineDir` 指过去。模型优先 ModelScope，其次 HF 镜像。
- **验证时 CUDA OOM**：关掉浏览器和游戏重跑；工具会自动降档（T2→T1→T0），全失败会打印每档失败原因。
- **提示缺节点（UnetLoaderGGUF 等）**：工具会自动装 ComfyUI-GGUF 节点包；离线环境按其打印的手动指引放置即可。
- **第一次生成特别慢**：16GB 内存机型权重首过走 NVMe 页缓存，第二次起会快。
- **画面糊/动得像幻灯片**：这是 1.3B/5B 档位的真实能力上限，不是坏了。想要宣传片级效果需要 14B 档 + 32GB 内存 + 更多耐心。

## 原理一句话

模型选档是纯函数（`lib/plan.ps1`，可离线测试）；所有工作流 JSON 按 2026-11 官方 ComfyUI 模板逐节点核实（不凭记忆编）；“能不能跑”不信计划、只信一次真实的小规模生成（17 帧 4 步，几分钟出结果）；失败区分“显存/内存不足（降档）”与“接线错误（直接报）”。

## Status

- [x] 档位阶梯 / 工作流构建 / 下载器 / 验证降档 / 一键脚本 —— 离线测试 127 项全绿（arch 59 + smoke 68）
- [ ] 真实机器端到端实测数据（进行中，见 `tuning_report.txt`，完成后回填本表）
- [ ] 图生视频（TI2V 的 I 模式）：v1 未含，后续版本
- [ ] 多显卡：未做（llama-tuner 也仅单机单卡实测过，同声明）

## License

MIT © yuanjianghua
