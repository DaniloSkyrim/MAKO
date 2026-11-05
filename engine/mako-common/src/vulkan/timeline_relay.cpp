/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "mako-common/vulkan/timeline_relay.hpp"
#include "mako-common/helpers/errors.hpp"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <iostream>
#include <map>
#include <string>

#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace vk;

size_t TimelineRelay::attach(ViewSignal signal, const uint64_t viewInitial) {
    const std::scoped_lock lock{this->mutex};
    const size_t id = this->nextId++;
    if (this->current > viewInitial && !signal(this->current))
        this->failure = true;
    this->views.emplace_back(id, std::move(signal));
    return id;
}

void TimelineRelay::detach(const size_t id) {
    const std::scoped_lock lock{this->mutex};
    std::erase_if(this->views, [id](const auto& view) { return view.first == id; });
}

void TimelineRelay::publish(const uint64_t value) {
    const std::scoped_lock lock{this->mutex};
    if (value <= this->current)
        return;
    this->current = value;
    this->forwardLocked(value);
}

void TimelineRelay::forwardLocked(const uint64_t value) {
    for (const auto& view : this->views) {
        if (!view.second(value) && !this->failure) {
            this->failure = true;
            std::clog << "MAKO Renderer: frame-generation synchronization relay failed; "
                "operation=view-signal; value=" << value << '\n';
        }
    }
}

void TimelineRelay::fail() {
    const std::scoped_lock lock{this->mutex};
    this->failure = true;
}

uint64_t TimelineRelay::value() const {
    const std::scoped_lock lock{this->mutex};
    return this->current;
}

bool TimelineRelay::failed() const {
    const std::scoped_lock lock{this->mutex};
    return this->failure;
}

namespace {
    using RelayKey = std::pair<dev_t, ino_t>;

    struct RelayRegistry {
        std::mutex mutex;
        std::map<RelayKey, std::weak_ptr<TimelineRelay>> relays;
    };

    RelayRegistry& registry() {
        static RelayRegistry instance;
        return instance;
    }

    bool descriptorKey(const int fd, RelayKey& key) {
        struct stat status{};
        if (::fstat(fd, &status) != 0)
            return false;
        key = {status.st_dev, status.st_ino};
        return true;
    }
}

int vk::exportTimelineRelay(const std::shared_ptr<TimelineRelay>& relay) {
    // A memfd has a unique inode for as long as any descriptor to it is open,
    // so its identity cannot collide with another live relay or with the
    // anonymous-inode descriptors used by real semaphore payloads.
    const int fd = ::memfd_create("mako-timeline-relay", MFD_CLOEXEC);
    if (fd < 0)
        throw ls::error(std::string{"memfd_create() failed for the timeline relay: "}
            + std::strerror(errno));
    RelayKey key{};
    if (!descriptorKey(fd, key)) {
        const int error = errno;
        static_cast<void>(::close(fd));
        throw ls::error(std::string{"fstat() failed for the timeline relay: "}
            + std::strerror(error));
    }
    auto& state = registry();
    const std::scoped_lock lock{state.mutex};
    std::erase_if(state.relays, [](const auto& entry) { return entry.second.expired(); });
    state.relays[key] = relay;
    return fd;
}

std::shared_ptr<TimelineRelay> vk::importTimelineRelay(const int fd) {
    RelayKey key{};
    if (fd < 0 || !descriptorKey(fd, key))
        return nullptr;
    auto& state = registry();
    const std::scoped_lock lock{state.mutex};
    const auto entry = state.relays.find(key);
    if (entry == state.relays.end())
        return nullptr;
    auto relay = entry->second.lock();
    state.relays.erase(entry);
    return relay;
}
