// Internal checks for the prepared timeline encoding protocol, not conformance.
#include "MVKDevice.h"
#include "MVKQueue.h"
#include "MVKSync.h"
#include <chrono>
#include <future>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static void success(VkResult result, const char* message) {
    if (result != VK_SUCCESS) throw std::runtime_error(std::string(message) + ": " + std::to_string(result));
}
static void await(std::future<VkResult>& result, VkResult expected) {
    if (result.wait_for(std::chrono::seconds(2)) != std::future_status::ready) {
        std::cerr << "FAIL Stranded timeline encoding wait" << std::endl;
        std::_Exit(2);
    }
    require(result.get() == expected, "Unexpected timeline wait result");
}

int main(int argc, char** argv) {
 @autoreleasepool {
  try {
    unsigned rounds=argc>1?std::stoul(argv[1]):50;
    require(rounds && rounds<=500,"Round count must be 1..500");
    VkInstanceCreateInfo ci={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    VkApplicationInfo app={VK_STRUCTURE_TYPE_APPLICATION_INFO};app.apiVersion=VK_API_VERSION_1_3;ci.pApplicationInfo=&app;
    VkInstance instance;success(vkCreateInstance(&ci,nullptr,&instance),"create instance");
    VkPhysicalDevice gpu;uint32_t count=1;success(vkEnumeratePhysicalDevices(instance,&count,&gpu),"enumerate GPU");
    vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,nullptr);
    std::vector<VkQueueFamilyProperties> families(count);vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,families.data());
    uint32_t family=UINT32_MAX;
    for(uint32_t i=0;i<count;i++) if(families[i].queueFlags&VK_QUEUE_GRAPHICS_BIT){family=i;break;}
    require(family!=UINT32_MAX,"No graphics queue");
    float priority=1;VkDeviceQueueCreateInfo qi={VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qi.queueFamilyIndex=family;qi.queueCount=1;qi.pQueuePriorities=&priority;
    success(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,nullptr),"extensions");
    std::vector<VkExtensionProperties> extensions(count);success(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,extensions.data()),"extensions");
    std::vector<const char*> enabled;
    for(auto& e:extensions) if(!strcmp(e.extensionName,"VK_KHR_portability_subset"))enabled.push_back("VK_KHR_portability_subset");
    bool metal_objects=false;
    for(auto& e:extensions) if(!strcmp(e.extensionName,"VK_EXT_metal_objects")){enabled.push_back("VK_EXT_metal_objects");metal_objects=true;}
    require(metal_objects,"Metal object extension unavailable");
    VkPhysicalDeviceTimelineSemaphoreFeatures feature={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};feature.timelineSemaphore=VK_TRUE;
    VkDeviceCreateInfo di={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};di.pNext=&feature;di.queueCreateInfoCount=1;di.pQueueCreateInfos=&qi;
    di.enabledExtensionCount=static_cast<uint32_t>(enabled.size());di.ppEnabledExtensionNames=enabled.data();
    id<MTLDevice> metal_device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> metal_queue=[metal_device newCommandQueue];[metal_device release];
    unsigned waits=0, encoded_without_gpu=0, retired=0, external_skips=0;
    for(unsigned round=0;round<rounds;round++) { @autoreleasepool {
        VkDevice device;success(vkCreateDevice(gpu,&di,nullptr,&device),"create device");
        VkSemaphoreTypeCreateInfo type={VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};type.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;
        VkSemaphoreCreateInfo si={VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};si.pNext=&type;
        VkSemaphore semaphore;success(vkCreateSemaphore(device,&si,nullptr,&semaphore),"create timeline");
        auto* native=reinterpret_cast<MVKTimelineSemaphore*>(semaphore);
        std::vector<std::weak_ptr<MVKSemaphoreImpl>> weak;
        {
            std::vector<std::unique_ptr<MVKSemaphoreSubmitInfo>> consumers;
            // Duplicate waits share one threshold state. Cover legacy pNext
            // rebinding, API2 values, copying and assignment of submit metadata.
            for(uint64_t value:{3,3,5,7}) {
                VkSemaphoreSubmitInfo info={VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};info.semaphore=semaphore;info.value=value;
                consumers.emplace_back(new MVKSemaphoreSubmitInfo(info));consumers.back()->reserveWaitToken();
            }
            consumers.emplace_back(new MVKSemaphoreSubmitInfo(semaphore,0));
            consumers.back()->reserveWaitToken();consumers.back()->setTimelineValue(3);
            consumers.emplace_back(new MVKSemaphoreSubmitInfo(*consumers.front()));
            consumers.emplace_back(new MVKSemaphoreSubmitInfo(semaphore,0));*consumers.back()=*consumers.front();
            for(uint64_t value:{3,5,7}) weak.push_back(native->getSignalEncoding(value,true));
            std::vector<std::promise<VkResult>> promises(consumers.size());
            std::vector<std::future<VkResult>> futures;std::vector<std::thread> workers;
            for(unsigned i=0;i<consumers.size();i++) {
                futures.push_back(promises[i].get_future());
                workers.emplace_back([&,i]{@autoreleasepool{promises[i].set_value(consumers[i]->waitForSignalEncoding());}});
            }
            // Encoding a signal completes CPU dependencies while the actual
            // GPU counter is still zero. The command buffer is never committed.
            id<MTLCommandBuffer> command=[metal_queue commandBuffer];
            native->encodeSignal(command,5);
            for(unsigned i=0;i<futures.size();i++) if(i!=3) await(futures[i],VK_SUCCESS);
            require(futures[3].wait_for(std::chrono::milliseconds(1))==std::future_status::timeout,"Value 5 released a wait for 7");
            require(native->getCounterValue()==0,"Internal check unexpectedly executed GPU work");encoded_without_gpu++;
            VkSemaphoreSignalInfo host={VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO};host.semaphore=semaphore;host.value=7;
            success(vkSignalSemaphore(device,&host),"host signal");await(futures[3],VK_SUCCESS);
            for(auto& worker:workers)worker.join();waits+=static_cast<unsigned>(consumers.size());
        }
        for(auto& state:weak)require(state.expired(),"Completed timeline state was retained");retired+=static_cast<unsigned>(weak.size());
        std::weak_ptr<MVKSemaphoreImpl> lost_state;
        {
            MVKSemaphoreSubmitInfo lost(semaphore,0);lost.reserveWaitToken();lost.setTimelineValue(9);
            lost_state=native->getSignalEncoding(9,true);
            std::promise<VkResult> promise;auto future=promise.get_future();
            std::thread worker([&]{@autoreleasepool{promise.set_value(lost.waitForSignalEncoding());}});
            require(MVKDevice::getMVKDevice(device)->markLost()==VK_ERROR_DEVICE_LOST,"inject loss");
            await(future,VK_ERROR_DEVICE_LOST);worker.join();waits++;
        }
        vkDestroySemaphore(device,semaphore,nullptr);
        require(lost_state.expired(),"Lost timeline state retained beyond semaphore destruction");retired++;
        vkDestroyDevice(device,nullptr);
        success(vkCreateDevice(gpu,&di,nullptr,&device),"create external device");
        VkExportMetalObjectCreateInfoEXT export_info={VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT};
        export_info.exportObjectType=VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT;export_info.pNext=&type;si.pNext=&export_info;
        success(vkCreateSemaphore(device,&si,nullptr,&semaphore),"create exportable timeline");
        require(!reinterpret_cast<MVKSemaphore*>(semaphore)->getSignalEncoding(11,true),"External payload unexpectedly uses Vulkan-only gate");external_skips++;
        vkDestroySemaphore(device,semaphore,nullptr);vkDestroyDevice(device,nullptr);
    }
    }
    [metal_queue release];vkDestroyInstance(instance,nullptr);
    std::cout<<"RESULT {\"rounds\":"<<rounds<<",\"waits\":"<<waits<<",\"retired_states\":"<<retired
        <<",\"cpu_signals_without_gpu\":"<<encoded_without_gpu<<",\"external_payload_skips\":"<<external_skips
        <<",\"internal_protocol_test\":true}"<<std::endl;
    return 0;
  } catch(const std::exception& e) {std::cerr<<"FAIL "<<e.what()<<std::endl;return 2;}
 }
}
