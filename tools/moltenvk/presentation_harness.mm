// Bounded native Vulkan checks for the local MoltenVK drawable candidate.
// Runs independently of RetroArch: queue-idle calls here own their queues.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <mach/mach.h>

#define FUNCTIONS(X) \
 X(vkCreateInstance) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) \
 X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) X(vkGetPhysicalDeviceFeatures2) \
 X(vkEnumerateDeviceExtensionProperties) X(vkGetPhysicalDeviceSurfaceSupportKHR) \
 X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) X(vkGetPhysicalDeviceSurfaceFormatsKHR) \
 X(vkCreateMetalSurfaceEXT) X(vkDestroySurfaceKHR) X(vkCreateDevice) X(vkDestroyDevice) \
 X(vkGetDeviceQueue) X(vkCreateSwapchainKHR) X(vkDestroySwapchainKHR) \
 X(vkGetSwapchainImagesKHR) X(vkAcquireNextImageKHR) X(vkQueuePresentKHR) \
 X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) \
 X(vkResetCommandBuffer) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
 X(vkCmdPipelineBarrier) X(vkCmdClearColorImage) X(vkCmdCopyImageToBuffer) \
 X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences) \
 X(vkCreateSemaphore) X(vkDestroySemaphore) X(vkSignalSemaphore) X(vkQueueSubmit) X(vkQueueWaitIdle) \
 X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) \
 X(vkAllocateMemory) X(vkFreeMemory) X(vkBindBufferMemory) X(vkMapMemory) X(vkUnmapMemory)
#define DECLARE(name) static PFN_##name name;
FUNCTIONS(DECLARE)
static PFN_vkReleaseSwapchainImagesEXT release_images;
static PFN_vkQueueSubmit2 queue_submit2;
static bool use_submit2 = false;
static bool trace_enabled = false;
static unsigned current_cycle = 0, current_frame = 0;
static NSWindow* hidden_window = nil;
static std::chrono::steady_clock::time_point restore_at;
static unsigned hide_count = 0, restore_count = 0, hidden_presents = 0;
static double max_restore_delay_ms = 0;
static std::atomic<unsigned> validation_errors{0}, validation_warnings{0};
static bool validation_enabled = false;
static VKAPI_ATTR VkBool32 VKAPI_CALL validation_message(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity, VkDebugUtilsMessageTypeFlagsEXT,
    const VkDebugUtilsMessengerCallbackDataEXT* data, void*) {
    if(severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) validation_errors++;
    if(severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) validation_warnings++;
    std::cerr << "VULKAN_VALIDATION " << data->pMessage << std::endl;
    return VK_FALSE;
}
static void trace(const char* stage, uint32_t image = UINT32_MAX) {
    if (trace_enabled) std::cerr << "TRACE cycle=" << current_cycle
        << " frame=" << current_frame << " image=" << image << " " << stage << std::endl;
}

static void check(VkResult result, const char* operation) {
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR)
        throw std::runtime_error(std::string(operation) + ": " + std::to_string(result));
}
#define CHECK(call) check(call, #call)
// Route the same workload through either submission API. Keep image commands
// and synchronization intent identical so this checks the API 2 metadata path.
static VkResult submit_queue(VkQueue queue, const VkSubmitInfo& legacy, VkFence fence) {
    if (!use_submit2) return vkQueueSubmit(queue, 1, &legacy, fence);
    const VkTimelineSemaphoreSubmitInfo* timeline = nullptr;
    for (auto* next = static_cast<const VkBaseInStructure*>(legacy.pNext); next; next=next->pNext)
        if (next->sType == VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO)
            timeline = reinterpret_cast<const VkTimelineSemaphoreSubmitInfo*>(next);
    std::vector<VkSemaphoreSubmitInfo> waits, signals;
    std::vector<VkCommandBufferSubmitInfo> commands;
    for (uint32_t i=0; i<legacy.waitSemaphoreCount; ++i) {
        VkSemaphoreSubmitInfo info={VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
        info.semaphore=legacy.pWaitSemaphores[i];
        info.value=timeline?timeline->pWaitSemaphoreValues[i]:0;
        info.stageMask=legacy.pWaitDstStageMask[i];
        waits.push_back(info);
    }
    for (uint32_t i=0; i<legacy.signalSemaphoreCount; ++i) {
        VkSemaphoreSubmitInfo info={VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
        info.semaphore=legacy.pSignalSemaphores[i];
        info.value=timeline?timeline->pSignalSemaphoreValues[i]:0;
        info.stageMask=VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
        signals.push_back(info);
    }
    for (uint32_t i=0; i<legacy.commandBufferCount; ++i) {
        VkCommandBufferSubmitInfo info={VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO};
        info.commandBuffer=legacy.pCommandBuffers[i];info.deviceMask=1;commands.push_back(info);
    }
    VkSubmitInfo2 submit={VK_STRUCTURE_TYPE_SUBMIT_INFO_2};
    submit.waitSemaphoreInfoCount=static_cast<uint32_t>(waits.size());submit.pWaitSemaphoreInfos=waits.data();
    submit.commandBufferInfoCount=static_cast<uint32_t>(commands.size());submit.pCommandBufferInfos=commands.data();
    submit.signalSemaphoreInfoCount=static_cast<uint32_t>(signals.size());submit.pSignalSemaphoreInfos=signals.data();
    return queue_submit2(queue,1,&submit,fence);
}

static void pump() {
    @autoreleasepool {
        // Restore by wall time, including while a Vulkan fence is pending.
        // A frame-count trigger would deadlock the test if hidden presentation
        // stops acquisition from making progress.
        if (hidden_window && std::chrono::steady_clock::now() >= restore_at) {
            max_restore_delay_ms = std::max(max_restore_delay_ms,
                std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - restore_at).count());
            [hidden_window orderFront:nil];
            if (![hidden_window isVisible]) throw std::runtime_error("Window restore failed");
            hidden_window = nil;
            restore_count++;
            trace("window-restored");
        }
        for (NSEvent* event; (event = [NSApp nextEventMatchingMask:NSEventMaskAny
             untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES]);)
            [NSApp sendEvent:event];
        [NSApp updateWindows];
    }
}
static void wait_fence(VkDevice device, VkFence fence, const char* stage, uint32_t image) {
    trace(stage, image);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    VkResult result;
    do {
        result = vkWaitForFences(device, 1, &fence, VK_TRUE, 10000000);
        pump();
    } while (result == VK_TIMEOUT && std::chrono::steady_clock::now() < deadline);
    check(result, stage);
    trace("fence-complete", image);
}

int main(int argc, char** argv) {
 @autoreleasepool {
  try {
    if (argc < 4) throw std::runtime_error("Usage: harness driver one|multi sync|async [--trace] [--wait-render] [--present-only] [--fresh-semaphores] [--hide-restore] [--frames-per-cycle=N] [--cycles=N] [--acquire-semaphore] [--gpu-acquire-only] [--render-chain] [--timeline-chain] [--timeline-forward] [--timeline-host-gate] [--submit2] [--producer-barriers=N] [--retire-without-idle] [--validation] [--progress]");
    if (strcmp(argv[2], "one") && strcmp(argv[2], "multi")) throw std::runtime_error("Invalid queue mode");
    if (strcmp(argv[3], "sync") && strcmp(argv[3], "async")) throw std::runtime_error("Invalid submission mode");
    bool wait_render = false, present_only = false, fresh_semaphores = false, hide_restore = false;
    unsigned frames_per_cycle = 60, cycles = 4;
    bool acquire_semaphore = false, progress = false, retire_without_idle = false;
    bool gpu_acquire_only = false, render_chain = false, validation = false, timeline_chain = false;
    bool timeline_forward = false;
    bool timeline_host_gate = false;
    unsigned producer_barriers = 0;
    for (int arg = 4; arg < argc; ++arg) {
        if (!strcmp(argv[arg], "--trace")) trace_enabled = true;
        else if (!strcmp(argv[arg], "--wait-render")) wait_render = true;
        else if (!strcmp(argv[arg], "--present-only")) present_only = true;
        else if (!strcmp(argv[arg], "--fresh-semaphores")) fresh_semaphores = true;
        else if (!strcmp(argv[arg], "--hide-restore")) hide_restore = true;
        else if (!strcmp(argv[arg], "--acquire-semaphore")) acquire_semaphore = true;
        else if (!strcmp(argv[arg], "--progress")) progress = true;
        else if (!strcmp(argv[arg], "--retire-without-idle")) retire_without_idle = true;
        else if (!strcmp(argv[arg], "--gpu-acquire-only")) gpu_acquire_only = true;
        else if (!strcmp(argv[arg], "--render-chain")) render_chain = true;
        else if (!strcmp(argv[arg], "--validation")) validation = true;
        else if (!strcmp(argv[arg], "--submit2")) use_submit2 = true;
        else if (!strcmp(argv[arg], "--timeline-chain")) timeline_chain = true;
        else if (!strcmp(argv[arg], "--timeline-forward")) timeline_forward = true;
        else if (!strcmp(argv[arg], "--timeline-host-gate")) timeline_host_gate = true;
        else if (!strncmp(argv[arg], "--producer-barriers=", 20)) {
            std::string value=argv[arg]+20;size_t consumed=0;
            auto parsed=std::stoul(value,&consumed);
            if(consumed!=value.size() || parsed>100000) throw std::runtime_error("Invalid producer barrier count");
            producer_barriers=static_cast<unsigned>(parsed);
        }
        else if (!strncmp(argv[arg], "--cycles=", 9)) {
            std::string value=argv[arg]+9;size_t consumed=0;
            auto parsed=std::stoul(value,&consumed);
            if(consumed!=value.size() || parsed<1 || parsed>1000) throw std::runtime_error("Invalid cycle count");
            cycles=static_cast<unsigned>(parsed);
        }
        else if (!strncmp(argv[arg], "--frames-per-cycle=", 19)) {
            std::string value=argv[arg]+19;size_t consumed=0;
            unsigned long parsed=std::stoul(value,&consumed);
            if(consumed!=value.size() || parsed<1 || parsed>3600)
                throw std::runtime_error("Frames per cycle must be between 1 and 3600");
            frames_per_cycle=static_cast<unsigned>(parsed);
        }
        else throw std::runtime_error("Unknown argument: " + std::string(argv[arg]));
    }
    if(hide_restore && frames_per_cycle<=20)
        throw std::runtime_error("Hide/restore requires at least 21 frames per cycle");
    if(acquire_semaphore && !present_only)
        throw std::runtime_error("Acquire semaphore diagnostic requires --present-only");
    if(gpu_acquire_only && !acquire_semaphore)
        throw std::runtime_error("GPU-only acquisition requires --acquire-semaphore");
    if(render_chain && (strcmp(argv[2], "multi") || !present_only))
        throw std::runtime_error("Render chain requires multi and --present-only");
    if(producer_barriers && !render_chain)
        throw std::runtime_error("Producer barriers require --render-chain");
    if(timeline_chain && !render_chain)
        throw std::runtime_error("Timeline chain requires --render-chain");
    if(timeline_forward && !timeline_chain)
        throw std::runtime_error("Forward timeline requires --timeline-chain");
    if(timeline_host_gate && !timeline_chain)
        throw std::runtime_error("Host timeline gate requires --timeline-chain");
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) throw std::runtime_error(dlerror());
    using LifetimeCounters = void (*)(uint64_t*);
    auto lifetime = reinterpret_cast<LifetimeCounters>(
        dlsym(library, "xeniaMoltenVKDrawableLifetimeCounters"));
    auto encoding_lifetime = reinterpret_cast<LifetimeCounters>(
        dlsym(library, "xeniaMoltenVKEncodingCounters"));
    auto get_proc = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(library, "vkGetInstanceProcAddr"));
    if (!get_proc) throw std::runtime_error("Missing vkGetInstanceProcAddr");
    vkCreateInstance = reinterpret_cast<PFN_vkCreateInstance>(get_proc(VK_NULL_HANDLE,"vkCreateInstance"));
    if (!vkCreateInstance) throw std::runtime_error("Missing vkCreateInstance");
#define LOAD(name) name = reinterpret_cast<PFN_##name>(get_proc( \
    !strcmp(#name,"vkCreateInstance") ? VK_NULL_HANDLE : instance, #name)); \
    if (!name) throw std::runtime_error("Missing " #name);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80,80,320,180)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    std::cout << "METAL_DEVICE_CLASS " << NSStringFromClass([layer.device class]).UTF8String << std::endl;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.drawableSize = CGSizeMake(320,180);
    window.contentView.wantsLayer = YES;
    window.contentView.layer = layer;
    [window setTitle:@"MoltenVK Presentation Harness"];
    [window orderFront:nil]; pump();

    VkBool32 sync = !strcmp(argv[3], "sync");
    VkBool32 validate_sync=VK_TRUE;
    VkLayerSettingEXT setting[] = {
        {"MoltenVK", "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &sync},
        {"VK_LAYER_KHRONOS_validation", "validate_sync", VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &validate_sync}};
    VkLayerSettingsCreateInfoEXT settings = {
        VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT, nullptr, validation?2u:1u, setting};
    std::vector<const char*> instance_extensions = {"VK_KHR_surface", "VK_EXT_metal_surface", "VK_EXT_layer_settings",
        "VK_KHR_get_surface_capabilities2", "VK_EXT_surface_maintenance1"};
    const char* validation_layer="VK_LAYER_KHRONOS_validation";
    VkDebugUtilsMessengerCreateInfoEXT debug_info={VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT};
    debug_info.messageSeverity=VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
    debug_info.messageType=VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    debug_info.pfnUserCallback=validation_message;
    if(validation) {
        instance_extensions.push_back("VK_EXT_debug_utils");
        instance_extensions.push_back("VK_KHR_portability_enumeration");
        settings.pNext=&debug_info;
    }
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "Drawable Ownership Checks"; app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo ci = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ci.pNext=&settings; ci.pApplicationInfo=&app; ci.enabledExtensionCount=static_cast<uint32_t>(instance_extensions.size());
    ci.ppEnabledExtensionNames=instance_extensions.data();
    if(validation) {
        ci.flags=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        ci.enabledLayerCount=1;ci.ppEnabledLayerNames=&validation_layer;
    }
    VkInstance instance; CHECK(vkCreateInstance(&ci,nullptr,&instance));
    FUNCTIONS(LOAD)
    if(use_submit2) {
        queue_submit2=reinterpret_cast<PFN_vkQueueSubmit2>(get_proc(instance,"vkQueueSubmit2"));
        if(!queue_submit2) throw std::runtime_error("QueueSubmit2 unavailable");
    }
    release_images = reinterpret_cast<PFN_vkReleaseSwapchainImagesEXT>(get_proc(instance,"vkReleaseSwapchainImagesEXT"));
    VkDebugUtilsMessengerEXT messenger=VK_NULL_HANDLE;
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_messenger=nullptr;
    if(validation) {
        auto create_messenger=reinterpret_cast<PFN_vkCreateDebugUtilsMessengerEXT>(get_proc(instance,"vkCreateDebugUtilsMessengerEXT"));
        destroy_messenger=reinterpret_cast<PFN_vkDestroyDebugUtilsMessengerEXT>(get_proc(instance,"vkDestroyDebugUtilsMessengerEXT"));
        if(!create_messenger || !destroy_messenger) throw std::runtime_error("Validation debug messenger unavailable");
        debug_info.pNext=nullptr;
        CHECK(create_messenger(instance,&debug_info,nullptr,&messenger));
        validation_enabled=true;
        std::cout<<"VULKAN_VALIDATION_ENABLED "<<validation_layer<<std::endl;
    }
    VkMetalSurfaceCreateInfoEXT sci = {VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
    sci.pLayer=layer; VkSurfaceKHR surface; CHECK(vkCreateMetalSurfaceEXT(instance,&sci,nullptr,&surface));
    uint32_t count=1; VkPhysicalDevice gpu;
    CHECK(vkEnumeratePhysicalDevices(instance,&count,&gpu));
    vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,nullptr);
    std::vector<VkQueueFamilyProperties> families(count);
    vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,families.data());
    std::vector<uint32_t> graphics;
    for(uint32_t i=0;i<count;i++) {
        VkBool32 present=0; CHECK(vkGetPhysicalDeviceSurfaceSupportKHR(gpu,i,surface,&present));
        if (present && (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) graphics.push_back(i);
    }
    if(graphics.empty()) throw std::runtime_error("No presentable graphics queue");
    bool multi=!strcmp(argv[2],"multi");
    if(multi && graphics.size()<2) throw std::runtime_error("Second graphics family unavailable");
    uint32_t render_family=graphics[0], present_family=multi?graphics[1]:graphics[0];
    float priority=1;
    std::vector<VkDeviceQueueCreateInfo> queues;
    for(uint32_t family: {render_family,present_family}) {
        if (!queues.empty() && family==render_family) continue;
        VkDeviceQueueCreateInfo qi={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        qi.queueFamilyIndex=family; qi.queueCount=1; qi.pQueuePriorities=&priority; queues.push_back(qi);
    }
    CHECK(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,nullptr));
    std::vector<VkExtensionProperties> extensions(count);
    CHECK(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,extensions.data()));
    bool maintenance=false, portability=false;
    for(auto& ext: extensions) {
        if(!strcmp(ext.extensionName,"VK_EXT_swapchain_maintenance1")) maintenance=true;
        if(!strcmp(ext.extensionName,"VK_KHR_portability_subset")) portability=true;
    }
    std::vector<const char*> device_extensions={"VK_KHR_swapchain","VK_EXT_swapchain_maintenance1"};
    // Required whenever the physical device advertises the portability subset.
    if(portability) device_extensions.push_back("VK_KHR_portability_subset");
    VkPhysicalDeviceSwapchainMaintenance1FeaturesEXT mf={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT};
    VkPhysicalDeviceTimelineSemaphoreFeatures tf={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
    VkPhysicalDeviceSynchronization2Features sf={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES};
    if(timeline_chain) mf.pNext=&tf;
    if(use_submit2) { if(timeline_chain) tf.pNext=&sf; else mf.pNext=&sf; }
    VkPhysicalDeviceFeatures2 features={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
    if (maintenance) {
        features.pNext=&mf;vkGetPhysicalDeviceFeatures2(gpu,&features);
        maintenance=mf.swapchainMaintenance1;
    }
    if (!maintenance || !release_images) throw std::runtime_error("Swapchain maintenance1 is required for release and presentation-fence checks");
    if(timeline_chain && !tf.timelineSemaphore) throw std::runtime_error("Timeline semaphore feature unavailable");
    if(use_submit2 && !sf.synchronization2) throw std::runtime_error("Synchronization2 feature unavailable");
    VkDeviceCreateInfo di={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    di.pNext=maintenance?&mf:nullptr; di.queueCreateInfoCount=uint32_t(queues.size());di.pQueueCreateInfos=queues.data();
    di.enabledExtensionCount=uint32_t(device_extensions.size());di.ppEnabledExtensionNames=device_extensions.data();
    VkDevice device; CHECK(vkCreateDevice(gpu,&di,nullptr,&device));
    VkQueue render,present;vkGetDeviceQueue(device,render_family,0,&render);vkGetDeviceQueue(device,present_family,0,&present);
    VkCommandPoolCreateInfo pi={VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pi.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;pi.queueFamilyIndex=render_family;
    VkCommandPool pool;CHECK(vkCreateCommandPool(device,&pi,nullptr,&pool));
    VkCommandPool consumer_pool=VK_NULL_HANDLE;
    if(render_chain) {
        pi.queueFamilyIndex=present_family;
        CHECK(vkCreateCommandPool(device,&pi,nullptr,&consumer_pool));
    }
    VkBufferCreateInfo bi={VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bi.size=64;bi.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer buffer;CHECK(vkCreateBuffer(device,&bi,nullptr,&buffer));
    VkMemoryRequirements mr;vkGetBufferMemoryRequirements(device,buffer,&mr);
    VkPhysicalDeviceMemoryProperties mp;vkGetPhysicalDeviceMemoryProperties(gpu,&mp);
    uint32_t type=UINT32_MAX;
    for(uint32_t i=0;i<mp.memoryTypeCount;i++) if((mr.memoryTypeBits&(1u<<i)) &&
        (mp.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==
         (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {type=i;break;}
    if(type==UINT32_MAX) throw std::runtime_error("No coherent host memory");
    VkMemoryAllocateInfo ai={VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.allocationSize=mr.size;ai.memoryTypeIndex=type;
    VkDeviceMemory memory;CHECK(vkAllocateMemory(device,&ai,nullptr,&memory));CHECK(vkBindBufferMemory(device,buffer,memory,0));
    void* mapped;CHECK(vkMapMemory(device,memory,0,mr.size,0,&mapped));
    VkFenceCreateInfo fi={VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};VkFence acquired;
    CHECK(vkCreateFence(device,&fi,nullptr,&acquired));
    unsigned frames=0,readbacks=0,released=0,preservation_checks=0,preservation_failures=0;
    for(unsigned cycle=0;cycle<cycles;cycle++) {
        current_cycle=cycle;current_frame=0;
        pump();
        VkSurfaceCapabilitiesKHR caps;CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu,surface,&caps));
        CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu,surface,&count,nullptr));
        std::vector<VkSurfaceFormatKHR> formats(count);CHECK(vkGetPhysicalDeviceSurfaceFormatsKHR(gpu,surface,&count,formats.data()));
        VkSurfaceFormatKHR format=formats[0];
        for(auto f:formats) if(f.format==VK_FORMAT_B8G8R8A8_UNORM) {format=f;break;}
        if(format.format!=VK_FORMAT_B8G8R8A8_UNORM) throw std::runtime_error("BGRA8 unavailable");
        VkSwapchainCreateInfoKHR sw={VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
        sw.surface=surface;sw.minImageCount=std::max(3u,caps.minImageCount);
        if(caps.maxImageCount) sw.minImageCount=std::min(sw.minImageCount,caps.maxImageCount);
        sw.imageFormat=format.format;sw.imageColorSpace=format.colorSpace;sw.imageExtent=caps.currentExtent;
        if(sw.imageExtent.width==UINT32_MAX) sw.imageExtent={320,180};
        sw.imageArrayLayers=1;sw.imageUsage=VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        if((caps.supportedUsageFlags&sw.imageUsage)!=sw.imageUsage) throw std::runtime_error("Swapchain transfer usage unavailable");
        uint32_t indices[]={render_family,present_family};
        sw.imageSharingMode=multi?VK_SHARING_MODE_CONCURRENT:VK_SHARING_MODE_EXCLUSIVE;
        sw.queueFamilyIndexCount=multi?2:0;sw.pQueueFamilyIndices=multi?indices:nullptr;
        sw.preTransform=caps.currentTransform;
        sw.compositeAlpha=(caps.supportedCompositeAlpha&VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)?VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR:VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
        sw.presentMode=VK_PRESENT_MODE_FIFO_KHR;sw.clipped=VK_TRUE;
        VkSwapchainKHR chain;CHECK(vkCreateSwapchainKHR(device,&sw,nullptr,&chain));
        CHECK(vkGetSwapchainImagesKHR(device,chain,&count,nullptr));
        std::vector<VkImage> images(count);CHECK(vkGetSwapchainImagesKHR(device,chain,&count,images.data()));
        if (count > bi.size / 4) throw std::runtime_error("Readback buffer cannot cover swapchain image count");
        std::vector<VkImageLayout> layouts(count,VK_IMAGE_LAYOUT_UNDEFINED);
        std::vector<VkCommandBuffer> commands(count); std::vector<VkFence> fences(count);
        std::vector<VkSemaphore> semaphores(fresh_semaphores?frames_per_cycle:count);std::vector<int> expected(count,-1);
        // One fence per present avoids adding an extra CPU wait to steady-state
        // semaphore reuse. Keep every fence until this swapchain is retired.
        std::vector<VkFence> presented(frames_per_cycle);
        VkCommandBufferAllocateInfo ca={VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        ca.commandPool=pool;ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;ca.commandBufferCount=count;
        CHECK(vkAllocateCommandBuffers(device,&ca,commands.data()));
        std::vector<VkCommandBuffer> consumer_commands(render_chain?count:0);
        if(render_chain) {
            ca.commandPool=consumer_pool;
            CHECK(vkAllocateCommandBuffers(device,&ca,consumer_commands.data()));
        }
        for(uint32_t i=0;i<count;i++) {
            fi.flags=VK_FENCE_CREATE_SIGNALED_BIT;CHECK(vkCreateFence(device,&fi,nullptr,&fences[i]));
        }
        VkSemaphoreCreateInfo si={VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        for(auto& semaphore:semaphores) CHECK(vkCreateSemaphore(device,&si,nullptr,&semaphore));
        std::vector<VkSemaphore> chain_semaphores(render_chain?count:0);
        VkSemaphoreTypeCreateInfo chain_type={VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
        chain_type.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;
        VkSemaphoreCreateInfo chain_info=si;
        if(timeline_chain) chain_info.pNext=&chain_type;
        for(auto& semaphore:chain_semaphores) CHECK(vkCreateSemaphore(device,&chain_info,nullptr,&semaphore));
        std::vector<VkSemaphore> host_gates(timeline_host_gate?count:0);
        for(auto& semaphore:host_gates) CHECK(vkCreateSemaphore(device,&chain_info,nullptr,&semaphore));
        std::vector<uint64_t> chain_values(count,0);
        std::vector<VkSemaphore> acquire_semaphores(acquire_semaphore?count:0);
        std::vector<VkFence> acquire_uses(acquire_semaphores.size(),VK_NULL_HANDLE);
        for(auto& semaphore:acquire_semaphores) CHECK(vkCreateSemaphore(device,&si,nullptr,&semaphore));
        VkSemaphore acquiring=VK_NULL_HANDLE;
        fi.flags=0;
        for(auto& fence:presented) CHECK(vkCreateFence(device,&fi,nullptr,&fence));
        auto acquire=[&]() {
            if(acquire_semaphore) {
                unsigned slot=current_frame%count;
                if(acquire_uses[slot]) wait_fence(device,acquire_uses[slot],"acquire-semaphore-reuse",slot);
                acquiring=acquire_semaphores[slot];
            }
            trace("acquire-call");
            uint32_t index;CHECK(vkAcquireNextImageKHR(device,chain,1000000000,acquiring,gpu_acquire_only?VK_NULL_HANDLE:acquired,&index));
            trace("acquire-return",index);
            if(!gpu_acquire_only) {
                wait_fence(device,acquired,"acquire-fence",index);CHECK(vkResetFences(device,1,&acquired));
            }
            return index;
        };
        auto wait=[&](uint32_t i) {
            wait_fence(device,fences[i],"render-fence",i);
            if(expected[i]>=0) {
                auto* bytes=static_cast<unsigned char*>(mapped)+i*4;
                int channel=expected[i];
                for(int k=0;k<4;k++) if(bytes[k]!=(k==channel||k==3?255:0)) {
                    std::cerr << "READBACK image=" << i << " expected-channel=" << channel
                        << " actual=" << unsigned(bytes[0]) << "," << unsigned(bytes[1])
                        << "," << unsigned(bytes[2]) << "," << unsigned(bytes[3]) << std::endl;
                    throw std::runtime_error("Rendered readback mismatch");
                }
                readbacks++;expected[i]=-1;
            }
        };
        auto encode=[&](uint32_t i,int color,bool display,bool preserve) {
            wait(i);CHECK(vkResetFences(device,1,&fences[i]));CHECK(vkResetCommandBuffer(commands[i],0));
            VkCommandBufferBeginInfo cb={VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};CHECK(vkBeginCommandBuffer(commands[i],&cb));
            VkCommandBuffer recording=commands[i];
            auto barrier=[&](VkImageLayout next) {
                VkImageMemoryBarrier b={VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
                b.srcAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
                b.dstAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
                b.oldLayout=layouts[i];b.newLayout=next;b.srcQueueFamilyIndex=b.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
                b.image=images[i];b.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
                vkCmdPipelineBarrier(recording,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,nullptr,0,nullptr,1,&b);layouts[i]=next;
            };
            // Increase producer CPU encoding work without adding a host wait or
            // changing the Vulkan semaphore dependency being exercised.
            VkMemoryBarrier delay={VK_STRUCTURE_TYPE_MEMORY_BARRIER};
            delay.srcAccessMask=delay.dstAccessMask=VK_ACCESS_MEMORY_WRITE_BIT;
            for(unsigned n=0;n<producer_barriers;n++)
                vkCmdPipelineBarrier(recording,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,1,&delay,0,nullptr,0,nullptr);
            if(!preserve) {
                barrier(VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
                VkClearColorValue clear={};clear.float32[2-color]=1;clear.float32[3]=1;
                VkImageSubresourceRange range={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
                vkCmdClearColorImage(commands[i],images[i],layouts[i],&clear,1,&range);
            }
            barrier(VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
            if(render_chain) {
                CHECK(vkEndCommandBuffer(recording));
                recording=consumer_commands[i];
                CHECK(vkResetCommandBuffer(recording,0));
                CHECK(vkBeginCommandBuffer(recording,&cb));
            }
            // Keep reused readback writes explicitly ordered on the consumer
            // queue, including submissions with unresolved forward timeline waits.
            VkBufferMemoryBarrier reuse={VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            reuse.srcAccessMask=reuse.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
            reuse.srcQueueFamilyIndex=reuse.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
            reuse.buffer=buffer;reuse.offset=i*4;reuse.size=4;
            vkCmdPipelineBarrier(recording,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,1,&reuse,0,nullptr);
            VkBufferImageCopy copy={};copy.bufferOffset=i*4;copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1};copy.imageExtent={1,1,1};
            vkCmdCopyImageToBuffer(recording,images[i],layouts[i],buffer,1,&copy);
            VkBufferMemoryBarrier host={VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            host.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;host.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
            host.srcQueueFamilyIndex=host.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;host.buffer=buffer;host.offset=i*4;host.size=4;
            vkCmdPipelineBarrier(recording,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&host,0,nullptr);
            barrier(display?VK_IMAGE_LAYOUT_PRESENT_SRC_KHR:VK_IMAGE_LAYOUT_GENERAL);
            CHECK(vkEndCommandBuffer(recording));
            // A fresh semaphore per present isolates drawable access from binary reuse.
            VkSemaphore finished=semaphores[fresh_semaphores?current_frame:i];
            VkSubmitInfo submit={VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&commands[i];
            VkPipelineStageFlags acquired_stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
            if(acquire_semaphore) {
                submit.waitSemaphoreCount=1;submit.pWaitSemaphores=&acquiring;submit.pWaitDstStageMask=&acquired_stage;
            }
            submit.signalSemaphoreCount=display?1:0;submit.pSignalSemaphores=display?&finished:nullptr;
            trace("submit-call",i);
            if(render_chain) {
                uint64_t signal_value=++chain_values[i], binary_value=0;
                VkTimelineSemaphoreSubmitInfo producer_values={VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
                producer_values.signalSemaphoreValueCount=1;producer_values.pSignalSemaphoreValues=&signal_value;
                producer_values.waitSemaphoreValueCount=submit.waitSemaphoreCount;producer_values.pWaitSemaphoreValues=&binary_value;
                VkSemaphore host_waits[]={acquiring,timeline_host_gate?host_gates[i]:VK_NULL_HANDLE};
                VkPipelineStageFlags host_stages[]={VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT};
                uint64_t host_values[]={0,signal_value};
                if(timeline_host_gate) {
                    unsigned first=acquire_semaphore?0:1;
                    submit.waitSemaphoreCount=2-first;submit.pWaitSemaphores=host_waits+first;submit.pWaitDstStageMask=host_stages+first;
                    producer_values.waitSemaphoreValueCount=2-first;producer_values.pWaitSemaphoreValues=host_values+first;
                }
                if(timeline_chain) submit.pNext=&producer_values;
                submit.signalSemaphoreCount=1;submit.pSignalSemaphores=&chain_semaphores[i];
                VkSubmitInfo producer_submit=submit;
                if(!timeline_forward) CHECK(submit_queue(render,producer_submit,VK_NULL_HANDLE));
                submit.waitSemaphoreCount=1;submit.pWaitSemaphores=&chain_semaphores[i];
                submit.pWaitDstStageMask=&acquired_stage;
                submit.pCommandBuffers=&consumer_commands[i];
                submit.pSignalSemaphores=&finished;
                VkTimelineSemaphoreSubmitInfo consumer_values={VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
                consumer_values.waitSemaphoreValueCount=1;consumer_values.pWaitSemaphoreValues=&signal_value;
                consumer_values.signalSemaphoreValueCount=1;consumer_values.pSignalSemaphoreValues=&binary_value;
                if(timeline_chain) submit.pNext=&consumer_values;
                CHECK(submit_queue(present,submit,fences[i]));
                // Valid timeline forward wait: the consumer submission returns
                // before its signal is submitted on another queue. Queue both
                // dependencies before the final binary-semaphore presentation.
                if(timeline_forward) CHECK(submit_queue(render,producer_submit,VK_NULL_HANDLE));
                // The same host thread supplies this signal only after both
                // public submit calls returned. A blocking CPU gate in a
                // synchronous submit would prevent the signal from arriving.
                if(timeline_host_gate) {
                    VkSemaphoreSignalInfo host_signal={VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO};
                    host_signal.semaphore=host_gates[i];host_signal.value=signal_value;
                    CHECK(vkSignalSemaphore(device,&host_signal));
                }
            } else { CHECK(submit_queue(render,submit,fences[i])); }
            trace("submit-return",i);
            if(acquire_semaphore) acquire_uses[current_frame%count]=fences[i];
            if(!preserve) expected[i]=color;
            if(display) {
                // Diagnostic isolation only: order CPU encoding before presentation.
                // The normal test relies on its Vulkan semaphore, without this wait.
                if(wait_render) wait_fence(device,fences[i],"diagnostic-render-before-present",i);
                VkSwapchainPresentFenceInfoEXT present_fence={VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT};
                present_fence.swapchainCount=1;present_fence.pFences=&presented[current_frame];
                VkPresentInfoKHR present_info={VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};present_info.waitSemaphoreCount=1;present_info.pWaitSemaphores=&finished;
                present_info.pNext=&present_fence;
                present_info.swapchainCount=1;present_info.pSwapchains=&chain;present_info.pImageIndices=&i;
                if (hidden_window) hidden_presents++;
                trace("present-call",i);CHECK(vkQueuePresentKHR(present,&present_info));trace("present-return",i);frames++;
            }
        };
        // Exercise release/reacquisition before presenting on this swapchain.
        if(!present_only) {
            uint32_t i=acquire();encode(i,2,false,false);wait(i);
            VkReleaseSwapchainImagesInfoEXT ri={VK_STRUCTURE_TYPE_RELEASE_SWAPCHAIN_IMAGES_INFO_EXT};
            ri.swapchain=chain;ri.imageIndexCount=1;ri.pImageIndices=&i;
            CHECK(release_images(device,&ri));released++;
            for(unsigned attempt=0;attempt<count+1;attempt++) {
                uint32_t j=acquire();
                if(j==i) {
                    encode(j,2,false,true);wait(j);preservation_checks++;
                    auto* pixel=static_cast<unsigned char*>(mapped)+j*4;
                    if(pixel[0]!=0 || pixel[1]!=0 || pixel[2]!=255 || pixel[3]!=255) preservation_failures++;
                    CHECK(release_images(device,&ri));released++;break;
                }
                VkReleaseSwapchainImagesInfoEXT other=ri;other.pImageIndices=&j;
                CHECK(release_images(device,&other));released++;
            }
        }
        for(unsigned f=0;f<frames_per_cycle;f++) {
            current_frame=f;
            if(hide_restore && f==20) {
                [window orderOut:nil];
                if([window isVisible]) throw std::runtime_error("Window hide failed");
                hidden_window=window;hide_count++;
                restore_at=std::chrono::steady_clock::now()+std::chrono::milliseconds(250);
                trace("window-hidden");
            }
            pump();uint32_t i=acquire();encode(i,f%3,true,false);
        }
        while(hidden_window) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            pump();
        }
        for(uint32_t i=0;i<count;i++) wait(i);
        if(retire_without_idle) {
            // Maintenance1 fences authorize retirement without queue-idle.
            // Avoid an event-pump delay after the final fence: teardown should
            // be safe even when completion handlers are still returning.
            CHECK(vkWaitForFences(device,static_cast<uint32_t>(presented.size()),presented.data(),VK_TRUE,5000000000));
        } else {
            for(uint32_t i=0;i<presented.size();i++) wait_fence(device,presented[i],"retire-present-fence",i);
            CHECK(vkQueueWaitIdle(render));if(multi) CHECK(vkQueueWaitIdle(present));
        }
        vkDestroySwapchainKHR(device,chain,nullptr);
        for(uint32_t i=0;i<count;i++) vkDestroyFence(device,fences[i],nullptr);
        for(auto semaphore:semaphores) vkDestroySemaphore(device,semaphore,nullptr);
        for(auto semaphore:chain_semaphores) vkDestroySemaphore(device,semaphore,nullptr);
        for(auto semaphore:host_gates) vkDestroySemaphore(device,semaphore,nullptr);
        for(auto semaphore:acquire_semaphores) vkDestroySemaphore(device,semaphore,nullptr);
        for(auto fence:presented) vkDestroyFence(device,fence,nullptr);
        [window setContentSize:NSMakeSize(320+cycle*8,180+cycle*8)];pump();
        if(progress) {
            uint64_t image_counts[5]={}, encoding_counts[2]={};
            if(lifetime) lifetime(image_counts);
            if(encoding_lifetime) encoding_lifetime(encoding_counts);
            mach_task_basic_info_data_t info={};mach_msg_type_number_t size=MACH_TASK_BASIC_INFO_COUNT;
            auto status=task_info(mach_task_self(),MACH_TASK_BASIC_INFO,reinterpret_cast<task_info_t>(&info),&size);
            std::cout<<"PROGRESS {\"cycle\":"<<(cycle+1)<<",\"frames\":"<<frames
                <<",\"presentation_begin\":"<<image_counts[0]<<",\"presentation_end\":"<<image_counts[1]
                <<",\"images_created\":"<<image_counts[2]<<",\"images_destroyed\":"<<image_counts[3]
                <<",\"encoding_created\":"<<encoding_counts[0]<<",\"encoding_destroyed\":"<<encoding_counts[1]
                <<",\"rss_bytes\":"<<(status==KERN_SUCCESS?info.resident_size:0)<<"}"<<std::endl;
        }
    }
    vkDestroyFence(device,acquired,nullptr);vkUnmapMemory(device,memory);vkDestroyBuffer(device,buffer,nullptr);vkFreeMemory(device,memory,nullptr);
    if(consumer_pool) vkDestroyCommandPool(device,consumer_pool,nullptr);
    vkDestroyCommandPool(device,pool,nullptr);vkDestroyDevice(device,nullptr);
    vkDestroySurfaceKHR(instance,surface,nullptr);
    if(messenger) destroy_messenger(instance,messenger,nullptr);
    vkDestroyInstance(instance,nullptr);
    [window close];[window release];pump();
    uint64_t counters[5] = {};
    uint64_t encoding_counters[2] = {};
    if (lifetime || encoding_lifetime) {
        for (unsigned attempt=0;attempt<100;attempt++) {
            if(lifetime) lifetime(counters);
            if(encoding_lifetime) encoding_lifetime(encoding_counters);
            if(counters[0]==counters[1] && counters[2]==counters[3] && encoding_counters[0]==encoding_counters[1]) break;
            [[NSRunLoop currentRunLoop] runUntilDate:
                [NSDate dateWithTimeIntervalSinceNow:0.01]];
            pump();
        }
    }
    if(preservation_failures || (!present_only && preservation_checks!=cycles))
        throw std::runtime_error("Release/reacquisition preservation checks failed or incomplete");
    if(hide_restore && (hide_count!=cycles || restore_count!=cycles || !hidden_presents))
        throw std::runtime_error("Hide/restore checks incomplete");
    std::cout<<"RESULT {\"frames\":"<<frames<<",\"readbacks\":"<<readbacks
        <<",\"frames_per_cycle\":"<<frames_per_cycle
        <<",\"swapchains\":"<<cycles<<",\"released\":"<<released<<",\"preservation_checks\":"<<preservation_checks
        <<",\"preservation_failures\":"<<preservation_failures<<",\"multi_queue\":"<<(multi?"true":"false")
        <<",\"presentation_fences\":true,\"wait_render_before_present\":"<<(wait_render?"true":"false")
        <<",\"present_only\":"<<(present_only?"true":"false")
        <<",\"fresh_semaphores\":"<<(fresh_semaphores?"true":"false")
        <<",\"hide_restore\":"<<(hide_restore?"true":"false")
        <<",\"acquire_semaphore\":"<<(acquire_semaphore?"true":"false")
        <<",\"retire_without_idle\":"<<(retire_without_idle?"true":"false")
        <<",\"gpu_acquire_only\":"<<(gpu_acquire_only?"true":"false")
        <<",\"render_chain\":"<<(render_chain?"true":"false")
        <<",\"submit2\":"<<(use_submit2?"true":"false")
        <<",\"timeline_chain\":"<<(timeline_chain?"true":"false")
        <<",\"timeline_forward\":"<<(timeline_forward?"true":"false")
        <<",\"timeline_host_gate\":"<<(timeline_host_gate?"true":"false")
        <<",\"producer_barriers\":"<<producer_barriers
        <<",\"vulkan_validation\":"<<(validation?"true":"false")
        <<",\"validation_errors\":"<<validation_errors.load()
        <<",\"validation_warnings\":"<<validation_warnings.load()
        <<",\"hide_count\":"<<hide_count<<",\"restore_count\":"<<restore_count
        <<",\"hidden_presents\":"<<hidden_presents<<",\"max_restore_delay_ms\":"<<max_restore_delay_ms
        <<",\"lifetime_instrumented\":"<<(lifetime?"true":"false")
        <<",\"encoding_lifetime_instrumented\":"<<(encoding_lifetime?"true":"false")
        <<",\"encoding_states_created\":"<<encoding_counters[0]<<",\"encoding_states_destroyed\":"<<encoding_counters[1]
        <<",\"presentation_begin\":"<<counters[0]<<",\"presentation_end\":"<<counters[1]
        <<",\"images_created\":"<<counters[2]<<",\"images_destroyed\":"<<counters[3]
        <<",\"gpu_completed\":"<<counters[4]<<"}"<<std::endl;
    if(lifetime && (counters[0]!=counters[1] || counters[2]!=counters[3] || counters[4]!=frames))
        throw std::runtime_error("Diagnostic presentation/image retirement incomplete within the bounded drain");
    if(encoding_counters[0]!=encoding_counters[1])
        throw std::runtime_error("CPU encoding state retirement incomplete within the bounded drain");
    if(validation_errors) throw std::runtime_error("Vulkan validation reported errors");
    // Pending callbacks must not run code from an unloaded diagnostic driver.
    if (!lifetime || (counters[0]==counters[1] && counters[2]==counters[3])) dlclose(library);
    return 0;
  } catch(const std::exception& e) {
    std::cerr<<"FAIL "<<e.what()<<std::endl;
    std::cout<<"FAILURE_CHECKS {\"vulkan_validation\":"<<(validation_enabled?"true":"false")
        <<",\"validation_errors\":"<<validation_errors.load()
        <<",\"validation_warnings\":"<<validation_warnings.load()<<"}"<<std::endl;
    return 2;
  }
 }
}
