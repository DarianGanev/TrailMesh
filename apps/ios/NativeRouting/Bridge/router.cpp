#include "TrailMeshValhalla.h"
#include "include/main.h" // Private upstream headers are used only while building.
#include <cstdlib>
#include <cstring>
#include <string>
#ifdef __APPLE__
#include <dlfcn.h>
#include <mutex>
#include <stdexcept>
#include <date/tz.h>
#endif
namespace {
constexpr size_t max_response = 4 * 1024 * 1024;
void initialize_timezones() {
#ifdef __APPLE__
    static std::once_flag once;
    std::call_once(once, [] {
        Dl_info location{};
        if (!dladdr(reinterpret_cast<const void *>(&tm_router_create), &location) || !location.dli_fname)
            throw std::runtime_error("Native routing framework location unavailable");
        const std::string binary(location.dli_fname);
        const auto slash = binary.find_last_of('/');
        if (slash == std::string::npos) throw std::runtime_error("Native routing resource path unavailable");
        date::set_install(binary.substr(0, slash) + "/tzdata");
        (void)date::get_tzdb(); // Fail closed before creating an actor if resources are missing.
    });
#endif
}
}
extern "C" int tm_router_create(const char *config_path, void **actor) noexcept {
    if (!actor) return 1;
    *actor = nullptr;
    if (!config_path || !*config_path) return 1;
    try {
        initialize_timezones();
        // A null HTTP client disables tile fetching in the pinned mobile engine.
        *actor = create_valhalla_actor(config_path, nullptr);
        return *actor ? 0 : 2;
    } catch (...) { return 2; }
}
extern "C" int tm_router_route(void *actor, const char *request, uint8_t **bytes, size_t *length) noexcept {
    if (bytes) *bytes = nullptr;
    if (length) *length = 0;
    if (!actor || !request || !bytes || !length) return 1;
    try {
        const std::string response = route(request, actor);
        if (response.empty() || response.size() > max_response) return 3;
        auto *copy = static_cast<uint8_t *>(std::malloc(response.size()));
        if (!copy) return 4;
        std::memcpy(copy, response.data(), response.size());
        *bytes = copy; *length = response.size();
        return 0;
    } catch (...) { return 2; }
}
extern "C" int tm_router_destroy(void *actor) noexcept {
    try { if (actor) delete_valhalla_actor(actor); return 0; }
    catch (...) { return 2; }
}
extern "C" void tm_router_free(uint8_t *bytes) noexcept { std::free(bytes); }
