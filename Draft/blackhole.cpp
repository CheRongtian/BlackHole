#include <GL/glew.h>
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <iostream>
#include <cmath>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <chrono>

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

struct Camera
{
    vec3 pos;
    vec3 target;
    float fovY;
    float azimuth, elevation, radius;
    float minRadius = 1e12f, maxRadius = 1e20f;
    bool dragging = false;
    bool panning = false;
    double lastX = 0, lastY = 0;

    // adjustable speeds
    float orbitSpeed = 0.008f;
    float panSpeed = 0.001f;
    float zoomSpeed = 1.08f;

    // Camera() : azimuth(0), elevation(M_PI / 2.0f), radius(6.34194e10f)
    Camera() : fovY(60.0f), azimuth(0), elevation(M_PI / 2.0f), radius(6.34194e10f)
    {
        target=vec3(0, 0, 0);
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

    // The 3D ray tracer will produce an RGB image instead of drawing the ray paths directly with OpenGL.
    // quadVAO / quadVBO: Store the full-screen quad used to display the image.
    // texture: Stores the RGB pixel buffer on the GPU.
    // shaderProgram: Draws the texture onto the full-screen quad.

    GLuint quadVAO = 0;
    GLuint quadVBO = 0;
    GLuint texture = 0;
    GLuint shaderProgram = 0;

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

        // GLEW must be initialized after an OpenGL context has been created.
        glewExperimental = GL_TRUE;

        if (glewInit() != GLEW_OK)
        {
            std::cerr << "Failed to initialize GLEW\n";
            glfwDestroyWindow(window);
            glfwTerminate();
            std::exit(EXIT_FAILURE);
        }
        
        // Create the rendering pipeline used to display the RGB pixel buffer.
        shaderProgram = createShaderProgram();

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

        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

        // Allocate texture memory now. Actual RGB values will be uploaded by renderScene()
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, WIDTH, HEIGHT, 0, GL_RGB, GL_UNSIGNED_BYTE, nullptr);
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

            void main()
            {
                FragColor = texture(screenTexture, TexCoord);
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
            glGetProgramInfoLog(vertexShader, 1024, nullptr, infoLog);
            std::cerr << "Shader program linking failed:\n" << infoLog << "\n";
        }

        glDeleteShader(vertexShader);
        glDeleteShader(fragmentShader);

        return program;
    }

    // Upload the CPU RGB pixel buffer into the OpenGL texture and display it using the full-screen quad
    void renderScene(const std::vector<unsigned char> &pixels)
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
        glClear(GL_COLOR_BUFFER_BIT);

        // Copy the current CPU pixel buffer into the texture.
        glBindTexture(GL_TEXTURE_2D, texture); 

        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, WIDTH, HEIGHT,GL_RGB, GL_UNSIGNED_BYTE, pixels.data());

        // Draw the texture across the entire window
        glUseProgram(shaderProgram);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, texture);

        GLint textureLocation = glGetUniformLocation(shaderProgram, "screenTexture");
        glUniform1i(textureLocation, 0);

        glBindVertexArray(quadVAO);
        glDrawArrays(GL_TRIANGLES, 0, 6);

        glBindVertexArray(0);

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

    BlackHole(vec3 pos, double m)
        : position(pos),
          mass(m)
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
        if(button == GLFW_MOUSE_BUTTON_MIDDLE)
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

                if(ray.r > ESCAPE_R)
                {
                    // escaped to infinity -> remains black
                    break;
                }
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
            

            int idx = (y * W + x) * 3;
            pixels[idx + 0] = static_cast<unsigned char>(color.r * 255.0f);
            pixels[idx + 1] = static_cast<unsigned char>(color.g * 255.0f);
            pixels[idx + 2] = static_cast<unsigned char>(color.b * 255.0f);
        }
    }
}

int main()
{
    setupCameraCallbacks(engine.window);
    // Create one RGB entry for every pixel in the window.
    // WIDTH * HEIGHT pixels, 3bytes for each pixel: R, G and B
    std::vector<unsigned char>pixels(engine.WIDTH * engine.HEIGHT * 3, 0);

    /*
    // Fill half of the pixel buffer with red. The other half remains black because the vector was initialized with 0
    for(int i=0; i<engine.WIDTH * engine.HEIGHT / 2; i++)
    {
        pixels[i*3 + 0] = 255;
        pixels[i*3 + 1] = 0;
        pixels[i*3 + 2] = 0;
    }
    */
    
    // This is the loop structure the 3D ray tracer will use later: every (x,y) pixel will eventually create and simulaye one ray
    for(int y=0; y<engine.HEIGHT; y++)
    {
        for(int x=0; x<engine.WIDTH; x++)
        {
            // No ray or colour calculation is added yet.
        }
    }
    
    int frameCount = 0;
    auto t0 = Clock::now();
    double lastPrintTime = std::chrono::duration<double>(t0.time_since_epoch()).count();

    while(!glfwWindowShouldClose(engine.window))
    {
        raytrace(pixels, engine.WIDTH, engine.HEIGHT);
        // Upload the RGB pixel array and display it on the full-screen quad.
        engine.renderScene(pixels);
        
        frameCount++;
        auto now = Clock::now();
        double currentTime = std::chrono::duration<double>(now.time_since_epoch()).count();

        double elapsed = currentTime - lastPrintTime;

        if(elapsed >= 1.0)
        {
            double fps = static_cast<double>(frameCount) / elapsed;

            std::cout << "FPS: " << fps << std::endl;

            frameCount = 0;
            lastPrintTime = currentTime;
        }
    }
    return 0;
}

/*
int main()
{
    for(float y = -engine.height; y< engine.height; y+= 1e10f)
    {
        // Create the first ray.
        rays.push_back(Ray(vec2(-engine.width, y),vec2(1.0f, 0.0f)));
    }
    
    while (!glfwWindowShouldClose(engine.window))
    {
        // Clear the frame and configure the 2D projection
        engine.run();
        // Draw the black hole
        SagA.draw();
        // Update every ray in the simulation.
        for (auto &ray : rays)
        {
            ray.draw();
            //ray.step(SagA.r_s, 1e-1);
            rk4Step(ray, 1e-1, SagA.r_s);
        }
        // Display the completed frame
        glfwSwapBuffers(engine.window);
        // Process window and input events
        glfwPollEvents();
    }
    return 0;
}
*/
