#include <GL/glew.h>
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>
#include <glm/gtc/type_ptr.hpp>
#include <iostream>
#include <cmath>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <chrono>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdint>

#define _USE_MATH_DEFINES

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

using namespace glm;

// Gravitational constant
const double G = 6.67430e-11;
// Speed of light
const double c = 299792458.0;

using Clock = std::chrono::high_resolution_clock;

static constexpr int METAL_RENDER_WIDTH = 400;          // 800->400
static constexpr int METAL_RENDER_HEIGHT = 300;         // 600->300
static constexpr uint32_t TEMPORAL_SAMPLE_COUNT = 8;
static constexpr uint32_t METAL_MAX_STEPS = 16000;
static constexpr double METAL_D_LAMBDA_METERS = 5.0e7;
static constexpr double METAL_ESCAPE_R_METERS = 8.0e11;
static constexpr float METAL_DISK_R1_RS = 3.0f;         // disk_r1->2.5 * r_s
static constexpr float METAL_DISK_R2_RS = 4.5f;         // disk_r2->5.0 * r_s

static constexpr int GRID_HALF_CELLS = 32;
static constexpr float GRID_STEP_RS = 1.5f;
static constexpr float GRID_WELL_DEPTH_RS = 9.0f;
static constexpr float GRID_WELL_RADIUS_RS = 10.0f;

struct Camera
{
    vec3 pos;
    vec3 target;
    float fovY;
    float azimuth, elevation, radius;

    float minRadius = 1.0e11f, maxRadius = 1.2e12f;

    bool dragging = false;
    bool panning = false;
    double lastX = 0, lastY = 0;

    // adjustable speeds
    float orbitSpeed = 0.008f;
    float panSpeed = 0.001f;
    float zoomSpeed = 1.08f;

    // Camera() : azimuth(0), elevation(M_PI / 2.0f), radius(6.34194e10f)
    // Camera() : fovY(60.0f), azimuth(0), elevation(M_PI / 2.0f), radius(6.34194e10f)
    Camera() : fovY(75.0f), azimuth(M_PI / 2.0f), elevation(M_PI / 3.0f), radius(4.5e11f)
    {
        // Frame the black hole and the reference object at x = 4e11 in the same view.
        target=vec3(8.0e10f, 0.0f, 0.0f);
        updateVectors();
    }

    void updateVectors()
    {
        pos.x = target.x + radius * sin(elevation) * cos(azimuth);
        pos.y = target.y + radius * cos(elevation);
        pos.z = target.z + radius * sin(elevation) * sin(azimuth);
    }

    void processMouse(GLFWwindow* window, double xpos, double ypos)
    {
        float dx = float(xpos - lastX), dy = float(ypos - lastY);

        if (dragging && !panning)
        {
            // Orbit
            azimuth -= dx * orbitSpeed;
            elevation -= dy * orbitSpeed;
            elevation = glm::clamp(elevation, 0.01f, static_cast<float>(M_PI) - 0.01f);
        }
        else if (panning)
        {
            // Pan
            vec3 forward = normalize(target - pos);
            vec3 right = normalize(cross(forward, vec3(0.0f, 1.0f, 0.0f)));
            vec3 up = normalize(cross(right, forward));
            target += (-dx * right + dy * up) * radius * panSpeed;
        }

        lastX = xpos;
        lastY = ypos;
        updateVectors();
    }
};

Camera camera;

struct Engine
{
    GLFWwindow* window = nullptr;

    // Actual window size in pixels
    int WIDTH = 800;
    int HEIGHT = 600;

    /*
    Size of the simulated physical space.
    These values are independent of the 800 x 600 window resolution.

    WIDTH / HEIGHT:
        screen resolution in pixels

    width / height:
        physical size of the simulated world
    */
    float width = 1e11f;
    float height = 7.5e10f;

    // The 3D ray tracer produces an RGBA image that is composited over the OpenGL grid.
    // quadVAO / quadVBO: Store the full-screen quad used to display the image.
    // texture: Stores the RGBA pixel buffer on the GPU.
    // shaderProgram: Draws the texture onto the full-screen quad.

    GLuint quadVAO = 0;
    GLuint quadVBO = 0;
    GLuint texture = 0;
    GLuint shaderProgram = 0;

    GLuint gridVAO = 0;
    GLuint gridVBO = 0;
    GLuint gridEBO = 0;
    GLuint gridShaderProgram = 0;
    GLsizei gridIndexCount = 0;

    Engine()
    {
        // Initialize GLFW
        if (!glfwInit())
        {
            std::cerr << "Failed to initialize GLFW\n";
            std::exit(EXIT_FAILURE);
        }

        // The new texture renderer uses shaders, VAOs and VBOs. Request a modern OpenGL context before creating the window.
        glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
        glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 1);
        glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);

        // macOS requires forward compatibility when using a modern OpenGL core profile
        #ifdef __APPLE__
            glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
        #endif

        // Create the 800 x 600 window shown in the video
        window = glfwCreateWindow(WIDTH, HEIGHT, "Black Hole", nullptr, nullptr);

        if (!window)
        {
            std::cerr << "Window failed to create\n";
            glfwTerminate();
            std::exit(EXIT_FAILURE);
        }

        // Make this window's OpenGL context current
        glfwMakeContextCurrent(window);
        glfwSwapInterval(1);

        // GLEW must be initialized after an OpenGL context has been created.
        glewExperimental = GL_TRUE;

        if (glewInit() != GLEW_OK)
        {
            std::cerr << "Failed to initialize GLEW\n";
            glfwDestroyWindow(window);
            glfwTerminate();
            std::exit(EXIT_FAILURE);
        }
        
        // Create the rendering pipelines used by the ray image and the perspective grid.
        shaderProgram = createShaderProgram();
        gridShaderProgram = createGridShaderProgram();
        createPerspectiveGrid();

        // Create a full-screen quad.
        float quadVerices[] =
        {
            // Position     // Texture coordinate
            -1.0f, -1.0f,   0.0f, 0.0f,
            1.0f, -1.0f,    1.0f, 0.0f,
            1.0f, 1.0f,     1.0f, 1.0f,
            
            -1.0f, -1.0f,   0.0f, 0.0f,
            1.0f, 1.0f,     1.0f, 1.0f,
            -1.0f, 1.0f,    0.0f, 1.0f
        };

        glGenVertexArrays(1, &quadVAO);
        glGenBuffers(1, &quadVBO);

        glBindVertexArray(quadVAO);

        glBindBuffer(GL_ARRAY_BUFFER, quadVBO);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quadVerices), quadVerices, GL_STATIC_DRAW);

        // Vertex position attribute
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
        glEnableVertexAttribArray(0);

        // Texture coordinate attribute
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
        glEnableVertexAttribArray(1);

        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glBindVertexArray(0);

        // Create the texture that will contain the CPU pixel array
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);

        // glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        // glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);   
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        // Keep the texture at the native Metal resolution. OpenGL performs the 2x upscale.
        glTexImage2D(
            GL_TEXTURE_2D,
            0,
            GL_RGBA8,
            METAL_RENDER_WIDTH,
            METAL_RENDER_HEIGHT,
            0,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            nullptr
        );
        glBindTexture(GL_TEXTURE_2D, 0);
    }

    // Create the shader used to display the RGB texture. The vertex shader places the quad directly on the screen. The fragment shader reads the color from the texture.
    GLuint createShaderProgram()
    {
        const char *vertexShaderSource = R"(
            #version 410 core

            layout(location = 0) in vec2 aPos;
            layout(location = 1) in vec2 aTexCoord;

            out vec2 TexCoord;
            
            void main()
            {
                gl_Position = vec4(aPos, 0.0, 1.0);
                TexCoord = aTexCoord;
            }
        )";

        const char *fragmentShaderSource = R"(
            #version 410 core

            in vec2 TexCoord;
            
            out vec4 FragColor;

            uniform sampler2D screenTexture;

            float edgeLuma(vec4 color)
            {
                // Alpha also exposes the opaque black-hole edge to FXAA.
                return dot(color.rgb, vec3(0.299, 0.587, 0.114)) + color.a * 0.25;
            }

            void main()
            {
                vec2 inverseSize = 1.0 / vec2(textureSize(screenTexture, 0));

                vec4 center = texture(screenTexture, TexCoord);
                vec4 northWest = texture(screenTexture, TexCoord + vec2(-1.0,  1.0) * inverseSize);
                vec4 northEast = texture(screenTexture, TexCoord + vec2( 1.0,  1.0) * inverseSize);
                vec4 southWest = texture(screenTexture, TexCoord + vec2(-1.0, -1.0) * inverseSize);
                vec4 southEast = texture(screenTexture, TexCoord + vec2( 1.0, -1.0) * inverseSize);

                float lumaCenter = edgeLuma(center);
                float lumaNorthWest = edgeLuma(northWest);
                float lumaNorthEast = edgeLuma(northEast);
                float lumaSouthWest = edgeLuma(southWest);
                float lumaSouthEast = edgeLuma(southEast);
                float lumaMinimum = min(
                    lumaCenter,
                    min(min(lumaNorthWest, lumaNorthEast), min(lumaSouthWest, lumaSouthEast))
                );
                float lumaMaximum = max(
                    lumaCenter,
                    max(max(lumaNorthWest, lumaNorthEast), max(lumaSouthWest, lumaSouthEast))
                );

                if(lumaMaximum - lumaMinimum < 0.035)
                {
                    FragColor = center;
                    return;
                }

                vec2 direction;
                direction.x = -((lumaNorthWest + lumaNorthEast) - (lumaSouthWest + lumaSouthEast));
                direction.y =  ((lumaNorthWest + lumaSouthWest) - (lumaNorthEast + lumaSouthEast));

                float directionReduce = max(
                    (lumaNorthWest + lumaNorthEast + lumaSouthWest + lumaSouthEast) * 0.0078125,
                    0.0009765625
                );
                float inverseDirectionMinimum = 1.0 / (min(abs(direction.x), abs(direction.y)) + directionReduce);
                direction = clamp(direction * inverseDirectionMinimum, vec2(-4.0), vec2(4.0)) * inverseSize;

                vec4 resultA = 0.5 * (
                    texture(screenTexture, TexCoord + direction * (1.0 / 3.0 - 0.5)) +
                    texture(screenTexture, TexCoord + direction * (2.0 / 3.0 - 0.5))
                );
                vec4 resultB = resultA * 0.5 + 0.25 * (
                    texture(screenTexture, TexCoord + direction * -0.5) +
                    texture(screenTexture, TexCoord + direction *  0.5)
                );

                float lumaResultB = edgeLuma(resultB);
                FragColor = (lumaResultB < lumaMinimum || lumaResultB > lumaMaximum) ? resultA : resultB;
            }
        )";

        GLuint vertexShader = glCreateShader(GL_VERTEX_SHADER);

        glShaderSource(vertexShader, 1, &vertexShaderSource, nullptr);
        glCompileShader(vertexShader);

        GLint vertexSuccess;
        glGetShaderiv(vertexShader, GL_COMPILE_STATUS, &vertexSuccess);

        if(!vertexSuccess)
        {
            char infoLog[1024];
            glGetShaderInfoLog(vertexShader, 1024, nullptr, infoLog);
            std::cerr << "Vertex shader compilation failed:\n" << infoLog << "\n";
        }

        GLuint fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);

        glShaderSource(fragmentShader, 1, &fragmentShaderSource, nullptr);
        glCompileShader(fragmentShader);

        GLint fragmentSuccess;
        glGetShaderiv(fragmentShader, GL_COMPILE_STATUS, &fragmentSuccess);

        if(!fragmentSuccess)
        {
            char infoLog[1024];
            glGetShaderInfoLog(fragmentShader, 1024, nullptr, infoLog);
            std::cerr << "Fragment shader compilation failed:\n" << infoLog << "\n";
        }

        GLuint program = glCreateProgram();

        glAttachShader(program, vertexShader);
        glAttachShader(program, fragmentShader);
        glLinkProgram(program);

        GLint linkSuccess;
        glGetProgramiv(program, GL_LINK_STATUS, &linkSuccess);

        if(!linkSuccess)
        {
            char infoLog[1024];
            glGetProgramInfoLog(program, 1024, nullptr, infoLog);
            std::cerr << "Shader program linking failed:\n" << infoLog << "\n";
        }

        glDeleteShader(vertexShader);
        glDeleteShader(fragmentShader);

        return program;
    }

    GLuint createGridShaderProgram()
    {
        const char *vertexShaderSource = R"(
            #version 410 core

            layout(location = 0) in vec3 aPosition;

            uniform mat4 uMVP;

            void main()
            {
                gl_Position = uMVP * vec4(aPosition, 1.0);
            }
        )";

        const char *fragmentShaderSource = R"(
            #version 410 core

            out vec4 FragColor;

            uniform vec4 uGridColor;

            void main()
            {
                FragColor = uGridColor;
            }
        )";

        auto compileShader = [](GLenum type, const char *source, const char *label)
        {
            GLuint shader = glCreateShader(type);
            glShaderSource(shader, 1, &source, nullptr);
            glCompileShader(shader);

            GLint success = GL_FALSE;
            glGetShaderiv(shader, GL_COMPILE_STATUS, &success);

            if(!success)
            {
                char infoLog[1024];
                glGetShaderInfoLog(shader, sizeof(infoLog), nullptr, infoLog);
                std::cerr << label << " compilation failed:\n" << infoLog << "\n";
            }

            return shader;
        };

        GLuint vertexShader = compileShader(GL_VERTEX_SHADER, vertexShaderSource, "Grid vertex shader");
        GLuint fragmentShader = compileShader(GL_FRAGMENT_SHADER, fragmentShaderSource, "Grid fragment shader");
        GLuint program = glCreateProgram();

        glAttachShader(program, vertexShader);
        glAttachShader(program, fragmentShader);
        glLinkProgram(program);

        GLint success = GL_FALSE;
        glGetProgramiv(program, GL_LINK_STATUS, &success);

        if(!success)
        {
            char infoLog[1024];
            glGetProgramInfoLog(program, sizeof(infoLog), nullptr, infoLog);
            std::cerr << "Grid shader link failed:\n" << infoLog << "\n";
        }

        glDeleteShader(vertexShader);
        glDeleteShader(fragmentShader);

        return program;
    }

    void createPerspectiveGrid()
    {
        const int sideVertexCount = GRID_HALF_CELLS * 2 + 1;
        std::vector<vec3> vertices;
        std::vector<GLuint> indices;

        vertices.reserve(static_cast<size_t>(sideVertexCount * sideVertexCount));

        for(int zIndex = 0; zIndex < sideVertexCount; ++zIndex)
        {
            float z = static_cast<float>(zIndex - GRID_HALF_CELLS) * GRID_STEP_RS;

            for(int xIndex = 0; xIndex < sideVertexCount; ++xIndex)
            {
                float x = static_cast<float>(xIndex - GRID_HALF_CELLS) * GRID_STEP_RS;
                float radius = std::sqrt(x * x + z * z);
                float normalizedRadius = radius / GRID_WELL_RADIUS_RS;
                float y = -GRID_WELL_DEPTH_RS / (1.0f + normalizedRadius * normalizedRadius);

                vertices.emplace_back(x, y, z);
            }
        }

        auto vertexIndex = [sideVertexCount](int zIndex, int xIndex)
        {
            return static_cast<GLuint>(zIndex * sideVertexCount + xIndex);
        };

        indices.reserve(static_cast<size_t>(sideVertexCount * (sideVertexCount - 1) * 4));

        for(int zIndex = 0; zIndex < sideVertexCount; ++zIndex)
        {
            for(int xIndex = 0; xIndex < sideVertexCount - 1; ++xIndex)
            {
                indices.push_back(vertexIndex(zIndex, xIndex));
                indices.push_back(vertexIndex(zIndex, xIndex + 1));
            }
        }

        for(int xIndex = 0; xIndex < sideVertexCount; ++xIndex)
        {
            for(int zIndex = 0; zIndex < sideVertexCount - 1; ++zIndex)
            {
                indices.push_back(vertexIndex(zIndex, xIndex));
                indices.push_back(vertexIndex(zIndex + 1, xIndex));
            }
        }

        gridIndexCount = static_cast<GLsizei>(indices.size());

        glGenVertexArrays(1, &gridVAO);
        glGenBuffers(1, &gridVBO);
        glGenBuffers(1, &gridEBO);

        glBindVertexArray(gridVAO);

        glBindBuffer(GL_ARRAY_BUFFER, gridVBO);
        glBufferData(
            GL_ARRAY_BUFFER,
            static_cast<GLsizeiptr>(vertices.size() * sizeof(vec3)),
            vertices.data(),
            GL_STATIC_DRAW
        );

        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, gridEBO);
        glBufferData(
            GL_ELEMENT_ARRAY_BUFFER,
            static_cast<GLsizeiptr>(indices.size() * sizeof(GLuint)),
            indices.data(),
            GL_STATIC_DRAW
        );

        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(vec3), nullptr);
        glEnableVertexAttribArray(0);

        glBindVertexArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
    }

    void drawPerspectiveGrid(double schwarzschildRadius, float aspect)
    {
        if(schwarzschildRadius <= 0.0 || gridIndexCount == 0) return;

        float inverseRadius = static_cast<float>(1.0 / schwarzschildRadius);
        vec3 eye = camera.pos * inverseRadius;
        vec3 target = camera.target * inverseRadius;

        mat4 projection = glm::perspective(glm::radians(camera.fovY), aspect, 0.05f, 200.0f);
        mat4 view = glm::lookAt(eye, target, vec3(0.0f, 1.0f, 0.0f));
        mat4 mvp = projection * view;

        glEnable(GL_DEPTH_TEST);
        glDepthMask(GL_TRUE);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        glUseProgram(gridShaderProgram);
        glUniformMatrix4fv(glGetUniformLocation(gridShaderProgram, "uMVP"), 1, GL_FALSE, glm::value_ptr(mvp));
        glUniform4f(glGetUniformLocation(gridShaderProgram, "uGridColor"), 0.86f, 0.53f, 0.38f, 0.78f);

        glBindVertexArray(gridVAO);
        glLineWidth(1.0f);
        glDrawElements(GL_LINES, gridIndexCount, GL_UNSIGNED_INT, nullptr);
        glBindVertexArray(0);
    }

    // Draw the 3D grid first, then blend the ray-traced RGBA image over it.
    void renderScene(const std::vector<unsigned char> &pixels, double schwarzschildRadius)
    {
        // glViewport(0, 0, WIDTH, HEIGHT);
        // glClearColor(0.0f, 0.0f, 0.0f, 1.0f);

        // On Retina displays, the framebuffer can be larger than the logical GLFW window size.
        // Use the real framebuffer size so the full-screen quad actually covers the entire drawable area.
        int framebufferWidth;
        int framebufferHeight;

        glfwGetFramebufferSize(window, &framebufferWidth, &framebufferHeight);
        glViewport(0, 0, framebufferWidth, framebufferHeight);

        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        float aspect = static_cast<float>(framebufferWidth) / static_cast<float>(framebufferHeight);
        drawPerspectiveGrid(schwarzschildRadius, aspect);

        // Copy the current CPU pixel buffer into the texture.
        glBindTexture(GL_TEXTURE_2D, texture); 

        glTexSubImage2D(
            GL_TEXTURE_2D,
            0,
            0,
            0,
            METAL_RENDER_WIDTH,
            METAL_RENDER_HEIGHT,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            pixels.data()
        );

        // Transparent background pixels preserve the grid. Opaque ray hits cover it.
        glDisable(GL_DEPTH_TEST);
        glDepthMask(GL_FALSE);
        glEnable(GL_BLEND);
        // Temporal coverage and FXAA produce premultiplied-alpha edge pixels.
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        glUseProgram(shaderProgram);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, texture);

        GLint textureLocation = glGetUniformLocation(shaderProgram, "screenTexture");
        glUniform1i(textureLocation, 0);

        glBindVertexArray(quadVAO);
        glDrawArrays(GL_TRIANGLES, 0, 6);

        glBindVertexArray(0);
        glDisable(GL_BLEND);
        glDepthMask(GL_TRUE);

        glfwSwapBuffers(window);
        glfwPollEvents();
    } 

    void run()
    {
        // Clear everything drawn during the previous frame
        glClear(GL_COLOR_BUFFER_BIT);
        // Set up the 2D orthographic coordinate system
        glMatrixMode(GL_PROJECTION);
        glLoadIdentity();

        double left   = -width;
        double right  =  width;
        double bottom = -height;
        double top    =  height;

        /*
        The visible simulation space becomes:
        x: -1e11   to +1e11
        y: -7.5e10 to +7.5e10

        The black hole and the rays added later will use these world-space coordinates directly.
        */
        glOrtho(left, right, bottom, top, -1.0, 1.0);

        // Switch back to the model-view matrix
        glMatrixMode(GL_MODELVIEW);
        glLoadIdentity();
    }

    ~Engine()
    {
        // Delete the OpenGL objects created for the pixel-buffer rendering pipeline
        if(texture) glDeleteTextures(1, &texture);
        if(quadVBO) glDeleteBuffers(1, &quadVBO);
        if(quadVAO) glDeleteVertexArrays(1, &quadVAO);
        if(gridEBO) glDeleteBuffers(1, &gridEBO);
        if(gridVBO) glDeleteBuffers(1, &gridVBO);
        if(gridVAO) glDeleteVertexArrays(1, &gridVAO);
        if(gridShaderProgram) glDeleteProgram(gridShaderProgram);
        if(shaderProgram) glDeleteProgram(shaderProgram);
        if(window) glfwDestroyWindow(window);
        glfwTerminate();
    }
};

// Create the global Engine used by the simulation
Engine engine;

// position -> center of the black hole
// mass     -> mass of the black hole
// r_s      -> Schwarzschild radius / event horizon radius
struct BlackHole
{
    // vec2 position;
    vec3 position;
    double mass;
    // Schwarzschild radius
    double r_s;

    BlackHole(vec3 pos, double m): position(pos), mass(m)
    {
        /*
        Calculate the Schwarzschild radius:
                      2GM
              r_s = --------
                       c^2
        This radius will later be used both to detect whether a ray has entered the event horizon and inside the geodesic calculations.
        */
        r_s = (2.0 * G * mass) / (c * c);
    }

    bool Intercept(double px, double py, double pz) const
    {
        double dx = px - position.x;
        double dy = py - position.y;
        double dz = pz - position.z;
        double dist2 = dx * dx + dy * dy + dz * dz;
        return dist2 < r_s * r_s;
    }

    void draw()
    {
        // Draw the black hole in red for now. This makes the event horizon easy to see while developing and debugging the simulation.
        glColor3f(1.0f, 0.0f, 0.0f);
        // Use a triangle fan to draw a filled circle
        glBegin(GL_TRIANGLE_FAN);

        // Add the center of the circle first
        glVertex2f(position.x, position.y);

        // Approximate the circle with 100 small triangles
        for (int i = 0; i <= 100; i++)
        {
            // Move from 0 to 2*pi around the full circle
            float angle = 2.0f * static_cast<float>(M_PI) * static_cast<float>(i) / 100.0f;

            // A circle centered at the origin would use:
            // x = cos(angle) * radius
            // y = sin(angle) * radius
            // Adding position moves the circle so that the black hole can be placed anywhere in the scene.
            float x = std::cos(angle) * static_cast<float>(r_s) + position.x;
            float y = std::sin(angle) * static_cast<float>(r_s) + position.y;

            glVertex2f(x, y);
        }
        glEnd();
    }
};

// Place it on the right-hand side of the simulation:
// x = engine.width / 2
// y = 0
// The mass value follows the value shown in this stage of the video.
BlackHole SagA(vec3(0.0f, 0.0f, 0.0f), 8.54e36);

// Scene objects use meters on the CPU. They are converted to Schwarzschild-radius
// units before being sent to the Metal ray tracer.
struct alignas(16) Object
{
    vec4 posRadius;
    vec4 color;
    float mass;
    float alignmentPadding[3];
    vec3 velocity;
    float velocityPadding;
};

static_assert(sizeof(Object) == 64, "Object must match the Metal buffer layout");

std::vector<Object> objects =
{
    {
        vec4(4.0e11f, 0.0f, 0.0f, 4.0e10f),
        vec4(1.0f, 1.0f, 0.0f, 1.0f),
        0.0f,
        {0.0f, 0.0f, 0.0f},
        vec3(0.0f),
        0.0f
    }
};

/*
x, y -> current Cartesian position of the ray
dir -> direction in which the ray is travelling

At this stage the ray moves in a perfectly straight line.
Gravity has not been implemented yet.
*/
struct Ray;
void rk4Step(Ray &ray, double dLambda, double r_s);

struct Ray
{
    // Store the current position and polar position.
    double x; double y; double z;
    double r; double phi; double theta;
    // First derivatives with respect to the affine parameter
    double dr; double dphi; double dtheta;
    double E, L;
    
    // Original Cartesian direction
    vec3 dir;
    // Store every previous position of the ray.
    std::vector<vec3> trail;
    // Initialize the ray from a starting position and a direction vector.
    
    Ray(vec3 pos, vec3 direction): x(pos.x), y(pos.y),z(pos.z), dir(direction)
    {
        r = std::sqrt(x * x + y * y + z * z);
        phi = glm::atan(y, x);
        theta = std::acos(z / r);

        // Convert the initial Cartesian direction into radial and angular rates.
        dr = (x * dir.x + y * dir.y + z * dir.z) / r;
        double sinTheta = std::sin(theta);
        double cosTheta = std::cos(theta);
        double sinPhi = std::sin(phi);
        double cosPhi = std::cos(phi);

        dtheta = (dir.x * cosTheta * cosPhi + dir.y * cosTheta * sinPhi - dir.z * sinTheta) / r;
        dphi = (-dir.x * sinPhi + dir.y * cosPhi) / (r * sinTheta);

        double f = 1.0 - SagA.r_s / r;
        E = std::sqrt(dr * dr + f * r * r * (dtheta * dtheta + sinTheta * sinTheta * dphi * dphi));
        L = r * r * sinTheta * sinTheta * dphi;
    }

    // Draw the ray as a single point.
    void draw()
    {
        // Enable alpha blending because different parts of the trail will use different opacity values
        glEnable(GL_BLEND);
        // Standard alpha blending:
        // final = source * alpha + destination * (1-alpha)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        // Render the trail as a thin line
        glLineWidth(1.0f);
        // A line strip needs at least 2 points
        size_t N = trail.size();
        if(N<2) return;
        // Connect all recorded positions into one continuous line
        glBegin(GL_LINE_STRIP);
        for(size_t i=0; i<N; i++)
        {
            float alpha = static_cast<float>(i) / static_cast<float>(N-1);
            // Draw the trail iin white. Keep a min alpha of 0.05 so the oldest part does not become completely invisible.
            glColor4f(1.0f, 1.0f, 1.0f, std::max(alpha, 0.05f));
            // Draw the position recorded at this point in the ray's history
            glVertex2f(trail[i].x, trail[i].y);
        }
        /*
        // Make the ray visible as a small point
        glPointSize(2.0f);

        glBegin(GL_POINTS);

        // Draw the point at the ray's current position
        glVertex2f(
            static_cast<float>(x),
            static_cast<float>(y)
        );
        */
        glEnd();
    }

    // Advance the ray by one simulation step.
    void step(double dLambda, double r_s)
    {
        if(r<r_s) return;

        rk4Step(*this, dLambda, r_s);
        x = r * std::sin(theta) * std::cos(phi);
        y = r * std::sin(theta) * std::sin(phi);
        z = r * std::cos(theta);

        /*
        double d2r = r * dphi * dphi - (c * c * r_s) / (2.0 * r * r);
        double d2phi = -2.0 * dr * dphi / r;
        
        dr += d2r * dLambda;
        dphi += d2phi * dLambda;

        r += dr * dLambda;
        phi += dphi * dLambda;

        x = std::cos(phi) * r;
        y = std::sin(phi) * r;
        */
        
        /*
        // Recalculate the ray's current distance from the black hole before advancing it.
        r = std::hypot(x, y);
        if(r < SagA.r_s) return;
        // Move along the x component of the direction
        x += dir.x * c;
        // Move along the y component of the direction
        y += dir.y * c;
        // Save the new Cartesian position in the trail. Later draw() will connect all of these points
        */
        // trail.push_back(vec3(static_cast<float>(x), static_cast<float>(y), static_cast<float>(z)));
    }
};

// Store rays in a vector.
std::vector<Ray> rays;

// Returns the derivatives of the current four-value state.
void geodesicRHS(Ray &ray, double rhs[6], double r_s)
{
    // double sinTheta = std::sin(ray.theta);
    // double cosTheta = std::cos(ray.theta);
    double r = ray.r;
    double theta = ray.theta;
    double dr = ray.dr;
    double dtheta = ray.dtheta;
    double dphi = ray.dphi;
    double E = ray.E;

    double f = 1.0 - r_s / r;
    double dt_dlambda = E / f;

    rhs[0] = dr;
    rhs[1] = dtheta;
    rhs[2] = dphi;
    rhs[3] = - (r_s / (2 * r * r)) * f * dt_dlambda * dt_dlambda
        + (r_s / (2 * r * r * f)) * dr * dr
        + r * (dtheta * dtheta + std::sin(theta) * std::sin(theta) * dphi * dphi);

    rhs[4] =
        - (2.0 / r) * dr * dtheta
        + std::sin(theta) * std::cos(theta) * dphi * dphi;

    rhs[5] =
        - (2.0 / r) * dr * dphi
        - 2.0 * std::cos(theta) / std::sin(theta) * dtheta * dphi;
}

// Create a temporary state by adding a sacled derivative to the original state
void addState(const double a[6], const double b[6], double factor, double out[6])
{
    for(int i=0; i<6; i++)
    {
        out[i] = a[i] + factor * b[i];
    }
}

// Evaluate the geodesic four times before accepting the next ray state.
void rk4Step(Ray &ray, double dLambda, double r_s)
{
    if(ray.r < r_s) return;

    double y0[6] = {ray.r, ray.theta, ray.phi, ray.dr, ray.dtheta, ray.dphi};
    double k1[6], k2[6], k3[6], k4[6], temp[6];

    geodesicRHS(ray, k1, r_s);

    addState(y0, k1, dLambda/2.0, temp);
    Ray r2 = ray;
    r2.r = temp[0];
    r2.theta = temp[1];
    r2.phi = temp[2];
    r2.dr = temp[3];
    r2.dtheta = temp[4];
    r2.dphi = temp[5];
    geodesicRHS(r2, k2, r_s);

    addState(y0, k2, dLambda/2.0, temp);
    Ray r3 = ray;
    r3.r = temp[0];
    r3.theta = temp[1];
    r3.phi = temp[2];
    r3.dr = temp[3];
    r3.dtheta = temp[4];
    r3.dphi = temp[5];
    geodesicRHS(r3, k3, r_s);

    addState(y0, k3, dLambda, temp);
    Ray r4 = ray;
    r4.r = temp[0];
    r4.theta = temp[1];
    r4.phi = temp[2];
    r4.dr = temp[3];
    r4.dtheta = temp[4];
    r4.dphi = temp[5];
    geodesicRHS(r4, k4, r_s);

    ray.r += (dLambda/6.0)*(k1[0] + 2*k2[0] + 2*k3[0] + k4[0]);
    ray.theta += (dLambda/6.0)*(k1[1] + 2*k2[1] + 2*k3[1] + k4[1]);
    ray.phi += (dLambda/6.0)*(k1[2] + 2*k2[2] + 2*k3[2] + k4[2]);
    ray.dr += (dLambda/6.0)*(k1[3] + 2*k2[3] + 2*k3[3] + k4[3]);
    ray.dtheta += (dLambda/6.0)*(k1[4] + 2*k2[4] + 2*k3[4] + k4[4]);
    ray.dphi += (dLambda/6.0)*(k1[5] + 2*k2[5] + 2*k3[5] + k4[5]);
}

void setupCameraCallbacks(GLFWwindow* window)
{
    glfwSetCursorPosCallback(window, [](GLFWwindow* window, double xpos, double ypos)
    {
        camera.processMouse(window, xpos, ypos);
    });

    glfwSetMouseButtonCallback(window, [](GLFWwindow* window, int button, int action, int mods)
    {
        if(button == GLFW_MOUSE_BUTTON_LEFT)
        {
            if(action == GLFW_PRESS)
            {
                camera.dragging = true;
                camera.panning = (mods & GLFW_MOD_SHIFT) != 0;
                glfwGetCursorPos(window, &camera.lastX, &camera.lastY);
            }
            else if(action == GLFW_RELEASE)
            {
                camera.dragging = false;
                camera.panning = false;
            }
        }
    });

    glfwSetScrollCallback(window, [](GLFWwindow* window, double xoffset, double yoffset)
    {
        if(yoffset > 0.0)
            camera.radius /= camera.zoomSpeed;
        else if(yoffset < 0.0)
            camera.radius *= camera.zoomSpeed;

        camera.radius = glm::clamp(camera.radius, camera.minRadius, camera.maxRadius);
        camera.updateVectors();
    });
}


struct MetalPixelRGBA
{
    unsigned char r;
    unsigned char g;
    unsigned char b;
    unsigned char a;
};

static_assert(sizeof(MetalPixelRGBA) == 4, "MetalPixelRGBA must be exactly 4 bytes");

struct MetalRaytraceParams
{
    float cameraPosX;
    float cameraPosY;
    float cameraPosZ;
    float pad0;

    float targetX;
    float targetY;
    float targetZ;
    float pad1;

    float fovYRadians;
    float aspect;
    uint32_t renderWidth;
    uint32_t renderHeight;

    uint32_t maxSteps;
    float dLambda;
    float escapeR;
    float horizonR;

    float diskR1;
    float diskR2;
    uint32_t objectCount;
    float pad2;

    uint32_t sampleIndex;
    float jitterX;
    float jitterY;
    float pad3;
};

static_assert(sizeof(MetalRaytraceParams) == 96, "MetalRaytraceParams must match the Metal layout");

static const char* METAL_RAYTRACE_SHADER = R"METAL(
#include <metal_stdlib>
using namespace metal;

constant uint TEMPORAL_SAMPLE_COUNT = 8;

struct Params
{
    float cameraPosX;
    float cameraPosY;
    float cameraPosZ;
    float pad0;

    float targetX;
    float targetY;
    float targetZ;
    float pad1;

    float fovYRadians;
    float aspect;
    uint renderWidth;
    uint renderHeight;

    uint maxSteps;
    float dLambda;
    float escapeR;
    float horizonR;

    float diskR1;
    float diskR2;
    uint objectCount;
    float pad2;

    uint sampleIndex;
    float jitterX;
    float jitterY;
    float pad3;
};

struct Object
{
    float4 posRadius;
    float4 color;
    float mass;
    float3 velocity;
};

struct RayState
{
    // q = (r, theta, phi)
    float3 q;

    // v = (dr, dtheta, dphi)
    float3 v;

    float E;
};

struct Derivative
{
    float3 dq;
    float3 dv;
};

float safeSin(float x)
{
    float s = sin(x);

    if(fabs(s) < 1e-5f)
        return (s < 0.0f) ? -1e-5f : 1e-5f;

    return s;
}

float3 rayCartesian(RayState ray)
{
    float r = ray.q.x;
    float theta = ray.q.y;
    float phi = ray.q.z;

    return float3(
        r * sin(theta) * cos(phi),
        r * sin(theta) * sin(phi),
        r * cos(theta)
    );
}

bool interceptDisk(float3 oldPos, float3 newPos, constant Params& p, thread float& radiusAtHit)
{
    bool crossed = (oldPos.y * newPos.y < 0.0f);
    if(!crossed) return false;

    float denominator = newPos.y - oldPos.y;
    if(fabs(denominator) < 1e-8f) return false;

    float crossingT = clamp(-oldPos.y / denominator, 0.0f, 1.0f);
    float3 crossingPoint = mix(oldPos, newPos, crossingT);
    float diskRadius = length(float2(crossingPoint.x, crossingPoint.z));

    if(diskRadius < p.diskR1 || diskRadius > p.diskR2) return false;

    radiusAtHit = diskRadius;
    return true;
}

bool interceptObject(
    float3 oldPos,
    float3 newPos,
    constant Object* objects,
    uint objectCount,
    thread float4& objectColor,
    thread float3& hitCenter,
    thread float& hitRadius,
    thread float3& hitPoint
)
{
    float3 segment = newPos - oldPos;
    float a = dot(segment, segment);
    if(a < 1e-12f) return false;

    bool foundHit = false;
    float closestT = 2.0f;

    for(uint objectIndex = 0; objectIndex < objectCount; ++objectIndex)
    {
        float3 center = objects[objectIndex].posRadius.xyz;
        float radius = objects[objectIndex].posRadius.w;
        float3 offset = oldPos - center;
        float b = 2.0f * dot(offset, segment);
        float c = dot(offset, offset) - radius * radius;
        float discriminant = b * b - 4.0f * a * c;

        if(discriminant < 0.0f) continue;

        float squareRoot = sqrt(discriminant);
        float inverseDenominator = 0.5f / a;
        float nearT = (-b - squareRoot) * inverseDenominator;
        float farT = (-b + squareRoot) * inverseDenominator;
        float candidateT = nearT;

        if(candidateT < 0.0f || candidateT > 1.0f) candidateT = farT;
        if(candidateT < 0.0f || candidateT > 1.0f || candidateT >= closestT) continue;

        closestT = candidateT;
        objectColor = objects[objectIndex].color;
        hitCenter = center;
        hitRadius = radius;
        hitPoint = oldPos + candidateT * segment;
        foundHit = true;
    }

    return foundHit;
}

RayState makeRay(float3 pos, float3 dir, constant Params& p)
{
    RayState ray;

    float r = length(pos);
    float phi = atan2(pos.y, pos.x);
    float theta = acos(clamp(pos.z / r, -1.0f, 1.0f));

    float sinTheta = safeSin(theta);
    float cosTheta = cos(theta);
    float sinPhi = sin(phi);
    float cosPhi = cos(phi);

    float dr = dot(pos, dir) / r;
    float dtheta = (dir.x*cosTheta*cosPhi+dir.y*cosTheta*sinPhi-dir.z*sinTheta)/r;
    float dphi = (-dir.x*sinPhi+dir.y*cosPhi)/(r*sinTheta);
    float f = max(1.0f-p.horizonR/r,1e-5f);
    float angular = dtheta*dtheta+sinTheta*sinTheta*dphi*dphi;
    float E2 = dr*dr+f*r*r*angular;

    ray.q = float3(r, theta, phi);
    ray.v = float3(dr, dtheta, dphi);
    ray.E = sqrt(max(E2, 0.0f));

    return ray;
}

Derivative geodesicRHS(RayState ray, constant Params& p)
{
    Derivative out;

    float r = max(ray.q.x,p.horizonR * 1.00001f);
    float theta = ray.q.y;
    float dr = ray.v.x;
    float dtheta = ray.v.y;
    float dphi = ray.v.z;
    float sinTheta = safeSin(theta);
    float cosTheta = cos(theta);

    // Near the event horizon f -> 0.
    // The ray is classified as captured before reaching
    // the exact Schwarzschild coordinate singularity.
    
    float f = max(1.0f - p.horizonR / r, 1e-5f);
    float dt_dlambda = ray.E / f;

    // First derivatives
    out.dq = ray.v;

    // Second derivatives
    float d2r = -(p.horizonR/(2.0f*r*r))*f*dt_dlambda*dt_dlambda+(p.horizonR/(2.0f*r*r*f))*dr*dr+r*f*(dtheta*dtheta+sinTheta*sinTheta*dphi*dphi);
    float d2theta = -(2.0f/r)*dr*dtheta+sinTheta*cosTheta*dphi*dphi;
    float d2phi = -(2.0f/r)*dr*dphi-2.0f*cosTheta/sinTheta*dtheta*dphi;

    out.dv = float3(d2r, d2theta, d2phi);

    return out;
}

RayState addState(RayState base, Derivative k, float factor)
{
    RayState out = base;

    out.q = base.q+factor*k.dq;
    out.v = base.v+factor*k.dv;

    return out;
}

void rk4Step(thread RayState& ray, float h, constant Params& p)
{
    Derivative k1 = geodesicRHS(ray, p);
    Derivative k2 = geodesicRHS(addState(ray, k1, h * 0.5f), p);
    Derivative k3 = geodesicRHS(addState(ray, k2, h * 0.5f), p);
    Derivative k4 = geodesicRHS(addState(ray, k3, h), p);

    ray.q += (h/6.0f)*(k1.dq+2.0f*k2.dq+2.0f*k3.dq+k4.dq);
    ray.v += (h/6.0f)*(k1.dv+2.0f*k2.dv+2.0f*k3.dv+k4.dv);
}

kernel void raytraceKernel(
    device uchar4* output [[buffer(0)]],
    constant Params& p [[buffer(1)]],
    constant Object* objects [[buffer(2)]],
    device float4* accumulation [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
)
{
    if((gid.x >= p.renderWidth)||(gid.y >= p.renderHeight)) return;
    if(p.sampleIndex >= TEMPORAL_SAMPLE_COUNT) return;

    float3 cameraPos = float3(p.cameraPosX, p.cameraPosY, p.cameraPosZ);
    float3 target = float3(p.targetX, p.targetY, p.targetZ);
    float3 forward = normalize(target-cameraPos);
    float3 worldUp = float3(0.0f, 1.0f, 0.0f);
    float3 right = cross(forward, worldUp);

    if(dot(right, right)<1e-8f) right = float3(0.0f, 0.0f, 1.0f);
    else right = normalize(right);

    float3 up = normalize(cross(right, forward));
    float tanHalfFov = tan(p.fovYRadians*0.5f);
    float sampleX = float(gid.x) + 0.5f + p.jitterX;
    float sampleY = float(gid.y) + 0.5f + p.jitterY;
    float u = (2.0f*(sampleX/float(p.renderWidth))-1.0f)*p.aspect*tanHalfFov;
    float v = (1.0f-2.0f*(sampleY/float(p.renderHeight)))*tanHalfFov;
    float3 dir = normalize(u*right+v*up+forward);

    RayState ray =makeRay(cameraPos, dir, p);

    bool captured = false;
    bool diskHit = false;
    bool objectHit = false;

    float diskRadiusAtHit = 0.0f;
    float4 objectColor = float4(0.0f);
    float3 hitCenter = float3(0.0f);
    float hitRadius = 0.0f;
    float3 objectHitPoint = float3(0.0f);

    for(uint i = 0; i < p.maxSteps; i++)
    {
        if(ray.q.x<=p.horizonR*1.01f)
        {
            captured=true;
            break;
        }

        if(ray.q.x > p.escapeR&&ray.v.x > 0.0f) break;

        float previousR = ray.q.x;
        float3 oldPos = rayCartesian(ray);

        rk4Step(ray, p.dLambda, p);

        if(!all(isfinite(ray.q)) || !all(isfinite(ray.v)))
        {
            if(previousR <= p.horizonR * 1.02f) captured = true;
            break;
        }

        float3 newPos = rayCartesian(ray);

        if(interceptObject(
            oldPos,
            newPos,
            objects,
            p.objectCount,
            objectColor,
            hitCenter,
            hitRadius,
            objectHitPoint
        ))
        {
            objectHit = true;
            break;
        }

        if(interceptDisk(oldPos, newPos, p, diskRadiusAtHit))
        {
            diskHit = true;
            break;
        }

        if(ray.q.x <= p.horizonR * 1.01f)
        {
            captured = true;
            break;
        }
    }

    uint index = gid.y*p.renderWidth+gid.x;
    float4 currentColor = float4(0.0f);

    if(objectHit)
    {
        float3 normal = normalize((objectHitPoint - hitCenter) / max(hitRadius, 1e-6f));
        float3 lightDirection = normalize(float3(-0.35f, 0.80f, 0.48f));
        float3 viewDirection = normalize(cameraPos - objectHitPoint);
        float diffuse = max(dot(normal, lightDirection), 0.0f);
        float3 reflectedLight = reflect(-lightDirection, normal);
        float specular = pow(max(dot(reflectedLight, viewDirection), 0.0f), 24.0f) * 0.30f;
        float3 shadedColor = clamp(objectColor.rgb * (0.22f + 0.78f * diffuse) + specular, 0.0f, 1.0f);
        float objectAlpha = clamp(objectColor.a, 0.0f, 1.0f);

        currentColor = float4(shadedColor * objectAlpha, objectAlpha);
    }
    else if(diskHit)
    {
        float diskT = clamp((diskRadiusAtHit-p.diskR1)/(p.diskR2-p.diskR1), 0.0f, 1.0f);
        float3 innerColor = float3(1.0f, 0.15f, 0.01f);
        float3 outerColor = float3(1.0f, 0.72f, 0.10f);
        float3 diskColor = mix(innerColor, outerColor, diskT);

        currentColor = float4(diskColor, 1.0f);
    }
    else if(captured) currentColor = float4(0.0f, 0.0f, 0.0f, 1.0f);

    float4 accumulatedColor = currentColor;

    if(p.sampleIndex > 0)
    {
        float sampleWeight = 1.0f / float(p.sampleIndex + 1);
        accumulatedColor = mix(accumulation[index], currentColor, sampleWeight);
    }

    accumulatedColor = clamp(accumulatedColor, 0.0f, 1.0f);
    accumulation[index] = accumulatedColor;
    output[index] = uchar4(
        uchar(accumulatedColor.r * 255.0f + 0.5f),
        uchar(accumulatedColor.g * 255.0f + 0.5f),
        uchar(accumulatedColor.b * 255.0f + 0.5f),
        uchar(accumulatedColor.a * 255.0f + 0.5f)
    );
}
)METAL";

class MetalRayTracer
{
public:
    MetalRayTracer()
    {
        device = MTLCreateSystemDefaultDevice();

        if(!device)
        {
            std::cerr << "Metal device was not found.\n";
            std::exit(EXIT_FAILURE);
        }

        commandQueue =[device newCommandQueue];

        if(!commandQueue)
        {
            std::cerr << "Failed to create Metal command queue.\n";
            std::exit(EXIT_FAILURE);
        }

        NSString* source =[NSString stringWithUTF8String: METAL_RAYTRACE_SHADER];
        MTLCompileOptions* options = [[MTLCompileOptions alloc] init];

        options.mathMode = MTLMathModeFast;

        NSError* error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];

        if(!library)
        {
            std::cerr<<"Metal shader compilation failed:\n"<<[[error localizedDescription] UTF8String]<<"\n";
            std::exit(EXIT_FAILURE);
        }

        id<MTLFunction> function = [library newFunctionWithName: @"raytraceKernel"];

        if(!function)
        {
            std::cerr<<"Failed to find raytraceKernel in Metal library.\n";
            std::exit(EXIT_FAILURE);
        }

        pipeline = [device newComputePipelineStateWithFunction:function error:&error];

        if(!pipeline)
        {
            std::cerr<<"Failed to create Metal compute pipeline:\n"<<[[error localizedDescription] UTF8String]<<"\n";
            std::exit(EXIT_FAILURE);
        }

        outputBuffer =
            [device
                newBufferWithLength: METAL_RENDER_WIDTH*METAL_RENDER_HEIGHT*sizeof(MetalPixelRGBA)
                options: MTLResourceStorageModeShared
            ];

        if(!outputBuffer)
        {
            std::cerr<<"Failed to create shared Metal output buffer.\n";
            std::exit(EXIT_FAILURE);
        }

        accumulationBuffer =
            [device
                newBufferWithLength: METAL_RENDER_WIDTH*METAL_RENDER_HEIGHT*sizeof(float)*4
                options: MTLResourceStorageModePrivate
            ];

        if(!accumulationBuffer)
        {
            std::cerr<<"Failed to create Metal temporal accumulation buffer.\n";
            std::exit(EXIT_FAILURE);
        }

        std::cout<<"Metal GPU: "<<[[device name] UTF8String]<<"\n";
        std::cout<<"Metal raytrace resolution: "<<METAL_RENDER_WIDTH<<" x "<<METAL_RENDER_HEIGHT<<"\n";
        std::cout<< "Metal MAX_STEPS: "<< METAL_MAX_STEPS<<" (original CPU value: 10000)"<<"\n";
        std::cout<<"Accretion disk: "<<METAL_DISK_R1_RS<<" r_s -> "<<METAL_DISK_R2_RS<<" r_s"<<"\n";
        std::cout<<"Temporal anti-aliasing: "<<TEMPORAL_SAMPLE_COUNT<<" samples while camera is still\n";
    }

    void render(std::vector<unsigned char>& pixels, int displayWidth, int displayHeight)
    {
        @autoreleasepool
        {
            const bool cameraChanged =
                !hasPreviousCamera ||
                glm::length(camera.pos - previousCameraPos) > 1.0e4f ||
                glm::length(camera.target - previousCameraTarget) > 1.0e4f ||
                std::fabs(camera.fovY - previousCameraFovY) > 1.0e-5f;

            if(cameraChanged)
            {
                accumulatedSampleCount = 0;
                previousCameraPos = camera.pos;
                previousCameraTarget = camera.target;
                previousCameraFovY = camera.fovY;
                hasPreviousCamera = true;
            }

            static constexpr float jitterOffsets[TEMPORAL_SAMPLE_COUNT][2] =
            {
                { 0.000f,  0.000f},
                {-0.250f, -0.250f},
                { 0.250f,  0.250f},
                { 0.250f, -0.250f},
                {-0.250f,  0.250f},
                {-0.375f,  0.000f},
                { 0.375f,  0.000f},
                { 0.000f,  0.000f}
            };

            uint32_t jitterIndex = std::min(accumulatedSampleCount, TEMPORAL_SAMPLE_COUNT - 1);
            MetalRaytraceParams params{};
            const double invRs = 1.0/SagA.r_s;
            
            params.cameraPosX = static_cast<float>(camera.pos.x*invRs);
            params.cameraPosY = static_cast<float>(camera.pos.y*invRs);
            params.cameraPosZ = static_cast<float>(camera.pos.z*invRs);
            
            params.targetX = static_cast<float>(camera.target.x*invRs);
            params.targetY = static_cast<float>(camera.target.y*invRs);
            params.targetZ = static_cast<float>(camera.target.z*invRs);

            params.fovYRadians = glm::radians(camera.fovY);

            params.aspect = static_cast<float>(displayWidth)/static_cast<float>(displayHeight);

            params.renderWidth = METAL_RENDER_WIDTH;
            params.renderHeight = METAL_RENDER_HEIGHT;
            params.maxSteps = METAL_MAX_STEPS;

            params.dLambda = static_cast<float>(METAL_D_LAMBDA_METERS*invRs);
            params.escapeR = static_cast<float>(METAL_ESCAPE_R_METERS*invRs);

            params.horizonR =1.0f;
            params.diskR1 = METAL_DISK_R1_RS;
            params.diskR2 = METAL_DISK_R2_RS;
            params.objectCount = static_cast<uint32_t>(objects.size());
            params.pad2 = 0.0f;
            params.sampleIndex = accumulatedSampleCount;
            params.jitterX = jitterOffsets[jitterIndex][0];
            params.jitterY = jitterOffsets[jitterIndex][1];
            params.pad3 = 0.0f;

            std::vector<Object> normalizedObjects = objects;

            for(Object& object : normalizedObjects)
            {
                object.posRadius.x = static_cast<float>(object.posRadius.x * invRs);
                object.posRadius.y = static_cast<float>(object.posRadius.y * invRs);
                object.posRadius.z = static_cast<float>(object.posRadius.z * invRs);
                object.posRadius.w = static_cast<float>(object.posRadius.w * invRs);
            }

            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

            [encoder setComputePipelineState: pipeline];
            [encoder setBuffer: outputBuffer offset:0 atIndex:0];
            [encoder setBytes: &params length: sizeof(params) atIndex:1];
            [encoder
                setBytes: normalizedObjects.data()
                length: normalizedObjects.size() * sizeof(Object)
                atIndex:2
            ];
            [encoder setBuffer: accumulationBuffer offset:0 atIndex:3];

            MTLSize gridSize = MTLSizeMake(METAL_RENDER_WIDTH, METAL_RENDER_HEIGHT, 1);

            NSUInteger threadWidth = pipeline.threadExecutionWidth;
            NSUInteger maxThreads = pipeline.maxTotalThreadsPerThreadgroup;
            NSUInteger threadHeight = std::max<NSUInteger>(1, std::min<NSUInteger>(8, maxThreads/threadWidth));

            MTLSize threadgroupSize = MTLSizeMake(threadWidth, threadHeight, 1);

            [encoder dispatchThreads: gridSize threadsPerThreadgroup: threadgroupSize];
            [encoder endEncoding];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];

            if(commandBuffer.status==MTLCommandBufferStatusError)
            {
                std::cerr<<"Metal command buffer failed:\n"<<[[[commandBuffer error] localizedDescription] UTF8String]<<"\n";
                return;
            }

            if(accumulatedSampleCount < TEMPORAL_SAMPLE_COUNT)
                ++accumulatedSampleCount;

            const MetalPixelRGBA* gpuPixels = static_cast<const MetalPixelRGBA*>([outputBuffer contents]);

            for(int y = 0; y < METAL_RENDER_HEIGHT; ++y)
            {
                int sourceY = METAL_RENDER_HEIGHT - 1 - y;
                
                for(int x = 0; x < METAL_RENDER_WIDTH; ++x)
                {
                    const MetalPixelRGBA& sourcePixel = gpuPixels[sourceY * METAL_RENDER_WIDTH + x];
                    int idx = (y * METAL_RENDER_WIDTH + x) * 4;

                    pixels[idx + 0] = sourcePixel.r;
                    pixels[idx + 1] = sourcePixel.g;
                    pixels[idx + 2] = sourcePixel.b;
                    pixels[idx + 3] = sourcePixel.a;
                }
            }
        }
    }

private:
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> commandQueue = nil;
    id<MTLComputePipelineState> pipeline = nil;
    id<MTLBuffer> outputBuffer = nil;
    id<MTLBuffer> accumulationBuffer = nil;

    uint32_t accumulatedSampleCount = 0;
    bool hasPreviousCamera = false;
    vec3 previousCameraPos = vec3(0.0f);
    vec3 previousCameraTarget = vec3(0.0f);
    float previousCameraFovY = 0.0f;
};

void raytrace(std::vector<unsigned char>& pixels, int W, int H)
{
    vec3 forward = normalize(camera.target - camera.pos);
    vec3 right = normalize(cross(forward, vec3(0.0f, 1.0f, 0.0f)));
    vec3 up = normalize(cross(right, forward));

    float aspect = static_cast<float>(W) / static_cast<float>(H);
    float tanHalfFov = std::tan(glm::radians(camera.fovY) * 0.5f);

    for(int y=0; y<H; y++)
    {
        for(int x=0; x<W; x++)
        {
            float u = (2.0f * (x + 0.5f) / static_cast<float>(W) - 1.0f) * aspect * tanHalfFov;
            float v = (1.0f - 2.0f * (y + 0.5f) / static_cast<float>(H)) * tanHalfFov;
            vec3 dir = normalize(u * right + v * up + forward);

            // Construct one 3D ray for this pixel.
            Ray ray(camera.pos, dir);

            const int MAX_STEPS = 10000;
            const double D_LAMBDA = 1e7;
            const double ESCAPE_R = 1e14;

            // For this final stage-7 validation, keep the ray straight and test whether it intersects the event-horizon sphere.
            // The full curved null-geodesic march belongs to stage 8.
            vec3 color(0.0f);
            
            for(int i=0; i<MAX_STEPS; ++i)
            {
                if(SagA.Intercept(ray.x, ray.y, ray.z))
                {
                    color = vec3(1.0f, 0.0f, 0.0f);
                    break;
                }

                ray.step(D_LAMBDA, SagA.r_s);

                if(ray.r > ESCAPE_R) break; // escaped to infinity -> remains black
            }

            /*
            double b = 2.0 * dot(camera.pos, dir);
            double c0 = dot(camera.pos, camera.pos) - SagA.r_s * SagA.r_s;
            double disc = b * b - 4.0 * c0;

            if(disc > 0.0)
            {
                color = vec3(1.0f, 0.0f, 0.0f);
            }
            */
            
            int idx = (y * W + x) * 4;
            pixels[idx + 0] = static_cast<unsigned char>(color.r * 255.0f);
            pixels[idx + 1] = static_cast<unsigned char>(color.g * 255.0f);
            pixels[idx + 2] = static_cast<unsigned char>(color.b * 255.0f);
            pixels[idx + 3] = 255;
        }
    }
}


int main()
{
    @autoreleasepool
    {
        setupCameraCallbacks(engine.window);

        // Keep one RGBA entry for every native Metal ray-tracing pixel.
        std::vector<unsigned char>pixels(METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT * 4, 0);
        MetalRayTracer metalRayTracer;

        /*
        // Fill half of the pixel buffer with red. The other half remains black because the vector was initialized with 0
        for(int i=0; i<METAL_RENDER_WIDTH * METAL_RENDER_HEIGHT / 2; i++)
        {
            pixels[i*4 + 0] = 255;
            pixels[i*4 + 1] = 0;
            pixels[i*4 + 2] = 0;
            pixels[i*4 + 3] = 255;
        }
        */
        
        int frameCount = 0;
        auto t0 = Clock::now();
        double lastPrintTime = std::chrono::duration<double>(t0.time_since_epoch()).count();

        while(!glfwWindowShouldClose(engine.window))
        {
            metalRayTracer.render(pixels, engine.WIDTH, engine.HEIGHT);
            // Upload the RGBA ray image and composite it over the perspective grid.
            engine.renderScene(pixels, SagA.r_s);
            
            frameCount++;
            auto now = Clock::now();
            double currentTime = std::chrono::duration<double>(now.time_since_epoch()).count();

            double elapsed = currentTime - lastPrintTime;

            if(elapsed >= 1.0)
            {
                double fps = static_cast<double>(frameCount) / elapsed;

                std::cout << "Metal FPS: " << fps << std::endl;

                frameCount = 0;
                lastPrintTime = currentTime;
            }
        }
    }

    return 0;
}
