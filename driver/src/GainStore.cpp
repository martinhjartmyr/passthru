// Per-app gain table - see GainStore.hpp for the contract.

#include "GainStore.hpp"

#include <algorithm>
#include <cmath>

namespace passthru {
namespace {

// Optional-entry lookup with type validation: an absent key is fine (*out
// stays null); a present key of the wrong type fails.
bool LookupTyped(CFDictionaryRef dict, CFStringRef key, CFTypeID type, CFTypeRef* out)
{
    *out = nullptr;
    CFTypeRef raw = nullptr;
    if (CFDictionaryGetValueIfPresent(dict, key, &raw) &&
        (!raw || CFGetTypeID(raw) != type)) {
        return false;
    }
    *out = raw;
    return true;
}

bool GetDictNumber(CFDictionaryRef dict, CFStringRef key, double* outValue)
{
    CFTypeRef raw = nullptr;
    if (!LookupTyped(dict, key, CFNumberGetTypeID(), &raw) || !raw) {
        return false;
    }
    return CFNumberGetValue(static_cast<CFNumberRef>(raw), kCFNumberDoubleType,
        outValue);
}

Float32 ClampGain(double value)
{
    if (std::isnan(value)) {
        return 1.0f;
    }
    return std::clamp(static_cast<Float32>(value), GainStore::MinGain,
        GainStore::MaxGain);
}

} // namespace

bool GainStore::SetFromPlist(CFPropertyListRef value)
{
    auto next = std::make_shared<Snapshot>();

    if (value) {
        if (CFGetTypeID(value) != CFArrayGetTypeID()) {
            return false;
        }

        CFArrayRef array = static_cast<CFArrayRef>(value);
        const CFIndex count = CFArrayGetCount(array);
        next->entries.reserve(count);

        for (CFIndex i = 0; i < count; i++) {
            CFTypeRef item = CFArrayGetValueAtIndex(array, i);
            if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) {
                return false;
            }
            CFDictionaryRef dict = static_cast<CFDictionaryRef>(item);

            AppGainEntry entry;

            CFTypeRef pidRaw = nullptr;
            if (!LookupTyped(dict, CFSTR("pid"), CFNumberGetTypeID(), &pidRaw)) {
                return false;
            }
            if (pidRaw) {
                SInt32 pid32 = 0;
                if (!CFNumberGetValue(static_cast<CFNumberRef>(pidRaw),
                        kCFNumberSInt32Type, &pid32)) {
                    return false;
                }
                entry.pid = pid32 > 0 ? static_cast<pid_t>(pid32) : 0;
            }

            CFTypeRef bundleRaw = nullptr;
            if (!LookupTyped(dict, CFSTR("bundle-id"), CFStringGetTypeID(),
                    &bundleRaw)) {
                return false;
            }
            if (bundleRaw) {
                char buffer[512];
                if (!CFStringGetCString(static_cast<CFStringRef>(bundleRaw),
                        buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
                    return false;
                }
                entry.bundleId = buffer;
            }

            double gain = 0.0;
            if (!GetDictNumber(dict, CFSTR("gain"), &gain)) {
                return false;
            }

            if (entry.pid == 0 && entry.bundleId.empty()) {
                continue; // well-formed but inert; skip
            }

            entry.gain = ClampGain(gain);
            next->entries.push_back(entry);
        }
    }

    std::atomic_store(&snapshot_,
        std::shared_ptr<const Snapshot>(std::move(next)));
    revision_.fetch_add(1, std::memory_order_relaxed);
    return true;
}

CFPropertyListRef GainStore::CopyPlist() const
{
    auto snapshot = AcquireSnapshot();

    CFMutableArrayRef array =
        CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

    if (snapshot && array) {
        for (const AppGainEntry& entry : snapshot->entries) {
            CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);

            if (dict) {
                if (entry.pid != 0) {
                    SInt32 pid32 = static_cast<SInt32>(entry.pid);
                    if (CFNumberRef num = CFNumberCreate(
                            kCFAllocatorDefault, kCFNumberSInt32Type, &pid32)) {
                        CFDictionarySetValue(dict, CFSTR("pid"), num);
                        CFRelease(num);
                    }
                }
                if (!entry.bundleId.empty()) {
                    if (CFStringRef str = CFStringCreateWithCString(
                            kCFAllocatorDefault, entry.bundleId.c_str(),
                            kCFStringEncodingUTF8)) {
                        CFDictionarySetValue(dict, CFSTR("bundle-id"), str);
                        CFRelease(str);
                    }
                }
                double gain = entry.gain;
                if (CFNumberRef num = CFNumberCreate(
                        kCFAllocatorDefault, kCFNumberDoubleType, &gain)) {
                    CFDictionarySetValue(dict, CFSTR("gain"), num);
                    CFRelease(num);
                }
                CFArrayAppendValue(array, dict);
                CFRelease(dict);
            }
        }
    }

    return array;
}

Float32 GainStore::GainFor(pid_t pid, const std::string& bundleId) const
{
    auto snapshot = AcquireSnapshot();
    if (!snapshot) {
        return 1.0f;
    }

    const AppGainEntry* bundleMatch = nullptr;

    for (const AppGainEntry& entry : snapshot->entries) {
        // Exact pid match has priority over any bundle match.
        if (entry.pid != 0 && pid > 0 && entry.pid == pid) {
            return entry.gain;
        }
        // Only pure bundle-keyed entries act as bundle fallbacks; a pid-keyed
        // entry applies exclusively to its own process.
        if (!bundleMatch && entry.pid == 0 && !entry.bundleId.empty() &&
            !bundleId.empty() && entry.bundleId == bundleId) {
            bundleMatch = &entry;
        }
    }

    return bundleMatch ? bundleMatch->gain : 1.0f;
}

size_t GainStore::EntryCount() const
{
    auto snapshot = AcquireSnapshot();
    return snapshot ? snapshot->entries.size() : 0;
}

} // namespace passthru
