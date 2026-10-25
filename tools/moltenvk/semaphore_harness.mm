// Isolate binary-semaphore reuse across two queues without a swapchain/drawable.
// The producer is submitted before the consumer; both fences complete before reuse.
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_METAL_EXT
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

#define FUNCTIONS(X) \
 X(vkCreateInstance) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) \
 X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkGetPhysicalDeviceMemoryProperties) X(vkGetPhysicalDeviceFeatures2) \
 X(vkEnumerateDeviceExtensionProperties) X(vkCreateDevice) X(vkDestroyDevice) \
 X(vkGetDeviceQueue) X(vkCreateCommandPool) X(vkDestroyCommandPool) \
 X(vkAllocateCommandBuffers) X(vkResetCommandBuffer) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
 X(vkCmdFillBuffer) X(vkCmdCopyBuffer) X(vkCmdPipelineBarrier) \
 X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences) \
 X(vkCreateSemaphore) X(vkDestroySemaphore) X(vkQueueSubmit) X(vkQueueSubmit2) X(vkExportMetalObjectsEXT) \
 X(vkCreateBuffer) X(vkDestroyBuffer) X(vkGetBufferMemoryRequirements) \
 X(vkAllocateMemory) X(vkFreeMemory) X(vkBindBufferMemory) X(vkMapMemory) X(vkUnmapMemory)
#define DECLARE(name) static PFN_##name name;
FUNCTIONS(DECLARE)

static void check(VkResult result,const char* name) {
    if(result!=VK_SUCCESS)throw std::runtime_error(std::string(name)+": "+std::to_string(result));
}
#define CHECK(call) check(call,#call)

int main(int argc,char** argv) {
 @autoreleasepool {
    try {
        if(argc<3 || (strcmp(argv[2],"sync") && strcmp(argv[2],"async")))
            throw std::runtime_error("Usage: semaphore-harness driver sync|async [--fresh-semaphores] [--submit2] [--timeline] [--timeline-info-binary] [--same-queue] [--rounds=N]");
        bool fresh=false,submit2=false,timeline=false,timeline_info_binary=false,same_queue=false;
        bool export_event=false,import_event=false;
        unsigned rounds=32;
        for(int arg=3;arg<argc;arg++) {
            if(!strcmp(argv[arg],"--fresh-semaphores"))fresh=true;
            else if(!strcmp(argv[arg],"--submit2"))submit2=true;
            else if(!strcmp(argv[arg],"--timeline"))timeline=true;
            else if(!strcmp(argv[arg],"--timeline-info-binary"))timeline_info_binary=true;
            else if(!strcmp(argv[arg],"--same-queue"))same_queue=true;
            else if(!strcmp(argv[arg],"--export-event"))export_event=true;
            else if(!strcmp(argv[arg],"--import-event"))import_event=true;
            else if(!strncmp(argv[arg],"--rounds=",9)) {
                std::string value=argv[arg]+9;size_t consumed=0;auto parsed=std::stoul(value,&consumed);
                if(consumed!=value.size() || parsed<1 || parsed>4096)throw std::runtime_error("Invalid round count");
                rounds=static_cast<unsigned>(parsed);
            } else throw std::runtime_error("Unknown argument: "+std::string(argv[arg]));
        }
        if(timeline && timeline_info_binary)throw std::runtime_error("Choose timeline or binary timeline-info diagnostic");
        if(export_event && import_event)throw std::runtime_error("Choose export or import");
        if(timeline && (export_event || import_event))throw std::runtime_error("Metal event diagnostic covers binary semaphores");
        void* library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
        if(!library)throw std::runtime_error(dlerror());
#define LOAD(name) name=reinterpret_cast<PFN_##name>(dlsym(library,#name)); \
        if(!name)throw std::runtime_error("Missing " #name);
        FUNCTIONS(LOAD)
        VkBool32 sync=!strcmp(argv[2],"sync");
        VkLayerSettingEXT setting={"MoltenVK","MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS",VK_LAYER_SETTING_TYPE_BOOL32_EXT,1,&sync};
        VkLayerSettingsCreateInfoEXT settings={VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT,nullptr,1,&setting};
        const char* instance_extension="VK_EXT_layer_settings";
        VkApplicationInfo app={VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.pApplicationName="Binary Semaphore Reuse Check";app.apiVersion=VK_API_VERSION_1_3;
        VkInstanceCreateInfo ci={VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        ci.pNext=&settings;ci.pApplicationInfo=&app;ci.enabledExtensionCount=1;ci.ppEnabledExtensionNames=&instance_extension;
        VkInstance instance;CHECK(vkCreateInstance(&ci,nullptr,&instance));
        uint32_t count=1;VkPhysicalDevice gpu;
        CHECK(vkEnumeratePhysicalDevices(instance,&count,&gpu));
        vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,nullptr);
        std::vector<VkQueueFamilyProperties> families(count);
        vkGetPhysicalDeviceQueueFamilyProperties(gpu,&count,families.data());
        std::vector<uint32_t> transfer;
        for(uint32_t i=0;i<count;i++)if(families[i].queueFlags&VK_QUEUE_TRANSFER_BIT)transfer.push_back(i);
        if(transfer.size()<2)throw std::runtime_error("Two transfer-capable queue families required");
        uint32_t indices[]={transfer[0],transfer[1]};float priority=1;
        VkDeviceQueueCreateInfo queues[2]={};
        for(unsigned i=0;i<2;i++){
            queues[i].sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            queues[i].queueFamilyIndex=indices[i];queues[i].queueCount=1;queues[i].pQueuePriorities=&priority;
        }
        CHECK(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,nullptr));
        std::vector<VkExtensionProperties> extensions(count);
        CHECK(vkEnumerateDeviceExtensionProperties(gpu,nullptr,&count,extensions.data()));
        bool portability=false;
        for(const auto& e:extensions)if(!strcmp(e.extensionName,"VK_KHR_portability_subset"))portability=true;
        std::vector<const char*> device_extensions;
        if(portability)device_extensions.push_back("VK_KHR_portability_subset");
        if(export_event || import_event) {
            bool available=false;
            for(auto e:extensions)if(!strcmp(e.extensionName,"VK_EXT_metal_objects"))available=true;
            if(!available)throw std::runtime_error("VK_EXT_metal_objects unavailable");
            device_extensions.push_back("VK_EXT_metal_objects");
        }
        VkDeviceCreateInfo di={VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        di.queueCreateInfoCount=2;di.pQueueCreateInfos=queues;
        di.enabledExtensionCount=static_cast<uint32_t>(device_extensions.size());di.ppEnabledExtensionNames=device_extensions.data();
        VkPhysicalDeviceSynchronization2Features sync_feature={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES};
        VkPhysicalDeviceTimelineSemaphoreFeatures timeline_feature={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES};
        timeline_feature.pNext=&sync_feature;
        VkPhysicalDeviceFeatures2 features={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};features.pNext=&timeline_feature;
        vkGetPhysicalDeviceFeatures2(gpu,&features);
        if((submit2 && !sync_feature.synchronization2) || (timeline && !timeline_feature.timelineSemaphore))
            throw std::runtime_error("Requested synchronization feature unavailable");
        sync_feature.synchronization2=submit2;timeline_feature.timelineSemaphore=timeline;
        di.pNext=&timeline_feature;
        VkDevice device;CHECK(vkCreateDevice(gpu,&di,nullptr,&device));
        VkQueue producer,consumer;vkGetDeviceQueue(device,indices[0],0,&producer);vkGetDeviceQueue(device,indices[1],0,&consumer);
        if(same_queue)consumer=producer;
        constexpr unsigned scratch_words=4096;
        constexpr VkDeviceSize readback_offset=(scratch_words+1)*4,buffer_size=readback_offset+4;
        VkBufferCreateInfo bi={VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        bi.size=buffer_size;bi.usage=VK_BUFFER_USAGE_TRANSFER_SRC_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        bi.sharingMode=VK_SHARING_MODE_CONCURRENT;bi.queueFamilyIndexCount=2;bi.pQueueFamilyIndices=indices;
        VkBuffer buffer;CHECK(vkCreateBuffer(device,&bi,nullptr,&buffer));
        VkMemoryRequirements mr;vkGetBufferMemoryRequirements(device,buffer,&mr);
        VkPhysicalDeviceMemoryProperties mp;vkGetPhysicalDeviceMemoryProperties(gpu,&mp);
        uint32_t type=UINT32_MAX;
        for(uint32_t i=0;i<mp.memoryTypeCount;i++)if((mr.memoryTypeBits&(1u<<i)) &&
            (mp.memoryTypes[i].propertyFlags&(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==
            (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)){type=i;break;}
        if(type==UINT32_MAX)throw std::runtime_error("No coherent host memory");
        VkMemoryAllocateInfo ai={VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};ai.allocationSize=mr.size;ai.memoryTypeIndex=type;
        VkDeviceMemory memory;CHECK(vkAllocateMemory(device,&ai,nullptr,&memory));CHECK(vkBindBufferMemory(device,buffer,memory,0));
        void* mapped;CHECK(vkMapMemory(device,memory,0,mr.size,0,&mapped));
        VkCommandPool pools[2];VkCommandBuffer commands[2];VkFence fences[2];
        for(unsigned i=0;i<2;i++){
            VkCommandPoolCreateInfo pi={VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
            pi.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;pi.queueFamilyIndex=indices[same_queue?0:i];
            CHECK(vkCreateCommandPool(device,&pi,nullptr,&pools[i]));
            VkCommandBufferAllocateInfo ca={VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
            ca.commandPool=pools[i];ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;ca.commandBufferCount=1;
            CHECK(vkAllocateCommandBuffers(device,&ca,&commands[i]));
            VkFenceCreateInfo fi={VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};fi.flags=VK_FENCE_CREATE_SIGNALED_BIT;
            CHECK(vkCreateFence(device,&fi,nullptr,&fences[i]));
        }
        VkSemaphoreCreateInfo si={VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};VkSemaphore semaphore;
        VkSemaphoreTypeCreateInfo semaphore_type={VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO};
        semaphore_type.semaphoreType=VK_SEMAPHORE_TYPE_TIMELINE;
        if(timeline)si.pNext=&semaphore_type;
        id<MTLSharedEvent> imported=nil;
        VkExportMetalObjectCreateInfoEXT export_create={VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT};
        export_create.exportObjectType=VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT;
        VkImportMetalSharedEventInfoEXT import_create={VK_STRUCTURE_TYPE_IMPORT_METAL_SHARED_EVENT_INFO_EXT};
        if(export_event)si.pNext=&export_create;
        if(import_event) {
            imported=[MTLCreateSystemDefaultDevice() newSharedEvent];
            imported.signaledValue=7;import_create.mtlSharedEvent=imported;si.pNext=&import_create;
        }
        CHECK(vkCreateSemaphore(device,&si,nullptr,&semaphore));
        uint64_t final_shared_value=0;
        bool shared_event_observed=false;
        unsigned mismatches=0,first_mismatch=0;uint32_t first_actual=0;
        for(unsigned round=1;round<=rounds;round++){
            if(fresh && round>1){
                // Both fences from the previous round have completed, including
                // its signal/wait operations; retirement is safe on these queues.
                vkDestroySemaphore(device,semaphore,nullptr);
                CHECK(vkCreateSemaphore(device,&si,nullptr,&semaphore));
            }
            CHECK(vkResetFences(device,2,fences));
            for(unsigned i=0;i<2;i++){
                CHECK(vkResetCommandBuffer(commands[i],0));
                VkCommandBufferBeginInfo begin={VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
                CHECK(vkBeginCommandBuffer(commands[i],&begin));
            }
            // Disjoint scratch writes create CPU encoding work without transfer hazards.
            for(unsigned word=0;word<scratch_words;word++)vkCmdFillBuffer(commands[0],buffer,(word+1)*4,4,round);
            vkCmdFillBuffer(commands[0],buffer,0,4,round);
            VkBufferCopy copy={0,readback_offset,4};vkCmdCopyBuffer(commands[1],buffer,buffer,1,&copy);
            VkBufferMemoryBarrier host={VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
            host.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;host.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
            host.srcQueueFamilyIndex=host.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
            host.buffer=buffer;host.offset=readback_offset;host.size=4;
            vkCmdPipelineBarrier(commands[1],VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&host,0,nullptr);
            CHECK(vkEndCommandBuffer(commands[0]));CHECK(vkEndCommandBuffer(commands[1]));
            // Non-unit timeline values detect accidental replacement by binary
            // counters. Different ignored binary values detect legacy pNext
            // overwriting an internal token reserved on the submitting thread.
            uint64_t signal_value=timeline?round*7:100000+round;
            uint64_t wait_value=timeline?signal_value:200000+round;
            if(submit2) {
                VkCommandBufferSubmitInfo command={VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO};command.commandBuffer=commands[0];
                VkSemaphoreSubmitInfo sem={VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
                sem.semaphore=semaphore;sem.value=signal_value;sem.stageMask=VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
                VkSubmitInfo2 submit={VK_STRUCTURE_TYPE_SUBMIT_INFO_2};submit.commandBufferInfoCount=1;submit.pCommandBufferInfos=&command;
                submit.signalSemaphoreInfoCount=1;submit.pSignalSemaphoreInfos=&sem;
                CHECK(vkQueueSubmit2(producer,1,&submit,fences[0]));
                command.commandBuffer=commands[1];sem.value=wait_value;sem.stageMask=VK_PIPELINE_STAGE_2_TRANSFER_BIT;
                submit.signalSemaphoreInfoCount=0;submit.pSignalSemaphoreInfos=nullptr;
                submit.waitSemaphoreInfoCount=1;submit.pWaitSemaphoreInfos=&sem;
                CHECK(vkQueueSubmit2(consumer,1,&submit,fences[1]));
            } else {
                VkTimelineSemaphoreSubmitInfo values={VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO};
                values.signalSemaphoreValueCount=1;values.pSignalSemaphoreValues=&signal_value;
                VkSubmitInfo submit={VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;
                if(timeline || timeline_info_binary)submit.pNext=&values;
                submit.pCommandBuffers=&commands[0];submit.signalSemaphoreCount=1;submit.pSignalSemaphores=&semaphore;
                CHECK(vkQueueSubmit(producer,1,&submit,fences[0]));
                VkPipelineStageFlags stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
                values.signalSemaphoreValueCount=0;values.pSignalSemaphoreValues=nullptr;
                values.waitSemaphoreValueCount=1;values.pWaitSemaphoreValues=&wait_value;
                submit.pCommandBuffers=&commands[1];submit.signalSemaphoreCount=0;submit.pSignalSemaphores=nullptr;
                submit.waitSemaphoreCount=1;submit.pWaitSemaphores=&semaphore;submit.pWaitDstStageMask=&stage;
                CHECK(vkQueueSubmit(consumer,1,&submit,fences[1]));
            }
            CHECK(vkWaitForFences(device,2,fences,VK_TRUE,5000000000));
            if(export_event || import_event) {
                VkExportMetalSharedEventInfoEXT exported={VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT};exported.semaphore=semaphore;
                VkExportMetalObjectsInfoEXT objects={VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT};objects.pNext=&exported;
                vkExportMetalObjectsEXT(device,&objects);
                // This MoltenVK base can return nil for binary export. Observe
                // the known imported event directly; do not release borrowed
                // objects returned by vkExportMetalObjectsEXT.
                id<MTLSharedEvent> observed=import_event?imported:exported.mtlSharedEvent;
                if(observed) {
                    shared_event_observed=true;final_shared_value=observed.signaledValue;
                    uint64_t expected=import_event?7+round:(fresh?1:round);
                    if(final_shared_value!=expected)throw std::runtime_error("Shared event token mismatch");
                }
            }
            uint32_t actual=*reinterpret_cast<uint32_t*>(static_cast<char*>(mapped)+readback_offset);
            if(actual!=round){
                if(!mismatches){first_mismatch=round;first_actual=actual;}
                mismatches++;
                std::cerr<<"STALE round="<<round<<" actual="<<actual<<std::endl;
            }
        }
        vkDestroySemaphore(device,semaphore,nullptr);
        [imported release];
        for(unsigned i=0;i<2;i++){vkDestroyFence(device,fences[i],nullptr);vkDestroyCommandPool(device,pools[i],nullptr);}
        vkUnmapMemory(device,memory);vkDestroyBuffer(device,buffer,nullptr);vkFreeMemory(device,memory,nullptr);
        vkDestroyDevice(device,nullptr);vkDestroyInstance(instance,nullptr);dlclose(library);
        std::cout<<"RESULT {\"rounds\":"<<rounds<<",\"mismatches\":"<<mismatches
          <<",\"first_mismatch\":"<<first_mismatch<<",\"first_actual\":"<<first_actual
          <<",\"fresh_semaphores\":"<<(fresh?"true":"false")
          <<",\"submit2\":"<<(submit2?"true":"false")<<",\"timeline\":"<<(timeline?"true":"false")
          <<",\"timeline_info_binary\":"<<(timeline_info_binary?"true":"false")<<",\"same_queue\":"<<(same_queue?"true":"false")
          <<",\"export_event\":"<<(export_event?"true":"false")<<",\"import_event\":"<<(import_event?"true":"false")
          <<",\"final_shared_value\":"<<final_shared_value
          <<",\"shared_event_observed\":"<<(shared_event_observed?"true":"false")
          <<",\"scratch_words\":"<<scratch_words<<",\"synchronous\":"<<(sync?"true":"false")<<"}"<<std::endl;
        return mismatches?2:0;
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<std::endl;return 2;}
 }
}
