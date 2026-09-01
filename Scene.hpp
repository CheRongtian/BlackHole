#ifndef BLACK_HOLE_SCENE_HPP
#define BLACK_HOLE_SCENE_HPP

#include <glm/glm.hpp>

#include <cstdint>
#include <vector>

struct GLFWwindow;

inline constexpr int METAL_RENDER_WIDTH = 400;
inline constexpr int METAL_RENDER_HEIGHT = 300;
inline constexpr std::uint32_t TEMPORAL_SAMPLE_COUNT = 8;
inline constexpr std::uint32_t METAL_MAX_STEPS = 16000;
inline constexpr double METAL_D_LAMBDA_METERS = 5.0e7;
inline constexpr double METAL_ESCAPE_R_METERS = 8.0e11;
inline constexpr float METAL_DISK_R1_RS = 3.0f;
inline constexpr float METAL_DISK_R2_RS = 4.5f;

inline constexpr int GRID_HALF_CELLS = 32;
inline constexpr float GRID_STEP_RS = 1.5f;
inline constexpr float GRID_WELL_DEPTH_RS = 9.0f;
inline constexpr float GRID_WELL_RADIUS_RS = 10.0f;

struct Camera
{
    glm::vec3 pos;
    glm::vec3 target;
    float fovY;
    float azimuth;
    float elevation;
    float radius;

    float minRadius = 1.0e11f;
    float maxRadius = 1.2e12f;

    bool dragging = false;
    bool panning = false;
    double lastX = 0.0;
    double lastY = 0.0;

    float orbitSpeed = 0.008f;
    float panSpeed = 0.001f;
    float zoomSpeed = 1.08f;

    Camera();

    void updateVectors();
    void processMouse(GLFWwindow* window, double xpos, double ypos);
};

struct BlackHole
{
    glm::vec3 position;
    double mass;
    double r_s;

    BlackHole(glm::vec3 pos, double m);

    bool Intercept(double px, double py, double pz) const;
};

struct alignas(16) Object
{
    glm::vec4 posRadius;
    glm::vec4 color;
    float mass;
    float alignmentPadding[3];
    glm::vec3 velocity;
    float velocityPadding;
};

static_assert(sizeof(Object) == 64, "Object must match the Metal buffer layout");

extern Camera camera;
extern BlackHole SagA;
extern std::vector<Object> objects;

void setupCameraCallbacks(GLFWwindow* window);

#endif
