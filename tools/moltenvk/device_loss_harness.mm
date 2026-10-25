// Internal fault-injection checks, linked to an exact local MoltenVK build.
// No GPU fault is induced. These synthesize a pending CPU encoding dependency
// and call the real driver loss path; they are not a Vulkan conformance test.
#include "MVKDevice.h"
#include "MVKQueue.h"
#include "MVKSync.h"
#include <atomic>
#include <chrono>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

// Access inherited protected data through base-class member pointers. Do not
// downcast a base object to this inspection type or change its private layout.
struct DeviceInspection : MVKDevice {
    static size_t waiting(MVKDevice& device) {
        std::lock_guard<std::mutex> lock(device.*&DeviceInspection::_sem4Lock);
        return (device.*&DeviceInspection::_awaitingSemaphores).size();
    }
};
struct QueueInspection : MVKQueue {
    static VkResult enqueue(MVKQueue& queue, MVKQueueSubmission* submission) {
        auto method = static_cast<VkResult (MVKQueue::*)(MVKQueueSubmission*)>(&QueueInspection::submit);
        return (queue.*method)(submission);
    }
    static unsigned jobs(MVKQueue& queue) {
        std::lock_guard<std::mutex> lock(queue.*&QueueInspection::_execQueueMutex);
        return queue.*&QueueInspection::_execQueueJobCount;
    }
};

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static void success(VkResult result, const char* message) {
    if (result != VK_SUCCESS) throw std::runtime_error(std::string(message) + ": " + std::to_string(result));
}
using Clock = std::chrono::steady_clock;

int main(int argc, char** argv) {
 @autoreleasepool {
  try {
    unsigned races = argc > 1 ? std::stoul(argv[1]) : 100;
    require(races > 0 && races <= 1000, "Race count must be 1..1000");
    VkBool32 synchronous = VK_FALSE;
    VkLayerSettingEXT setting = {"MoltenVK", "MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS",
        VK_LAYER_SETTING_TYPE_BOOL32_EXT, 1, &synchronous};
    VkLayerSettingsCreateInfoEXT settings = {VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT, nullptr, 1, &setting};
    const char* extension = "VK_EXT_layer_settings";
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "Internal CPU Encoding Device Loss Check";
    app.apiVersion = VK_API_VERSION_1_3;
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pNext = &settings; ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 1; ici.ppEnabledExtensionNames = &extension;
    VkInstance instance; success(vkCreateInstance(&ici, nullptr, &instance), "create instance");
    uint32_t count = 1; VkPhysicalDevice physical;
    success(vkEnumeratePhysicalDevices(instance, &count, &physical), "enumerate GPU");
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
    std::vector<VkQueueFamilyProperties> families(count);
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, families.data());
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < count; ++i) if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) { family = i; break; }
    require(family != UINT32_MAX, "No graphics queue");
    success(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr), "device extensions");
    std::vector<VkExtensionProperties> extensions(count);
    success(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data()), "device extensions");
    std::vector<const char*> enabled;
    for (const auto& e : extensions) if (!strcmp(e.extensionName, "VK_KHR_portability_subset")) enabled.push_back("VK_KHR_portability_subset");
    float priority = 1;
    VkDeviceQueueCreateInfo qi = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qi.queueFamilyIndex = family; qi.queueCount = 1; qi.pQueuePriorities = &priority;
    VkDeviceCreateInfo di = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    di.queueCreateInfoCount = 1; di.pQueueCreateInfos = &qi;
    di.enabledExtensionCount = static_cast<uint32_t>(enabled.size()); di.ppEnabledExtensionNames = enabled.data();
    double worst_wakeup_ms = 0;
    unsigned completed = 0, confirmed_blocked = 0, queue_abort_checks = 0;
    // Before registration, registered waits, then simultaneous registration/loss.
    for (unsigned iteration = 0; iteration < races + 2; ++iteration) {
        VkDevice device; success(vkCreateDevice(physical, &di, nullptr, &device), "create device");
        auto* internal = MVKDevice::getMVKDevice(device);
        unsigned waiters = iteration == 1 ? 16 : 1;
        std::vector<VkSemaphore> semaphores(waiters);
        std::vector<std::unique_ptr<MVKSemaphoreSubmitInfo>> producers, consumers;
        VkSemaphoreCreateInfo si = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        for (unsigned n = 0; n < waiters; ++n) {
            success(vkCreateSemaphore(device, &si, nullptr, &semaphores[n]), "create semaphore");
            producers.emplace_back(new MVKSemaphoreSubmitInfo(semaphores[n], 0));
            producers.back()->reserveSignalToken();
            auto* sem = reinterpret_cast<MVKSemaphore*>(semaphores[n]);
            require(bool(sem->getSignalEncoding(producers.back()->value, false)), "Native binary encoding state unavailable");
            consumers.emplace_back(new MVKSemaphoreSubmitInfo(semaphores[n], 0));
            consumers.back()->reserveWaitToken();
        }
        if (iteration == 0) require(internal->markLost() == VK_ERROR_DEVICE_LOST, "Loss before registration failed");
        std::atomic<bool> start{false};
        std::atomic<unsigned> entered{0}, returned{0}, wrong_result{0};
        std::vector<std::thread> threads;
        for (unsigned n = 0; n < waiters; ++n) threads.emplace_back([&, n] {
            @autoreleasepool {
                while (!start.load(std::memory_order_acquire)) std::this_thread::yield();
                entered.fetch_add(1);
                if (consumers[n]->waitForSignalEncoding() != VK_ERROR_DEVICE_LOST) wrong_result++;
                returned.fetch_add(1);
            }
        });
        start.store(true, std::memory_order_release);
        if (iteration == 1) {
            auto deadline = Clock::now() + std::chrono::seconds(2);
            while (DeviceInspection::waiting(*internal) != waiters && Clock::now() < deadline) std::this_thread::yield();
            // A failure exits the process under the external watchdog; do not
            // destroy objects or join a thread that might still be blocked.
            if (DeviceInspection::waiting(*internal) != waiters || returned.load()) {
                std::cerr << "FAIL Wait registration did not reach the blocked checkpoint" << std::endl;
                std::_Exit(2);
            }
            confirmed_blocked += waiters;
        } else if (iteration > 1 && (iteration % 3 == 0)) {
            while (!entered.load()) std::this_thread::yield();
        }
        auto loss_time = Clock::now();
        require(internal->markLost() == VK_ERROR_DEVICE_LOST, "Loss injection failed");
        auto deadline = Clock::now() + std::chrono::seconds(2);
        while (returned.load() != waiters && Clock::now() < deadline) std::this_thread::yield();
        if (returned.load() != waiters) {
            std::cerr << "FAIL CPU wait stranded after device loss, iteration=" << iteration << std::endl;
            std::_Exit(2);
        }
        for (auto& thread : threads) thread.join();
        require(wrong_result.load() == 0, "Encoding wait did not report device loss");
        worst_wakeup_ms = std::max(worst_wakeup_ms, std::chrono::duration<double, std::milli>(Clock::now() - loss_time).count());
        require(DeviceInspection::waiting(*internal) == 0, "Stale wait registration after loss");
        consumers.clear(); producers.clear();
        for (auto semaphore : semaphores) vkDestroySemaphore(device, semaphore, nullptr);
        vkDestroyDevice(device, nullptr);
        completed++;
    }
    // Exercise the real asynchronous rendering/presentation submission workers.
    // Their input signal state is injected internally, not submitted as an
    // application Vulkan signal. No pending GPU operation is manufactured.
    for (bool presentation : {false, true}) {
        VkDevice device; success(vkCreateDevice(physical, &di, nullptr, &device), "create worker device");
        auto* internal = MVKDevice::getMVKDevice(device);
        VkQueue queue_handle; vkGetDeviceQueue(device, family, 0, &queue_handle);
        auto* queue = MVKQueue::getMVKQueue(queue_handle);
        VkSemaphore semaphore; VkSemaphoreCreateInfo si = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        success(vkCreateSemaphore(device, &si, nullptr, &semaphore), "create worker semaphore");
        {
            MVKSemaphoreSubmitInfo producer(semaphore, 0); producer.reserveSignalToken();
            if (presentation) {
                VkPresentInfoKHR info = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
                info.waitSemaphoreCount = 1; info.pWaitSemaphores = &semaphore;
                success(QueueInspection::enqueue(*queue, new MVKQueuePresentSurfaceSubmission(queue, &info)), "queue present worker");
            } else {
                VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
                VkSubmitInfo info = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
                info.waitSemaphoreCount = 1; info.pWaitSemaphores = &semaphore; info.pWaitDstStageMask = &stage;
                success(QueueInspection::enqueue(*queue, new MVKQueueCommandBufferSubmission(queue, &info, VK_NULL_HANDLE, kMVKCommandUseQueueSubmit)), "queue rendering worker");
            }
            auto deadline = Clock::now() + std::chrono::seconds(2);
            while (DeviceInspection::waiting(*internal) != 1 && Clock::now() < deadline) std::this_thread::yield();
            if (DeviceInspection::waiting(*internal) != 1 || QueueInspection::jobs(*queue) != 1) {
                std::cerr << "FAIL Submission worker did not block before injection" << std::endl;
                std::_Exit(2);
            }
            require(internal->markLost() == VK_ERROR_DEVICE_LOST, "Worker loss injection failed");
            deadline = Clock::now() + std::chrono::seconds(2);
            while (QueueInspection::jobs(*queue) && Clock::now() < deadline) std::this_thread::yield();
            if (QueueInspection::jobs(*queue)) {
                std::cerr << "FAIL Submission worker failed to abort on device loss" << std::endl;
                std::_Exit(2);
            }
            require(DeviceInspection::waiting(*internal) == 0, "Worker left an encoding wait registered");
            queue_abort_checks++;
        }
        vkDestroySemaphore(device, semaphore, nullptr);
        vkDestroyDevice(device, nullptr);
    }
    vkDestroyInstance(instance, nullptr);
    std::cout << "RESULT {\"devices\":" << completed << ",\"racing_losses\":" << races
        << ",\"confirmed_blocked_waits\":" << confirmed_blocked
        << ",\"worst_wakeup_ms\":" << worst_wakeup_ms
        << ",\"loss_result_checked\":true,\"submission_worker_aborts\":" << queue_abort_checks
        << ",\"internal_fault_injection\":true,\"gpu_fault_induced\":false}" << std::endl;
    return 0;
  } catch (const std::exception& e) { std::cerr << "FAIL " << e.what() << std::endl; return 2; }
 }
}
