#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include "vulkan14_push_spv.h"

#define TEST_BUFFER_SIZE 4096u
#define TEST_PATTERN 0xA5C3197Bu
#define RENDER_WIDTH 64u
#define RENDER_HEIGHT 64u
#define RENDER_BPP 4u
#define RENDER_BUFFER_SIZE ((VkDeviceSize)RENDER_WIDTH * RENDER_HEIGHT * RENDER_BPP)

static void print_version(const char *key, uint32_t v)
{
    printf("%s=%u.%u.%u\n", key,
           VK_API_VERSION_MAJOR(v),
           VK_API_VERSION_MINOR(v),
           VK_API_VERSION_PATCH(v));
}

static void print_memory_types(VkPhysicalDevice physical)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(physical, &mp);

    printf("memory_type_count=%u\n", mp.memoryTypeCount);
    for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
        printf("memory_type[%u].flags=0x%x\n",
               i, mp.memoryTypes[i].propertyFlags);
        printf("memory_type[%u].heap=%u\n",
               i, mp.memoryTypes[i].heapIndex);
    }
}

static int choose_memory_type(VkPhysicalDevice physical,
                              uint32_t type_bits,
                              VkMemoryPropertyFlags required,
                              VkMemoryPropertyFlags preferred,
                              uint32_t *type_index,
                              VkMemoryPropertyFlags *chosen_flags)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(physical, &mp);

    int coherent_fallback = -1;
    int visible_fallback = -1;

    /*
     * Prefer HOST_CACHED + HOST_COHERENT where the driver exposes it.
     * The stock Qualcomm driver selected flags=0xf on this device, while
     * Turnip's first matching coherent type is flags=0x7.  Prefer the
     * cached coherent type for an apples-to-apples CPU readback test.
     */
    VkMemoryPropertyFlags strongest =
        required |
        VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
        VK_MEMORY_PROPERTY_HOST_CACHED_BIT;

    for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
        if (!(type_bits & (1u << i)))
            continue;

        VkMemoryPropertyFlags flags = mp.memoryTypes[i].propertyFlags;
        if ((flags & strongest) == strongest) {
            *type_index = i;
            *chosen_flags = flags;
            return 0;
        }

        if ((flags & required) == required &&
            (flags & preferred) == preferred &&
            coherent_fallback < 0)
            coherent_fallback = (int)i;

        if ((flags & required) == required && visible_fallback < 0)
            visible_fallback = (int)i;
    }

    if (coherent_fallback >= 0) {
        *type_index = (uint32_t)coherent_fallback;
        *chosen_flags = mp.memoryTypes[coherent_fallback].propertyFlags;
        return 0;
    }

    if (visible_fallback >= 0) {
        *type_index = (uint32_t)visible_fallback;
        *chosen_flags = mp.memoryTypes[visible_fallback].propertyFlags;
        return 0;
    }

    return -1;
}

static int run_noop_submit_probe(VkDevice device,
                                 VkQueue queue,
                                 uint32_t queue_family)
{
    VkResult r;

    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family,
    };

    VkCommandPool pool = VK_NULL_HANDLE;
    r = vkCreateCommandPool(device, &cpci, NULL, &pool);
    printf("noop_vkCreateCommandPool_result=%d\n", r);
    if (r != VK_SUCCESS)
        return 70;

    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    VkCommandBuffer command = VK_NULL_HANDLE;
    r = vkAllocateCommandBuffers(device, &cbai, &command);
    printf("noop_vkAllocateCommandBuffers_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        return 71;
    }

    VkCommandBufferBeginInfo cbbi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    r = vkBeginCommandBuffer(command, &cbbi);
    printf("noop_vkBeginCommandBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        return 72;
    }

    r = vkEndCommandBuffer(command);
    printf("noop_vkEndCommandBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        return 73;
    }

    VkFenceCreateInfo fci = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };

    VkFence fence = VK_NULL_HANDLE;
    r = vkCreateFence(device, &fci, NULL, &fence);
    printf("noop_vkCreateFence_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        return 74;
    }

    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
    };

    printf("noop_before_vkQueueSubmit=1\n");
    fflush(stdout);
    r = vkQueueSubmit(queue, 1, &si, fence);
    printf("noop_vkQueueSubmit_result=%d\n", r);
    fflush(stdout);
    if (r != VK_SUCCESS) {
        vkDestroyFence(device, fence, NULL);
        vkDestroyCommandPool(device, pool, NULL);
        return 75;
    }

    printf("noop_before_vkWaitForFences=1\n");
    fflush(stdout);
    r = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL);
    printf("noop_vkWaitForFences_result=%d\n", r);
    fflush(stdout);

    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, pool, NULL);

    if (r != VK_SUCCESS)
        return 76;

    printf("noop_submit_status=PASS\n");
    fflush(stdout);
    return 0;
}

static int choose_image_memory_type(VkPhysicalDevice physical,
                                    uint32_t type_bits,
                                    uint32_t *type_index)
{
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(physical, &mp);

    int fallback = -1;
    for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
        if (!(type_bits & (1u << i)))
            continue;

        if (fallback < 0)
            fallback = (int)i;

        if (mp.memoryTypes[i].propertyFlags &
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
            *type_index = i;
            return 0;
        }
    }

    if (fallback >= 0) {
        *type_index = (uint32_t)fallback;
        return 0;
    }

    return -1;
}

static int run_offscreen_render_probe(VkPhysicalDevice physical,
                                      VkDevice device,
                                      VkQueue queue,
                                      uint32_t queue_family)
{
    VkResult r;
    int rc = 0;
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory image_memory = VK_NULL_HANDLE;
    VkImageView image_view = VK_NULL_HANDLE;
    VkBuffer readback = VK_NULL_HANDLE;
    VkDeviceMemory readback_memory = VK_NULL_HANDLE;
    void *mapped = NULL;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;

    printf("=== OFFSCREEN DYNAMIC RENDERING ===\n");
    printf("render_extent=%ux%u\n", RENDER_WIDTH, RENDER_HEIGHT);
    printf("render_format=VK_FORMAT_R8G8B8A8_UNORM\n");
    printf("render_expected_rgba=ff00ffff\n");

    VkFormatProperties fp;
    vkGetPhysicalDeviceFormatProperties(
        physical, VK_FORMAT_R8G8B8A8_UNORM, &fp);
    printf("render_optimal_tiling_features=0x%x\n",
           fp.optimalTilingFeatures);

    const VkFormatFeatureFlags required_features =
        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
        VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
    if ((fp.optimalTilingFeatures & required_features) != required_features) {
        printf("offscreen_render_error=format_features\n");
        return 80;
    }

    VkImageCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = { RENDER_WIDTH, RENDER_HEIGHT, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                 VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };

    r = vkCreateImage(device, &ici, NULL, &image);
    printf("render_vkCreateImage_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 81;
        goto cleanup;
    }

    VkMemoryRequirements image_req;
    vkGetImageMemoryRequirements(device, image, &image_req);
    printf("render_image_memory_size=%llu\n",
           (unsigned long long)image_req.size);
    printf("render_image_memory_type_bits=0x%x\n",
           image_req.memoryTypeBits);

    uint32_t image_type = 0;
    if (choose_image_memory_type(physical, image_req.memoryTypeBits,
                                 &image_type) != 0) {
        printf("render_image_memory_type=NONE\n");
        rc = 82;
        goto cleanup;
    }
    printf("render_image_memory_type=%u\n", image_type);

    VkMemoryAllocateInfo image_mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = image_req.size,
        .memoryTypeIndex = image_type,
    };
    r = vkAllocateMemory(device, &image_mai, NULL, &image_memory);
    printf("render_vkAllocateImageMemory_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 83;
        goto cleanup;
    }

    r = vkBindImageMemory(device, image, image_memory, 0);
    printf("render_vkBindImageMemory_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 84;
        goto cleanup;
    }

    VkImageViewCreateInfo ivci = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    r = vkCreateImageView(device, &ivci, NULL, &image_view);
    printf("render_vkCreateImageView_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 85;
        goto cleanup;
    }

    VkBufferCreateInfo bci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = RENDER_BUFFER_SIZE,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    r = vkCreateBuffer(device, &bci, NULL, &readback);
    printf("render_vkCreateReadbackBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 86;
        goto cleanup;
    }

    VkMemoryRequirements read_req;
    vkGetBufferMemoryRequirements(device, readback, &read_req);
    printf("render_readback_memory_size=%llu\n",
           (unsigned long long)read_req.size);
    printf("render_readback_memory_type_bits=0x%x\n",
           read_req.memoryTypeBits);

    uint32_t read_type = 0;
    VkMemoryPropertyFlags read_flags = 0;
    if (choose_memory_type(physical, read_req.memoryTypeBits,
                           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                           &read_type, &read_flags) != 0) {
        printf("render_readback_memory_type=NONE\n");
        rc = 87;
        goto cleanup;
    }
    printf("render_readback_memory_type=%u\n", read_type);
    printf("render_readback_memory_flags=0x%x\n", read_flags);

    VkMemoryAllocateInfo read_mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = read_req.size,
        .memoryTypeIndex = read_type,
    };
    r = vkAllocateMemory(device, &read_mai, NULL, &readback_memory);
    printf("render_vkAllocateReadbackMemory_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 88;
        goto cleanup;
    }

    r = vkBindBufferMemory(device, readback, readback_memory, 0);
    printf("render_vkBindReadbackMemory_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 89;
        goto cleanup;
    }

    r = vkMapMemory(device, readback_memory, 0, VK_WHOLE_SIZE, 0, &mapped);
    printf("render_vkMapReadbackMemory_result=%d\n", r);
    if (r != VK_SUCCESS || mapped == NULL) {
        rc = 90;
        goto cleanup;
    }
    memset(mapped, 0x5a, (size_t)RENDER_BUFFER_SIZE);

    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family,
    };
    r = vkCreateCommandPool(device, &cpci, NULL, &pool);
    printf("render_vkCreateCommandPool_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 91;
        goto cleanup;
    }

    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command = VK_NULL_HANDLE;
    r = vkAllocateCommandBuffers(device, &cbai, &command);
    printf("render_vkAllocateCommandBuffers_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 92;
        goto cleanup;
    }

    VkCommandBufferBeginInfo cbbi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    r = vkBeginCommandBuffer(command, &cbbi);
    printf("render_vkBeginCommandBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 93;
        goto cleanup;
    }

    VkImageMemoryBarrier to_color = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vkCmdPipelineBarrier(command,
                         VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                         0, 0, NULL, 0, NULL, 1, &to_color);

    PFN_vkCmdBeginRendering pfn_begin =
        (PFN_vkCmdBeginRendering)vkGetDeviceProcAddr(
            device, "vkCmdBeginRendering");
    PFN_vkCmdEndRendering pfn_end =
        (PFN_vkCmdEndRendering)vkGetDeviceProcAddr(
            device, "vkCmdEndRendering");
    printf("render_vkCmdBeginRendering_ptr=%s\n",
           pfn_begin ? "OK" : "NULL");
    printf("render_vkCmdEndRendering_ptr=%s\n",
           pfn_end ? "OK" : "NULL");
    if (!pfn_begin || !pfn_end) {
        rc = 94;
        goto cleanup;
    }

    VkRenderingAttachmentInfo color_attachment = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = image_view,
        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = {
            .color = { .float32 = { 1.0f, 0.0f, 1.0f, 1.0f } },
        },
    };
    VkRenderingInfo rendering = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = {
            .offset = { 0, 0 },
            .extent = { RENDER_WIDTH, RENDER_HEIGHT },
        },
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
    };

    printf("render_before_vkCmdBeginRendering=1\n");
    pfn_begin(command, &rendering);
    pfn_end(command);
    printf("render_after_vkCmdEndRendering=1\n");

    VkImageMemoryBarrier to_transfer = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    vkCmdPipelineBarrier(command,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, NULL, 0, NULL, 1, &to_transfer);

    VkBufferImageCopy copy = {
        .bufferOffset = 0,
        .bufferRowLength = 0,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { RENDER_WIDTH, RENDER_HEIGHT, 1 },
    };
    vkCmdCopyImageToBuffer(command, image,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           readback, 1, &copy);

    VkBufferMemoryBarrier to_host = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = readback,
        .offset = 0,
        .size = VK_WHOLE_SIZE,
    };
    vkCmdPipelineBarrier(command,
                         VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT,
                         0, 0, NULL, 1, &to_host, 0, NULL);

    r = vkEndCommandBuffer(command);
    printf("render_vkEndCommandBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 95;
        goto cleanup;
    }

    VkFenceCreateInfo fci = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };
    r = vkCreateFence(device, &fci, NULL, &fence);
    printf("render_vkCreateFence_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 96;
        goto cleanup;
    }

    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
    };

    printf("render_before_vkQueueSubmit=1\n");
    r = vkQueueSubmit(queue, 1, &si, fence);
    printf("render_vkQueueSubmit_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 97;
        goto cleanup;
    }

    printf("render_before_vkWaitForFences=1\n");
    r = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL);
    printf("render_vkWaitForFences_result=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 98;
        goto cleanup;
    }

    if (!(read_flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        VkMappedMemoryRange range = {
            .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = readback_memory,
            .offset = 0,
            .size = VK_WHOLE_SIZE,
        };
        r = vkInvalidateMappedMemoryRanges(device, 1, &range);
        printf("render_vkInvalidateMappedMemoryRanges_result=%d\n", r);
        if (r != VK_SUCCESS) {
            rc = 99;
            goto cleanup;
        }
    } else {
        printf("render_vkInvalidateMappedMemoryRanges_result=SKIP_COHERENT\n");
    }

    const uint8_t *pixels = (const uint8_t *)mapped;
    uint32_t mismatches = 0;
    const uint32_t pixel_count = RENDER_WIDTH * RENDER_HEIGHT;
    printf("render_first_pixel=%02x%02x%02x%02x\n",
           pixels[0], pixels[1], pixels[2], pixels[3]);

    for (uint32_t i = 0; i < pixel_count; ++i) {
        const uint8_t *p = pixels + i * 4u;
        if (p[0] != 0xff || p[1] != 0x00 ||
            p[2] != 0xff || p[3] != 0xff) {
            if (mismatches < 8) {
                printf("render_mismatch[%u]=%02x%02x%02x%02x\n",
                       i, p[0], p[1], p[2], p[3]);
            }
            ++mismatches;
        }
    }

    printf("render_verify_pixels=%u\n", pixel_count);
    printf("render_verify_mismatches=%u\n", mismatches);
    if (mismatches != 0) {
        rc = 100;
        goto cleanup;
    }

    printf("offscreen_render_status=PASS\n");

cleanup:
    if (fence != VK_NULL_HANDLE)
        vkDestroyFence(device, fence, NULL);
    if (pool != VK_NULL_HANDLE)
        vkDestroyCommandPool(device, pool, NULL);
    if (mapped != NULL)
        vkUnmapMemory(device, readback_memory);
    if (readback != VK_NULL_HANDLE)
        vkDestroyBuffer(device, readback, NULL);
    if (readback_memory != VK_NULL_HANDLE)
        vkFreeMemory(device, readback_memory, NULL);
    if (image_view != VK_NULL_HANDLE)
        vkDestroyImageView(device, image_view, NULL);
    if (image != VK_NULL_HANDLE)
        vkDestroyImage(device, image, NULL);
    if (image_memory != VK_NULL_HANDLE)
        vkFreeMemory(device, image_memory, NULL);

    if (rc != 0)
        printf("offscreen_render_status=FAIL\n");
    printf("offscreen_render_exit=%d\n", rc);
    return rc;
}


static int run_vulkan14_host_image_copy_probe(VkPhysicalDevice physical,
                                               VkDevice device)
{
    printf("=== VULKAN 1.4 HOST IMAGE COPY ===\n");

    PFN_vkTransitionImageLayout pTransitionImageLayout =
        (PFN_vkTransitionImageLayout)vkGetDeviceProcAddr(
            device, "vkTransitionImageLayout");
    PFN_vkCopyMemoryToImage pCopyMemoryToImage =
        (PFN_vkCopyMemoryToImage)vkGetDeviceProcAddr(
            device, "vkCopyMemoryToImage");
    PFN_vkCopyImageToMemory pCopyImageToMemory =
        (PFN_vkCopyImageToMemory)vkGetDeviceProcAddr(
            device, "vkCopyImageToMemory");

    printf("vulkan14_hostcopy.transition_ptr=%s\n",
           pTransitionImageLayout ? "OK" : "MISSING");
    printf("vulkan14_hostcopy.copy_in_ptr=%s\n",
           pCopyMemoryToImage ? "OK" : "MISSING");
    printf("vulkan14_hostcopy.copy_out_ptr=%s\n",
           pCopyImageToMemory ? "OK" : "MISSING");

    if (!pTransitionImageLayout || !pCopyMemoryToImage ||
        !pCopyImageToMemory) {
        printf("vulkan14_hostcopy_status=FAIL_DISPATCH\n");
        return 120;
    }

    VkPhysicalDeviceVulkan14Features f14 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
    };
    VkPhysicalDeviceFeatures2 f2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &f14,
    };
    vkGetPhysicalDeviceFeatures2(physical, &f2);
    printf("vulkan14_hostcopy.feature=%u\n", f14.hostImageCopy);
    if (!f14.hostImageCopy) {
        printf("vulkan14_hostcopy_status=SKIP_UNSUPPORTED\n");
        return 0;
    }

    VkPhysicalDeviceVulkan14Properties p14 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_PROPERTIES,
    };
    VkPhysicalDeviceProperties2 p2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = &p14,
    };
    vkGetPhysicalDeviceProperties2(physical, &p2);

    printf("vulkan14_hostcopy.src_layout_count=%u\n",
           p14.copySrcLayoutCount);
    printf("vulkan14_hostcopy.dst_layout_count=%u\n",
           p14.copyDstLayoutCount);

    if (!p14.copySrcLayoutCount || !p14.copyDstLayoutCount) {
        printf("vulkan14_hostcopy_status=FAIL_NO_LAYOUTS\n");
        return 121;
    }

    VkImageLayout *src_layouts =
        calloc(p14.copySrcLayoutCount, sizeof(*src_layouts));
    VkImageLayout *dst_layouts =
        calloc(p14.copyDstLayoutCount, sizeof(*dst_layouts));
    if (!src_layouts || !dst_layouts) {
        free(src_layouts);
        free(dst_layouts);
        return 122;
    }

    uint32_t src_cap = p14.copySrcLayoutCount;
    uint32_t dst_cap = p14.copyDstLayoutCount;
    p14.pCopySrcLayouts = src_layouts;
    p14.pCopyDstLayouts = dst_layouts;
    p14.copySrcLayoutCount = src_cap;
    p14.copyDstLayoutCount = dst_cap;
    vkGetPhysicalDeviceProperties2(physical, &p2);

    VkImageLayout src_layout = src_layouts[0];
    VkImageLayout dst_layout = dst_layouts[0];
    for (uint32_t i = 0; i < p14.copySrcLayoutCount; ++i) {
        printf("vulkan14_hostcopy.src_layout[%u]=%d\n", i, src_layouts[i]);
        if (src_layouts[i] == VK_IMAGE_LAYOUT_GENERAL)
            src_layout = VK_IMAGE_LAYOUT_GENERAL;
    }
    for (uint32_t i = 0; i < p14.copyDstLayoutCount; ++i) {
        printf("vulkan14_hostcopy.dst_layout[%u]=%d\n", i, dst_layouts[i]);
        if (dst_layouts[i] == VK_IMAGE_LAYOUT_GENERAL)
            dst_layout = VK_IMAGE_LAYOUT_GENERAL;
    }
    free(src_layouts);
    free(dst_layouts);

    printf("vulkan14_hostcopy.chosen_src_layout=%d\n", src_layout);
    printf("vulkan14_hostcopy.chosen_dst_layout=%d\n", dst_layout);

    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    int rc = 0;

    VkImageCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {4, 4, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_HOST_TRANSFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };

    VkResult r = vkCreateImage(device, &ici, NULL, &image);
    printf("vulkan14_hostcopy.vkCreateImage=%d\n", r);
    if (r != VK_SUCCESS) {
        printf("vulkan14_hostcopy_status=FAIL_CREATE_IMAGE\n");
        return 123;
    }

    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(device, image, &req);
    printf("vulkan14_hostcopy.memory_size=%llu\n",
           (unsigned long long)req.size);
    printf("vulkan14_hostcopy.memory_type_bits=0x%x\n",
           req.memoryTypeBits);

    uint32_t memory_type = 0;
    if (choose_image_memory_type(physical, req.memoryTypeBits,
                                 &memory_type) != 0) {
        printf("vulkan14_hostcopy_status=FAIL_MEMORY_TYPE\n");
        rc = 124;
        goto cleanup;
    }

    VkMemoryAllocateInfo mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type,
    };

    r = vkAllocateMemory(device, &mai, NULL, &memory);
    printf("vulkan14_hostcopy.vkAllocateMemory=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 125;
        goto cleanup;
    }

    r = vkBindImageMemory(device, image, memory, 0);
    printf("vulkan14_hostcopy.vkBindImageMemory=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 126;
        goto cleanup;
    }

    VkHostImageLayoutTransitionInfo transition = {
        .sType = VK_STRUCTURE_TYPE_HOST_IMAGE_LAYOUT_TRANSITION_INFO,
        .image = image,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = dst_layout,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    r = pTransitionImageLayout(device, 1, &transition);
    printf("vulkan14_hostcopy.transition_to_dst=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 127;
        goto cleanup;
    }

    uint8_t src[4 * 4 * 4];
    uint8_t dst[4 * 4 * 4];
    for (unsigned i = 0; i < sizeof(src); ++i)
        src[i] = (uint8_t)((i * 37u + 11u) & 0xffu);
    memset(dst, 0, sizeof(dst));

    VkMemoryToImageCopy in_region = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_TO_IMAGE_COPY,
        .pHostPointer = src,
        .memoryRowLength = 0,
        .memoryImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {4, 4, 1},
    };
    VkCopyMemoryToImageInfo in_info = {
        .sType = VK_STRUCTURE_TYPE_COPY_MEMORY_TO_IMAGE_INFO,
        .dstImage = image,
        .dstImageLayout = dst_layout,
        .regionCount = 1,
        .pRegions = &in_region,
    };

    r = pCopyMemoryToImage(device, &in_info);
    printf("vulkan14_hostcopy.copy_memory_to_image=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 128;
        goto cleanup;
    }

    if (src_layout != dst_layout) {
        transition.oldLayout = dst_layout;
        transition.newLayout = src_layout;
        r = pTransitionImageLayout(device, 1, &transition);
        printf("vulkan14_hostcopy.transition_to_src=%d\n", r);
        if (r != VK_SUCCESS) {
            rc = 129;
            goto cleanup;
        }
    } else {
        printf("vulkan14_hostcopy.transition_to_src=SKIP_SAME_LAYOUT\n");
    }

    VkImageToMemoryCopy out_region = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_TO_MEMORY_COPY,
        .pHostPointer = dst,
        .memoryRowLength = 0,
        .memoryImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = {0, 0, 0},
        .imageExtent = {4, 4, 1},
    };
    VkCopyImageToMemoryInfo out_info = {
        .sType = VK_STRUCTURE_TYPE_COPY_IMAGE_TO_MEMORY_INFO,
        .srcImage = image,
        .srcImageLayout = src_layout,
        .regionCount = 1,
        .pRegions = &out_region,
    };

    r = pCopyImageToMemory(device, &out_info);
    printf("vulkan14_hostcopy.copy_image_to_memory=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 130;
        goto cleanup;
    }

    unsigned mismatches = 0;
    for (unsigned i = 0; i < sizeof(src); ++i) {
        if (src[i] != dst[i]) {
            if (mismatches < 8)
                printf("vulkan14_hostcopy.mismatch[%u]=%u/%u\n",
                       i, src[i], dst[i]);
            mismatches++;
        }
    }

    printf("vulkan14_hostcopy.bytes=%zu\n", sizeof(src));
    printf("vulkan14_hostcopy.mismatches=%u\n", mismatches);
    if (mismatches) {
        printf("vulkan14_hostcopy_status=FAIL_COMPARE\n");
        rc = 131;
        goto cleanup;
    }

    printf("vulkan14_hostcopy_status=PASS\n");

cleanup:
    if (memory != VK_NULL_HANDLE)
        vkFreeMemory(device, memory, NULL);
    if (image != VK_NULL_HANDLE)
        vkDestroyImage(device, image, NULL);

    if (rc)
        printf("vulkan14_hostcopy_exit=%d\n", rc);
    else
        printf("vulkan14_hostcopy_exit=0\n");
    return rc;
}


static int run_vulkan14_push_descriptor_probe(VkPhysicalDevice physical,
                                              VkDevice device,
                                              VkQueue queue,
                                              uint32_t queue_family)
{
    printf("=== VULKAN 1.4 PUSH DESCRIPTOR + MAINTENANCE6 ===\n");

    PFN_vkCmdPushDescriptorSet pCmdPushDescriptorSet =
        (PFN_vkCmdPushDescriptorSet)vkGetDeviceProcAddr(
            device, "vkCmdPushDescriptorSet");
    PFN_vkCmdPushConstants2 pCmdPushConstants2 =
        (PFN_vkCmdPushConstants2)vkGetDeviceProcAddr(
            device, "vkCmdPushConstants2");

    printf("vulkan14_push.push_descriptor_ptr=%s\n",
           pCmdPushDescriptorSet ? "OK" : "MISSING");
    printf("vulkan14_push.push_constants2_ptr=%s\n",
           pCmdPushConstants2 ? "OK" : "MISSING");

    if (!pCmdPushDescriptorSet || !pCmdPushConstants2) {
        printf("vulkan14_push_status=FAIL_DISPATCH\n");
        return 140;
    }

    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkShaderModule shader = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    void *mapped = NULL;
    int rc = 0;
    VkResult r;

    VkBufferCreateInfo bci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = sizeof(uint32_t),
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    r = vkCreateBuffer(device, &bci, NULL, &buffer);
    printf("vulkan14_push.vkCreateBuffer=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 141;
        goto cleanup;
    }

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, buffer, &req);

    uint32_t memory_type = 0;
    VkMemoryPropertyFlags memory_flags = 0;
    if (choose_memory_type(physical, req.memoryTypeBits,
                           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                           &memory_type, &memory_flags) != 0) {
        printf("vulkan14_push.memory_type=NONE\n");
        rc = 142;
        goto cleanup;
    }
    printf("vulkan14_push.memory_type=%u\n", memory_type);
    printf("vulkan14_push.memory_flags=0x%x\n", memory_flags);

    VkMemoryAllocateInfo mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type,
    };
    r = vkAllocateMemory(device, &mai, NULL, &memory);
    printf("vulkan14_push.vkAllocateMemory=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 143;
        goto cleanup;
    }

    r = vkBindBufferMemory(device, buffer, memory, 0);
    printf("vulkan14_push.vkBindBufferMemory=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 144;
        goto cleanup;
    }

    r = vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped);
    printf("vulkan14_push.vkMapMemory=%d\n", r);
    if (r != VK_SUCCESS || mapped == NULL) {
        rc = 145;
        goto cleanup;
    }
    *(volatile uint32_t *)mapped = 0u;

    VkDescriptorSetLayoutBinding binding = {
        .binding = 0,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
    };
    VkDescriptorSetLayoutCreateInfo dsci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT,
        .bindingCount = 1,
        .pBindings = &binding,
    };
    r = vkCreateDescriptorSetLayout(device, &dsci, NULL, &set_layout);
    printf("vulkan14_push.vkCreateDescriptorSetLayout=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 146;
        goto cleanup;
    }

    VkPushConstantRange push_range = {
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = sizeof(uint32_t),
    };
    VkPipelineLayoutCreateInfo plci = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };
    r = vkCreatePipelineLayout(device, &plci, NULL, &pipeline_layout);
    printf("vulkan14_push.vkCreatePipelineLayout=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 147;
        goto cleanup;
    }

    VkShaderModuleCreateInfo smci = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = vulkan14_push_spv_size,
        .pCode = vulkan14_push_spv,
    };
    r = vkCreateShaderModule(device, &smci, NULL, &shader);
    printf("vulkan14_push.vkCreateShaderModule=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 148;
        goto cleanup;
    }

    VkPipelineShaderStageCreateInfo stage = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_COMPUTE_BIT,
        .module = shader,
        .pName = "main",
    };
    VkComputePipelineCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = stage,
        .layout = pipeline_layout,
    };
    r = vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &cpci,
                                 NULL, &pipeline);
    printf("vulkan14_push.vkCreateComputePipelines=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 149;
        goto cleanup;
    }

    VkCommandPoolCreateInfo pool_ci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family,
    };
    r = vkCreateCommandPool(device, &pool_ci, NULL, &pool);
    printf("vulkan14_push.vkCreateCommandPool=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 150;
        goto cleanup;
    }

    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command = VK_NULL_HANDLE;
    r = vkAllocateCommandBuffers(device, &cbai, &command);
    printf("vulkan14_push.vkAllocateCommandBuffers=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 151;
        goto cleanup;
    }

    VkCommandBufferBeginInfo cbbi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    r = vkBeginCommandBuffer(command, &cbbi);
    printf("vulkan14_push.vkBeginCommandBuffer=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 152;
        goto cleanup;
    }

    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);

    VkDescriptorBufferInfo dbi = {
        .buffer = buffer,
        .offset = 0,
        .range = sizeof(uint32_t),
    };
    VkWriteDescriptorSet write = {
        .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pBufferInfo = &dbi,
    };

    pCmdPushDescriptorSet(command,
                          VK_PIPELINE_BIND_POINT_COMPUTE,
                          pipeline_layout,
                          0,
                          1,
                          &write);
    printf("vulkan14_push.push_descriptor_recorded=1\n");

    const uint32_t expected = 0xA6191401u;
    VkPushConstantsInfo push_info = {
        .sType = VK_STRUCTURE_TYPE_PUSH_CONSTANTS_INFO,
        .layout = pipeline_layout,
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = sizeof(expected),
        .pValues = &expected,
    };
    pCmdPushConstants2(command, &push_info);
    printf("vulkan14_push.push_constants2_recorded=1\n");

    vkCmdDispatch(command, 1, 1, 1);

    VkBufferMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .offset = 0,
        .size = sizeof(uint32_t),
    };
    vkCmdPipelineBarrier(command,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT,
                         0,
                         0, NULL,
                         1, &barrier,
                         0, NULL);

    r = vkEndCommandBuffer(command);
    printf("vulkan14_push.vkEndCommandBuffer=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 153;
        goto cleanup;
    }

    VkFenceCreateInfo fci = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };
    r = vkCreateFence(device, &fci, NULL, &fence);
    printf("vulkan14_push.vkCreateFence=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 154;
        goto cleanup;
    }

    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
    };
    r = vkQueueSubmit(queue, 1, &si, fence);
    printf("vulkan14_push.vkQueueSubmit=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 155;
        goto cleanup;
    }

    r = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL);
    printf("vulkan14_push.vkWaitForFences=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 156;
        goto cleanup;
    }

    if (!(memory_flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        VkMappedMemoryRange range = {
            .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = memory,
            .offset = 0,
            .size = VK_WHOLE_SIZE,
        };
        r = vkInvalidateMappedMemoryRanges(device, 1, &range);
        printf("vulkan14_push.vkInvalidateMappedMemoryRanges=%d\n", r);
        if (r != VK_SUCCESS) {
            rc = 157;
            goto cleanup;
        }
    } else {
        printf("vulkan14_push.vkInvalidateMappedMemoryRanges=SKIP_COHERENT\n");
    }

    uint32_t actual = *(volatile uint32_t *)mapped;
    printf("vulkan14_push.expected=0x%08x\n", expected);
    printf("vulkan14_push.actual=0x%08x\n", actual);
    if (actual != expected) {
        printf("vulkan14_push_status=FAIL_COMPARE\n");
        rc = 158;
        goto cleanup;
    }

    printf("vulkan14_push_status=PASS\n");

cleanup:
    if (fence != VK_NULL_HANDLE)
        vkDestroyFence(device, fence, NULL);
    if (pool != VK_NULL_HANDLE)
        vkDestroyCommandPool(device, pool, NULL);
    if (pipeline != VK_NULL_HANDLE)
        vkDestroyPipeline(device, pipeline, NULL);
    if (shader != VK_NULL_HANDLE)
        vkDestroyShaderModule(device, shader, NULL);
    if (pipeline_layout != VK_NULL_HANDLE)
        vkDestroyPipelineLayout(device, pipeline_layout, NULL);
    if (set_layout != VK_NULL_HANDLE)
        vkDestroyDescriptorSetLayout(device, set_layout, NULL);
    if (mapped != NULL)
        vkUnmapMemory(device, memory);
    if (memory != VK_NULL_HANDLE)
        vkFreeMemory(device, memory, NULL);
    if (buffer != VK_NULL_HANDLE)
        vkDestroyBuffer(device, buffer, NULL);

    printf("vulkan14_push_exit=%d\n", rc);
    return rc;
}


static uint64_t monotonic_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t av = *(const uint64_t *)a;
    uint64_t bv = *(const uint64_t *)b;
    return (av > bv) - (av < bv);
}

static void print_timing_stats(const char *name, uint64_t *samples, uint32_t count)
{
    if (!count)
        return;

    qsort(samples, count, sizeof(samples[0]), cmp_u64);

    long double sum = 0.0;
    for (uint32_t i = 0; i < count; ++i)
        sum += samples[i];

    uint32_t p50_i = (count - 1u) * 50u / 100u;
    uint32_t p95_i = (count - 1u) * 95u / 100u;
    double mean_us = (double)(sum / count) / 1000.0;

    printf("syncfd.%s.min_us=%.3f\n", name, samples[0] / 1000.0);
    printf("syncfd.%s.p50_us=%.3f\n", name, samples[p50_i] / 1000.0);
    printf("syncfd.%s.p95_us=%.3f\n", name, samples[p95_i] / 1000.0);
    printf("syncfd.%s.max_us=%.3f\n", name, samples[count - 1u] / 1000.0);
    printf("syncfd.%s.mean_us=%.3f\n", name, mean_us);
}

static int device_has_extension(VkPhysicalDevice physical, const char *name)
{
    uint32_t count = 0;
    VkResult r = vkEnumerateDeviceExtensionProperties(physical, NULL, &count, NULL);
    if (r != VK_SUCCESS || count == 0)
        return 0;

    VkExtensionProperties *exts = calloc(count, sizeof(*exts));
    if (!exts)
        return 0;

    r = vkEnumerateDeviceExtensionProperties(physical, NULL, &count, exts);
    if (r != VK_SUCCESS) {
        free(exts);
        return 0;
    }

    int found = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (strcmp(exts[i].extensionName, name) == 0) {
            found = 1;
            break;
        }
    }

    free(exts);
    return found;
}

static int run_syncfd_profile(VkPhysicalDevice physical,
                              VkDevice device,
                              VkQueue queue,
                              uint32_t queue_family)
{
    enum {
        WARMUP = 8,
        SAMPLES = 64,
        SIZE_COUNT = 4,
        MAX_WORK_BYTES = 16 * 1024 * 1024
    };

    const VkDeviceSize work_sizes[SIZE_COUNT] = {
        256 * 1024,
        1 * 1024 * 1024,
        4 * 1024 * 1024,
        16 * 1024 * 1024,
    };

    printf("=== SYNC FD A/B WORKLOAD PROFILE ===\n");
    printf("syncfd_ab.samples=%u\n", (unsigned)SAMPLES);
    printf("syncfd_ab.warmup=%u\n", (unsigned)WARMUP);
    printf("syncfd_ab.size_count=%u\n", (unsigned)SIZE_COUNT);

    PFN_vkGetSemaphoreFdKHR pGetSemaphoreFdKHR =
        (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(
            device, "vkGetSemaphoreFdKHR");
    printf("syncfd.vkGetSemaphoreFdKHR_ptr=%s\n",
           pGetSemaphoreFdKHR ? "OK" : "MISSING");
    if (!pGetSemaphoreFdKHR) {
        printf("syncfd_status=FAIL_DISPATCH\n");
        return 160;
    }

    VkResult r;
    int rc = 0;
    VkBuffer work = VK_NULL_HANDLE;
    VkDeviceMemory work_memory = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBuffer commands[SIZE_COUNT];
    VkFence fence = VK_NULL_HANDLE;
    memset(commands, 0, sizeof(commands));

    VkBufferCreateInfo bci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = MAX_WORK_BYTES,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    r = vkCreateBuffer(device, &bci, NULL, &work);
    printf("syncfd.vkCreateWorkBuffer=%d\n", r);
    if (r != VK_SUCCESS)
        return 161;

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, work, &req);

    uint32_t memory_type = 0;
    if (choose_image_memory_type(physical, req.memoryTypeBits,
                                 &memory_type) != 0) {
        printf("syncfd.work_memory_type=NONE\n");
        rc = 162;
        goto cleanup;
    }
    printf("syncfd.work_memory_type=%u\n", memory_type);

    VkMemoryAllocateInfo mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type,
    };
    r = vkAllocateMemory(device, &mai, NULL, &work_memory);
    printf("syncfd.vkAllocateWorkMemory=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 163;
        goto cleanup;
    }

    r = vkBindBufferMemory(device, work, work_memory, 0);
    printf("syncfd.vkBindWorkMemory=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 164;
        goto cleanup;
    }

    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family,
    };
    r = vkCreateCommandPool(device, &cpci, NULL, &pool);
    printf("syncfd.vkCreateCommandPool=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 165;
        goto cleanup;
    }

    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = SIZE_COUNT,
    };
    r = vkAllocateCommandBuffers(device, &cbai, commands);
    printf("syncfd.vkAllocateCommandBuffers=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 166;
        goto cleanup;
    }

    for (uint32_t size_i = 0; size_i < SIZE_COUNT; ++size_i) {
        VkCommandBufferBeginInfo cbbi = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT,
        };
        r = vkBeginCommandBuffer(commands[size_i], &cbbi);
        if (r != VK_SUCCESS) {
            printf("syncfd.vkBeginCommandBuffer[%u]=%d\n", size_i, r);
            rc = 167;
            goto cleanup;
        }

        vkCmdFillBuffer(commands[size_i], work, 0, work_sizes[size_i],
                        0x61914021u + size_i);

        r = vkEndCommandBuffer(commands[size_i]);
        if (r != VK_SUCCESS) {
            printf("syncfd.vkEndCommandBuffer[%u]=%d\n", size_i, r);
            rc = 168;
            goto cleanup;
        }
    }
    printf("syncfd.command_buffers_ready=4\n");

    VkFenceCreateInfo fci = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };
    r = vkCreateFence(device, &fci, NULL, &fence);
    printf("syncfd.vkCreateFence=%d\n", r);
    if (r != VK_SUCCESS) {
        rc = 169;
        goto cleanup;
    }

    for (uint32_t size_i = 0; size_i < SIZE_COUNT; ++size_i) {
        uint64_t baseline_submit_ns[SAMPLES];
        uint64_t baseline_wait_ns[SAMPLES];
        uint64_t baseline_total_ns[SAMPLES];
        uint64_t sync_submit_ns[SAMPLES];
        uint64_t sync_getfd_ns[SAMPLES];
        uint64_t sync_wait_ns[SAMPLES];
        uint64_t sync_total_ns[SAMPLES];
        memset(baseline_submit_ns, 0, sizeof(baseline_submit_ns));
        memset(baseline_wait_ns, 0, sizeof(baseline_wait_ns));
        memset(baseline_total_ns, 0, sizeof(baseline_total_ns));
        memset(sync_submit_ns, 0, sizeof(sync_submit_ns));
        memset(sync_getfd_ns, 0, sizeof(sync_getfd_ns));
        memset(sync_wait_ns, 0, sizeof(sync_wait_ns));
        memset(sync_total_ns, 0, sizeof(sync_total_ns));

        uint32_t real_fd_count = 0;
        uint32_t already_signaled_count = 0;

        printf("--- SYNC FD A/B SIZE ---\n");
        printf("syncfd_ab.size_index=%u\n", size_i);
        printf("syncfd_ab.size_bytes=%llu\n",
               (unsigned long long)work_sizes[size_i]);

        for (uint32_t iter = 0;
             iter < (uint32_t)(WARMUP + SAMPLES); ++iter) {
            uint32_t sample_i = iter >= WARMUP ? iter - WARMUP : 0;

            /* A: identical GPU work with a plain fence, no sync-fd export. */
            r = vkResetFences(device, 1, &fence);
            if (r != VK_SUCCESS) {
                printf("syncfd_ab.baseline_reset[%u,%u]=%d\n",
                       size_i, iter, r);
                rc = 170;
                goto cleanup;
            }

            VkSubmitInfo baseline_submit = {
                .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .commandBufferCount = 1,
                .pCommandBuffers = &commands[size_i],
            };

            uint64_t a0 = monotonic_ns();
            r = vkQueueSubmit(queue, 1, &baseline_submit, fence);
            uint64_t a1 = monotonic_ns();
            if (r != VK_SUCCESS) {
                printf("syncfd_ab.baseline_submit[%u,%u]=%d\n",
                       size_i, iter, r);
                rc = 171;
                goto cleanup;
            }

            uint64_t a2 = monotonic_ns();
            r = vkWaitForFences(device, 1, &fence, VK_TRUE,
                                5000000000ull);
            uint64_t a3 = monotonic_ns();
            if (r != VK_SUCCESS) {
                printf("syncfd_ab.baseline_wait[%u,%u]=%d\n",
                       size_i, iter, r);
                rc = 172;
                goto cleanup;
            }

            if (iter >= WARMUP) {
                baseline_submit_ns[sample_i] = a1 - a0;
                baseline_wait_ns[sample_i] = a3 - a2;
                baseline_total_ns[sample_i] = a3 - a0;
            }

            /*
             * B: same command buffer and workload, but signal an exportable
             * semaphore and immediately export its Android sync-fd before
             * waiting for the same completion fence.
             */
            r = vkResetFences(device, 1, &fence);
            if (r != VK_SUCCESS) {
                printf("syncfd_ab.sync_reset[%u,%u]=%d\n",
                       size_i, iter, r);
                rc = 173;
                goto cleanup;
            }

            VkExportSemaphoreCreateInfo export_info = {
                .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
                .handleTypes =
                    VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
            };
            VkSemaphoreCreateInfo sci = {
                .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
                .pNext = &export_info,
            };

            VkSemaphore semaphore = VK_NULL_HANDLE;
            r = vkCreateSemaphore(device, &sci, NULL, &semaphore);
            if (r != VK_SUCCESS) {
                printf("syncfd_ab.create_semaphore[%u,%u]=%d\n",
                       size_i, iter, r);
                rc = 174;
                goto cleanup;
            }

            VkSubmitInfo sync_submit = {
                .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .commandBufferCount = 1,
                .pCommandBuffers = &commands[size_i],
                .signalSemaphoreCount = 1,
                .pSignalSemaphores = &semaphore,
            };

            uint64_t b0 = monotonic_ns();
            r = vkQueueSubmit(queue, 1, &sync_submit, fence);
            uint64_t b1 = monotonic_ns();
            if (r != VK_SUCCESS) {
                printf("syncfd_ab.sync_submit[%u,%u]=%d\n",
                       size_i, iter, r);
                vkDestroySemaphore(device, semaphore, NULL);
                rc = 175;
                goto cleanup;
            }

            VkSemaphoreGetFdInfoKHR fd_info = {
                .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
                .semaphore = semaphore,
                .handleType =
                    VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
            };

            int fd = -1;
            uint64_t b2 = monotonic_ns();
            r = pGetSemaphoreFdKHR(device, &fd_info, &fd);
            uint64_t b3 = monotonic_ns();
            if (r != VK_SUCCESS) {
                printf("syncfd_ab.get_fd[%u,%u]=%d fd=%d\n",
                       size_i, iter, r, fd);
                if (fd >= 0)
                    close(fd);
                vkWaitForFences(device, 1, &fence, VK_TRUE,
                                5000000000ull);
                vkDestroySemaphore(device, semaphore, NULL);
                rc = 176;
                goto cleanup;
            }

            uint64_t b4 = monotonic_ns();
            r = vkWaitForFences(device, 1, &fence, VK_TRUE,
                                5000000000ull);
            uint64_t b5 = monotonic_ns();

            if (iter >= WARMUP) {
                sync_submit_ns[sample_i] = b1 - b0;
                sync_getfd_ns[sample_i] = b3 - b2;
                sync_wait_ns[sample_i] = b5 - b4;
                sync_total_ns[sample_i] = b5 - b0;

                if (fd >= 0)
                    real_fd_count++;
                else
                    already_signaled_count++;
            }

            if (fd >= 0)
                close(fd);
            vkDestroySemaphore(device, semaphore, NULL);

            if (r != VK_SUCCESS) {
                printf("syncfd_ab.sync_wait[%u,%u]=%d\n",
                       size_i, iter, r);
                rc = 177;
                goto cleanup;
            }
        }

        printf("syncfd_ab.real_fd_count=%u\n", real_fd_count);
        printf("syncfd_ab.already_signaled_count=%u\n",
               already_signaled_count);
        print_timing_stats("ab_baseline_queue_submit",
                           baseline_submit_ns, SAMPLES);
        print_timing_stats("ab_baseline_fence_wait",
                           baseline_wait_ns, SAMPLES);
        print_timing_stats("ab_baseline_end_to_end",
                           baseline_total_ns, SAMPLES);
        print_timing_stats("ab_syncfd_queue_submit",
                           sync_submit_ns, SAMPLES);
        print_timing_stats("ab_syncfd_get_fd",
                           sync_getfd_ns, SAMPLES);
        print_timing_stats("ab_syncfd_post_export_wait",
                           sync_wait_ns, SAMPLES);
        print_timing_stats("ab_syncfd_end_to_end",
                           sync_total_ns, SAMPLES);

        if (real_fd_count == SAMPLES)
            printf("syncfd_ab.size_status=PASS_ALL_PENDING\n");
        else if (real_fd_count > 0)
            printf("syncfd_ab.size_status=PASS_MIXED\n");
        else
            printf("syncfd_ab.size_status=PASS_ALL_ALREADY_SIGNALED\n");
    }

    printf("syncfd_ab_status=PASS\n");
    printf("syncfd_status=PASS\n");

cleanup:
    if (fence != VK_NULL_HANDLE)
        vkDestroyFence(device, fence, NULL);
    if (pool != VK_NULL_HANDLE)
        vkDestroyCommandPool(device, pool, NULL);
    if (work_memory != VK_NULL_HANDLE)
        vkFreeMemory(device, work_memory, NULL);
    if (work != VK_NULL_HANDLE)
        vkDestroyBuffer(device, work, NULL);

    return rc;
}

static int run_submit_probe(VkPhysicalDevice physical)
{
    VkResult r;
    uint32_t queue_count = 0;
    uint32_t queue_family = UINT32_MAX;

    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_count, NULL);
    printf("queue_family_count=%u\n", queue_count);
    if (queue_count == 0)
        return 40;

    VkQueueFamilyProperties *queues = calloc(queue_count, sizeof(*queues));
    if (!queues)
        return 41;

    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_count, queues);

    for (uint32_t i = 0; i < queue_count; ++i) {
        printf("queue[%u].flags=0x%x\n", i, queues[i].queueFlags);
        printf("queue[%u].count=%u\n", i, queues[i].queueCount);

        if (queue_family == UINT32_MAX && queues[i].queueCount > 0 &&
            (queues[i].queueFlags &
             (VK_QUEUE_TRANSFER_BIT | VK_QUEUE_GRAPHICS_BIT |
              VK_QUEUE_COMPUTE_BIT)))
            queue_family = i;
    }

    free(queues);

    if (queue_family == UINT32_MAX) {
        printf("submit_queue_family=NONE\n");
        return 42;
    }

    printf("submit_queue_family=%u\n", queue_family);

    const float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };

    VkPhysicalDeviceProperties submit_props;
    vkGetPhysicalDeviceProperties(physical, &submit_props);

    VkPhysicalDeviceVulkan14Features v14_features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
    };
    VkPhysicalDeviceDynamicRenderingFeatures dynamic_rendering = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
        .pNext = &v14_features,
    };
    VkPhysicalDeviceFeatures2 features2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &dynamic_rendering,
    };
    vkGetPhysicalDeviceFeatures2(physical, &features2);

    int dynamic_rendering_supported =
        submit_props.apiVersion >= VK_API_VERSION_1_3 &&
        dynamic_rendering.dynamicRendering == VK_TRUE;
    int vulkan14_supported =
        submit_props.apiVersion >= VK_API_VERSION_1_4;

    printf("dynamic_rendering_feature=%u\n",
           dynamic_rendering.dynamicRendering);
    printf("dynamic_rendering_probe_supported=%d\n",
           dynamic_rendering_supported);
    printf("vulkan14_enable_supported=%d\n", vulkan14_supported);
    if (vulkan14_supported) {
        printf("vulkan14_enable.maintenance5=%u\n", v14_features.maintenance5);
        printf("vulkan14_enable.maintenance6=%u\n", v14_features.maintenance6);
        printf("vulkan14_enable.dynamicRenderingLocalRead=%u\n",
               v14_features.dynamicRenderingLocalRead);
        printf("vulkan14_enable.hostImageCopy=%u\n", v14_features.hostImageCopy);
        printf("vulkan14_enable.pushDescriptor=%u\n", v14_features.pushDescriptor);
        printf("vulkan14_enable.pipelineRobustness=%u\n",
               v14_features.pipelineRobustness);
    }

    int syncfd_supported =
        device_has_extension(physical, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME);
    printf("syncfd.extension_supported=%d\n", syncfd_supported);

    const char *device_extensions[1];
    uint32_t device_extension_count = 0;
    if (syncfd_supported)
        device_extensions[device_extension_count++] =
            VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME;

    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = dynamic_rendering_supported
                    ? (const void *)&dynamic_rendering
                    : (vulkan14_supported ? (const void *)&v14_features : NULL),
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledExtensionCount = device_extension_count,
        .ppEnabledExtensionNames =
            device_extension_count ? device_extensions : NULL,
    };

    VkDevice device = VK_NULL_HANDLE;
    r = vkCreateDevice(physical, &dci, NULL, &device);
    printf("vkCreateDevice_result=%d\n", r);
    if (r != VK_SUCCESS)
        return 43;

    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, queue_family, 0, &queue);
    if (queue == VK_NULL_HANDLE) {
        printf("vkGetDeviceQueue_result=NULL\n");
        vkDestroyDevice(device, NULL);
        return 44;
    }
    printf("vkGetDeviceQueue_result=OK\n");

    if (syncfd_supported) {
        int syncfd_rc = run_syncfd_profile(
            physical, device, queue, queue_family);
        if (syncfd_rc != 0) {
            vkDestroyDevice(device, NULL);
            return syncfd_rc;
        }
    } else {
        printf("syncfd_status=SKIP_UNSUPPORTED\n");
    }

    if (vulkan14_supported) {
        const char *v14_dispatch_names[] = {
            "vkCmdPushDescriptorSet",
            "vkCmdPushDescriptorSetKHR",
            "vkCmdBindIndexBuffer2",
            "vkCmdBindIndexBuffer2KHR",
            "vkGetRenderingAreaGranularity",
            "vkGetRenderingAreaGranularityKHR",
            "vkCmdBindDescriptorSets2",
            "vkCmdBindDescriptorSets2KHR",
            "vkCmdPushConstants2",
            "vkCmdPushConstants2KHR",
            "vkCopyMemoryToImage",
            "vkCopyMemoryToImageEXT",
            "vkCopyImageToMemory",
            "vkCopyImageToMemoryEXT",
            "vkTransitionImageLayout",
            "vkTransitionImageLayoutEXT",
        };
        unsigned v14_dispatch_present = 0;
        const unsigned v14_dispatch_count =
            sizeof(v14_dispatch_names) / sizeof(v14_dispatch_names[0]);

        for (unsigned i = 0; i < v14_dispatch_count; ++i) {
            PFN_vkVoidFunction fn =
                vkGetDeviceProcAddr(device, v14_dispatch_names[i]);
            printf("vulkan14_dispatch.%s=%s\n",
                   v14_dispatch_names[i], fn ? "PRESENT" : "MISSING");
            if (fn)
                v14_dispatch_present++;
        }

        printf("vulkan14_dispatch_present=%u/%u\n",
               v14_dispatch_present, v14_dispatch_count);
        printf("vulkan14_feature_enable_status=PASS\n");
    }

    if (vulkan14_supported && v14_features.hostImageCopy) {
        int hostcopy_rc =
            run_vulkan14_host_image_copy_probe(physical, device);
        if (hostcopy_rc != 0) {
            vkDestroyDevice(device, NULL);
            return hostcopy_rc;
        }
    } else {
        printf("vulkan14_hostcopy_status=SKIP_UNSUPPORTED\n");
        printf("vulkan14_hostcopy_exit=0\n");
    }

    if (vulkan14_supported &&
        v14_features.pushDescriptor &&
        v14_features.maintenance6) {
        int push_rc = run_vulkan14_push_descriptor_probe(
            physical, device, queue, queue_family);
        if (push_rc != 0) {
            vkDestroyDevice(device, NULL);
            return push_rc;
        }
    } else {
        printf("vulkan14_push_status=SKIP_UNSUPPORTED\n");
        printf("vulkan14_push_exit=0\n");
    }

    printf("=== NO-OP GPU SUBMISSION ===\n");
    fflush(stdout);
    int noop_rc = run_noop_submit_probe(device, queue, queue_family);
    printf("noop_submit_exit=%d\n", noop_rc);
    fflush(stdout);
    if (noop_rc != 0) {
        vkDestroyDevice(device, NULL);
        return noop_rc;
    }

    printf("=== BUFFER FILL GPU SUBMISSION ===\n");
    fflush(stdout);

    VkBufferCreateInfo bci = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = TEST_BUFFER_SIZE,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT |
                 VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };

    VkBuffer buffer = VK_NULL_HANDLE;
    r = vkCreateBuffer(device, &bci, NULL, &buffer);
    printf("vkCreateBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyDevice(device, NULL);
        return 45;
    }

    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, buffer, &req);
    print_memory_types(physical);
    printf("buffer_memory_size=%llu\n",
           (unsigned long long)req.size);
    printf("buffer_memory_type_bits=0x%x\n", req.memoryTypeBits);

    uint32_t memory_type = 0;
    VkMemoryPropertyFlags memory_flags = 0;
    if (choose_memory_type(physical, req.memoryTypeBits,
                           VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                           &memory_type, &memory_flags) != 0) {
        printf("host_visible_memory_type=NONE\n");
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 46;
    }

    printf("host_visible_memory_type=%u\n", memory_type);
    printf("host_visible_memory_flags=0x%x\n", memory_flags);

    VkMemoryAllocateInfo mai = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = req.size,
        .memoryTypeIndex = memory_type,
    };

    VkDeviceMemory memory = VK_NULL_HANDLE;
    r = vkAllocateMemory(device, &mai, NULL, &memory);
    printf("vkAllocateMemory_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 47;
    }

    r = vkBindBufferMemory(device, buffer, memory, 0);
    printf("vkBindBufferMemory_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 48;
    }

    /*
     * Map before submitting GPU work.  This separates mmap viability from
     * post-submit CPU readback and avoids introducing a fresh KGSL mmap only
     * after the GPU has already written the allocation.
     */
    void *mapped = NULL;
    printf("pre_submit_vkMapMemory_begin=1\n");
    r = vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped);
    printf("pre_submit_vkMapMemory_result=%d\n", r);
    printf("pre_submit_mapped_nonnull=%d\n", mapped != NULL);
    if (r != VK_SUCCESS || !mapped) {
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 59;
    }

    ((volatile uint32_t *)mapped)[0] = 0x13579BDFu;
    printf("pre_submit_cpu_sentinel_write=PASS\n");

    VkCommandPoolCreateInfo cpci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family,
    };

    VkCommandPool pool = VK_NULL_HANDLE;
    r = vkCreateCommandPool(device, &cpci, NULL, &pool);
    printf("vkCreateCommandPool_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 49;
    }

    VkCommandBufferAllocateInfo cbai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    VkCommandBuffer command = VK_NULL_HANDLE;
    r = vkAllocateCommandBuffers(device, &cbai, &command);
    printf("vkAllocateCommandBuffers_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 50;
    }

    VkCommandBufferBeginInfo cbbi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    r = vkBeginCommandBuffer(command, &cbbi);
    printf("vkBeginCommandBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 51;
    }

    vkCmdFillBuffer(command, buffer, 0, TEST_BUFFER_SIZE, TEST_PATTERN);

    r = vkEndCommandBuffer(command);
    printf("vkEndCommandBuffer_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 52;
    }

    VkFenceCreateInfo fci = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };

    VkFence fence = VK_NULL_HANDLE;
    r = vkCreateFence(device, &fci, NULL, &fence);
    printf("vkCreateFence_result=%d\n", r);
    if (r != VK_SUCCESS) {
        vkDestroyCommandPool(device, pool, NULL);
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 53;
    }

    VkSubmitInfo si = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
    };

    printf("fill_before_vkQueueSubmit=1\n");
    fflush(stdout);
    r = vkQueueSubmit(queue, 1, &si, fence);
    printf("vkQueueSubmit_result=%d\n", r);
    fflush(stdout);
    if (r != VK_SUCCESS) {
        vkDestroyFence(device, fence, NULL);
        vkDestroyCommandPool(device, pool, NULL);
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 54;
    }

    printf("fill_before_vkWaitForFences=1\n");
    fflush(stdout);
    r = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL);
    printf("vkWaitForFences_result=%d\n", r);
    fflush(stdout);
    if (r != VK_SUCCESS) {
        vkDeviceWaitIdle(device);
        vkDestroyFence(device, fence, NULL);
        vkDestroyCommandPool(device, pool, NULL);
        vkFreeMemory(device, memory, NULL);
        vkDestroyBuffer(device, buffer, NULL);
        vkDestroyDevice(device, NULL);
        return 55;
    }

    printf("post_submit_reuse_existing_mapping=1\n");
    if (!(memory_flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
        VkMappedMemoryRange range = {
            .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = memory,
            .offset = 0,
            .size = VK_WHOLE_SIZE,
        };
        r = vkInvalidateMappedMemoryRanges(device, 1, &range);
        printf("vkInvalidateMappedMemoryRanges_result=%d\n", r);
        if (r != VK_SUCCESS) {
            vkUnmapMemory(device, memory);
            vkDestroyFence(device, fence, NULL);
            vkDestroyCommandPool(device, pool, NULL);
            vkFreeMemory(device, memory, NULL);
            vkDestroyBuffer(device, buffer, NULL);
            vkDestroyDevice(device, NULL);
            return 57;
        }
    } else {
        printf("vkInvalidateMappedMemoryRanges_result=SKIP_COHERENT\n");
    }

    uint32_t mismatches = 0;
    uint32_t *words = (uint32_t *)mapped;
    const uint32_t word_count = TEST_BUFFER_SIZE / sizeof(uint32_t);

    for (uint32_t i = 0; i < word_count; ++i) {
        if (words[i] != TEST_PATTERN) {
            if (mismatches < 8)
                printf("verify_mismatch[%u]=0x%08x\n", i, words[i]);
            ++mismatches;
        }
    }

    printf("verify_pattern=0x%08x\n", TEST_PATTERN);
    printf("verify_words=%u\n", word_count);
    printf("verify_mismatches=%u\n", mismatches);

    vkUnmapMemory(device, memory);
    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkFreeMemory(device, memory, NULL);
    vkDestroyBuffer(device, buffer, NULL);

    if (mismatches != 0) {
        vkDestroyDevice(device, NULL);
        return 58;
    }

    printf("gpu_submit_status=PASS\n");

    if (dynamic_rendering_supported) {
        int render_rc = run_offscreen_render_probe(
            physical, device, queue, queue_family);
        if (render_rc != 0) {
            vkDestroyDevice(device, NULL);
            return render_rc;
        }
    } else {
        printf("offscreen_render_status=SKIP_UNSUPPORTED\n");
        printf("offscreen_render_exit=0\n");
    }

    vkDestroyDevice(device, NULL);
    return 0;
}

int main(void)
{
    /* Preserve the exact last successful milestone if Turnip hangs, crashes,
     * or the GPU resets during a submission. */
    setvbuf(stdout, NULL, _IONBF, 0);

    uint32_t loader_version = VK_API_VERSION_1_0;
    PFN_vkEnumerateInstanceVersion enumerate_instance_version =
        (PFN_vkEnumerateInstanceVersion)vkGetInstanceProcAddr(
            NULL, "vkEnumerateInstanceVersion");

    if (enumerate_instance_version) {
        VkResult vr = enumerate_instance_version(&loader_version);
        if (vr != VK_SUCCESS) {
            printf("vkEnumerateInstanceVersion_result=%d\n", vr);
            return 10;
        }
    }

    print_version("loader_instance_version", loader_version);

    uint32_t requested = loader_version < VK_API_VERSION_1_4
        ? loader_version : VK_API_VERSION_1_4;
    print_version("requested_instance_version", requested);

    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "touchGrass Turnip A619 submit probe",
        .applicationVersion = VK_MAKE_VERSION(2, 0, 0),
        .pEngineName = "touchGrass",
        .engineVersion = VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = requested,
    };

    VkInstanceCreateInfo ci = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
    };

    VkInstance instance = VK_NULL_HANDLE;
    VkResult r = vkCreateInstance(&ci, NULL, &instance);
    printf("vkCreateInstance_result=%d\n", r);
    if (r != VK_SUCCESS)
        return 20;

    uint32_t count = 0;
    r = vkEnumeratePhysicalDevices(instance, &count, NULL);
    printf("vkEnumeratePhysicalDevices_result=%d\n", r);
    printf("physical_device_count=%u\n", count);
    if (r != VK_SUCCESS || count == 0) {
        vkDestroyInstance(instance, NULL);
        return 30;
    }

    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices) {
        vkDestroyInstance(instance, NULL);
        return 31;
    }

    r = vkEnumeratePhysicalDevices(instance, &count, devices);
    if (r != VK_SUCCESS) {
        free(devices);
        vkDestroyInstance(instance, NULL);
        return 32;
    }

    for (uint32_t i = 0; i < count; ++i) {
        VkPhysicalDeviceProperties p;
        vkGetPhysicalDeviceProperties(devices[i], &p);

        printf("device[%u].name=%s\n", i, p.deviceName);
        printf("device[%u].vendor_id=0x%04x\n", i, p.vendorID);
        printf("device[%u].device_id=0x%04x\n", i, p.deviceID);
        print_version("device_api_version", p.apiVersion);
        printf("device[%u].driver_version_raw=%u\n", i, p.driverVersion);

#ifdef VK_VERSION_1_4
        if (p.apiVersion >= VK_API_VERSION_1_4) {
            VkPhysicalDeviceVulkan14Features v14_features = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_FEATURES,
            };
            VkPhysicalDeviceFeatures2 v14_features2 = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
                .pNext = &v14_features,
            };
            vkGetPhysicalDeviceFeatures2(devices[i], &v14_features2);

            VkPhysicalDeviceVulkan14Properties v14_props = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_4_PROPERTIES,
            };
            VkPhysicalDeviceProperties2 v14_props2 = {
                .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
                .pNext = &v14_props,
            };
            vkGetPhysicalDeviceProperties2(devices[i], &v14_props2);

            printf("device[%u].vulkan14_query=PASS\n", i);
            printf("device[%u].vulkan14.maintenance5=%u\n",
                   i, v14_features.maintenance5);
            printf("device[%u].vulkan14.maintenance6=%u\n",
                   i, v14_features.maintenance6);
            printf("device[%u].vulkan14.dynamicRenderingLocalRead=%u\n",
                   i, v14_features.dynamicRenderingLocalRead);
            printf("device[%u].vulkan14.hostImageCopy=%u\n",
                   i, v14_features.hostImageCopy);
            printf("device[%u].vulkan14.pushDescriptor=%u\n",
                   i, v14_features.pushDescriptor);
            printf("device[%u].vulkan14.pipelineRobustness=%u\n",
                   i, v14_features.pipelineRobustness);
            printf("device[%u].vulkan14.maxPushDescriptors=%u\n",
                   i, v14_props.maxPushDescriptors);
            printf("device[%u].vulkan14.maxVertexAttribDivisor=%u\n",
                   i, v14_props.maxVertexAttribDivisor);
            printf("device[%u].vulkan14.identicalMemoryTypeRequirements=%u\n",
                   i, v14_props.identicalMemoryTypeRequirements);
        } else {
            printf("device[%u].vulkan14_query=FAIL_API_TOO_LOW\n", i);
        }
#else
        printf("device[%u].vulkan14_query=FAIL_HEADERS_TOO_OLD\n", i);
#endif

        uint32_t ext_count = 0;
        VkResult er = vkEnumerateDeviceExtensionProperties(
            devices[i], NULL, &ext_count, NULL);
        printf("device[%u].extension_query_result=%d\n", i, er);
        printf("device[%u].extension_count=%u\n", i, ext_count);

        if (er == VK_SUCCESS && ext_count > 0) {
            VkExtensionProperties *exts =
                calloc(ext_count, sizeof(*exts));
            if (exts) {
                er = vkEnumerateDeviceExtensionProperties(
                    devices[i], NULL, &ext_count, exts);
                int has_swapchain = 0;
                int has_timeline = 0;
                int has_dynamic_rendering = 0;

                for (uint32_t j = 0;
                     er == VK_SUCCESS && j < ext_count; ++j) {
                    if (!strcmp(exts[j].extensionName,
                                VK_KHR_SWAPCHAIN_EXTENSION_NAME))
                        has_swapchain = 1;
                    if (!strcmp(exts[j].extensionName,
                                "VK_KHR_timeline_semaphore"))
                        has_timeline = 1;
                    if (!strcmp(exts[j].extensionName,
                                "VK_KHR_dynamic_rendering"))
                        has_dynamic_rendering = 1;
                }

                printf("device[%u].has_VK_KHR_swapchain=%d\n",
                       i, has_swapchain);
                printf("device[%u].has_VK_KHR_timeline_semaphore=%d\n",
                       i, has_timeline);
                printf("device[%u].has_VK_KHR_dynamic_rendering=%d\n",
                       i, has_dynamic_rendering);
                free(exts);
            }
        }
    }

    VkPhysicalDeviceProperties primary_props;
    vkGetPhysicalDeviceProperties(devices[0], &primary_props);
    if (primary_props.apiVersion < VK_API_VERSION_1_4) {
        printf("vulkan14_device_api_status=FAIL\n");
        free(devices);
        vkDestroyInstance(instance, NULL);
        return 33;
    }
    printf("vulkan14_device_api_status=PASS\n");

    printf("=== GPU COMMAND SUBMISSION ===\n");
    int submit_rc = run_submit_probe(devices[0]);
    printf("gpu_submit_exit=%d\n", submit_rc);

    free(devices);
    vkDestroyInstance(instance, NULL);

    if (submit_rc != 0) {
        printf("probe_status=FAIL\n");
        return submit_rc;
    }

    printf("probe_status=PASS\n");
    return 0;
}
