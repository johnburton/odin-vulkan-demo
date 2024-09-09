package main

import fmt  "core:fmt"

import glfw "vendor:glfw"
import vk   "vendor:vulkan"

FRAMES_IN_FLIGHT :: 3

window          : glfw.WindowHandle
instance        : vk.Instance
physical_device : vk.PhysicalDevice
device          : vk.Device
queue_family    : u32
queue           : vk.Queue
surface         : vk.SurfaceKHR
swapchain       : vk.SwapchainKHR

images          : [dynamic]vk.Image

swapchain_sem   : [FRAMES_IN_FLIGHT]vk.Semaphore
render_sem      : [FRAMES_IN_FLIGHT]vk.Semaphore
fence           : [FRAMES_IN_FLIGHT]vk.Fence

command_pool    : [FRAMES_IN_FLIGHT]vk.CommandPool
command_buffer  : [FRAMES_IN_FLIGHT]vk.CommandBuffer

init_main_window :: proc() {
	glfw.Init()
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	window = glfw.CreateWindow(1400, 900, "HELLO WORLD", nil, nil)
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
}

init_vulkan_instance :: proc() {

	layers := []cstring {
		"VK_LAYER_KHRONOS_validation"
	}

	extensions := glfw.GetRequiredInstanceExtensions()

	application_info: vk.ApplicationInfo
	application_info.sType = .APPLICATION_INFO
	application_info.apiVersion = vk.API_VERSION_1_3

	instance_create_info: vk.InstanceCreateInfo
	instance_create_info.sType = .INSTANCE_CREATE_INFO
	instance_create_info.pApplicationInfo = &application_info
	instance_create_info.enabledLayerCount = u32(len(layers))
	instance_create_info.ppEnabledLayerNames = raw_data(layers)
	instance_create_info.enabledExtensionCount = u32(len(extensions))
	instance_create_info.ppEnabledExtensionNames = raw_data(extensions)
	check_vk(vk.CreateInstance(&instance_create_info, nil, &instance))

	vk.load_proc_addresses(instance)
}

init_vulkan_physical_device :: proc() {
	physical_device_count: u32
	check_vk(vk.EnumeratePhysicalDevices(instance, &physical_device_count, nil))
	fmt.printf("[INFO] physical_device_count = {}\n", physical_device_count)

	physical_devices := make([]vk.PhysicalDevice, physical_device_count)
	defer delete (physical_devices)

	check_vk(vk.EnumeratePhysicalDevices(instance, &physical_device_count, raw_data(physical_devices)))

	max_score := 0
	max_score_index := 0

	for device, index in physical_devices {
		physical_device_properties: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &physical_device_properties)
		fmt.printf("[INFO] physical_device_properties[{}].deviceName = {}, deviceType = {}\n",
			index, cstring(&physical_device_properties.deviceName[0]), physical_device_properties.deviceType)
		score := 0
		if physical_device_properties.deviceType == .CPU do score += 100
		if physical_device_properties.deviceType == .INTEGRATED_GPU do score += 200
		if physical_device_properties.deviceType == .DISCRETE_GPU do score += 300

		if score > max_score {
			max_score = score
			max_score_index = index
		}
	}

	fmt.printf("[INFO] max_score_index = {}\n", max_score_index)
	physical_device = physical_devices[max_score_index]
}

init_vulkan_device :: proc() {

	features: vk.PhysicalDeviceVulkan13Features
	features.sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
	features.synchronization2 = true

	extensions := []cstring {
		vk.KHR_SWAPCHAIN_EXTENSION_NAME
	}

	queue_priority := f32(1.0)

	queue_create_info: vk.DeviceQueueCreateInfo
	queue_create_info.sType = .DEVICE_QUEUE_CREATE_INFO
	queue_create_info.queueFamilyIndex = queue_family
	queue_create_info.queueCount = 1
	queue_create_info.pQueuePriorities = &queue_priority

	device_create_info: vk.DeviceCreateInfo
	device_create_info.sType = .DEVICE_CREATE_INFO
	device_create_info.pNext = &features
	device_create_info.queueCreateInfoCount = 1
	device_create_info.pQueueCreateInfos = &queue_create_info
	device_create_info.enabledExtensionCount = u32(len(extensions))
	device_create_info.ppEnabledExtensionNames = raw_data(extensions)
	check_vk(vk.CreateDevice(physical_device, &device_create_info, nil, &device))

	vk.GetDeviceQueue(device, queue_family, 0, &queue)
}

init_vulkan_surface :: proc() {
	check_vk(glfw.CreateWindowSurface(instance, window, nil, &surface))
}

init_vulkan_swapchain :: proc() {
	swapchain_create_info: vk.SwapchainCreateInfoKHR
	swapchain_create_info.sType = .SWAPCHAIN_CREATE_INFO_KHR
	swapchain_create_info.clipped = false
	swapchain_create_info.compositeAlpha = { .OPAQUE }
	swapchain_create_info.imageArrayLayers = 1
	swapchain_create_info.imageColorSpace = .SRGB_NONLINEAR
	swapchain_create_info.imageExtent = vk.Extent2D{1400, 900}
	swapchain_create_info.imageFormat = .B8G8R8A8_UNORM
	swapchain_create_info.imageSharingMode = .EXCLUSIVE
	swapchain_create_info.imageUsage = { .COLOR_ATTACHMENT, .TRANSFER_DST }
	swapchain_create_info.minImageCount = 3
	swapchain_create_info.pQueueFamilyIndices = &queue_family
	swapchain_create_info.preTransform = { .IDENTITY }
	swapchain_create_info.presentMode = .FIFO
	swapchain_create_info.surface = surface
	vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain)

	swapchain_image_count: u32
	check_vk(vk.GetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, nil))
	fmt.printf("[INFO] swapchain_image_count = {}\n", swapchain_image_count)

	resize(&images, swapchain_image_count)
	check_vk(vk.GetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, raw_data(images)))
}

init_vulkan_sync :: proc () {
	for i := 0; i < FRAMES_IN_FLIGHT; i += 1 {
		semaphore_create_info: vk.SemaphoreCreateInfo
		semaphore_create_info.sType = .SEMAPHORE_CREATE_INFO
		check_vk(vk.CreateSemaphore(device, &semaphore_create_info, nil, &swapchain_sem[i]))
		check_vk(vk.CreateSemaphore(device, &semaphore_create_info, nil, &render_sem[i]))

		fence_create_info: vk.FenceCreateInfo
		fence_create_info.sType = .FENCE_CREATE_INFO
		fence_create_info.flags = { .SIGNALED }
		check_vk(vk.CreateFence(device, &fence_create_info, nil, &fence[i]))
	}
}


init_vulkan_cmd_buffers :: proc() {
	for i := 0; i < FRAMES_IN_FLIGHT; i += 1 {
		command_pool_create_info: vk.CommandPoolCreateInfo
		command_pool_create_info.sType = .COMMAND_POOL_CREATE_INFO
		command_pool_create_info.queueFamilyIndex = queue_family
		command_pool_create_info.flags = { .RESET_COMMAND_BUFFER }
		check_vk(vk.CreateCommandPool(device, &command_pool_create_info, nil, &command_pool[i]))

		command_buffer_create_info: vk.CommandBufferAllocateInfo
		command_buffer_create_info.sType = .COMMAND_BUFFER_ALLOCATE_INFO
		command_buffer_create_info.commandPool = command_pool[i]
		command_buffer_create_info.commandBufferCount = 1
		command_buffer_create_info.level = .PRIMARY
		check_vk(vk.AllocateCommandBuffers(device, &command_buffer_create_info, &command_buffer[i]))
	}
}


render_frame :: proc(frame: int) {

	check_vk(vk.WaitForFences(device, 1, &fence[frame], true, 1000000000))
	check_vk(vk.ResetFences(device, 1, &fence[frame]))

	image_index: u32
	check_vk(vk.AcquireNextImageKHR(device, swapchain, 1000000000, swapchain_sem[frame], {}, &image_index))

	// Initialize the command buffer
	check_vk(vk.ResetCommandBuffer(command_buffer[frame], {}))
	command_buffer_begin_info: vk.CommandBufferBeginInfo
	command_buffer_begin_info.sType = .COMMAND_BUFFER_BEGIN_INFO
	command_buffer_begin_info.flags = { .ONE_TIME_SUBMIT }
	check_vk(vk.BeginCommandBuffer(command_buffer[frame], &command_buffer_begin_info))

	// TODO:
	transition_image(command_buffer[frame], images[image_index], .UNDEFINED, .GENERAL)
	clear_image(command_buffer[frame], images[image_index])
	transition_image(command_buffer[frame], images[image_index], .GENERAL, .PRESENT_SRC_KHR)

	// End the command buffer
	check_vk(vk.EndCommandBuffer(command_buffer[frame]))

	// Submit the command buffer to the queue
	wait_semaphore_info: vk.SemaphoreSubmitInfo
	wait_semaphore_info.sType = .SEMAPHORE_SUBMIT_INFO
	wait_semaphore_info.semaphore = swapchain_sem[frame]
	wait_semaphore_info.stageMask = { .ALL_COMMANDS }

	signal_semaphore_info: vk.SemaphoreSubmitInfo
	signal_semaphore_info.sType = .SEMAPHORE_SUBMIT_INFO
	signal_semaphore_info.semaphore = render_sem[frame]
	signal_semaphore_info.stageMask = { .ALL_COMMANDS }

	command_buffer_info: vk.CommandBufferSubmitInfo
	command_buffer_info.sType = .COMMAND_BUFFER_SUBMIT_INFO
	command_buffer_info.commandBuffer = command_buffer[frame]

	submit_info: vk.SubmitInfo2
	submit_info.sType = .SUBMIT_INFO_2
	submit_info.waitSemaphoreInfoCount = 1
	submit_info.pWaitSemaphoreInfos = &wait_semaphore_info
	submit_info.signalSemaphoreInfoCount = 1
	submit_info.pSignalSemaphoreInfos = &signal_semaphore_info
	submit_info.commandBufferInfoCount = 1
	submit_info.pCommandBufferInfos = &command_buffer_info
	check_vk(vk.QueueSubmit2(queue, 1, &submit_info, fence[frame]))

	present_info : vk.PresentInfoKHR
	present_info.sType = .PRESENT_INFO_KHR
	present_info.pImageIndices = &image_index
	present_info.swapchainCount = 1
	present_info.pSwapchains = &swapchain
	present_info.waitSemaphoreCount = 1
	present_info.pWaitSemaphores = &render_sem[frame]
	check_vk(vk.QueuePresentKHR(queue, &present_info))

}

clear_image :: proc(cmd: vk.CommandBuffer, image: vk.Image) {
	range: vk.ImageSubresourceRange
	range.aspectMask = {.COLOR}
	range.layerCount = 1
	range.levelCount = 1

	clear_colour: vk.ClearColorValue
	clear_colour.float32.r = 0.6
	clear_colour.float32.g = 0.2
	clear_colour.float32.b = 0.4
	clear_colour.float32.a = 1.0
	vk.CmdClearColorImage(cmd, image, .GENERAL, &clear_colour, 1, &range)
}


transition_image :: proc(cmd: vk.CommandBuffer, image: vk.Image, from: vk.ImageLayout, to: vk.ImageLayout) {

	image_memory_barrier: vk.ImageMemoryBarrier2
	image_memory_barrier.sType = .IMAGE_MEMORY_BARRIER_2
	image_memory_barrier.srcStageMask = { .ALL_COMMANDS }
	image_memory_barrier.srcAccessMask = { .MEMORY_WRITE }
	image_memory_barrier.dstStageMask = { .ALL_COMMANDS }
	image_memory_barrier.dstAccessMask = { .MEMORY_READ, .MEMORY_WRITE }
	image_memory_barrier.oldLayout = from
	image_memory_barrier.newLayout = to
	image_memory_barrier.image = image
	image_memory_barrier.subresourceRange.aspectMask = {.COLOR}
	image_memory_barrier.subresourceRange.layerCount = vk.REMAINING_ARRAY_LAYERS
	image_memory_barrier.subresourceRange.levelCount = vk.REMAINING_MIP_LEVELS

	dependency_info: vk.DependencyInfo
	dependency_info.sType = .DEPENDENCY_INFO
	dependency_info.imageMemoryBarrierCount = 1
	dependency_info.pImageMemoryBarriers = &image_memory_barrier
	vk.CmdPipelineBarrier2(cmd, &dependency_info)
}


run_event_loop :: proc() {

	frame_count: int

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()

		render_frame(frame_count % FRAMES_IN_FLIGHT)
		frame_count += 1
	}
}

main :: proc() {
	init_main_window()
	init_vulkan_instance()
	init_vulkan_physical_device()
	init_vulkan_device()
	init_vulkan_surface()
	init_vulkan_swapchain()
	init_vulkan_sync()
	init_vulkan_cmd_buffers()
	run_event_loop()
}

check_vk :: proc(result: vk.Result, loc := #caller_location) {
	if result == .SUCCESS do return
	fmt.panicf("Vulkan error at {}: {}\n", loc, result)
}