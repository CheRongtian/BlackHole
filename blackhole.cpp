#include <GL/glew.h>
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <iostream>
#include <cmath>
#include <cstdlib>
#include <vector>
#include <algorithm>

#define _USE_MATH_DEFINES

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

using namespace glm;

// Gravitational constant
const double G = 6.67430e-11;
// Speed of light
const double c = 299792458.0;

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

    Engine()
    {
        // Initialize GLFW
        if (!glfwInit())
        {
            std::cerr << "Failed to initialize GLFW\n";
            std::exit(EXIT_FAILURE);
        }

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
        if (window) glfwDestroyWindow(window);
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
    vec2 position;
    double mass;
    // Schwarzschild radius
    double r_s;

    BlackHole(vec2 pos, double m)
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
BlackHole SagA(vec2(0.0f, 0.0f), 8.54e36);

/*
x, y -> current Cartesian position of the ray
dir -> direction in which the ray is travelling

At this stage the ray moves in a perfectly straight line.
Gravity has not been implemented yet.
*/

struct Ray
{
    // Store the current position and polar position.
    double x; double y;
    double r; double phi;
    // First derivatives with respect to the affine parameter
    double dr; double dphi;
    // Original Cartesian direction
    vec2 dir;
    // Store every previous position of the ray.
    std::vector<vec2> trail;
    // Initialize the ray from a starting position and a direction vector.
    Ray(vec2 pos, vec2 direction): x(pos.x), y(pos.y),dir(direction)
    {
        r = std::hypot(x, y);
        phi = glm::atan(y, x);

        // Convert the initial Cartesian direction into radial and angular rates.
        dr = c * (x * dir.x + y * dir.y) / r;
        dphi = c * (x * dir.y - y * dir.x) / (r * r);
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
    void step(double r_s, double dLambda)
    {
        if(r<r_s) return;
        double d2r = r * dphi * dphi - (c * c * r_s) / (2.0 * r * r);
        double d2phi = -2.0 * dr * dphi / r;
        
        dr += d2r * dLambda;
        dphi += d2phi * dLambda;

        r += dr * dLambda;
        phi += dphi * dLambda;

        x = std::cos(phi) * r;
        y = std::sin(phi) * r;
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
        trail.push_back(vec2(static_cast<float>(x), static_cast<float>(y)));
    }
};

// Store rays in a vector.
std::vector<Ray> rays;

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
            ray.step(SagA.r_s, 1e-1);
        }
        // Display the completed frame
        glfwSwapBuffers(engine.window);
        // Process window and input events
        glfwPollEvents();
    }
    return 0;
}