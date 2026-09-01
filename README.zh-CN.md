# BlackHole

[English](README.md) | **简体中文**

一个面向 macOS 的实时黑洞可视化项目。光线追踪部分运行在 Metal compute shader 上，窗口、三维透视网格和最终画面合成由 OpenGL 完成。

## 功能

- Schwarzschild 黑洞及事件视界
- 沿弯曲测地线追踪的吸积盘
- 可被引力透镜拉伸成多个弧形像的球体
- 独立于光线追踪器绘制的真实三维 wireframe grid
- 8 帧时间抗锯齿和按材质区分强度的 FXAA

## 渲染结构

Metal 以 `400 × 300` 分辨率计算黑洞、吸积盘和球体，同时输出 RGBA 图像与材质掩码。OpenGL 将结果放大到 `800 × 600` 窗口，对不同材质使用不同强度的边缘处理，再与三维透视网格合成。

主要视觉和计算参数集中在 `Scene.hpp`，包括积分步数、步长、逃逸半径、吸积盘半径和网格尺寸。

## 项目结构

```text
BlackHole.mm           程序入口和渲染循环
Scene.hpp/.cpp         相机、黑洞、对象和场景参数
Engine.hpp/.cpp        GLFW 窗口、OpenGL 合成和三维网格
MetalRayTracer.hpp/.mm Metal compute shader 与测地线追踪
CMakeLists.txt         CMake 构建配置
run.sh                 独立 clang++ 编译运行脚本
GPUinfoFile/           GPU 信息采集工具源码
Draft/                 早期实验版本
```

## 环境要求

- 支持 Metal 的 Mac
- Xcode 或 Xcode Command Line Tools
- Homebrew
- C++17 编译器

安装依赖：

```bash
brew install cmake glfw glew glm
```

## 快速运行

`run.sh` 会直接调用 `clang++`，将当前全部模块编译为项目根目录下的 `BlackHole`，随后启动程序。这个流程不调用 CMake。

```bash
chmod +x run.sh
./run.sh
```

脚本会自动定位项目目录和 Homebrew 安装路径，因此可以从任意工作目录启动。

## 使用 CMake 构建

```bash
cmake -S . -B build
cmake --build build
./build/BlackHole
```

CMake 构建产物位于 `build/`。这种方式适合 IDE 集成以及查看详细构建信息。

## 操作方式

- 鼠标左键拖动：环绕黑洞旋转相机
- `Shift` + 鼠标左键拖动：平移相机目标
- 鼠标滚轮：拉近或拉远

相机移动时，时间累积会立即清空；停止移动后，画面会在 8 帧内重新收敛。
