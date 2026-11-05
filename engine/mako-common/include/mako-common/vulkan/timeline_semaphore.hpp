/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include "../helpers/pointers.hpp"
#include "vulkan.hpp"

#include <cstdint>
#include <optional>

#include <vulkan/vulkan_core.h>

namespace vk {
    /// vulkan timeline semaphore
    class TimelineSemaphore {
    public:
        /// create a timeline semaphore
        /// @param vk the vulkan instance
        /// @param initial initial value of the timeline semaphore
        /// Import consumes the descriptor on success and failure.
        /// @param importFd optional file descriptor to import from
        /// @param exportFd optional file descriptor to export to
        ///
        /// When the device cannot export timeline semaphores, an exporting
        /// semaphore becomes one endpoint of a process-local vk::TimelineRelay
        /// and exports that relay's descriptor instead; importing that
        /// descriptor on another device opens the second endpoint. Each relayed
        /// endpoint has separate producer and view semaphores: submissions
        /// signal signalHandle() and wait on handle(). For an ordinary
        /// semaphore both are the same handle.
        /// @throws ls::vulkan_error on failure
        TimelineSemaphore(const vk::Vulkan& vk, uint32_t initial,
            std::optional<int> importFd = std::nullopt,
            std::optional<int*> exportFd = std::nullopt);

        /// signal the timeline semaphore
        /// @param vk the vulkan instance
        /// @param value the value to signal to
        /// @throws ls::vulkan_error on failure
        void signal(const vk::Vulkan& vk, uint64_t value) const;

        /// wait for the timeline semaphore
        /// @param vk the vulkan instance
        /// @param value the value to wait for
        /// @param timeout the timeout in nanoseconds, or UINT64_MAX for no timeout
        /// @returns true if the semaphore reached the value, false if it timed out
        /// @throws ls::vulkan_error on failure
        [[nodiscard]] bool wait(const vk::Vulkan& vk,
            uint64_t value, uint64_t timeout = UINT64_MAX) const;

        /// get the VkSemaphore handle that submissions wait on
        /// @return the VkSemaphore handle
        [[nodiscard]] const auto& handle() const { return *this->semaphore; }

        /// get the VkSemaphore handle that submissions signal
        /// @return the producer handle of a relayed endpoint, otherwise handle()
        [[nodiscard]] const VkSemaphore& signalHandle() const {
            return this->producer != VK_NULL_HANDLE ? this->producer : *this->semaphore;
        }

        /// whether this endpoint synchronizes through a process-local relay
        [[nodiscard]] bool relayed() const { return this->producer != VK_NULL_HANDLE; }
    private:
        ls::owned_ptr<VkSemaphore> semaphore;
        VkSemaphore producer{VK_NULL_HANDLE};
    };
}
