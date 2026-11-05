/* SPDX-License-Identifier: GPL-3.0-or-later */

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

namespace vk {
    /// One logical timeline shared by two Vulkan devices of this process when
    /// the driver cannot export timeline semaphores (for example Turnip on
    /// Android KGSL, which exports only binary SYNC_FD semaphores).
    ///
    /// Each device signals its own private producer timeline and waits on a
    /// private view timeline. Producer watchers publish every value they
    /// observe; the relay forwards each new maximum to every attached view.
    /// The relay is the only writer of the views, so view values only ever
    /// increase. A view value v therefore means that some producer reached at
    /// least v. Because a shared timeline already requires its signals to
    /// execute in increasing value order, that is exactly the guarantee the
    /// exported semaphore provided.
    class TimelineRelay {
    public:
        /// Forward a value to one view. Returns false when the signal failed.
        using ViewSignal = std::function<bool(uint64_t)>;

        explicit TimelineRelay(uint64_t initial = 0) : current(initial) {}

        TimelineRelay(const TimelineRelay&) = delete;
        TimelineRelay& operator=(const TimelineRelay&) = delete;

        /// Register a view and bring it to the current value when that is
        /// above `viewInitial`. Returns the id passed to detach().
        size_t attach(ViewSignal signal, uint64_t viewInitial);

        /// Stop forwarding to a view. After return the view is never
        /// signalled again, so its owner may destroy it.
        void detach(size_t id);

        /// Record that a producer reached `value`; forwards a new maximum.
        void publish(uint64_t value);

        /// Record a failure that leaves the relay unable to progress.
        void fail();

        [[nodiscard]] uint64_t value() const;
        [[nodiscard]] bool failed() const;

    private:
        void forwardLocked(uint64_t value);

        mutable std::mutex mutex;
        uint64_t current;
        bool failure{false};
        size_t nextId{0};
        std::vector<std::pair<size_t, ViewSignal>> views;
    };

    /// Hand a relay to the importing device as an owned descriptor, in place
    /// of an exported semaphore descriptor. The descriptor carries no payload;
    /// it identifies the registration within this process only.
    /// @throws ls::error when no descriptor can be created
    [[nodiscard]] int exportTimelineRelay(const std::shared_ptr<TimelineRelay>& relay);

    /// Return the relay registered for `fd` and consume that registration, or
    /// nullptr when `fd` is not a relay descriptor. Never closes `fd`.
    [[nodiscard]] std::shared_ptr<TimelineRelay> importTimelineRelay(int fd);
}
