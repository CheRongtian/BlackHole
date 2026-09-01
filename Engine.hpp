#ifndef BLACK_HOLE_ENGINE_HPP
#define BLACK_HOLE_ENGINE_HPP

#include <GL/glew.h>
#include <GLFW/glfw3.h>

#include <vector>

class Engine
{
public:
    Engine();
    ~Engine();

    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    void renderScene(
        const std::vector<unsigned char>& pixels,
        const std::vector<unsigned char>& materialPixels,
        double schwarzschildRadius);

    GLFWwindow* window = nullptr;
    int WIDTH = 800;
    int HEIGHT = 600;

private:
    GLuint quadVAO = 0;
    GLuint quadVBO = 0;
    GLuint texture = 0;
    GLuint materialTexture = 0;
    GLuint shaderProgram = 0;

    GLuint gridVAO = 0;
    GLuint gridVBO = 0;
    GLuint gridEBO = 0;
    GLuint gridShaderProgram = 0;
    GLsizei gridIndexCount = 0;

    GLuint createShaderProgram();
    GLuint createGridShaderProgram();
    void createPerspectiveGrid();
    void drawPerspectiveGrid(double schwarzschildRadius, float aspect);
};

#endif
