/*
 * VulkanPresenter wrapper for libretro - isolates Vulkan headers from libretro.cpp
 */

#include "xenia/ui/vulkan/vulkan_presenter.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if XE_PLATFORM_MAC
#include <dlfcn.h>
#endif

#include "xenia/base/logging.h"
#include "xenia/ui/vulkan/vulkan_device.h"
#include "xenia/ui/vulkan/vulkan_instance.h"
#include "xenia/ui/vulkan/vulkan_provider.h"

#include "libretro_vk_presenter.h"

bool libretro_vk_capture_gpu_blit(xe::ui::Presenter* presenter,
                                   const void*& data_out,
                                   uint32_t& width_out,
                                   uint32_t& height_out) {
    if (!presenter) return false;
    auto* vk_presenter =
        dynamic_cast<xe::ui::vulkan::VulkanPresenter*>(presenter);
    if (!vk_presenter) return false;
    return vk_presenter->CaptureGuestOutputGPUBlit(data_out, width_out,
                                                    height_out);
}

// ---- The device shared with RetroArch ------------------------------------

using xe::ui::vulkan::VulkanDevice;
using xe::ui::vulkan::VulkanInstance;
using xe::ui::vulkan::VulkanProvider;

// Kept for as long as RetroArch keeps the device - across game loads, as it
// caches its context - not for one emulator's lifetime.
static std::unique_ptr<VulkanInstance> s_shared_instance;
static std::unique_ptr<VulkanDevice> s_shared_device;
static bool s_wait_for_blit_completion = false;

static const char* s_driver_notice = nullptr;
static std::string s_driver_status;

VkInstance libretro_vk_create_instance(
    PFN_vkGetInstanceProcAddr get_instance_proc_addr,
    const VkApplicationInfo* app,
    VkInstance (*create_instance_wrapper)(void*, const VkInstanceCreateInfo*),
    void* opaque) {
    VkInstanceCreateInfo info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    info.pApplicationInfo = app;
    s_driver_notice = nullptr;
    s_driver_status.clear();
#if XE_PLATFORM_MAC
    // Resolve from the provider selected by the frontend. Looking in the
    // process-wide namespace could find the core's statically linked copy.
    auto query_config = get_instance_proc_addr(
        VK_NULL_HANDLE, "vkGetMoltenVKConfigurationMVK");
    if (query_config) {
        uint32_t patch_version = 0;
        Dl_info provider = {};
        if (dladdr(reinterpret_cast<void*>(query_config), &provider) &&
            provider.dli_fname) {
            if (void* library = dlopen(provider.dli_fname,
                                      RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD)) {
                using PatchVersion = uint32_t (*)();
                auto version = reinterpret_cast<PatchVersion>(dlsym(
                    library, "xeniaMoltenVKDrawableOwnershipPatchVersion"));
                Dl_info marker_provider = {};
                if (version && dladdr(reinterpret_cast<void*>(version),
                                      &marker_provider) &&
                    marker_provider.dli_fbase == provider.dli_fbase) {
                    patch_version = version();
                }
                dlclose(library);
            }
        }
        auto enumerate = reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
            get_instance_proc_addr(VK_NULL_HANDLE,
                                  "vkEnumerateInstanceExtensionProperties"));
        uint32_t count = 0;
        std::vector<VkExtensionProperties> extensions;
        bool layer_settings = false;
        if (enumerate && enumerate(nullptr, &count, nullptr) == VK_SUCCESS) {
            extensions.resize(count);
            if (enumerate(nullptr, &count, extensions.data()) == VK_SUCCESS) {
                for (uint32_t i = 0; i < count; ++i) {
                    if (!strcmp(extensions[i].extensionName,
                                VK_EXT_LAYER_SETTINGS_EXTENSION_NAME)) {
                        layer_settings = true;
                        break;
                    }
                }
            }
        }
        if (layer_settings) {
            // Keep the core's CPU-completed handoff in either mode. The
            // driver fix makes asynchronous presentation safe on the tested
            // shared submission queue; it does not remove that handoff guard.
            VkBool32 synchronous = patch_version == 1 ? VK_FALSE : VK_TRUE;
            VkLayerSettingEXT setting = {
                "MoltenVK", "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS",
                VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &synchronous};
            VkLayerSettingsCreateInfoEXT settings = {
                VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT,
                nullptr, 1, &setting};
            const char* extension = VK_EXT_LAYER_SETTINGS_EXTENSION_NAME;
            info.pNext = &settings;
            info.enabledExtensionCount = 1;
            info.ppEnabledExtensionNames = &extension;
            if (synchronous) {
                s_driver_notice = "MoltenVK patch not detected: compatibility mode enabled (reduced performance).";
            }
            s_driver_status = "MoltenVK: drawable ownership patch " +
                std::to_string(patch_version) + ", " +
                (synchronous ? "synchronous compatibility" : "asynchronous") +
                " host submission selected per instance; provider " +
                (provider.dli_fname ? provider.dli_fname : "unknown");
            XELOGI("MoltenVK: drawable ownership patch {}, {} host submission "
                   "selected per instance; provider {}",
                   patch_version, synchronous ? "synchronous compatibility"
                                              : "asynchronous",
                   provider.dli_fname ? provider.dli_fname : "unknown");
            return create_instance_wrapper(opaque, &info);
        }
        s_driver_notice = "MoltenVK: automatic compatibility selection unavailable; using driver defaults.";
        XELOGW("MoltenVK: VK_EXT_layer_settings unavailable; retaining driver defaults");
    }
#endif
    return create_instance_wrapper(opaque, &info);
}

const char* libretro_vk_driver_notice() { return s_driver_notice; }
const char* libretro_vk_driver_status() {
    return s_driver_status.empty() ? nullptr : s_driver_status.c_str();
}

bool libretro_vk_create_shared_device(
    VkInstance instance, VkPhysicalDevice gpu, VkSurfaceKHR surface,
    PFN_vkGetInstanceProcAddr get_instance_proc_addr,
    const char** required_extensions, unsigned required_extension_count,
    const VkPhysicalDeviceFeatures* required_features,
    VkPhysicalDevice& gpu_out, VkDevice& device_out, VkQueue& queue_out,
    uint32_t& queue_family_out) {
    libretro_vk_destroy_shared_device();

    // The instance's version: the one asked for in the application info,
    // capped at what the loader has
    uint32_t api_version = VK_MAKE_API_VERSION(0, 1, 0, 0);
    if (auto enumerate_version = PFN_vkEnumerateInstanceVersion(
            get_instance_proc_addr(nullptr, "vkEnumerateInstanceVersion"))) {
        enumerate_version(&api_version);
    }
    api_version = std::min(api_version,
                           VulkanDevice::kHighestUsedApiMinorVersion);

    s_shared_instance = VulkanInstance::CreateExternal(
        instance, get_instance_proc_addr, api_version);
    if (!s_shared_instance) return false;

    std::vector<VkPhysicalDevice> gpus;
    if (gpu != VK_NULL_HANDLE) {
        gpus.push_back(gpu);
    } else {
        s_shared_instance->EnumeratePhysicalDevices(gpus);
    }

    VulkanDevice::FrontendRequest request;
    request.extensions = required_extensions;
    request.extension_count = required_extension_count;
    request.features = required_features;
    auto get_surface_support = PFN_vkGetPhysicalDeviceSurfaceSupportKHR(
        get_instance_proc_addr(instance,
                               "vkGetPhysicalDeviceSurfaceSupportKHR"));
    for (VkPhysicalDevice candidate : gpus) {
        std::unique_ptr<VulkanDevice> device = VulkanDevice::CreateIfSupported(
            s_shared_instance.get(), candidate, true, false, &request);
        if (!device) continue;
        const uint32_t family = device->queue_family_graphics_compute();
        // RetroArch presents from the queue it gets
        VkBool32 present = VK_TRUE;
        if (surface != VK_NULL_HANDLE && get_surface_support) {
            get_surface_support(candidate, family, surface, &present);
        }
        if (!present) {
            XELOGW("Vulkan: the graphics queue cannot present to RetroArch's "
                   "surface, RetroArch makes its own device");
            continue;
        }
        VkQueue queue = VK_NULL_HANDLE;
        device->functions().vkGetDeviceQueue(
            device->device(), family, device->frontend_queue_index(), &queue);
        gpu_out = candidate;
        device_out = device->device();
        queue_out = queue;
        queue_family_out = family;
        XELOGI("Vulkan: device shared with RetroArch, RetroArch on queue {} "
               "of family {}{}",
               device->frontend_queue_index(), family,
               device->frontend_queue_index() == 0 ? " (shared with Xenia)"
                                                   : "");
        s_wait_for_blit_completion = false;
#if XE_PLATFORM_MAC
        // On a shared queue, host-synchronous presentation starves guest
        // submissions without this wait. Host-asynchronous submission is not
        // sufficient to make handoff safe either: MoltenVK 1.4.2 reproduced a
        // use-after-free of CAMetalDrawable in its presentation callback.
        // Retain CPU completion in both driver modes, including with the
        // drawable fix. Submission policy is selected per instance above.
        s_wait_for_blit_completion = device->frontend_queue_index() == 0;
#endif
        XELOGI("Vulkan: frontend image handoff uses {} blits",
               s_wait_for_blit_completion ? "CPU-completed" : "asynchronous");
        s_shared_device = std::move(device);
        VulkanProvider::SetExternal(s_shared_instance.get(),
                                    s_shared_device.get());
        return true;
    }
    s_shared_instance.reset();
    return false;
}

void libretro_vk_destroy_shared_device() {
    VulkanProvider::SetExternal(nullptr, nullptr);
    // Neither destroys its Vulkan object: RetroArch does
    s_shared_device.reset();
    s_shared_instance.reset();
    s_wait_for_blit_completion = false;
}

bool libretro_vk_shared_device_active() { return s_shared_device != nullptr; }

void libretro_vk_set_shared_queue_lock(void (*lock)(void* user),
                                       void (*unlock)(void* user),
                                       void* user) {
    if (!s_shared_device || s_shared_device->frontend_queue_index() != 0)
        return;
    auto& queue = *s_shared_device->queue_families()
                       [s_shared_device->queue_family_graphics_compute()]
                           .queues[0];
    std::lock_guard<std::recursive_mutex> guard(queue.mutex);
    queue.external_lock = lock;
    queue.external_unlock = unlock;
    queue.external_lock_user = user;
}

bool libretro_vk_blit_guest_output(
    xe::ui::Presenter* presenter, uint32_t sync_index,
    const std::function<VkImage(uint32_t width, uint32_t height,
                                VkSemaphore& ready_semaphore)>& target_for,
    uint32_t& width_out, uint32_t& height_out) {
    auto* vk_presenter =
        dynamic_cast<xe::ui::vulkan::VulkanPresenter*>(presenter);
    return vk_presenter &&
           vk_presenter->BlitGuestOutputToImage(sync_index,
                                                s_wait_for_blit_completion,
                                                target_for, width_out,
                                                height_out);
}
