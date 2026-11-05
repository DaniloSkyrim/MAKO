/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "mako-common/vulkan/timeline_relay.hpp"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <mutex>
#include <string_view>
#include <thread>
#include <vector>

#include <unistd.h>

namespace {
    void expect(const bool condition, const std::string_view message) {
        if (condition)
            return;
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }

    struct RecordedView {
        std::mutex mutex;
        std::vector<uint64_t> values;
        bool succeed{true};

        vk::TimelineRelay::ViewSignal signal() {
            return [this](const uint64_t value) {
                const std::scoped_lock lock{this->mutex};
                this->values.push_back(value);
                return this->succeed;
            };
        }
    };

    bool strictlyIncreasing(const std::vector<uint64_t>& values) {
        for (size_t index = 1; index < values.size(); ++index) {
            if (values[index] <= values[index - 1])
                return false;
        }
        return true;
    }

    void testForwardsOnlyNewMaxima() {
        vk::TimelineRelay relay{3};
        RecordedView first;
        RecordedView second;
        const auto firstId = relay.attach(first.signal(), 3);
        static_cast<void>(relay.attach(second.signal(), 3));
        expect(first.values.empty(), "a view already at the relay value must not be signalled");

        relay.publish(5);
        relay.publish(4); // a slower producer reporting an older value
        relay.publish(5);
        relay.publish(9);
        expect(first.values == std::vector<uint64_t>{5, 9},
            "views must receive each new maximum exactly once");
        expect(second.values == first.values, "every view must receive the same values");
        expect(relay.value() == 9, "the relay value must track the maximum");

        relay.detach(firstId);
        relay.publish(12);
        expect(first.values == std::vector<uint64_t>{5, 9},
            "a detached view must never be signalled again");
        expect(second.values.back() == 12, "remaining views must keep receiving values");
        expect(!relay.failed(), "successful signals must not mark failure");
    }

    void testLateViewCatchesUp() {
        vk::TimelineRelay relay;
        relay.publish(7);
        RecordedView late;
        static_cast<void>(relay.attach(late.signal(), 0));
        expect(late.values == std::vector<uint64_t>{7},
            "a late view must be brought to the current value on attach");
    }

    void testSignalFailureIsRecorded() {
        vk::TimelineRelay relay;
        RecordedView broken;
        broken.succeed = false;
        static_cast<void>(relay.attach(broken.signal(), 0));
        relay.publish(1);
        expect(relay.failed(), "a failed view signal must mark the relay failed");
    }

    void testConcurrentProducersStayMonotonic() {
        vk::TimelineRelay relay;
        RecordedView view;
        static_cast<void>(relay.attach(view.signal(), 0));
        constexpr uint64_t count = 20000;
        // Interleaved producers, as the layer and backend devices alternate values.
        std::thread even([&relay]() {
            for (uint64_t value = 2; value <= count; value += 2)
                relay.publish(value);
        });
        std::thread odd([&relay]() {
            for (uint64_t value = 1; value <= count; value += 2)
                relay.publish(value);
        });
        even.join();
        odd.join();
        expect(strictlyIncreasing(view.values), "concurrent publication must stay strictly increasing");
        expect(view.values.back() == count, "the final value must reach the view");
    }

    void testDescriptorRegistration() {
        auto relay = std::make_shared<vk::TimelineRelay>();
        const int fd = vk::exportTimelineRelay(relay);
        expect(fd >= 0, "export must return a descriptor");
        expect(vk::importTimelineRelay(fd) == relay, "import must find the exported relay");
        expect(vk::importTimelineRelay(fd) == nullptr, "a registration must be consumed once");
        static_cast<void>(::close(fd));

        int pipeFds[2]{-1, -1};
        expect(::pipe(pipeFds) == 0, "pipe creation must succeed");
        expect(vk::importTimelineRelay(pipeFds[0]) == nullptr,
            "an unrelated descriptor must not be mistaken for a relay");
        static_cast<void>(::close(pipeFds[0]));
        static_cast<void>(::close(pipeFds[1]));
        expect(vk::importTimelineRelay(-1) == nullptr, "an invalid descriptor must be rejected");

        int expiredFd = -1;
        {
            auto expired = std::make_shared<vk::TimelineRelay>();
            expiredFd = vk::exportTimelineRelay(expired);
        }
        expect(vk::importTimelineRelay(expiredFd) == nullptr,
            "a relay destroyed before import must not be resurrected");
        static_cast<void>(::close(expiredFd));
    }
}

int main() {
    testForwardsOnlyNewMaxima();
    testLateViewCatchesUp();
    testSignalFailureIsRecorded();
    testConcurrentProducersStayMonotonic();
    testDescriptorRegistration();
    std::cout << "timeline relay tests passed\n";
    return 0;
}
