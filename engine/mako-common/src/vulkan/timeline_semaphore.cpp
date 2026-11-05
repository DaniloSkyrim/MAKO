/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "mako-common/vulkan/timeline_semaphore.hpp"
#include "mako-common/vulkan/timeline_relay.hpp"
#include "mako-common/helpers/errors.hpp"
#include "mako-common/helpers/file_descriptors.hpp"
#include "mako-common/helpers/pointers.hpp"
#include "mako-common/vulkan/vulkan.hpp"

#include <atomic>
#include <cstdint>
#include <iostream>
#include <memory>
#include <optional>
#include <thread>

#include <unistd.h>
#include <vulkan/vulkan_core.h>

using namespace vk;

namespace {
    /// create a timeline semaphore
    ls::owned_ptr<VkSemaphore> createTimelineSemaphore(const vk::Vulkan& vk, uint32_t initial,
            std::optional<int> importFd, std::optional<int*> exportFd) {
        const int incomingFd = importFd.value_or(-1);
        ls::FileDescriptorScope imported{{&incomingFd, 1}};
        VkSemaphore handle{};

        const VkExportSemaphoreCreateInfo exportInfo{
            .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
            .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT
        };
        const VkSemaphoreTypeCreateInfo typeInfo{
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .pNext = ( importFd.has_value() || exportFd.has_value() ) ? &exportInfo : nullptr,
            .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = initial
        };
        const VkSemaphoreCreateInfo semaphoreInfo{
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &typeInfo,
        };
        auto res = vk.df().CreateSemaphore(vk.dev(), &semaphoreInfo, VK_NULL_HANDLE, &handle);
        if (res != VK_SUCCESS)
            throw ls::vulkan_error(res, "vkCreateSemaphore() failed");

        auto semaphore = ls::owned_ptr<VkSemaphore>(
            new VkSemaphore(handle),
            [dev = vk.dev(), defunc = vk.df().DestroySemaphore](VkSemaphore& value) {
                defunc(dev, value, VK_NULL_HANDLE);
            }
        );

        if (importFd.has_value()) {
            // import semaphore from fd
            const VkImportSemaphoreFdInfoKHR importInfo{
                .sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
                .semaphore = handle,
                .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT,
                .fd = *importFd // closes the fd
            };
            res = vk.df().ImportSemaphoreFdKHR(vk.dev(), &importInfo);
            if (res != VK_SUCCESS)
                throw ls::vulkan_error(res, "vkImportSemaphoreFdKHR() failed");
            imported.release();
        }

        if (exportFd.has_value()) {
            // export semaphore to fd
            const VkSemaphoreGetFdInfoKHR getFdInfo{
                .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
                .semaphore = handle,
                .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT
            };
            int fd{};
            res = vk.df().GetSemaphoreFdKHR(vk.dev(), &getFdInfo, &fd);
            if (res != VK_SUCCESS)
                throw ls::vulkan_error(res, "vkGetSemaphoreFdKHR() failed");

            **exportFd = fd;
        }

        return semaphore;
    }
}

namespace {
    /// Whether this device can both export and import timeline semaphores as
    /// opaque descriptors. Without the query, keep the established exported path.
    bool supportsExportableTimeline(const vk::Vulkan& vk) {
        const auto query = vk.fi().GetPhysicalDeviceExternalSemaphoreProperties;
        if (!query)
            return true;
        const VkSemaphoreTypeCreateInfo typeInfo{
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = 0
        };
        const VkPhysicalDeviceExternalSemaphoreInfo info{
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO,
            .pNext = &typeInfo,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT
        };
        VkExternalSemaphoreProperties properties{
            .sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES
        };
        query(vk.physdev(), &info, &properties);
        constexpr VkExternalSemaphoreFeatureFlags required =
            VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT |
            VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT;
        return (properties.externalSemaphoreFeatures & required) == required;
    }

    /// One device's side of a vk::TimelineRelay: a private producer timeline
    /// that this device signals, a private view timeline that it waits on, and
    /// a watcher thread publishing producer progress to the relay.
    class RelayEndpoint {
    public:
        RelayEndpoint(const vk::Vulkan& vk, std::shared_ptr<TimelineRelay> relay,
                const uint32_t initial)
                : relay(std::move(relay)), device(vk.dev()),
                waitSemaphores(vk.df().WaitSemaphoresKHR),
                counterValue(vk.df().GetSemaphoreCounterValueKHR),
                signalSemaphore(vk.df().SignalSemaphoreKHR) {
            if (!this->waitSemaphores || !this->counterValue || !this->signalSemaphore)
                throw ls::vulkan_error("timeline relay requires host timeline semaphore operations");
            // The local timelines are never exported; the relay replaces the export.
            this->producerOwner = createTimelineSemaphore(vk, initial, std::nullopt, std::nullopt);
            this->viewOwner = createTimelineSemaphore(vk, initial, std::nullopt, std::nullopt);
            this->producer = *this->producerOwner;
            const VkDevice dev = this->device;
            const auto signal = this->signalSemaphore;
            const VkSemaphore view = *this->viewOwner;
            this->viewId = this->relay->attach([dev, signal, view](const uint64_t value) {
                const VkSemaphoreSignalInfo signalInfo{
                    .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
                    .semaphore = view,
                    .value = value
                };
                return signal(dev, &signalInfo) == VK_SUCCESS;
            }, initial);
            try {
                this->watcher = std::thread([this, initial]() { this->watch(initial); });
            } catch (...) {
                this->relay->detach(this->viewId);
                throw;
            }
        }

        RelayEndpoint(const RelayEndpoint&) = delete;
        RelayEndpoint& operator=(const RelayEndpoint&) = delete;

        ~RelayEndpoint() {
            this->stopping.store(true, std::memory_order_relaxed);
            if (this->watcher.joinable())
                this->watcher.join();
            // After detach the relay never signals the view again, so the
            // member semaphores can be destroyed safely afterwards.
            this->relay->detach(this->viewId);
        }

        [[nodiscard]] VkSemaphore producerHandle() const { return this->producer; }
        [[nodiscard]] VkSemaphore viewHandle() const { return *this->viewOwner; }

    private:
        void watch(uint64_t seen) {
            // The bounded wait only limits how quickly an idle endpoint stops;
            // progress is published as soon as the producer advances.
            constexpr uint64_t idleTimeoutNs = 20'000'000;
            while (!this->stopping.load(std::memory_order_relaxed)) {
                const uint64_t next = seen + 1;
                const VkSemaphoreWaitInfo waitInfo{
                    .sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                    .semaphoreCount = 1,
                    .pSemaphores = &this->producer,
                    .pValues = &next
                };
                const VkResult waited =
                    this->waitSemaphores(this->device, &waitInfo, idleTimeoutNs);
                if (waited == VK_TIMEOUT)
                    continue;
                uint64_t value = 0;
                const VkResult read = waited == VK_SUCCESS
                    ? this->counterValue(this->device, this->producer, &value) : waited;
                if (read != VK_SUCCESS) {
                    std::clog << "MAKO Renderer: frame-generation synchronization relay failed; "
                        "operation=producer-wait; result=" << read << '\n';
                    this->relay->fail();
                    return;
                }
                if (value > seen) {
                    seen = value;
                    this->relay->publish(value);
                }
            }
        }

        std::shared_ptr<TimelineRelay> relay;
        VkDevice device;
        PFN_vkWaitSemaphoresKHR waitSemaphores;
        PFN_vkGetSemaphoreCounterValueKHR counterValue;
        PFN_vkSignalSemaphoreKHR signalSemaphore;
        // Destroyed after the destructor body has joined the watcher.
        ls::owned_ptr<VkSemaphore> producerOwner;
        ls::owned_ptr<VkSemaphore> viewOwner;
        VkSemaphore producer{VK_NULL_HANDLE};
        size_t viewId{0};
        std::atomic<bool> stopping{false};
        std::thread watcher;
    };

    /// Present the endpoint's view as the TimelineSemaphore's owned handle.
    /// Destroying that handle destroys the endpoint: it joins the watcher,
    /// detaches from the relay, then destroys both private semaphores.
    ls::owned_ptr<VkSemaphore> openRelayEndpoint(const vk::Vulkan& vk,
            std::shared_ptr<TimelineRelay> relay, const uint32_t initial,
            VkSemaphore& producer) {
        auto endpoint = std::make_shared<RelayEndpoint>(vk, std::move(relay), initial);
        producer = endpoint->producerHandle();
        const VkSemaphore view = endpoint->viewHandle();
        return ls::owned_ptr<VkSemaphore>(
            new VkSemaphore(view),
            [endpoint = std::move(endpoint)](VkSemaphore&) mutable { endpoint.reset(); }
        );
    }
}

TimelineSemaphore::TimelineSemaphore(const vk::Vulkan& vk, uint32_t initial,
        std::optional<int> importFd, std::optional<int*> exportFd) {
    if (importFd.has_value()) {
        if (auto relay = importTimelineRelay(*importFd)) {
            // A relay descriptor identifies the exporter's relay and carries no
            // payload. Consume it exactly as an import would, also on failure.
            static_cast<void>(::close(*importFd));
            this->semaphore = openRelayEndpoint(vk, std::move(relay), initial, this->producer);
            return;
        }
    }
    if (exportFd.has_value() && !importFd.has_value() && !supportsExportableTimeline(vk)) {
        auto relay = std::make_shared<TimelineRelay>(initial);
        this->semaphore = openRelayEndpoint(vk, relay, initial, this->producer);
        **exportFd = exportTimelineRelay(relay);
        std::clog << "MAKO Renderer: frame-generation synchronization: transport=timeline-relay; "
            "reason=timeline-export-unsupported\n";
        return;
    }
    this->semaphore = createTimelineSemaphore(vk, initial, importFd, exportFd);
}

void TimelineSemaphore::signal(const vk::Vulkan& vk, uint64_t value) const {
    const VkSemaphoreSignalInfo signalInfo{
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
        .semaphore = this->signalHandle(),
        .value = value
    };
    auto res = vk.df().SignalSemaphoreKHR(vk.dev(), &signalInfo);
    if (res != VK_SUCCESS)
        throw ls::vulkan_error(res, "vkSignalSemaphore() failed");
}

bool TimelineSemaphore::wait(const vk::Vulkan& vk, uint64_t value, uint64_t timeout) const {
    const VkSemaphoreWaitInfo waitInfo{
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
        .semaphoreCount = 1,
        .pSemaphores = &*this->semaphore,
        .pValues = &value
    };
    auto res = vk.df().WaitSemaphoresKHR(vk.dev(), &waitInfo, timeout);
    if (res != VK_SUCCESS && res != VK_TIMEOUT)
        throw ls::vulkan_error(res, "vkWaitSemaphores() failed");

    return res == VK_SUCCESS;
}
