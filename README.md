# BlackHole

一个面向 macOS 的实时黑洞可视化项目。光线追踪部分运行在 Metal compute shader 上，窗口、三维透视网格和最终画面合成由 OpenGL 完成。

当前场景包含：

- Schwarzschild 黑洞及事件视界
- 经过弯曲测地线追踪的吸积盘
- 可被引力透镜拉伸成多个像的球体对象
- 独立绘制的三维 wireframe grid
- 8 帧时间抗锯齿，以及按材质区分强度的 FXAA

## 渲染结构

Metal 以 `400 × 300` 分辨率计算黑洞、吸积盘和球体，同时输出颜色与材质掩码。OpenGL 将结果放大到 `800 × 600`，对不同材质使用不同强度的边缘处理，再与三维网格合成。

主要视觉和计算参数集中在 `Scene.hpp`，包括积分步数、步长、逃逸半径、吸积盘半径和网格尺寸。

## 项目结构

```text
BlackHole.mm           程序入口和渲染循环
Scene.hpp/.cpp         相机、黑洞、对象和场景参数
Engine.hpp/.cpp        GLFW 窗口、OpenGL 合成和三维网格
MetalRayTracer.hpp/.mm Metal compute shader 与测地线追踪
CMakeLists.txt         CMake 构建配置
run.sh                 独立 clang++ 编译并运行
GPUinfoFile/           GPU 信息采集工具源码
Draft/                 早期实验版本
```

## 环境要求

- macOS 与支持 Metal 的 Apple GPU
- Xcode 或 Xcode Command Line Tools
- Homebrew
- C++17 编译器

安装依赖：

```bash
brew install cmake glfw glew glm
```

## 快速运行

`run.sh` 会直接调用 `clang++` 编译全部模块，生成项目根目录下的 `BlackHole`，随后启动程序。这个流程不调用 CMake。

```bash
chmod +x run.sh
./run.sh
```

脚本可以从任意工作目录启动，它会自动定位项目目录和 Homebrew 安装路径。

## 使用 CMake 构建

```bash
cmake -S . -B build
cmake --build build
./build/BlackHole
```

CMake 构建产物位于 `build/`。这种方式适合查看完整编译信息或使用 IDE 的 CMake 集成。

## 操作方式

- 鼠标左键拖动：环绕黑洞旋转相机
- `Shift` + 鼠标左键拖动：平移观察目标
- 鼠标滚轮：拉近或拉远

相机移动时，时间累积会立即清空；停止移动后，画面会在 8 帧内重新收敛。

## 生成文件

以下本地生成内容已加入 `.gitignore`：

- `BlackHole`
- `GPUinfoFile/gpuinfo`
- `Draft/blackhole`
- `build/` 与常见 CMake 中间文件

如果这些文件已经被 Git 跟踪，需要使用 `git rm --cached` 将它们从索引中移除。
