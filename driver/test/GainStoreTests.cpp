// Host-side logic tests for GainStore. The payloads come from the checked-in
// golden vectors in contract/lapv/ (see SCHEMA.md there).
//
// Build+run: cmake --build driver/build --target GainStoreTests && \
//            ./driver/build/GainStoreTests
// Exit code 0 = all assertions passed.

#include "../src/GainStore.hpp"

#include <CoreFoundation/CoreFoundation.h>

#include <cstdio>
#include <string>
#include <vector>

using passthru::GainStore;

#define STRINGIFY_(x) #x
#define STRINGIFY(x) STRINGIFY_(x)

namespace {

int g_failures = 0;

void Check(bool condition, const char* what)
{
    if (condition) {
        std::printf("  ok   %s\n", what);
    } else {
        g_failures++;
        std::printf("  FAIL %s\n", what);
    }
}

// Reads a fixture's raw bytes; a zero-byte file stands for the null payload
// (XML plists cannot represent CF null - see contract/lapv/SCHEMA.md).
bool ReadFixtureBytes(const char* name, CFDataRef* out)
{
    const std::string path =
        std::string(STRINGIFY(LAPV_FIXTURE_DIR)) + "/" + name;
    FILE* file = fopen(path.c_str(), "rb");
    if (!file) {
        return false;
    }
    fseek(file, 0, SEEK_END);
    const long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    std::vector<UInt8> buffer(static_cast<size_t>(size));
    if (size > 0 && fread(buffer.data(), 1, static_cast<size_t>(size), file) !=
                        static_cast<size_t>(size)) {
        fclose(file);
        return false;
    }
    fclose(file);
    *out = CFDataCreate(kCFAllocatorDefault, buffer.data(), size);
    return *out != nullptr;
}

// Parses a fixture. Returns false on I/O trouble; *isNull distinguishes the
// null-payload case from a parsed property list.
bool LoadFixture(const char* name, CFPropertyListRef* outPlist, bool* isNull)
{
    *outPlist = nullptr;
    *isNull = false;

    CFDataRef data = nullptr;
    if (!ReadFixtureBytes(name, &data)) {
        return false;
    }
    if (CFDataGetLength(data) == 0) {
        CFRelease(data);
        *isNull = true;
        return true;
    }

    CFErrorRef error = nullptr;
    CFPropertyListRef plist = CFPropertyListCreateWithData(
        kCFAllocatorDefault, data, kCFPropertyListImmutable, nullptr, &error);
    CFRelease(data);
    if (!plist) {
        if (error) {
            CFRelease(error);
        }
        return false;
    }
    *outPlist = plist;
    return true;
}

struct Fixture
{
    CFPropertyListRef plist = nullptr;
    bool isNull = false;
    bool loaded = false;

    explicit Fixture(const char* name)
    {
        loaded = LoadFixture(name, &plist, &isNull);
    }
    ~Fixture()
    {
        if (plist) {
            CFRelease(plist);
        }
    }
};

// Applies a fixture to the store exactly as a client's payload would arrive.
bool ApplyFixture(GainStore& store, const char* name, bool* accepted)
{
    Fixture fixture(name);
    if (!fixture.loaded) {
        return false;
    }
    *accepted = store.SetFromPlist(fixture.isNull ? nullptr : fixture.plist);
    return true;
}

void CheckValidFixtureResolves(const char* name, pid_t pid,
    const char* bundleId, Float32 expectedGain)
{
    GainStore store;
    bool accepted = false;
    if (!ApplyFixture(store, name, &accepted)) {
        Check(false, name);
        return;
    }
    char label[160];
    std::snprintf(label, sizeof(label), "%s: %s resolves to %.2f",
        name, accepted ? "" : "NOT ACCEPTED, ", expectedGain);
    Check(accepted && store.GainFor(pid, bundleId) == expectedGain, label);
}

// Emit(parse(F)) must be equivalent to F: serializer and parser agree on the
// same bytes every other consumer reads (semantic equality, see SCHEMA.md).
void CheckSerializerReproducesFixture(const char* name)
{
    Fixture fixture(name);
    if (!fixture.loaded || fixture.isNull) {
        Check(false, name);
        return;
    }

    GainStore store;
    store.SetFromPlist(fixture.plist);
    CFPropertyListRef emitted = store.CopyPlist();
    Check(emitted != nullptr && CFEqual(fixture.plist, emitted),
        "serializer reproduces an equivalent payload");

    GainStore reparsed;
    Check(reparsed.SetFromPlist(emitted), "emitted payload re-parse accepted");
    Check(reparsed.EntryCount() == store.EntryCount() &&
              reparsed.GainFor(1234, "com.apple.Music") ==
                  store.GainFor(1234, "com.apple.Music"),
        "re-parse keeps the table");
    if (emitted) {
        CFRelease(emitted);
    }
}

} // namespace

int main()
{
    std::printf("GainStoreTests\n");

    {
        GainStore store;
        Check(store.EntryCount() == 0, "fresh store is empty");
        Check(store.GainFor(1234, "") == 1.0f, "unity default for unknown pid");
        Check(store.GainFor(0, "com.apple.Music") == 1.0f,
            "unity default for unknown bundle");
    }

    // Golden vectors: accept paths (contract/lapv/*.plist, see SCHEMA.md).
    CheckValidFixtureResolves("single-pid-entry.plist", 1234, "", 0.25f);
    CheckValidFixtureResolves("single-pid-entry.plist", 9999,
        "com.apple.Music", 1.0f);
    CheckValidFixtureResolves("single-bundle-entry.plist", 9999,
        "com.apple.Music", 0.5f);
    CheckValidFixtureResolves("single-bundle-entry.plist", 9999,
        "com.other.app", 1.0f);
    CheckValidFixtureResolves("pid-entry-plus-bundle-fallback.plist", 1234,
        "com.apple.Music", 0.25f);
    CheckValidFixtureResolves("pid-entry-plus-bundle-fallback.plist", 4321,
        "com.apple.Music", 0.75f);
    CheckValidFixtureResolves("pid-entry-plus-bundle-fallback.plist", 4321,
        "com.other.app", 1.0f);

    {
        GainStore store;
        bool accepted = false;
        Check(ApplyFixture(store, "gain-clamp-boundaries.plist", &accepted) &&
                  accepted,
            "clamp-boundary fixture accepted");
        Check(store.GainFor(111, "") == GainStore::MinGain,
            "boundary gain stays at min (0.0)");
        Check(store.GainFor(222, "") == GainStore::MaxGain,
            "boundary gain stays at max (4.0)");
    }

    // Serializer round-trips over the whole valid set.
    CheckSerializerReproducesFixture("empty-table.plist");
    CheckSerializerReproducesFixture("single-pid-entry.plist");
    CheckSerializerReproducesFixture("single-bundle-entry.plist");
    CheckSerializerReproducesFixture("pid-entry-plus-bundle-fallback.plist");
    CheckSerializerReproducesFixture("gain-clamp-boundaries.plist");

    {
        // Null payload means clear-the-table (zero-byte fixture).
        GainStore store;
        bool accepted = false;
        Check(ApplyFixture(store, "single-bundle-entry.plist", &accepted) &&
                  accepted && store.EntryCount() == 1,
            "pre-load before null-clear");
        Check(ApplyFixture(store, "null-clears-table.plist", &accepted) &&
                  accepted,
            "null payload accepted");
        Check(store.EntryCount() == 0 && store.GainFor(9999, "") == 1.0f,
            "null payload clears the table");
    }

    {
        GainStore store;
        bool accepted = false;
        Check(ApplyFixture(store, "empty-table.plist", &accepted) && accepted,
            "empty array accepted");
        Check(store.EntryCount() == 0, "empty array leaves table empty");
    }

    // Golden vectors: reject paths leave the previous table intact.
    {
        GainStore store;
        UInt64 revisionBefore = 0;
        bool accepted = false;

        Check(ApplyFixture(store, "single-pid-entry.plist", &accepted) &&
                  accepted,
            "pre-load before invalid payloads");
        revisionBefore = store.Revision();

        const char* invalid[] = {"invalid-non-array-root.plist",
            "invalid-non-dict-element.plist", "invalid-non-numeric-gain.plist",
            "invalid-boolean-gain.plist"};
        for (const char* name : invalid) {
            char label[128];
            std::snprintf(label, sizeof(label), "%s rejected", name);
            if (!ApplyFixture(store, name, &accepted)) {
                Check(false, label);
                continue;
            }
            std::snprintf(label, sizeof(label), "%s rejected", name);
            Check(!accepted, label);
        }

        Check(store.EntryCount() == 1 && store.GainFor(1234, "") == 0.25f,
            "rejected updates leave previous table intact");
        Check(store.Revision() == revisionBefore,
            "rejected updates do not bump revision");
    }

    if (g_failures == 0) {
        std::printf("ALL PASS\n");
        return 0;
    }
    std::printf("%d FAILURE(S)\n", g_failures);
    return 1;
}
