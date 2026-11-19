#ifndef TRAILMESH_VALHALLA_H
#define TRAILMESH_VALHALLA_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
#define TM_NOEXCEPT noexcept
extern "C" {
#else
#define TM_NOEXCEPT
#endif
// Opaque, caller-serialized actor. 0 succeeds; nonzero is a bounded failure.
// No actor, C++ type, exception or engine-owned allocation crosses this API.
__attribute__((visibility("default"))) int tm_router_create(const char *config_path, void **actor) TM_NOEXCEPT;
__attribute__((visibility("default"))) int tm_router_route(void *actor, const char *request, uint8_t **bytes, size_t *length) TM_NOEXCEPT;
__attribute__((visibility("default"))) int tm_router_destroy(void *actor) TM_NOEXCEPT;
__attribute__((visibility("default"))) void tm_router_free(uint8_t *bytes) TM_NOEXCEPT;
#ifdef __cplusplus
}
#endif
#undef TM_NOEXCEPT
#endif
