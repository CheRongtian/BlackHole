#include "Scene.hpp"

#include <GLFW/glfw3.h>

#include <glm/common.hpp>
#include <glm/geometric.hpp>

#include <cmath>

namespace
{
constexpr double GRAVITATIONAL_CONSTANT = 6.67430e-11;
constexpr double SPEED_OF_LIGHT = 299792458.0;
constexpr float PI = 3.14159265358979323846f;
}

Camera::Camera()
    : fovY(75.0f),
      azimuth(PI / 2.0f),
      elevation(PI / 3.0f),
      radius(4.5e11f)
{
    target = glm::vec3(8.0e10f, 0.0f, 0.0f);
    updateVectors();
}

void Camera::updateVectors()
{
    pos.x = target.x + radius * std::sin(elevation) * std::cos(azimuth);
    pos.y = target.y + radius * std::cos(elevation);
    pos.z = target.z + radius * std::sin(elevation) * std::sin(azimuth);
}

void Camera::processMouse(GLFWwindow* window, double xpos, double ypos)
{
    (void)window;

    float dx = static_cast<float>(xpos - lastX);
    float dy = static_cast<float>(ypos - lastY);

    if(dragging && !panning)
    {
        azimuth -= dx * orbitSpeed;
        elevation -= dy * orbitSpeed;
        elevation = glm::clamp(elevation, 0.01f, PI - 0.01f);
    }
    else if(panning)
    {
        glm::vec3 forward = glm::normalize(target - pos);
        glm::vec3 right = glm::normalize(glm::cross(forward, glm::vec3(0.0f, 1.0f, 0.0f)));
        glm::vec3 up = glm::normalize(glm::cross(right, forward));
        target += (-dx * right + dy * up) * radius * panSpeed;
    }

    lastX = xpos;
    lastY = ypos;
    updateVectors();
}

BlackHole::BlackHole(glm::vec3 pos, double m)
    : position(pos), mass(m)
{
    r_s = (2.0 * GRAVITATIONAL_CONSTANT * mass) /
          (SPEED_OF_LIGHT * SPEED_OF_LIGHT);
}

bool BlackHole::Intercept(double px, double py, double pz) const
{
    double dx = px - position.x;
    double dy = py - position.y;
    double dz = pz - position.z;
    double distanceSquared = dx * dx + dy * dy + dz * dz;
    return distanceSquared < r_s * r_s;
}

Camera camera;
BlackHole SagA(glm::vec3(0.0f), 8.54e36);

std::vector<Object> objects =
{
    {
        glm::vec4(4.0e11f, 0.0f, 0.0f, 4.0e10f),
        glm::vec4(1.0f, 1.0f, 0.0f, 1.0f),
        0.0f,
        {0.0f, 0.0f, 0.0f},
        glm::vec3(0.0f),
        0.0f
    }
};

void setupCameraCallbacks(GLFWwindow* window)
{
    glfwSetCursorPosCallback(window, [](GLFWwindow* callbackWindow, double xpos, double ypos)
    {
        camera.processMouse(callbackWindow, xpos, ypos);
    });

    glfwSetMouseButtonCallback(window, [](GLFWwindow* callbackWindow, int button, int action, int mods)
    {
        if(button != GLFW_MOUSE_BUTTON_LEFT) return;

        if(action == GLFW_PRESS)
        {
            camera.dragging = true;
            camera.panning = (mods & GLFW_MOD_SHIFT) != 0;
            glfwGetCursorPos(callbackWindow, &camera.lastX, &camera.lastY);
        }
        else if(action == GLFW_RELEASE)
        {
            camera.dragging = false;
            camera.panning = false;
        }
    });

    glfwSetScrollCallback(window, [](GLFWwindow* callbackWindow, double xoffset, double yoffset)
    {
        (void)callbackWindow;
        (void)xoffset;

        if(yoffset > 0.0)
            camera.radius /= camera.zoomSpeed;
        else if(yoffset < 0.0)
            camera.radius *= camera.zoomSpeed;

        camera.radius = glm::clamp(camera.radius, camera.minRadius, camera.maxRadius);
        camera.updateVectors();
    });
}
